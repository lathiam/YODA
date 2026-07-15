# Datasets BigQuery par couche (convention de nommage, documentation §10.3).
# app_<source> / enterprise_<domaine> / product_<domaine> / usage_<type> / ops

locals {
  datasets = {
    app_impulse = {
      description = "Modèle applicatif Impulse — données brutes et staging, proches de la source"
      layer       = "applicatif"
    }
    enterprise_referential = {
      description = "Référentiels centraux (produits, organisation) — pas de listes dupliquées"
      layer       = "entreprise"
    }
    enterprise_contract = {
      description = "Modèle d'entreprise — domaine Contrat, objets métier stables"
      layer       = "entreprise"
    }
    product_contract = {
      description = "Produits Data du domaine Contrat — gouvernés, testés, documentés"
      layer       = "produit"
    }
    usage_bi = {
      description = "Modèles d'usage BI — vues d'exposition stables pour Power BI"
      layer       = "usage"
    }
    ops = {
      description = "Exploitation — journaux d'exécution, rejets, résultats qualité, ledger d'ingestion"
      layer       = "transverse"
    }
  }
}

resource "google_bigquery_dataset" "layers" {
  for_each    = local.datasets
  dataset_id  = each.key
  description = each.value.description
  location    = var.region

  labels = merge(var.data_domain_labels, {
    environment = var.environment
    layer       = each.value.layer
    domain      = "contrat"
  })
}

# Table du produit Data — partitionnée par snapshot_date, clusterisée pour
# limiter le volume analysé par les requêtes (FinOps, documentation §17.2).
resource "google_bigquery_table" "active_contracts_daily" {
  dataset_id          = google_bigquery_dataset.layers["product_contract"].dataset_id
  table_id            = "active_contracts_daily"
  description         = "Photographie quotidienne du portefeuille contrats — voir docs/catalogue"
  deletion_protection = var.environment == "prod"

  time_partitioning {
    type  = "DAY"
    field = "snapshot_date"
  }
  clustering = ["product_code", "channel_code"]

  schema = jsonencode([
    { name = "snapshot_date", type = "DATE", mode = "REQUIRED" },
    { name = "contract_id", type = "STRING", mode = "REQUIRED" },
    { name = "customer_id", type = "STRING", mode = "NULLABLE", description = "Pseudonymisé SHA-256" },
    { name = "product_code", type = "STRING", mode = "REQUIRED" },
    { name = "contract_status", type = "STRING", mode = "REQUIRED" },
    { name = "start_date", type = "DATE", mode = "REQUIRED" },
    { name = "end_date", type = "DATE", mode = "NULLABLE" },
    { name = "annual_premium", type = "NUMERIC", mode = "NULLABLE" },
    { name = "channel_code", type = "STRING", mode = "NULLABLE" },
    { name = "is_active", type = "BOOLEAN", mode = "REQUIRED" },
    { name = "source_system", type = "STRING", mode = "REQUIRED" },
    { name = "ingestion_batch_id", type = "STRING", mode = "REQUIRED" },
  ])
}

# Tables d'exploitation : rejets et journal des exécutions (documentation §11.2-11.3)
resource "google_bigquery_table" "rejects" {
  dataset_id          = google_bigquery_dataset.layers["ops"].dataset_id
  table_id            = "rejects"
  description         = "Rejets de pipelines avec donnée originale, motif et statut de reprise"
  deletion_protection = var.environment == "prod"

  time_partitioning { type = "DAY" }

  schema = jsonencode([
    { name = "reject_id", type = "STRING", mode = "REQUIRED" },
    { name = "batch_id", type = "STRING", mode = "REQUIRED" },
    { name = "pipeline_name", type = "STRING", mode = "REQUIRED" },
    { name = "rule_code", type = "STRING", mode = "REQUIRED" },
    { name = "error_message", type = "STRING", mode = "NULLABLE" },
    { name = "source_record", type = "JSON", mode = "NULLABLE" },
    { name = "rejected_at", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "retry_status", type = "STRING", mode = "REQUIRED" },
  ])
}

resource "google_bigquery_table" "pipeline_runs" {
  dataset_id          = google_bigquery_dataset.layers["ops"].dataset_id
  table_id            = "pipeline_runs"
  description         = "Métadonnées d'exécution: run_id, batch, volumes, statut, erreurs"
  deletion_protection = var.environment == "prod"

  time_partitioning { type = "DAY" }

  schema = jsonencode([
    { name = "run_id", type = "STRING", mode = "REQUIRED" },
    { name = "pipeline_name", type = "STRING", mode = "REQUIRED" },
    { name = "source_name", type = "STRING", mode = "REQUIRED" },
    { name = "source_file", type = "STRING", mode = "NULLABLE" },
    { name = "business_date", type = "DATE", mode = "REQUIRED" },
    { name = "batch_id", type = "STRING", mode = "REQUIRED" },
    { name = "start_time", type = "TIMESTAMP", mode = "REQUIRED" },
    { name = "end_time", type = "TIMESTAMP", mode = "NULLABLE" },
    { name = "input_rows", type = "INTEGER", mode = "NULLABLE" },
    { name = "output_rows", type = "INTEGER", mode = "NULLABLE" },
    { name = "reject_rows", type = "INTEGER", mode = "NULLABLE" },
    { name = "status", type = "STRING", mode = "REQUIRED" },
    { name = "error_code", type = "STRING", mode = "NULLABLE" },
    { name = "error_message", type = "STRING", mode = "NULLABLE" },
  ])
}
