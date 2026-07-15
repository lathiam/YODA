-- Chaîne Interactions (domaine Interaction, sources Genesys + Adobe Analytics).
-- Portée du lot : raw -> staging -> modèle d'entreprise unifié des contacts.
-- Le produit Data (parcours client, pression commerciale) sera cadré avec le
-- métier dans un lot ultérieur — la couche entreprise est déjà consommable.
-- Placeholders @project@ et @ds@ substitués par scripts/seed_bigquery.sh.

-- ============ Staging Genesys ============
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
  'genesys_@ds@_seed' AS ingestion_batch_id,
  DATE('@ds@')        AS business_date
FROM `@project@.app_genesys.raw_interactions`
WHERE COALESCE(TRIM(interaction_id), '') != ''
  AND COALESCE(TRIM(customer_id), '') != ''
  AND SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S', TRIM(start_timestamp)) IS NOT NULL;

-- ============ Staging Adobe Analytics ============
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
  'adobe_@ds@_seed' AS ingestion_batch_id,
  DATE('@ds@')      AS business_date
FROM `@project@.app_adobe_analytics.raw_web_events`
WHERE COALESCE(TRIM(event_id), '') != ''
  AND SAFE.PARSE_TIMESTAMP('%Y-%m-%dT%H:%M:%S', TRIM(event_timestamp)) IS NOT NULL;

-- ==== Modèle d'entreprise : contact unifié multi-canal ====
-- Le concept métier « Interaction » est découplé des outils sources :
-- un contact téléphonique Genesys et un parcours web Adobe deviennent le
-- même objet, comparable et agrégeable (doc §6.6).
CREATE OR REPLACE TABLE `@project@.enterprise_interaction.interactions` AS
SELECT
  interaction_id                    AS interaction_id,
  customer_id,
  channel,
  direction,
  start_timestamp                   AS interaction_timestamp,
  duration_seconds,
  reason_code                       AS interaction_reason,
  'GENESYS'                         AS source_system,
  ingestion_batch_id,
  business_date
FROM `@project@.app_genesys.stg_interactions_clean`
UNION ALL
SELECT
  event_id,
  customer_id,
  'WEB',
  'INBOUND',
  event_timestamp,
  NULL,
  CONCAT(event_type, ':', page),
  'ADOBE_ANALYTICS',
  ingestion_batch_id,
  business_date
FROM `@project@.app_adobe_analytics.stg_web_events_clean`
WHERE customer_id IS NOT NULL;   -- seuls les visiteurs identifiés deviennent des interactions client

-- ==== Exposition Data Science : intensité de contact par client ====
CREATE OR REPLACE VIEW `@project@.usage_datascience.vw_customer_contact_features` AS
SELECT
  TO_HEX(SHA256(CONCAT(customer_id, 'yoda-mnv'))) AS customer_id,
  business_date,
  COUNT(*)                                   AS interaction_count,
  COUNTIF(channel = 'PHONE')                 AS phone_count,
  COUNTIF(channel = 'WEB')                   AS web_count,
  COUNTIF(interaction_reason LIKE 'RECLAMATION%' OR interaction_reason LIKE 'RESILIATION%')
                                             AS friction_signal_count,
  SUM(COALESCE(duration_seconds, 0))         AS total_duration_seconds
FROM `@project@.enterprise_interaction.interactions`
GROUP BY customer_id, business_date;

-- ==== Journal d'exécution ====
INSERT INTO `@project@.ops.pipeline_runs`
  (run_id, pipeline_name, source_name, source_file, business_date, batch_id,
   start_time, end_time, input_rows, output_rows, reject_rows, status)
SELECT
  GENERATE_UUID(), 'interactions_daily', 'genesys+adobe',
  'genesys_interactions_@ds@.csv + adobe_web_events_@ds@.csv (seed)',
  DATE('@ds@'), 'interactions_@ds@_seed',
  CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP(),
  (SELECT COUNT(*) FROM `@project@.app_genesys.raw_interactions`)
    + (SELECT COUNT(*) FROM `@project@.app_adobe_analytics.raw_web_events`),
  (SELECT COUNT(*) FROM `@project@.enterprise_interaction.interactions`),
  0,
  'SUCCESS';
