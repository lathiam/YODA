-- Produit Data : enterprise_contract.contracts -> product_contract.active_contracts_daily
-- Photographie quotidienne du portefeuille (schéma documentation §9.5).
-- Règle métier d'activité (§9.4, validée par le Data Owner du domaine Contrat) :
--   statut ACTIVE + date d'effet atteinte + non terminé à la date de snapshot.
-- Idempotent : la partition snapshot_date est remplacée à chaque exécution.

DECLARE snapshot DATE DEFAULT DATE('{{ ds }}');

DELETE FROM `{{ params.project_id }}.product_contract.active_contracts_daily`
WHERE snapshot_date = snapshot;

INSERT INTO `{{ params.project_id }}.product_contract.active_contracts_daily`
  (snapshot_date, contract_id, customer_id, product_code, contract_status,
   start_date, end_date, annual_premium, channel_code, is_active,
   source_system, ingestion_batch_id)
SELECT
  snapshot,
  contract_id,
  -- Pseudonymisation du client pour les usages sans besoin d'identité (§13.3)
  TO_HEX(SHA256(CONCAT(customer_id, 'yoda-mnv'))) AS customer_id,
  product_code,
  contract_status,
  start_date,
  end_date,
  annual_premium,
  channel_code,
  (
    contract_status = 'ACTIVE'
    AND start_date <= snapshot
    AND (end_date IS NULL OR end_date >= snapshot)
  ) AS is_active,
  source_system,
  ingestion_batch_id
FROM `{{ params.project_id }}.enterprise_contract.contracts`;
