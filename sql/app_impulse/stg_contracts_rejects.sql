-- Rejets du staging : les lignes exclues de stg_contracts_clean sont conservées
-- avec la donnée originale et un motif exploitable (documentation §11.3).
-- Jamais de perte silencieuse : ces lignes alimentent l'analyse et la reprise.

DECLARE business_date DATE DEFAULT DATE('{{ ds }}');

INSERT INTO `{{ params.project_id }}.ops.rejects`
  (reject_id, batch_id, pipeline_name, rule_code, error_message,
   source_record, rejected_at, retry_status)
WITH typed AS (
  SELECT
    *,
    CASE UPPER(TRIM(status))
      WHEN 'EN_COURS' THEN 'ACTIVE' WHEN 'ACTIF' THEN 'ACTIVE'
      WHEN 'SUSPENDU' THEN 'SUSPENDED' WHEN 'RESILIE' THEN 'TERMINATED'
      WHEN 'ANNULE' THEN 'CANCELLED' ELSE NULL
    END AS mapped_status,
    SAFE.PARSE_DATE('%Y-%m-%d', TRIM(start_date)) AS parsed_start,
    SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(end_date), '')) AS parsed_end,
    SAFE_CAST(REPLACE(TRIM(annual_premium), ',', '.') AS NUMERIC) AS parsed_premium
  FROM `{{ params.project_id }}.app_impulse.raw_contracts`
  WHERE _PARTITIONDATE = business_date
)
SELECT
  GENERATE_UUID(),
  ingestion_batch_id,
  'contracts_active_daily',
  CASE
    WHEN COALESCE(TRIM(contract_id), '') = ''
      OR COALESCE(TRIM(customer_id), '') = ''
      OR COALESCE(TRIM(product_code), '') = '' THEN 'STG_001_MISSING_FIELD'
    WHEN mapped_status IS NULL THEN 'STG_002_UNKNOWN_STATUS'
    WHEN parsed_start IS NULL THEN 'STG_003_BAD_DATE'
    WHEN parsed_end IS NOT NULL AND parsed_end < parsed_start THEN 'STG_004_DATE_ORDER'
    WHEN parsed_premium IS NULL THEN 'STG_005_BAD_PREMIUM'
    WHEN parsed_premium < 0 THEN 'STG_006_NEGATIVE_PREMIUM'
  END,
  'ligne exclue du staging — voir rule_code',
  TO_JSON_STRING(t),
  CURRENT_TIMESTAMP(),
  'PENDING'
FROM typed AS t
WHERE COALESCE(TRIM(contract_id), '') = ''
   OR COALESCE(TRIM(customer_id), '') = ''
   OR COALESCE(TRIM(product_code), '') = ''
   OR mapped_status IS NULL
   OR parsed_start IS NULL
   OR (parsed_end IS NOT NULL AND parsed_end < parsed_start)
   OR parsed_premium IS NULL
   OR parsed_premium < 0;
