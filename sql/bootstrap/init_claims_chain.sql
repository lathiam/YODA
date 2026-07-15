-- Chaîne Sinistres (domaine Sinistre, source TecCare) de bout en bout.
-- Démontre un second domaine et un produit Data croisant deux domaines
-- (le sinistre est rattaché au contrat du modèle d'entreprise).
-- Placeholders @project@ et @ds@ substitués par scripts/seed_bigquery.sh.

-- ============ Couche staging : typage + harmonisation des statuts ============
CREATE OR REPLACE TABLE `@project@.app_teccare.stg_claims_clean` AS
WITH typed AS (
  SELECT
    TRIM(claim_id)     AS claim_id,
    TRIM(contract_id)  AS contract_id,
    TRIM(customer_id)  AS customer_id,
    UPPER(TRIM(claim_type)) AS claim_type,
    CASE UPPER(TRIM(status))
      WHEN 'OUVERT'       THEN 'OPEN'
      WHEN 'REOUVERT'     THEN 'OPEN'
      WHEN 'EN_EXPERTISE' THEN 'ASSESSMENT'
      WHEN 'CLOS'         THEN 'CLOSED'
      WHEN 'SANS_SUITE'   THEN 'CLOSED_NO_ACTION'
      ELSE NULL
    END AS claim_status,
    SAFE.PARSE_DATE('%Y-%m-%d', TRIM(open_date)) AS open_date,
    SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(close_date), '')) AS close_date,
    SAFE_CAST(NULLIF(TRIM(estimated_amount), '') AS NUMERIC) AS estimated_amount,
    SAFE_CAST(NULLIF(TRIM(paid_amount), '') AS NUMERIC)      AS paid_amount,
    TRIM(event_timestamp) AS event_timestamp,
    'teccare_@ds@_seed'   AS ingestion_batch_id,
    DATE('@ds@')          AS business_date
  FROM `@project@.app_teccare.raw_claims`
)
SELECT * FROM typed
WHERE COALESCE(claim_id, '') != ''
  AND COALESCE(contract_id, '') != ''
  AND claim_status IS NOT NULL
  AND open_date IS NOT NULL
  AND (close_date IS NULL OR close_date >= open_date);

-- ============ Rejets staging ============
INSERT INTO `@project@.ops.rejects`
  (reject_id, batch_id, pipeline_name, rule_code, error_message,
   source_record, rejected_at, retry_status)
WITH typed AS (
  SELECT
    r.*,
    CASE UPPER(TRIM(status))
      WHEN 'OUVERT' THEN 'OPEN' WHEN 'REOUVERT' THEN 'OPEN'
      WHEN 'EN_EXPERTISE' THEN 'ASSESSMENT' WHEN 'CLOS' THEN 'CLOSED'
      WHEN 'SANS_SUITE' THEN 'CLOSED_NO_ACTION' ELSE NULL
    END AS mapped_status,
    SAFE.PARSE_DATE('%Y-%m-%d', TRIM(open_date)) AS parsed_open,
    SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(close_date), '')) AS parsed_close
  FROM `@project@.app_teccare.raw_claims` AS r
)
SELECT
  GENERATE_UUID(), 'teccare_@ds@_seed', 'claims_daily',
  CASE
    WHEN COALESCE(TRIM(claim_id), '') = ''
      OR COALESCE(TRIM(contract_id), '') = '' THEN 'STG_001_MISSING_FIELD'
    WHEN mapped_status IS NULL THEN 'STG_002_UNKNOWN_STATUS'
    WHEN parsed_open IS NULL THEN 'STG_003_BAD_DATE'
    ELSE 'STG_004_DATE_ORDER'
  END,
  'ligne exclue du staging Sinistres', TO_JSON(t), CURRENT_TIMESTAMP(), 'PENDING'
FROM typed AS t
WHERE COALESCE(TRIM(claim_id), '') = ''
   OR COALESCE(TRIM(contract_id), '') = ''
   OR mapped_status IS NULL
   OR parsed_open IS NULL
   OR (parsed_close IS NOT NULL AND parsed_close < parsed_open);

-- ==== Modèle d'entreprise : dédup + rattachement au contrat du domaine ====
CREATE OR REPLACE TABLE `@project@.enterprise_claim.claims` AS
SELECT * EXCEPT (rn)
FROM (
  SELECT
    stg.* EXCEPT (event_timestamp),
    'TECCARE' AS source_system,
    ROW_NUMBER() OVER (
      PARTITION BY stg.claim_id ORDER BY stg.event_timestamp DESC
    ) AS rn
  FROM `@project@.app_teccare.stg_claims_clean` AS stg
  INNER JOIN `@project@.enterprise_contract.contracts` AS c
    ON stg.contract_id = c.contract_id
)
WHERE rn = 1;

-- Rejets entreprise : sinistres orphelins (contrat inconnu du domaine)
INSERT INTO `@project@.ops.rejects`
  (reject_id, batch_id, pipeline_name, rule_code, error_message,
   source_record, rejected_at, retry_status)
SELECT
  GENERATE_UUID(), 'teccare_@ds@_seed', 'claims_daily',
  'ENT_002_UNKNOWN_CONTRACT',
  CONCAT('contrat inconnu du domaine Contrat: ', stg.contract_id),
  TO_JSON(stg), CURRENT_TIMESTAMP(), 'PENDING'
FROM `@project@.app_teccare.stg_claims_clean` AS stg
LEFT JOIN `@project@.enterprise_contract.contracts` AS c
  ON stg.contract_id = c.contract_id
WHERE c.contract_id IS NULL;

-- ==== Produit Data : photographie quotidienne des sinistres ====
CREATE TABLE IF NOT EXISTS `@project@.product_claim.claims_daily`
(
  snapshot_date      DATE    NOT NULL,
  claim_id           STRING  NOT NULL,
  contract_id        STRING  NOT NULL,
  customer_id        STRING,             -- pseudonymisé SHA-256
  claim_type         STRING,
  claim_status       STRING  NOT NULL,
  open_date          DATE,
  close_date         DATE,
  estimated_amount   NUMERIC,
  paid_amount        NUMERIC,
  is_open            BOOLEAN NOT NULL,
  product_code       STRING,             -- enrichi depuis le domaine Contrat
  channel_code       STRING,
  source_system      STRING  NOT NULL,
  ingestion_batch_id STRING  NOT NULL
)
PARTITION BY snapshot_date
CLUSTER BY claim_type, product_code;

DELETE FROM `@project@.product_claim.claims_daily`
WHERE snapshot_date = DATE('@ds@');

INSERT INTO `@project@.product_claim.claims_daily`
SELECT
  DATE('@ds@'),
  cl.claim_id,
  cl.contract_id,
  TO_HEX(SHA256(CONCAT(cl.customer_id, 'yoda-mnv'))),
  cl.claim_type,
  cl.claim_status,
  cl.open_date,
  cl.close_date,
  cl.estimated_amount,
  cl.paid_amount,
  cl.claim_status IN ('OPEN', 'ASSESSMENT'),
  c.product_code,
  c.channel_code,
  cl.source_system,
  cl.ingestion_batch_id
FROM `@project@.enterprise_claim.claims` AS cl
INNER JOIN `@project@.enterprise_contract.contracts` AS c
  ON cl.contract_id = c.contract_id;

-- ==== Exposition BI : sinistralité par produit et type ====
CREATE OR REPLACE VIEW `@project@.usage_bi.vw_claims` AS
SELECT
  snapshot_date, product_code, claim_type, claim_status,
  COUNT(*)              AS claim_count,
  COUNTIF(is_open)      AS open_claim_count,
  SUM(estimated_amount) AS total_estimated_amount,
  SUM(paid_amount)      AS total_paid_amount
FROM `@project@.product_claim.claims_daily`
GROUP BY snapshot_date, product_code, claim_type, claim_status;

-- ==== Journal d'exécution ====
INSERT INTO `@project@.ops.pipeline_runs`
  (run_id, pipeline_name, source_name, source_file, business_date, batch_id,
   start_time, end_time, input_rows, output_rows, reject_rows, status)
SELECT
  GENERATE_UUID(), 'claims_daily', 'teccare',
  'teccare_claims_@ds@.csv (seed)', DATE('@ds@'), 'teccare_@ds@_seed',
  CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
  (SELECT COUNT(*) FROM `@project@.app_teccare.raw_claims`),
  (SELECT COUNT(*) FROM `@project@.product_claim.claims_daily`
    WHERE snapshot_date = DATE('@ds@')),
  (SELECT COUNT(*) FROM `@project@.ops.rejects`
    WHERE batch_id = 'teccare_@ds@_seed'),
  'PARTIAL';
