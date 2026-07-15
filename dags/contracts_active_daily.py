"""DAG Composer — produit Data « Contrats actifs » (product_contract.active_contracts_daily).

Pattern d'orchestration pour flux fichier (documentation §11) :

    capteur fichier -> contrôles d'ingestion -> chargement raw -> staging
        -> modèle d'entreprise -> produit Data -> tests qualité -> publication vue
        -> archivage fichier -> journal d'exécution

Idempotence : chaque étape écrit par partition {{ ds }} (business_date) ;
un backfill ou une relance écrase la partition au lieu de dupliquer.
Les secrets ne figurent ni ici ni dans la config : comptes de service Composer.
"""

from __future__ import annotations

import os
from datetime import datetime, timedelta
from pathlib import Path

from airflow import DAG
from airflow.operators.empty import EmptyOperator
from airflow.providers.google.cloud.operators.bigquery import (
    BigQueryCheckOperator,
    BigQueryInsertJobOperator,
)
from airflow.providers.google.cloud.sensors.gcs import GCSObjectExistenceSensor
from airflow.providers.google.cloud.transfers.gcs_to_bigquery import (
    GCSToBigQueryOperator,
)
from airflow.providers.google.cloud.transfers.gcs_to_gcs import GCSToGCSOperator

# Paramétrage par environnement (variables d'environnement Composer, jamais en dur)
ENV = os.environ.get("YODA_ENV", "dev")
PROJECT_ID = os.environ.get("YODA_PROJECT_ID", f"yoda-mnv-{ENV}")
LANDING_BUCKET = os.environ.get("YODA_LANDING_BUCKET", f"yoda-mnv-{ENV}-landing")
ARCHIVE_BUCKET = os.environ.get("YODA_ARCHIVE_BUCKET", f"yoda-mnv-{ENV}-archive")

SQL_DIR = Path(__file__).resolve().parent / "sql"
SOURCE_OBJECT = "impulse/contracts/{{ ds_nodash }}/impulse_contracts_{{ ds_nodash }}.csv"


def _read_sql(relative_path: str) -> str:
    """Les transformations SQL sont versionnées dans sql/ et déployées avec le DAG."""
    return (SQL_DIR / relative_path).read_text(encoding="utf-8")


default_args = {
    "owner": "domaine-contrat",
    "retries": 2,
    "retry_delay": timedelta(minutes=10),
    "execution_timeout": timedelta(hours=2),
    # Alerte immédiate de l'exploitation en cas d'échec (runbook docs/)
    "email_on_failure": True,
}

with DAG(
    dag_id="contracts_active_daily",
    description=(
        "Produit Data Contrats actifs — Impulse vers product_contract.active_contracts_daily"
    ),
    schedule="0 5 * * *",  # 05:00 UTC, SLA de publication 07:00
    start_date=datetime(2026, 1, 1),
    catchup=False,
    max_active_runs=1,
    default_args=default_args,
    tags=["domaine:contrat", "source:impulse", "produit:active_contracts_daily", ENV],
) as dag:

    # 1. Détection : le fichier du jour est-il arrivé dans la fenêtre attendue ?
    wait_for_file = GCSObjectExistenceSensor(
        task_id="wait_for_impulse_file",
        bucket=LANDING_BUCKET,
        object=SOURCE_OBJECT,
        poke_interval=300,
        timeout=60 * 60 * 2,
        mode="reschedule",
    )

    # 2. Chargement du modèle applicatif (raw) — WRITE_TRUNCATE sur la partition
    #    du jour : relance idempotente garantie.
    load_raw = GCSToBigQueryOperator(
        task_id="load_raw_contracts",
        bucket=LANDING_BUCKET,
        source_objects=[SOURCE_OBJECT],
        destination_project_dataset_table=(
            f"{PROJECT_ID}.app_impulse.raw_contracts${{{{ ds_nodash }}}}"
        ),
        schema_object="schemas/impulse_contracts_bq_schema.json",
        source_format="CSV",
        field_delimiter=";",
        skip_leading_rows=1,
        write_disposition="WRITE_TRUNCATE",
        max_bad_records=0,  # tout écart de format est traité en amont, pas ignoré
    )

    # 3. Staging : nettoyage technique, typage, harmonisation, rejets isolés
    build_staging = BigQueryInsertJobOperator(
        task_id="build_stg_contracts_clean",
        configuration={
            "query": {
                "query": _read_sql("app_impulse/stg_contracts_clean.sql"),
                "useLegacySql": False,
            }
        },
        params={"project_id": PROJECT_ID},
    )

    # 4. Modèle d'entreprise : objets métier stables, découplés de la source
    build_enterprise = BigQueryInsertJobOperator(
        task_id="build_enterprise_contracts",
        configuration={
            "query": {
                "query": _read_sql("enterprise_contract/contracts.sql"),
                "useLegacySql": False,
            }
        },
        params={"project_id": PROJECT_ID},
    )

    # 5. Produit Data : snapshot quotidien avec la règle métier d'activité
    build_product = BigQueryInsertJobOperator(
        task_id="build_active_contracts_daily",
        configuration={
            "query": {
                "query": _read_sql("product_contract/active_contracts_daily.sql"),
                "useLegacySql": False,
            }
        },
        params={"project_id": PROJECT_ID},
    )

    # 6. Tests qualité bloquants (sévérité critique/élevée) — documentation §9.6
    qa_contract_id_not_null = BigQueryCheckOperator(
        task_id="qa_contract_id_not_null",
        sql=f"""
            SELECT COUNT(*) = 0
            FROM `{PROJECT_ID}.product_contract.active_contracts_daily`
            WHERE snapshot_date = '{{{{ ds }}}}' AND contract_id IS NULL
        """,
        use_legacy_sql=False,
    )

    qa_unique_contract_snapshot = BigQueryCheckOperator(
        task_id="qa_unique_contract_snapshot",
        sql=f"""
            SELECT COUNT(*) = 0 FROM (
              SELECT contract_id
              FROM `{PROJECT_ID}.product_contract.active_contracts_daily`
              WHERE snapshot_date = '{{{{ ds }}}}'
              GROUP BY contract_id
              HAVING COUNT(*) > 1
            )
        """,
        use_legacy_sql=False,
    )

    qa_dates_coherent = BigQueryCheckOperator(
        task_id="qa_dates_coherent",
        sql=f"""
            SELECT COUNT(*) = 0
            FROM `{PROJECT_ID}.product_contract.active_contracts_daily`
            WHERE snapshot_date = '{{{{ ds }}}}'
              AND end_date IS NOT NULL AND end_date < start_date
        """,
        use_legacy_sql=False,
    )

    # 7. Publication : rafraîchit la vue d'exposition BI (interface stable)
    publish_bi_view = BigQueryInsertJobOperator(
        task_id="publish_usage_bi_view",
        configuration={
            "query": {
                "query": _read_sql("usage_bi/vw_active_contracts.sql"),
                "useLegacySql": False,
            }
        },
        params={"project_id": PROJECT_ID},
    )

    # 8. Archivage du fichier source (traçabilité + politique de conservation)
    archive_file = GCSToGCSOperator(
        task_id="archive_source_file",
        source_bucket=LANDING_BUCKET,
        source_object=SOURCE_OBJECT,
        destination_bucket=ARCHIVE_BUCKET,
        destination_object=SOURCE_OBJECT,
        move_object=True,
    )

    done = EmptyOperator(task_id="pipeline_done")

    quality_checks = [qa_contract_id_not_null, qa_unique_contract_snapshot, qa_dates_coherent]

    (
        wait_for_file
        >> load_raw
        >> build_staging
        >> build_enterprise
        >> build_product
        >> quality_checks
        >> publish_bi_view
        >> archive_file
        >> done
    )
