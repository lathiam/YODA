"""Domaine Contrat — transformations du cas d'usage « Contrats actifs » (doc §9).

Chaîne implémentée :
  app_impulse.raw_contracts
      -> stg_contracts_clean        (nettoyage technique + rejets)
      -> enterprise_contract.contracts  (normalisation, déduplication, référentiels)
      -> product_contract.active_contracts_daily (règle d'activité + snapshot)

Les règles métier sont formalisées ici (et dans sql/) : définition du contrat
actif, choix de la date d'effet, gestion des doublons/réémissions, devise.
"""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal, InvalidOperation

from yoda.rejects import RejectStore

# Statuts source Impulse -> statut métier harmonisé (règle validée avec le métier)
STATUS_MAPPING = {
    "EN_COURS": "ACTIVE",
    "ACTIF": "ACTIVE",
    "SUSPENDU": "SUSPENDED",
    "RESILIE": "TERMINATED",
    "ANNULE": "CANCELLED",
}
ALLOWED_STATUSES = set(STATUS_MAPPING.values())

REQUIRED_FIELDS = ("contract_id", "customer_id", "product_code", "status", "start_date")


def _parse_date(value: str) -> date | None:
    if not value:
        return None
    for fmt in ("%Y-%m-%d", "%d/%m/%Y"):
        try:
            return datetime.strptime(value.strip(), fmt).date()
        except ValueError:
            continue
    raise ValueError(f"format de date non reconnu: {value!r}")


def clean_contracts(raw_rows: list[dict], rejects: RejectStore) -> list[dict]:
    """raw_contracts -> stg_contracts_clean.

    Nettoyage technique : champs obligatoires, typage des dates et montants,
    harmonisation des statuts. Toute ligne invalide part en rejet avec un
    motif exploitable — jamais de perte silencieuse.
    """
    clean: list[dict] = []
    for row in raw_rows:
        missing = [f for f in REQUIRED_FIELDS if not (row.get(f) or "").strip()]
        if missing:
            rejects.add(row, "STG_001_MISSING_FIELD", f"champs vides: {', '.join(missing)}")
            continue

        raw_status = row["status"].strip().upper()
        status = STATUS_MAPPING.get(raw_status)
        if status is None:
            rejects.add(row, "STG_002_UNKNOWN_STATUS", f"statut source inconnu: {raw_status}")
            continue

        try:
            start_date = _parse_date(row["start_date"])
            end_date = _parse_date(row.get("end_date", ""))
        except ValueError as exc:
            rejects.add(row, "STG_003_BAD_DATE", str(exc))
            continue

        if end_date is not None and start_date is not None and end_date < start_date:
            rejects.add(
                row, "STG_004_DATE_ORDER",
                f"end_date {end_date} antérieure à start_date {start_date}",
            )
            continue

        try:
            premium = Decimal(row.get("annual_premium", "0").replace(",", ".").strip() or "0")
        except InvalidOperation:
            rejects.add(
                row, "STG_005_BAD_PREMIUM",
                f"prime invalide: {row.get('annual_premium')!r}",
            )
            continue
        if premium < 0:
            rejects.add(row, "STG_006_NEGATIVE_PREMIUM", f"prime négative: {premium}")
            continue

        clean.append(
            {
                "contract_id": row["contract_id"].strip(),
                "customer_id": row["customer_id"].strip(),
                "product_code": row["product_code"].strip().upper(),
                "contract_status": status,
                "start_date": start_date,
                "end_date": end_date,
                "annual_premium": premium,
                "channel_code": (row.get("channel_code") or "UNKNOWN").strip().upper(),
                "event_timestamp": (row.get("event_timestamp") or "").strip(),
            }
        )
    return clean


def build_enterprise_contracts(
    stg_rows: list[dict],
    product_referential: set[str],
    rejects: RejectStore,
    source_system: str = "IMPULSE",
) -> list[dict]:
    """stg_contracts_clean -> enterprise_contract.contracts.

    Déduplication : en cas de réémission ou de doublon, seul le dernier
    événement par contract_id est conservé (event_timestamp le plus récent).
    Le rattachement au référentiel produit est obligatoire.
    """
    valid: list[dict] = []
    for row in stg_rows:
        if row["product_code"] not in product_referential:
            rejects.add(
                row, "ENT_001_UNKNOWN_PRODUCT",
                f"code produit absent du référentiel: {row['product_code']}",
            )
            continue
        valid.append(row)

    latest: dict[str, dict] = {}
    for row in valid:
        current = latest.get(row["contract_id"])
        if current is None or row["event_timestamp"] >= current["event_timestamp"]:
            latest[row["contract_id"]] = row

    return [
        {**row, "source_system": source_system}
        for row in sorted(latest.values(), key=lambda r: r["contract_id"])
    ]


def is_active(contract: dict, snapshot_date: date) -> bool:
    """Règle métier d'activité (documentation §9.4, à valider par le Data Owner).

    Un contrat est actif à une date donnée si :
      - son statut harmonisé est ACTIVE (les suspensions ne comptent pas),
      - sa date d'effet est atteinte (référence: date d'effet, pas de saisie),
      - il n'est pas terminé à cette date (résiliation rétroactive incluse).
    """
    if contract["contract_status"] != "ACTIVE":
        return False
    if contract["start_date"] is None or contract["start_date"] > snapshot_date:
        return False
    end_date = contract["end_date"]
    return end_date is None or end_date >= snapshot_date


def build_active_contracts_daily(
    enterprise_rows: list[dict],
    snapshot_date: date,
    batch_id: str,
) -> list[dict]:
    """enterprise_contract.contracts -> product_contract.active_contracts_daily.

    Photographie quotidienne du portefeuille, au schéma du produit Data (§9.5).
    """
    snapshot: list[dict] = []
    for contract in enterprise_rows:
        snapshot.append(
            {
                "snapshot_date": snapshot_date,
                "contract_id": contract["contract_id"],
                "customer_id": contract["customer_id"],
                "product_code": contract["product_code"],
                "contract_status": contract["contract_status"],
                "start_date": contract["start_date"],
                "end_date": contract["end_date"],
                "annual_premium": contract["annual_premium"],
                "channel_code": contract["channel_code"],
                "is_active": is_active(contract, snapshot_date),
                "source_system": contract["source_system"],
                "ingestion_batch_id": batch_id,
            }
        )
    return snapshot
