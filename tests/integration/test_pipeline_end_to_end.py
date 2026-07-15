"""Test d'intégration : chaîne complète source -> modèle applicatif -> domaine
-> produit (documentation §12.2), exécutée sur le jeu synthétique versionné.
"""

import csv
import json
from datetime import date
from pathlib import Path

import pytest

from yoda.config import Settings
from yoda.metadata import RunStatus
from yoda.pipeline import run_pipeline

REPO_ROOT = Path(__file__).resolve().parents[2]
SAMPLE_FILE = REPO_ROOT / "data" / "samples" / "impulse_contracts_20260713.csv"
BUSINESS_DATE = date(2026, 7, 13)


@pytest.fixture
def settings(tmp_path):
    return Settings(
        environment="dev",
        datasets={},
        local={
            "output_dir": str(tmp_path / "output"),
            "referential_products": str(
                REPO_ROOT / "data" / "samples" / "referential_products.csv"
            ),
        },
        quality={"freshness_sla_hours": 24, "max_reject_ratio": 0.30},
    )


def read_layer(path: Path) -> list[dict]:
    with open(path, encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle, delimiter=";"))


def test_full_pipeline_on_sample_data(settings, tmp_path):
    meta = run_pipeline(settings, BUSINESS_DATE, SAMPLE_FILE)
    output = Path(settings.local["output_dir"])

    # Le lot contient des anomalies volontaires : succès partiel attendu
    assert meta.status is RunStatus.PARTIAL
    assert meta.input_rows == 12

    # 3 rejets attendus : customer_id vide, produit hors référentiel, dates incohérentes
    rejects_file = f"rejects_contracts_active_daily_{meta.batch_id}.csv"
    rejects = read_layer(output / "ops" / "rejects" / rejects_file)
    codes = sorted(r["rule_code"] for r in rejects)
    assert codes == ["ENT_001_UNKNOWN_PRODUCT", "STG_001_MISSING_FIELD", "STG_004_DATE_ORDER"]
    assert meta.reject_rows == 3

    # Toutes les couches sont matérialisées
    assert (output / "app_impulse" / "raw_contracts_2026-07-13.csv").exists()
    assert (output / "app_impulse" / "stg_contracts_clean_2026-07-13.csv").exists()
    assert (output / "enterprise_contract" / "contracts_2026-07-13.csv").exists()

    # Produit Data : 8 contrats après nettoyage et déduplication (12 - 3 rejets - 1 doublon)
    snapshot = read_layer(output / "product_contract" / "active_contracts_daily_2026-07-13.csv")
    assert len(snapshot) == 8
    assert meta.output_rows == 8

    by_id = {r["contract_id"]: r for r in snapshot}

    # Contrat nominal actif
    assert by_id["CTR-000001"]["is_active"] == "True"
    # Résilié avant le snapshot : inactif
    assert by_id["CTR-000003"]["is_active"] == "False"
    # Suspendu : non compté comme actif
    assert by_id["CTR-000004"]["is_active"] == "False"
    # Date d'effet future : pas encore actif
    assert by_id["CTR-000005"]["is_active"] == "False"
    # Réémis puis résilié au 2026-07-01 : la déduplication garde le dernier événement
    assert by_id["CTR-000006"]["contract_status"] == "TERMINATED"
    assert by_id["CTR-000006"]["is_active"] == "False"
    # Prime au format virgule française correctement typée
    assert by_id["CTR-000011"]["annual_premium"] == "95.50"

    # 4 contrats actifs au 13/07/2026
    assert sum(1 for r in snapshot if r["is_active"] == "True") == 4

    # Journal d'exécution persisté avec les volumes
    runs = list((output / "ops" / "runs").glob("run_*.json"))
    assert len(runs) == 1
    run_record = json.loads(runs[0].read_text(encoding="utf-8"))
    assert run_record["status"] == "PARTIAL"
    assert run_record["input_rows"] == 12
    assert run_record["output_rows"] == 8
    assert run_record["reject_rows"] == 3


def test_rerun_is_idempotent(settings):
    """Relancer le même lot ne duplique rien : mêmes volumes en sortie (§11.1)."""
    first = run_pipeline(settings, BUSINESS_DATE, SAMPLE_FILE)
    second = run_pipeline(settings, BUSINESS_DATE, SAMPLE_FILE)

    assert first.batch_id == second.batch_id  # batch_id déterministe
    assert second.status is RunStatus.PARTIAL
    assert second.output_rows == first.output_rows == 8

    output = Path(settings.local["output_dir"])
    snapshot = read_layer(output / "product_contract" / "active_contracts_daily_2026-07-13.csv")
    assert len(snapshot) == 8


def test_missing_source_file_fails_cleanly(settings, tmp_path):
    """Fichier absent : échec contrôlé, journalisé, sans publication partielle."""
    meta = run_pipeline(settings, BUSINESS_DATE, tmp_path / "absent.csv")
    assert meta.status is RunStatus.FAILED
    assert meta.error_code == "ING_001_MISSING"
    output = Path(settings.local["output_dir"])
    assert not (output / "product_contract" / "active_contracts_daily_2026-07-13.csv").exists()
