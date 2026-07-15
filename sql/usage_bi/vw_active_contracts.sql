-- Exposition BI : vue stable consommée par Power BI (documentation §6.7).
-- Interface protégée : colonnes strictement nécessaires, agrégats performants,
-- pas de donnée personnelle directe. La structure interne peut évoluer sans
-- casser les rapports tant que cette vue reste compatible.

CREATE OR REPLACE VIEW `{{ params.project_id }}.usage_bi.vw_active_contracts` AS
SELECT
  snapshot_date,
  product_code,
  channel_code,
  contract_status,
  COUNT(*)                                        AS contract_count,
  COUNTIF(is_active)                              AS active_contract_count,
  SUM(IF(is_active, annual_premium, 0))           AS active_annual_premium
FROM `{{ params.project_id }}.product_contract.active_contracts_daily`
GROUP BY snapshot_date, product_code, channel_code, contract_status;
