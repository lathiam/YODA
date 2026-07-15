variable "project_id" {
  description = "Projet GCP du comptoir MNV pour l'environnement"
  type        = string
}

variable "region" {
  description = "Région GCP (résidence des données en Europe)"
  type        = string
  default     = "europe-west1"
}

variable "environment" {
  description = "Environnement: dev, preprod ou prod"
  type        = string
  validation {
    condition     = contains(["dev", "preprod", "prod"], var.environment)
    error_message = "environment doit valoir dev, preprod ou prod."
  }
}

variable "data_domain_labels" {
  description = "Labels FinOps: chaque ressource est rattachée à un domaine et un produit (documentation §17.2)"
  type        = map(string)
  default = {
    program  = "yoda"
    comptoir = "mnv"
  }
}

variable "bi_readers_group" {
  description = "Groupe IAM des consommateurs BI (accès usage_bi uniquement)"
  type        = string
  default     = ""
}

variable "data_engineers_group" {
  description = "Groupe IAM des Data Engineers du domaine"
  type        = string
  default     = ""
}
