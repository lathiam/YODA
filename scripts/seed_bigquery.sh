#!/usr/bin/env bash
# Alimente l'architecture cible YODA avec les données simulées, de bout en bout :
#   1. référentiels centraux (produits, organisation)
#   2. couche applicative : raw_* pour les 7 sources
#   3. chaînes complètes Contrats, Sinistres et Interactions
#      (staging -> entreprise -> produit -> vues d'usage -> rejets -> journal)
#   4. dépôt des fichiers dans le bucket landing (simulation de l'arrivée réelle)
#   5. contrôles finaux
#
# À exécuter APRÈS scripts/deploy_gcp.sh, depuis Cloud Shell :
#   bash scripts/seed_bigquery.sh [dev|preprod|prod] [PROJECT_ID]
set -euo pipefail

ENV="${1:-dev}"
PROJECT_ID="${2:-$(gcloud config get-value project 2>/dev/null)}"
DS="${BUSINESS_DATE:-2026-07-13}"
DS_NODASH="${DS//-/}"

if [ -z "${PROJECT_ID}" ]; then
  echo "Aucun projet GCP actif. Usage: bash scripts/seed_bigquery.sh dev MON_PROJET" >&2
  exit 1
fi

echo "== Seed YODA — projet=${PROJECT_ID} date métier=${DS} =="

run_sql() {
  # Substitue les placeholders et exécute le script multi-instructions
  sed -e "s/@project@/${PROJECT_ID}/g" -e "s/@ds@/${DS}/g" "$1" \
    | bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --nouse_cache
}

load_raw() { # dataset.table fichier schema
  bq --project_id="${PROJECT_ID}" load --replace \
    --source_format=CSV --field_delimiter=';' --skip_leading_rows=1 \
    "$1" "$2" "$3"
}

echo "== 1/5 Référentiels centraux =="
load_raw enterprise_referential.products data/samples/referential_products.csv \
  product_code:STRING,product_family:STRING,product_label:STRING
load_raw enterprise_referential.organisation data/samples/referential_organisation.csv \
  channel_code:STRING,channel_label:STRING,distribution_network:STRING

echo "== 2/5 Couche applicative : raw des 7 sources =="
load_raw app_impulse.raw_contracts data/samples/impulse_contracts_20260713.csv \
  contract_id:STRING,customer_id:STRING,product_code:STRING,status:STRING,start_date:STRING,end_date:STRING,annual_premium:STRING,channel_code:STRING,event_timestamp:STRING
load_raw app_teccare.raw_claims data/samples/teccare_claims_20260713.csv \
  claim_id:STRING,contract_id:STRING,customer_id:STRING,claim_type:STRING,status:STRING,open_date:STRING,close_date:STRING,estimated_amount:STRING,paid_amount:STRING,event_timestamp:STRING
load_raw app_genesys.raw_interactions data/samples/genesys_interactions_20260713.csv \
  interaction_id:STRING,customer_id:STRING,channel:STRING,direction:STRING,start_timestamp:STRING,duration_seconds:STRING,reason_code:STRING,agent_id:STRING
load_raw app_adobe_analytics.raw_web_events data/samples/adobe_web_events_20260713.csv \
  event_id:STRING,visitor_id:STRING,customer_id:STRING,page:STRING,event_type:STRING,event_timestamp:STRING,device:STRING,campaign:STRING
load_raw app_bpce_iard.raw_contracts data/samples/bpce_iard_contracts_20260713.csv \
  contract_id:STRING,customer_id:STRING,product_code:STRING,status:STRING,start_date:STRING,end_date:STRING,annual_premium:STRING,channel_code:STRING,event_timestamp:STRING
load_raw app_partners.raw_partner_flows data/samples/partner_flows_20260713.csv \
  partner_code:STRING,policy_ref:STRING,insured_id:STRING,product_code:STRING,premium:STRING,period_start:STRING,period_end:STRING,file_date:STRING
load_raw app_opendata.raw_communes data/samples/opendata_communes.csv \
  code_insee:STRING,commune:STRING,code_departement:STRING,departement:STRING,code_region:STRING,region:STRING,population:STRING

echo "== 3/5 Chaînes de transformation bout en bout =="
echo "-- Domaine Contrat (staging -> entreprise -> produit -> vues) --"
run_sql sql/bootstrap/init_contracts_chain.sql
echo "-- Domaine Sinistre (staging -> entreprise -> produit -> vue) --"
run_sql sql/bootstrap/init_claims_chain.sql
echo "-- Domaine Interaction (staging -> entreprise -> vue features) --"
run_sql sql/bootstrap/init_interactions_chain.sql

echo "== 4/5 Dépôt des fichiers sources dans le landing (simulation) =="
gcloud storage cp data/samples/impulse_contracts_20260713.csv \
  "gs://${PROJECT_ID}-landing/impulse/contracts/${DS_NODASH}/impulse_contracts_${DS_NODASH}.csv" --project "${PROJECT_ID}" -q
gcloud storage cp data/samples/teccare_claims_20260713.csv \
  "gs://${PROJECT_ID}-landing/teccare/claims/${DS_NODASH}/teccare_claims_${DS_NODASH}.csv" --project "${PROJECT_ID}" -q
gcloud storage cp data/samples/genesys_interactions_20260713.csv \
  "gs://${PROJECT_ID}-landing/genesys/interactions/${DS_NODASH}/genesys_interactions_${DS_NODASH}.csv" --project "${PROJECT_ID}" -q
gcloud storage cp data/samples/adobe_web_events_20260713.csv \
  "gs://${PROJECT_ID}-landing/adobe/web_events/${DS_NODASH}/adobe_web_events_${DS_NODASH}.csv" --project "${PROJECT_ID}" -q
gcloud storage cp data/samples/bpce_iard_contracts_20260713.csv \
  "gs://${PROJECT_ID}-landing/bpce_iard/contracts/${DS_NODASH}/bpce_iard_contracts_${DS_NODASH}.csv" --project "${PROJECT_ID}" -q
gcloud storage cp data/samples/partner_flows_20260713.csv \
  "gs://${PROJECT_ID}-landing/partners/PART-BROKER-01/${DS_NODASH}/partner_flows_${DS_NODASH}.csv" --project "${PROJECT_ID}" -q
gcloud storage cp data/samples/opendata_communes.csv \
  "gs://${PROJECT_ID}-landing/opendata/communes/communes.csv" --project "${PROJECT_ID}" -q

echo "== 5/5 Contrôles finaux : volumes par couche =="
bq --project_id="${PROJECT_ID}" query --use_legacy_sql=false --nouse_cache "
SELECT couche, objet, lignes FROM (
  SELECT '3-applicatif' AS couche, 'app_impulse.raw_contracts' AS objet,
         COUNT(*) AS lignes FROM \`${PROJECT_ID}.app_impulse.raw_contracts\`
  UNION ALL SELECT '3-applicatif', 'app_teccare.raw_claims', COUNT(*)
    FROM \`${PROJECT_ID}.app_teccare.raw_claims\`
  UNION ALL SELECT '3-applicatif', 'app_genesys.raw_interactions', COUNT(*)
    FROM \`${PROJECT_ID}.app_genesys.raw_interactions\`
  UNION ALL SELECT '3-applicatif', 'app_adobe_analytics.raw_web_events', COUNT(*)
    FROM \`${PROJECT_ID}.app_adobe_analytics.raw_web_events\`
  UNION ALL SELECT '3-applicatif', 'app_bpce_iard.raw_contracts', COUNT(*)
    FROM \`${PROJECT_ID}.app_bpce_iard.raw_contracts\`
  UNION ALL SELECT '3-applicatif', 'app_partners.raw_partner_flows', COUNT(*)
    FROM \`${PROJECT_ID}.app_partners.raw_partner_flows\`
  UNION ALL SELECT '3-applicatif', 'app_opendata.raw_communes', COUNT(*)
    FROM \`${PROJECT_ID}.app_opendata.raw_communes\`
  UNION ALL SELECT '5-entreprise', 'enterprise_referential.products', COUNT(*)
    FROM \`${PROJECT_ID}.enterprise_referential.products\`
  UNION ALL SELECT '5-entreprise', 'enterprise_contract.contracts', COUNT(*)
    FROM \`${PROJECT_ID}.enterprise_contract.contracts\`
  UNION ALL SELECT '5-entreprise', 'enterprise_claim.claims', COUNT(*)
    FROM \`${PROJECT_ID}.enterprise_claim.claims\`
  UNION ALL SELECT '5-entreprise', 'enterprise_interaction.interactions', COUNT(*)
    FROM \`${PROJECT_ID}.enterprise_interaction.interactions\`
  UNION ALL SELECT '6-produit', 'product_contract.active_contracts_daily', COUNT(*)
    FROM \`${PROJECT_ID}.product_contract.active_contracts_daily\`
  UNION ALL SELECT '6-produit', 'product_claim.claims_daily', COUNT(*)
    FROM \`${PROJECT_ID}.product_claim.claims_daily\`
  UNION ALL SELECT 'ops', 'ops.rejects', COUNT(*)
    FROM \`${PROJECT_ID}.ops.rejects\`
  UNION ALL SELECT 'ops', 'ops.pipeline_runs', COUNT(*)
    FROM \`${PROJECT_ID}.ops.pipeline_runs\`
)
ORDER BY couche, objet"

cat <<EOF

== Seed terminé ==
Architecture cible alimentée de bout en bout. À explorer dans BigQuery Studio :
  https://console.cloud.google.com/bigquery?project=${PROJECT_ID}

Exemples de requêtes :
  -- KPI portefeuille (vue BI)
  SELECT * FROM \`${PROJECT_ID}.usage_bi.vw_active_contracts\` ORDER BY product_code;
  -- Sinistralité (vue BI croisant deux domaines)
  SELECT * FROM \`${PROJECT_ID}.usage_bi.vw_claims\` ORDER BY product_code;
  -- Features Data Science
  SELECT * FROM \`${PROJECT_ID}.usage_datascience.vw_customer_contact_features\`;
  -- Rejets avec motifs
  SELECT rule_code, error_message FROM \`${PROJECT_ID}.ops.rejects\`;
  -- Journal des exécutions
  SELECT pipeline_name, input_rows, output_rows, reject_rows, status
  FROM \`${PROJECT_ID}.ops.pipeline_runs\`;
EOF
