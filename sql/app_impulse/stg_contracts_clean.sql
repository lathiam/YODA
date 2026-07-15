-- Couche staging : app_impulse.raw_contracts -> app_impulse.stg_contracts_clean
-- Nettoyage technique : typage, harmonisation des statuts, filtrage des lignes
-- invalides (isolées dans ops.rejects par la requête sœur stg_contracts_rejects.sql).
-- Idempotent : la partition de la date métier est remplacée à chaque exécution.

DECLARE business_date DATE DEFAULT DATE('{{ ds }}');

MERGE `{{ params.project_id }}.app_impulse.stg_contracts_clean` AS target
USING (
  WITH typed AS (
    SELECT
      TRIM(contract_id)                                   AS contract_id,
      TRIM(customer_id)                                   AS customer_id,
      UPPER(TRIM(product_code))                           AS product_code,
      CASE UPPER(TRIM(status))
        WHEN 'EN_COURS' THEN 'ACTIVE'
        WHEN 'ACTIF'    THEN 'ACTIVE'
        WHEN 'SUSPENDU' THEN 'SUSPENDED'
        WHEN 'RESILIE'  THEN 'TERMINATED'
        WHEN 'ANNULE'   THEN 'CANCELLED'
        ELSE NULL
      END                                                 AS contract_status,
      SAFE.PARSE_DATE('%Y-%m-%d', TRIM(start_date))       AS start_date,
      SAFE.PARSE_DATE('%Y-%m-%d', NULLIF(TRIM(end_date), '')) AS end_date,
      SAFE_CAST(REPLACE(TRIM(annual_premium), ',', '.') AS NUMERIC) AS annual_premium,
      UPPER(COALESCE(NULLIF(TRIM(channel_code), ''), 'UNKNOWN'))    AS channel_code,
      TRIM(event_timestamp)                               AS event_timestamp,
      ingestion_batch_id,
      business_date                                       AS business_date
    FROM `{{ params.project_id }}.app_impulse.raw_contracts`
    WHERE _PARTITIONDATE = business_date
  )
  SELECT * FROM typed
  WHERE contract_id IS NOT NULL AND contract_id != ''
    AND customer_id IS NOT NULL AND customer_id != ''
    AND product_code IS NOT NULL AND product_code != ''
    AND contract_status IS NOT NULL
    AND start_date IS NOT NULL
    AND (end_date IS NULL OR end_date >= start_date)
    AND annual_premium IS NOT NULL AND annual_premium >= 0
) AS source
ON FALSE
WHEN NOT MATCHED BY SOURCE AND target.business_date = business_date THEN DELETE
WHEN NOT MATCHED BY TARGET THEN INSERT ROW;
