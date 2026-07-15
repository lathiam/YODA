# Orchestration quotidienne sans Cloud Composer : requête programmée BigQuery
# (Data Transfer Service). Service gratuit — seuls les octets analysés comptent,
# largement couverts par le palier gratuit. La chaîne complète (Contrats,
# Sinistres, Interactions) se rejoue chaque jour à 05:00 UTC avec le compte de
# service pipeline, comme le ferait le DAG Composer en production.

data "google_project" "current" {
  project_id = var.project_id
}

# L'agent de service du Data Transfer Service doit pouvoir générer des jetons
# pour le compte de service pipeline (exécution déléguée).
# L'identité est créée par scripts/deploy_gcp.sh (gcloud beta services identity create).
resource "google_service_account_iam_member" "dts_impersonates_pipeline" {
  service_account_id = google_service_account.pipeline.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-bigquerydatatransfer.iam.gserviceaccount.com"
}

resource "google_bigquery_data_transfer_config" "daily_full_chain" {
  display_name         = "yoda-daily-full-chain-${var.environment}"
  data_source_id       = "scheduled_query"
  location             = var.region
  schedule             = "every day 05:00"
  service_account_name = google_service_account.pipeline.email

  params = {
    query = replace(
      file("${path.module}/../sql/orchestration/daily_full_chain.sql"),
      "@project@",
      var.project_id
    )
  }

  depends_on = [
    google_service_account_iam_member.dts_impersonates_pipeline,
    google_bigquery_dataset.layers,
    google_project_iam_member.pipeline_bq_jobs,
  ]
}
