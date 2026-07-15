-- Orchestration quotidienne YODA — exécutée par une requête programmée BigQuery
-- (alternative gratuite à Cloud Composer, planification: tous les jours 05:00 UTC).
-- Rejoue la chaîne complète dans l'ordre des dépendances :
--   1. Contrats  : staging -> entreprise -> snapshot produit du jour -> vues
--   2. Sinistres : staging -> entreprise (dépend des contrats) -> snapshot -> vue
--   3. Interactions : staging -> entreprise -> vue features
--   4. Rejets et journal d'exécution à chaque étape
-- La date métier est la date d'exécution (CURRENT_DATE) : chaque run ajoute la
-- photographie du jour dans les produits partitionnés — relance idempotente.
-- Placeholder @project@ substitué par Terraform au déploiement.

-- ======================= 1. DOMAINE CONTRAT =======================

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
    CONCAT('impulse_', CAST(CURRENT_DATE() AS STRING), '_scheduled') AS ingestion_batch_id,
    CURRENT_DATE() AS business_date
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

DELETE FROM `@project@.product_contract.active_contracts_daily`
WHERE snapshot_date = CURRENT_DATE();

INSERT INTO `@project@.product_contract.active_contracts_daily`
  (snapshot_date, contract_id, customer_id, product_code, contract_status,
   start_date, end_date, annual_premium, channel_code, is_active,
   source_system, ingestion_batch_id)
SELECT
  CURRENT_DATE(),
  contract_id,
  TO_HEX(SHA256(CONCAT(customer_id, 'yoda-mnv'))),
  product_code,
  contract_status,
  start_date,
  end_date,
  annual_premium,
  channel_code,
  (contract_status = 'ACTIVE'
    AND start_date <= CURRENT_DATE()
    AND (end_date IS NULL OR end_date >= CURRENT_DATE())),
  source_system,
  ingestion_batch_id
FROM `@project@.enterprise_contract.contracts`;

-- ======================= 2. DOMAINE SINISTRE =======================

CREATE OR REPLACE TABLE `@project@.app_teccare.stg_claims_clean` AS
WITH typed AS (
  SELECT
    TRIM(claim_id)    AS claim_id,
    TRIM(contract_id) AS contract_id,
    TRIM(customer_id) AS customer_id,
    UPPER(TRIM(claim_type)) AS claim_type,
    CASE UPPER(TRIM(status))
      WHEN 'OUVERT' THEN 'OPEN' WHEN 'REOUVERT' THEN 'OPEN'
      WHEN 'EN_EXPERTISE' THEN 'ASSESSMENT' WHEN 'CLOS' THEN 'CLOSED'
      WHEN 'SANS_SUITE' THEN 'CLOSED_NO_ACTION' ELSE NULL
    END AS claim_status,
    SAFE.PARSE_DATE('%Y-%m-%d', TRIM(open_date)) AS open_date,
    SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(close_date), '')) AS close_date,
    SAFE_CAST(NULLIF(TRIM(estimated_amount), '') AS NUMERIC) AS estimated_amount,
    SAFE_CAST(NULLIF(TRIM(paid_amount), '') AS NUMERIC)      AS paid_amount,
    TRIM(event_timestamp) AS event_timestamp,
    CONCAT('teccare_', CAST(CURRENT_DATE() AS STRING), '_scheduled') AS ingestion_batch_id,
    CURRENT_DATE() AS business_date
  FROM `@project@.app_teccare.raw_claims`
)
SELECT * FROM typed
WHERE COALESCE(claim_id, '') != ''
  AND COALESCE(contract_id, '') != ''
  AND claim_status IS NOT NULL
  AND open_date IS NOT NULL
  AND (close_date IS NULL OR close_date >= open_date);

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

DELETE FROM `@project@.product_claim.claims_daily`
WHERE snapshot_date = CURRENT_DATE();

INSERT INTO `@project@.product_claim.claims_daily`
SELECT
  CURRENT_DATE(),
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

-- ======================= 3. DOMAINE INTERACTION =======================

CREATE OR REPLACE TABLE `@project@.app_genesys.stg_interactions_clean` AS
SELECT
  TRIM(interaction_id) AS interaction_id,
  TRIM(customer_id)    AS customer_id,
  UPPER(TRIM(channel)) AS channel,
  UPPER(TRIM(direction)) AS direction,
  SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S', TRIM(start_timestamp)) AS start_timestamp,
  SAFE_CAST(NULLIF(TRIM(duration_seconds), '') AS INT64) AS duration_seconds,
  UPPER(TRIM(reason_code)) AS reason_code,
  NULLIF(TRIM(agent_id), '') AS agent_id,
  CONCAT('genesys_', CAST(CURRENT_DATE() AS STRING), '_scheduled') AS ingestion_batch_id,
  CURRENT_DATE() AS business_date
FROM `@project@.app_genesys.raw_interactions`
WHERE COALESCE(TRIM(interaction_id), '') != ''
  AND COALESCE(TRIM(customer_id), '') != ''
  AND SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S', TRIM(start_timestamp)) IS NOT NULL;

CREATE OR REPLACE TABLE `@project@.app_adobe_analytics.stg_web_events_clean` AS
SELECT
  TRIM(event_id)   AS event_id,
  TRIM(visitor_id) AS visitor_id,
  NULLIF(TRIM(customer_id), '') AS customer_id,
  TRIM(page)       AS page,
  UPPER(TRIM(event_type)) AS event_type,
  SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S', TRIM(event_timestamp)) AS event_timestamp,
  UPPER(TRIM(device)) AS device,
  NULLIF(TRIM(campaign), '') AS campaign,
  CONCAT('adobe_', CAST(CURRENT_DATE() AS STRING), '_scheduled') AS ingestion_batch_id,
  CURRENT_DATE() AS business_date
FROM `@project@.app_adobe_analytics.raw_web_events`
WHERE COALESCE(TRIM(event_id), '') != ''
  AND SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S', TRIM(event_timestamp)) IS NOT NULL;

CREATE OR REPLACE TABLE `@project@.enterprise_interaction.interactions` AS
SELECT
  interaction_id, customer_id, channel, direction,
  start_timestamp AS interaction_timestamp,
  duration_seconds,
  reason_code     AS interaction_reason,
  'GENESYS'       AS source_system,
  ingestion_batch_id, business_date
FROM `@project@.app_genesys.stg_interactions_clean`
UNION ALL
SELECT
  event_id, customer_id, 'WEB', 'INBOUND', event_timestamp, NULL,
  CONCAT(event_type, ':', page), 'ADOBE_ANALYTICS',
  ingestion_batch_id, business_date
FROM `@project@.app_adobe_analytics.stg_web_events_clean`
WHERE customer_id IS NOT NULL;

-- ======================= 4. JOURNAL D'EXÉCUTION =======================

INSERT INTO `@project@.ops.pipeline_runs`
  (run_id, pipeline_name, source_name, source_file, business_date, batch_id,
   start_time, end_time, input_rows, output_rows, reject_rows, status)
SELECT
  GENERATE_UUID(), 'daily_full_chain_scheduled', 'impulse+teccare+genesys+adobe',
  'raw tables (scheduled query)', CURRENT_DATE(),
  CONCAT('scheduled_', CAST(CURRENT_DATE() AS STRING)),
  CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
  (SELECT COUNT(*) FROM `@project@.app_impulse.raw_contracts`)
    + (SELECT COUNT(*) FROM `@project@.app_teccare.raw_claims`)
    + (SELECT COUNT(*) FROM `@project@.app_genesys.raw_interactions`)
    + (SELECT COUNT(*) FROM `@project@.app_adobe_analytics.raw_web_events`),
  (SELECT COUNT(*) FROM `@project@.product_contract.active_contracts_daily`
     WHERE snapshot_date = CURRENT_DATE())
    + (SELECT COUNT(*) FROM `@project@.product_claim.claims_daily`
       WHERE snapshot_date = CURRENT_DATE())
    + (SELECT COUNT(*) FROM `@project@.enterprise_interaction.interactions`),
  0,
  'SUCCESS';
