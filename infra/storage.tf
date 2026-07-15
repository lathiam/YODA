# Buckets GCS : atterrissage des fichiers sources et archivage.
# Cycle de conservation aligné sur la politique RGPD (documentation §13.4) :
# la durée exacte doit être validée avec le DPO avant la production.

resource "google_storage_bucket" "landing" {
  name                        = "${var.project_id}-landing"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = merge(var.data_domain_labels, { environment = var.environment, usage = "landing" })

  # Un fichier non traité au-delà de 30 jours signale un incident, pas une archive
  lifecycle_rule {
    condition { age = 30 }
    action { type = "Delete" }
  }
}

resource "google_storage_bucket" "archive" {
  name                        = "${var.project_id}-archive"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  labels = merge(var.data_domain_labels, { environment = var.environment, usage = "archive" })

  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }
  # Durée de conservation réglementaire — valeur à confirmer avec le DPO
  lifecycle_rule {
    condition { age = 3650 }
    action { type = "Delete" }
  }
}
