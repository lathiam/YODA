# IAM — moindre privilège, accès par groupes et comptes de service dédiés
# (documentation §13.3). Les consommateurs BI ne voient que usage_bi ;
# le compte de service pipeline n'a que les droits nécessaires à son exécution.

resource "google_service_account" "pipeline" {
  account_id   = "yoda-pipeline-${var.environment}"
  display_name = "YODA - compte de service des pipelines (${var.environment})"
}

# Le pipeline lit l'atterrissage, écrit l'archive, exécute des jobs BigQuery
resource "google_storage_bucket_iam_member" "pipeline_reads_landing" {
  bucket = google_storage_bucket.landing.name
  role   = "roles/storage.objectAdmin" # lecture + suppression après archivage
  member = "serviceAccount:${google_service_account.pipeline.email}"
}

resource "google_storage_bucket_iam_member" "pipeline_writes_archive" {
  bucket = google_storage_bucket.archive.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.pipeline.email}"
}

resource "google_project_iam_member" "pipeline_bq_jobs" {
  project = var.project_id
  role    = "roles/bigquery.jobUser"
  member  = "serviceAccount:${google_service_account.pipeline.email}"
}

resource "google_bigquery_dataset_iam_member" "pipeline_edits_layers" {
  for_each   = google_bigquery_dataset.layers
  dataset_id = each.value.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = "serviceAccount:${google_service_account.pipeline.email}"
}

# Les consommateurs BI n'accèdent qu'à la couche d'usage — jamais aux couches
# internes (protection des structures, documentation §6.7)
resource "google_bigquery_dataset_iam_member" "bi_readers" {
  count      = var.bi_readers_group != "" ? 1 : 0
  dataset_id = google_bigquery_dataset.layers["usage_bi"].dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "group:${var.bi_readers_group}"
}

# Les Data Engineers ont un accès lecture large pour le développement et le
# diagnostic ; les écritures en prod passent uniquement par la CI/CD
resource "google_bigquery_dataset_iam_member" "data_engineers" {
  for_each   = var.data_engineers_group != "" ? google_bigquery_dataset.layers : {}
  dataset_id = each.value.dataset_id
  role       = "roles/bigquery.dataViewer"
  member     = "group:${var.data_engineers_group}"
}
