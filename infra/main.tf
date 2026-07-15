# Infrastructure YODA — comptoir MNV sur GCP.
# Provisionne les datasets BigQuery par couche, les buckets d'atterrissage et
# d'archivage, les comptes de service et les tables d'exploitation (ops).
# Un fichier .tfvars par environnement : environments/{dev,preprod,prod}.tfvars

terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
  # Backend d'état à configurer par environnement (bucket GCS dédié) :
  # terraform init -backend-config="bucket=yoda-mnv-<env>-tfstate"
  backend "gcs" {
    prefix = "yoda/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
