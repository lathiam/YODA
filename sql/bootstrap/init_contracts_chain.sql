-- Chaîne Contrats de bout en bout, exécutable directement dans BigQuery
-- (initialisation / démo sans Composer). Version industrielle orchestrée :
-- sql/app_impulse, sql/enterprise_contract, sql/product_contract.
-- Placeholders @project@ et @ds@ substitués par scripts/seed_bigquery.sh.

-- ============ Couche staging : nettoyage technique + typage ============
CREATE OR REPLACE TABLE `@project@.app_impulse.stg_contracts_clean` AS
WITH typed AS (
  SELECT
    TRIM(contract_id)         AS contract_id,
    TRIM(customer_id)         AS customer_id,
    UPPER(TRIM(product_code)) AS product_code,
    CASE UPPER(TRIM(status))
      WHEN 'EN_COURS' THEN 'ACTIVE' WHEN 'ACTIF' THEN 'ACTIVE'
      WHEN 'SUSPENDU' THEN 'SUSPENDED' WHEN 'RESILIE' THEN 'TERMINATED'
      WHEN 'ANNULE' THEN 'CANCELLED' ELSE NULL
    END AS contract_status,
    SAFE.PARSE_DATE('%Y-%m-%d', TRIM(start_date)) AS start_date,
    SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(end_date), '')) AS end_date,
    SAFE_CAST(REPLACE(NULLIF(TRIM(annual_premium), ''), ',', '.') AS NUMERIC) AS annual_premium,
    UPPER(COALESCE(NULLIF(TRIM(channel_code), ''), 'UNKNOWN')) AS channel_code,
    TRIM(event_timestamp) AS event_timestamp,
    'impulse_@ds@_seed'   AS ingestion_batch_id,
    DATE('@ds@')          AS business_date
  FROM `@project@.app_impulse.raw_contracts`
)
SELECT * FROM typed
WHERE COALESCE(contract_id, '') != ''
  AND COALESCE(customer_id, '') != ''
  AND COALESCE(product_code, '') != ''
  AND contract_status IS NOT NULL
  AND start_date IS NOT NULL
  AND (end_date IS NULL OR end_date >= start_date)
  AND COALESCE(annual_premium, 0) >= 0;

-- ============ Rejets : lignes exclues, avec motif exploitable ============
INSERT INTO `@project@.ops.rejects`
  (reject_id, batch_id, pipeline_name, rule_code, error_message,
   source_record, rejected_at, retry_status)
WITH typed AS (
  SELECT
    r.*,
    CASE UPPER(TRIM(status))
      WHEN 'EN_COURS' THEN 'ACTIVE' WHEN 'ACTIF' THEN 'ACTIVE'
      WHEN 'SUSPENDU' THEN 'SUSPENDED' WHEN 'RESILIE' THEN 'TERMINATED'
      WHEN 'ANNULE' THEN 'CANCELLED' ELSE NULL
    END AS mapped_status,
    SAFE.PARSE_DATE('%Y-%m-%d', TRIM(start_date)) AS parsed_start,
    SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(end_date), '')) AS parsed_end,
    SAFE_CAST(REPLACE(NULLIF(TRIM(annual_premium), ''), ',', '.') AS NUMERIC) AS parsed_premium
  FROM `@project@.app_impulse.raw_contracts` AS r
)
SELECT
  GENERATE_UUID(), 'impulse_@ds@_seed', 'contracts_active_daily',
  CASE
    WHEN COALESCE(TRIM(contract_id), '') = ''
      OR COALESCE(TRIM(customer_id), '') = ''
      OR COALESCE(TRIM(product_code), '') = '' THEN 'STG_001_MISSING_FIELD'
    WHEN mapped_status IS NULL THEN 'STG_002_UNKNOWN_STATUS'
    WHEN parsed_start IS NULL THEN 'STG_003_BAD_DATE'
    WHEN parsed_end IS NOT NULL AND parsed_end < parsed_start THEN 'STG_004_DATE_ORDER'
    ELSE 'STG_005_BAD_PREMIUM'
  END,
  'ligne exclue du staging Contrats', TO_JSON(t), CURRENT_TIMESTAMP(), 'PENDING'
FROM typed AS t
WHERE COALESCE(TRIM(contract_id), '') = ''
   OR COALESCE(TRIM(customer_id), '') = ''
   OR COALESCE(TRIM(product_code), '') = ''
   OR mapped_status IS NULL
   OR parsed_start IS NULL
   OR (parsed_end IS NOT NULL AND parsed_end < parsed_start)
   OR COALESCE(parsed_premium, 0) < 0;

-- ==== Modèle d'entreprise : dédup (dernier événement) + référentiel ====
CREATE OR REPLACE TABLE `@project@.enterprise_contract.contracts` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT
    stg.* EXCEPT (event_timestamp),
    'IMPULSE' AS source_system,
    ROW_NUMBER() OVER (
      PARTITION BY stg.contract_id ORDER BY stg.event_timestamp DESC
    ) AS rn
  FROM `@project@.app_impulse.stg_contracts_clean` AS stg
  INNER JOIN `@project@.enterprise_referential.products` AS ref
    ON stg.product_code = ref.product_code
)
WHERE rn = 1;

-- Rejets entreprise : produits hors référentiel
INSERT INTO `@project@.ops.rejects`
  (reject_id, batch_id, pipeline_name, rule_code, error_message,
   source_record, rejected_at, retry_status)
SELECT
  GENERATE_UUID(), 'impulse_@ds@_seed', 'contracts_active_daily',
  'ENT_001_UNKNOWN_PRODUCT',
  CONCAT('code produit absent du référentiel: ', stg.product_code),
  TO_JSON(stg), CURRENT_TIMESTAMP(), 'PENDING'
FROM `@project@.app_impulse.stg_contracts_clean` AS stg
LEFT JOIN `@project@.enterprise_referential.products` AS ref
  ON stg.product_code = ref.product_code
WHERE ref.product_code IS NULL;

-- ==== Produit Data : snapshot quotidien (partition remplacée = idempotent) ====
DELETE FROM `@project@.product_contract.active_contracts_daily`
WHERE snapshot_date = DATE('@ds@');

INSERT INTO `@project@.product_contract.active_contracts_daily`
  (snapshot_date, contract_id, customer_id, product_code, contract_status,
   start_date, end_date, annual_premium, channel_code, is_active,
   source_system, ingestion_batch_id)
SELECT
  DATE('@ds@'),
  contract_id,
  TO_HEX(SHA256(CONCAT(customer_id, 'yoda-mnv'))),
  product_code,
  contract_status,
  start_date,
  end_date,
  annual_premium,
  channel_code,
  (contract_status = 'ACTIVE'
    AND start_date <= DATE('@ds@')
    AND (end_date IS NULL OR end_date >= DATE('@ds@'))),
  source_system,
  ingestion_batch_id
FROM `@project@.enterprise_contract.contracts`;

-- ==== Exposition : vues BI, Data Science et applicative ====
CREATE OR REPLACE VIEW `@project@.usage_bi.vw_active_contracts` AS
SELECT
  snapshot_date, product_code, channel_code, contract_status,
  COUNT(*)                              AS contract_count,
  COUNTIF(is_active)                    AS active_contract_count,
  SUM(IF(is_active, annual_premium, 0)) AS active_annual_premium
FROM `@project@.product_contract.active_contracts_daily`
GROUP BY snapshot_date, product_code, channel_code, contract_status;

CREATE OR REPLACE VIEW `@project@.usage_datascience.vw_contract_features` AS
SELECT
  snapshot_date, contract_id, customer_id, product_code, contract_status,
  is_active, annual_premium, channel_code,
  DATE_DIFF(snapshot_date, start_date, MONTH) AS tenure_months,
  end_date IS NOT NULL                        AS has_end_date
FROM `@project@.product_contract.active_contracts_daily`;

CREATE OR REPLACE VIEW `@project@.usage_app.vw_contract_status` AS
SELECT contract_id, contract_status, is_active, snapshot_date AS as_of_date
FROM `@project@.product_contract.active_contracts_daily`
WHERE snapshot_date = DATE('@ds@');

-- ==== Journal d'exécution : observabilité (doc §11.2) ====
INSERT INTO `@project@.ops.pipeline_runs`
  (run_id, pipeline_name, source_name, source_file, business_date, batch_id,
   start_time, end_time, input_rows, output_rows, reject_rows, status)
SELECT
  GENERATE_UUID(), 'contracts_active_daily', 'impulse',
  'impulse_contracts_@ds@.csv (seed)', DATE('@ds@'), 'impulse_@ds@_seed',
  CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
  (SELECT COUNT(*) FROM `@project@.app_impulse.raw_contracts`),
  (SELECT COUNT(*) FROM `@project@.product_contract.active_contracts_daily`
    WHERE snapshot_date = DATE('@ds@')),
  (SELECT COUNT(*) FROM `@project@.ops.rejects`
    WHERE batch_id = 'impulse_@ds@_seed'),
  'PARTIAL';
