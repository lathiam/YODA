# Catalogue — `product_contract.active_contracts_daily`

Fiche produit Data (informations minimales, documentation §14.2).

## Métier

| Élément | Valeur |
|---|---|
| Nom fonctionnel | Portefeuille contrats — photographie quotidienne |
| Description | Suivi quotidien des contrats : actifs, souscriptions, résiliations, primes, répartition par produit/canal |
| Domaine | Contrat |
| Data Owner | À nommer (domaine Contrat) |
| Référent technique | Équipe Data Engineering domaine Contrat |
| Règle clé | `is_active` = statut ACTIVE **et** date d'effet atteinte **et** non terminé au `snapshot_date` (validée §9.4) |

## Technique

| Élément | Valeur |
|---|---|
| Dataset.table | `product_contract.active_contracts_daily` |
| Schéma | `schemas/product_active_contracts_daily.schema.yaml` |
| Clé / granularité | 1 ligne par (`contract_id`, `snapshot_date`) |
| Partitionnement | `snapshot_date` (jour) |
| Clustering | `product_code`, `channel_code` |
| Fréquence | quotidienne, publication avant 07:00 UTC |
| Pipeline | DAG `contracts_active_daily` (`dags/contracts_active_daily.py`) |

## Qualité

Contrôles exécutés à chaque publication (bloquants en gras) :
**contract_id non nul**, **unicité (contract_id, snapshot_date)**,
**cohérence des dates**, **prime positive**, **produit au référentiel**,
réconciliation legacy (phase double run), fraîcheur < SLA.
Résultats : table `ops.pipeline_runs` + logs du DAG.

## Sécurité

| Élément | Valeur |
|---|---|
| Classification | Confidentielle (client pseudonymisé SHA-256) |
| Accès direct | Data Engineers du domaine + compte de service pipeline |
| Accès consommateurs | via `usage_bi.vw_active_contracts` uniquement (groupe BI) |
| Colonnes protégées | `customer_id` pseudonymisé dès cette couche |

## Lineage

```
Fichier Impulse (GCS landing)
  -> app_impulse.raw_contracts
  -> app_impulse.stg_contracts_clean
  -> enterprise_contract.contracts        (+ enterprise_referential.products)
  -> product_contract.active_contracts_daily
  -> usage_bi.vw_active_contracts -> Power BI « Portefeuille contrats »
```

## Exploitation

| Élément | Valeur |
|---|---|
| SLA | données du jour J disponibles à J 07:00 UTC |
| Runbook | `docs/runbook_contrats_actifs.md` |
| Reprise | relance idempotente du DAG run de la date concernée |
| Rejets | `ops.rejects` filtrés sur `pipeline_name = 'contracts_active_daily'` |
