#!/usr/bin/env bash
# Déploiement YODA en un passage, à exécuter depuis Google Cloud Shell :
#
#   git clone https://github.com/lathiam/YODA.git && cd YODA
#   git checkout claude/technical-setup-hzjojy
#   bash scripts/deploy_gcp.sh [dev|preprod|prod] [PROJECT_ID]
#
# Sans argument : environnement dev et projet actif de gcloud.
set -euo pipefail

ENV="${1:-dev}"
PROJECT_ID="${2:-$(gcloud config get-value project 2>/dev/null)}"
REGION="${REGION:-europe-west1}"

if [ -z "${PROJECT_ID}" ]; then
  echo "Aucun projet GCP actif. Usage: bash scripts/deploy_gcp.sh dev MON_PROJET" >&2
  exit 1
fi

echo "== Déploiement YODA — environnement=${ENV} projet=${PROJECT_ID} région=${REGION} =="

echo "== 1/5 Activation des APIs nécessaires =="
gcloud services enable \
  bigquery.googleapis.com \
  storage.googleapis.com \
  iam.googleapis.com \
  cloudresourcemanager.googleapis.com \
  --project "${PROJECT_ID}"

echo "== 2/5 Bucket d'état Terraform =="
gsutil ls -b "gs://${PROJECT_ID}-tfstate" 2>/dev/null \
  || gsutil mb -l "${REGION}" -p "${PROJECT_ID}" "gs://${PROJECT_ID}-tfstate"

echo "== 3/5 Infrastructure (datasets, tables ops, buckets, IAM) =="
terraform -chdir=infra init -backend-config="bucket=${PROJECT_ID}-tfstate"
terraform -chdir=infra apply -auto-approve \
  -var "project_id=${PROJECT_ID}" \
  -var "environment=${ENV}" \
  -var "region=${REGION}"

echo "== 4/5 Référentiel produits + fichier d'exemple dans le landing =="
bq --project_id="${PROJECT_ID}" load --replace \
  --source_format=CSV --field_delimiter=';' --skip_leading_rows=1 \
  enterprise_referential.products \
  data/samples/referential_products.csv \
  product_code:STRING,product_family:STRING,product_label:STRING
gsutil cp data/samples/impulse_contracts_20260713.csv \
  "gs://${PROJECT_ID}-landing/impulse/contracts/20260713/impulse_contracts_20260713.csv"

echo "== 5/5 Contrôles post-déploiement =="
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false \
  "SELECT 'referentiel_produits' AS objet, COUNT(*) AS lignes
   FROM \`${PROJECT_ID}.enterprise_referential.products\`"
echo "Datasets créés :"
bq --project_id="${PROJECT_ID}" ls | head -15

cat <<EOF

== Déploiement terminé ==
- Datasets BigQuery : app_impulse, enterprise_referential, enterprise_contract,
  product_contract, usage_bi, ops
- Buckets : gs://${PROJECT_ID}-landing (fichier d'exemple déposé),
  gs://${PROJECT_ID}-archive
- Compte de service pipeline : yoda-pipeline-${ENV}@${PROJECT_ID}.iam.gserviceaccount.com

Étape suivante (optionnelle, ~350 EUR/mois) : créer un environnement Cloud
Composer pour orchestrer le DAG — voir docs/deploiement_gcp.md.
EOF
