-- Modèle d'entreprise : app_impulse.stg_contracts_clean -> enterprise_contract.contracts
-- Objet métier Contrat, stable et découplé de la structure interne d'Impulse.
-- Déduplication : dernier événement par contract_id (réémissions, doublons).
-- Rattachement obligatoire au référentiel produit centralisé.

DECLARE business_date DATE DEFAULT DATE('{{ ds }}');

MERGE `{{ params.project_id }}.enterprise_contract.contracts` AS target
USING (
  WITH deduplicated AS (
    SELECT
      stg.*,
      ROW_NUMBER() OVER (
        PARTITION BY stg.contract_id
        ORDER BY stg.event_timestamp DESC
      ) AS rn
    FROM `{{ params.project_id }}.app_impulse.stg_contracts_clean` AS stg
    INNER JOIN `{{ params.project_id }}.enterprise_referential.products` AS ref
      ON stg.product_code = ref.product_code
    WHERE stg.business_date = business_date
  )
  SELECT
    contract_id,
    customer_id,
    product_code,
    contract_status,
    start_date,
    end_date,
    annual_premium,
    channel_code,
    'IMPULSE'      AS source_system,
    ingestion_batch_id,
    business_date
  FROM deduplicated
  WHERE rn = 1
) AS source
ON target.contract_id = source.contract_id
WHEN MATCHED THEN UPDATE SET
  customer_id        = source.customer_id,
  product_code       = source.product_code,
  contract_status    = source.contract_status,
  start_date         = source.start_date,
  end_date           = source.end_date,
  annual_premium     = source.annual_premium,
  channel_code       = source.channel_code,
  source_system      = source.source_system,
  ingestion_batch_id = source.ingestion_batch_id,
  business_date      = source.business_date
WHEN NOT MATCHED THEN INSERT ROW;
