# Architecture technique YODA

Ce document décrit l'implémentation technique du socle, en regard de la
documentation d'architecture du programme (support « Projet YODA — refonte de
l'architecture vers GCP »).

## Vue d'ensemble

| Couche (doc §6) | Implémentation | Emplacement |
|---|---|---|
| Sources & ingestion | Bucket GCS landing + contrôles d'entrée | `infra/storage.tf`, `src/yoda/ingestion.py` |
| Modèle applicatif | Dataset `app_impulse` (raw + staging) | `sql/app_impulse/`, `infra/datasets.tf` |
| Pipeline Factory & Composer | Package `yoda` + DAG Airflow | `src/yoda/`, `dags/` |
| Modèle d'entreprise | Dataset `enterprise_contract` | `sql/enterprise_contract/` |
| Exposition / Produits Data | Dataset `product_contract` + vues | `sql/product_contract/`, `sql/usage_bi/` |
| Modèles d'usage | Vues `usage_bi` (Power BI) | `sql/usage_bi/` |
| Transverse : qualité | Framework sévérités/dimensions | `src/yoda/quality.py` |
| Transverse : observabilité | Tables `ops.*` + journaux run | `src/yoda/metadata.py`, `infra/datasets.tf` |
| Transverse : rejets | Table `ops.rejects` | `src/yoda/rejects.py` |
| Transverse : IAM/sécurité | Comptes de service, groupes, moindre privilège | `infra/iam.tf` |
| Transverse : CI/CD | GitHub Actions + chaîne de promotion | `.github/workflows/ci.yml`, `pipeline.yml` |

## Décisions techniques

### D1 — Double implémentation SQL + Python de la logique métier

La logique du cas d'usage existe en SQL BigQuery (`sql/`, exécution cible) et en
Python pur (`src/yoda/transformations/`, testable localement et support du mode
démo). Les deux implémentations partagent les mêmes règles (mapping de statuts,
règle d'activité, codes de rejet) ; les tests unitaires Python constituent la
spécification exécutable de ces règles. Toute évolution de règle métier doit
modifier les deux et être validée par le Data Owner.

**Pourquoi** : le support ne confirme pas encore le moteur (hypothèse BigQuery).
La logique en Python standard reste portable ; le SQL est l'optimisation cible.

### D2 — Idempotence par partition et batch_id déterministe

- `batch_id = <source>_<date_metier>_<nom_fichier>` : rejouer un lot produit le
  même identifiant, donc écrase sa propre partition (pas de doublon).
- Toutes les tables cibles sont partitionnées par date (`snapshot_date`,
  `business_date`, `_PARTITIONDATE`) et écrites en `WRITE_TRUNCATE`/`DELETE+INSERT`
  sur la partition traitée.
- Le ledger d'ingestion (checksum SHA-256) détecte un même contenu livré sous
  deux noms différents (double chargement).

### D3 — Publication conditionnée par la qualité

L'ordre des étapes garantit qu'aucune donnée non contrôlée n'atteint les
consommateurs : le produit Data n'est écrit qu'après le passage des contrôles
bloquants (sévérités CRITICAL/HIGH, doc §12.3). Les sévérités MEDIUM/LOW
publient avec alerte.

### D4 — Pseudonymisation à l'exposition

`customer_id` est pseudonymisé (SHA-256 salé) dès la couche produit : les usages
BI n'ont pas besoin de l'identité (minimisation RGPD, doc §13). Les couches
internes conservent l'identifiant réel sous accès restreint pour les
rapprochements ; le droit à l'effacement s'exerce sur ces couches et se propage
par reconstruction des partitions.

### D5 — FinOps par construction

- Partitionnement + clustering pour limiter le volume analysé (doc §17.2).
- Labels `program/comptoir/environment/layer/domain` sur chaque ressource
  Terraform : attribution des coûts par domaine et produit.
- Vues d'agrégats (`usage_bi`) pour éviter les scans récurrents de la table fine.
- Cycle de vie GCS : landing purgé à 30 j, archive en Coldline à 90 j.

## Flux du cas d'usage « Contrats actifs »

```
GCS landing: impulse/contracts/YYYYMMDD/impulse_contracts_YYYYMMDD.csv
  │ 1. capteur (fenêtre d'arrivée) + contrôles: présence, intégrité, format,
  │    colonnes, encodage, idempotence (checksum) — src/yoda/ingestion.py
  ▼
app_impulse.raw_contracts (partition du jour, brut + batch_id + fichier source)
  │ 2. staging: typage, harmonisation statuts, rejets motivés -> ops.rejects
  ▼
app_impulse.stg_contracts_clean
  │ 3. jointure référentiel produits + déduplication (dernier événement)
  ▼
enterprise_contract.contracts (objet métier stable, découplé d'Impulse)
  │ 4. règle d'activité + pseudonymisation + snapshot quotidien
  ▼
product_contract.active_contracts_daily (partition snapshot_date)
  │ 5. contrôles qualité bloquants (§9.6) — sinon publication refusée
  ▼
usage_bi.vw_active_contracts ──> Power BI / Data Science / API
```

## Sécurité et RGPD

- **Moindre privilège** : compte de service `yoda-pipeline-<env>` limité à ses
  buckets et datasets ; consommateurs BI limités à `usage_bi` (jamais les
  couches internes).
- **Aucun secret dans le dépôt** : configuration non sensible dans `config/`,
  secrets via Secret Manager et comptes de service Composer.
- **Classification** : le fichier Impulse est classé « personnelle » dans son
  contrat de données (`schemas/data_contract_impulse_contracts.yaml`).
- **Conservation** : cycles de vie GCS définis, durées exactes à valider avec
  le DPO avant la production.
- **Environnements séparés** : projets GCP distincts dev/preprod/prod, données
  synthétiques en DEV.

## Points ouverts (hérités de la documentation §25)

À confirmer avec l'équipe plateforme avant industrialisation :
services GCP officiellement retenus, nature exacte de LUCI et de la Pipeline
Factory Groupe, outil de catalogue/lineage Groupe, normes de nommage
officielles, contenu des lots 01-10, organisation IAM Groupe.
