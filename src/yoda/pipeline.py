"""Exécution locale de bout en bout du pipeline « Contrats actifs ».

Ce module rejoue la même séquence que le DAG Composer, mais sur fichiers CSV
locaux — utile pour le développement, les tests d'intégration et la
démonstration du pattern sans accès GCP.

Usage :
    python -m yoda.pipeline --env dev --business-date 2026-07-13 \
        --source-file data/samples/impulse_contracts_20260713.csv
"""

from __future__ import annotations

import argparse
import csv
import logging
import sys
from datetime import date, datetime, timezone
from pathlib import Path

from yoda.config import Settings, load_settings
from yoda.ingestion import IngestionError, check_file, read_csv_rows
from yoda.metadata import RunMetadata, RunStatus, make_batch_id
from yoda.quality import (
    QualityReport,
    Severity,
    check_allowed_values,
    check_freshness,
    check_not_null,
    check_rule,
    check_unique,
)
from yoda.rejects import RejectStore
from yoda.transformations.contracts import (
    ALLOWED_STATUSES,
    REQUIRED_FIELDS,
    build_active_contracts_daily,
    build_enterprise_contracts,
    clean_contracts,
)

logger = logging.getLogger("yoda.pipeline")

PIPELINE_NAME = "contracts_active_daily"
EXPECTED_COLUMNS = list(REQUIRED_FIELDS) + ["end_date", "annual_premium", "channel_code"]


def _write_layer(rows: list[dict], path: Path) -> None:
    """Écriture idempotente d'une couche : la partition du lot est écrasée."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    with open(path, "w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(rows[0].keys()), delimiter=";")
        writer.writeheader()
        writer.writerows(rows)


def _load_product_referential(path: Path) -> set[str]:
    with open(path, encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter=";")
        return {row["product_code"].strip().upper() for row in reader}


def run_quality_checks(
    snapshot: list[dict],
    referential: set[str],
    settings: Settings,
    business_date: date,
) -> QualityReport:
    """Tests attendus sur le produit Data (documentation §9.6)."""
    rows = [
        {**r, "snapshot_date": str(r["snapshot_date"])} for r in snapshot
    ]
    return QualityReport(
        results=[
            check_not_null(rows, "contract_id", Severity.CRITICAL),
            check_unique(rows, ["contract_id", "snapshot_date"], Severity.CRITICAL),
            check_rule(
                rows,
                "start_date_before_end_date",
                "cohérence",
                lambda r: r["end_date"] is None or r["start_date"] <= r["end_date"],
                Severity.HIGH,
            ),
            check_rule(
                rows,
                "annual_premium_positive",
                "validité",
                lambda r: r["annual_premium"] >= 0,
                Severity.HIGH,
            ),
            check_allowed_values(rows, "product_code", referential, Severity.HIGH),
            check_allowed_values(rows, "contract_status", ALLOWED_STATUSES, Severity.HIGH),
            check_freshness(
                loaded_at=datetime.now(timezone.utc),
                business_date=business_date,
                sla_hours=int(settings.quality.get("freshness_sla_hours", 24)),
                severity=Severity.MEDIUM,
            ),
        ]
    )


def run_pipeline(settings: Settings, business_date: date, source_file: Path) -> RunMetadata:
    output_dir = Path(settings.local["output_dir"])
    business_date_str = business_date.isoformat()
    batch_id = make_batch_id("impulse", business_date_str, str(source_file))
    meta = RunMetadata(
        pipeline_name=PIPELINE_NAME,
        source_name="impulse",
        source_file=str(source_file),
        business_date=business_date_str,
        batch_id=batch_id,
    )
    rejects = RejectStore(PIPELINE_NAME, batch_id)

    try:
        # 1. Contrôles d'ingestion (porte d'entrée)
        check = check_file(
            source_file,
            expected_columns=EXPECTED_COLUMNS,
            ledger_path=output_dir / "ops" / "ingestion_ledger.json",
        )
        if check.duplicate_of_batch:
            logger.warning(
                "Lot déjà chargé (checksum identique à %s) — relance idempotente.",
                check.duplicate_of_batch,
            )
        logger.info(
            "Ingestion OK: %s lignes, sha256=%s", check.row_count, check.checksum_sha256[:12]
        )

        # 2. Modèle applicatif : conservation brute avec contexte d'origine
        raw_rows = read_csv_rows(source_file)
        meta.input_rows = len(raw_rows)
        raw_with_context = [
            {**row, "ingestion_batch_id": batch_id, "source_file": source_file.name}
            for row in raw_rows
        ]
        _write_layer(
            raw_with_context,
            output_dir / "app_impulse" / f"raw_contracts_{business_date_str}.csv",
        )

        # 3. Staging : nettoyage technique + rejets
        stg_rows = clean_contracts(raw_rows, rejects)
        _write_layer(
            [{**r} for r in stg_rows],
            output_dir / "app_impulse" / f"stg_contracts_clean_{business_date_str}.csv",
        )

        # 4. Modèle d'entreprise : normalisation, déduplication, référentiels
        referential = _load_product_referential(Path(settings.local["referential_products"]))
        enterprise_rows = build_enterprise_contracts(stg_rows, referential, rejects)
        _write_layer(
            enterprise_rows,
            output_dir / "enterprise_contract" / f"contracts_{business_date_str}.csv",
        )

        # 5. Produit Data : snapshot quotidien avec règle d'activité
        snapshot = build_active_contracts_daily(enterprise_rows, business_date, batch_id)
        meta.output_rows = len(snapshot)
        meta.reject_rows = len(rejects)

        # 6. Tests qualité — la publication dépend des sévérités (§12.3)
        report = run_quality_checks(snapshot, referential, settings, business_date)
        logger.info("Rapport qualité:\n%s", report.summary())

        reject_ratio = meta.reject_rows / meta.input_rows if meta.input_rows else 0.0
        max_reject_ratio = float(settings.quality.get("max_reject_ratio", 0.05))
        if reject_ratio > max_reject_ratio:
            raise RuntimeError(
                f"Taux de rejet {reject_ratio:.1%} > seuil {max_reject_ratio:.1%} "
                "— publication bloquée"
            )
        if not report.publishable:
            failing = ", ".join(r.check_name for r in report.blocking_failures)
            raise RuntimeError(f"Anomalies qualité bloquantes: {failing}")

        # 7. Publication (exposition) — uniquement si la qualité est garantie
        _write_layer(
            snapshot,
            output_dir / "product_contract" / f"active_contracts_daily_{business_date_str}.csv",
        )
        active_count = sum(1 for r in snapshot if r["is_active"])
        logger.info(
            "Publication OK: %s contrats dont %s actifs au %s (rejets: %s)",
            len(snapshot), active_count, business_date_str, meta.reject_rows,
        )
        meta.finish(RunStatus.SUCCESS if not rejects.rejects else RunStatus.PARTIAL)

    except (IngestionError, RuntimeError) as exc:
        code = exc.code if isinstance(exc, IngestionError) else "PIPELINE_BLOCKED"
        meta.reject_rows = len(rejects)
        meta.finish(RunStatus.FAILED, error_code=code, error_message=str(exc))
        logger.error("Échec du pipeline: %s", exc)

    finally:
        # 8. Traçabilité : rejets + journal d'exécution, même en cas d'échec
        rejects.write_csv(output_dir / "ops" / "rejects")
        run_path = meta.write_json(output_dir / "ops" / "runs")
        logger.info("Journal d'exécution: %s (statut %s)", run_path, meta.status.value)

    return meta


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Pipeline YODA - Contrats actifs (démo locale)")
    parser.add_argument("--env", default="dev", choices=["dev", "preprod", "prod"])
    parser.add_argument("--business-date", required=True, help="Date métier YYYY-MM-DD")
    parser.add_argument("--source-file", required=True, help="Fichier contrats Impulse (CSV ;)")
    args = parser.parse_args(argv)

    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s - %(message)s"
    )
    settings = load_settings(args.env)
    meta = run_pipeline(
        settings,
        business_date=date.fromisoformat(args.business_date),
        source_file=Path(args.source_file),
    )
    return 0 if meta.status in (RunStatus.SUCCESS, RunStatus.PARTIAL) else 1


if __name__ == "__main__":
    sys.exit(main())
