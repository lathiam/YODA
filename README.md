# Projet YODA — Your Own Data Architecture

Socle technique de la refonte de l'architecture Data vers GCP (BPCE Assurances — comptoir MNV, plateforme Groupe CDPG).

Ce dépôt implémente les patterns décrits dans la documentation d'architecture YODA :
couches de données, Pipeline Factory, orchestration Composer/Airflow, qualité, rejets,
contrats de données, CI/CD et infrastructure as code.

## Architecture en couches

```
Sources (Impulse, TecCare, Genesys, partenaires, Open Data)
        │  ingestion (LUCI / mise à disposition fichiers) + contrôles
        ▼
Modèle applicatif        app_<source>          ex: app_impulse.raw_contracts
        │  nettoyage technique, typage, rejets
        ▼
Staging                  app_<source>.stg_*    ex: app_impulse.stg_contracts_clean
        │  normalisation, déduplication, référentiels
        ▼
Modèle d'entreprise      enterprise_<domaine>  ex: enterprise_contract.contracts
        │  règles métier, agrégations
        ▼
Produits Data            product_<domaine>     ex: product_contract.active_contracts_daily
        │  vues d'exposition
        ▼
Modèles d'usage          usage_<type>_<équipe> ex: usage_bi.vw_active_contracts
        └──> BI (Power BI) / Data Science (Vertex AI, Dataiku) / Applications (API)
```

## Structure du dépôt

Conforme à la section 15.3 de la documentation :

```
YODA/
├── dags/                 # orchestration Composer / Airflow
├── src/yoda/             # Pipeline Factory : ingestion, transformations, qualité, rejets
├── sql/                  # transformations BigQuery par couche
├── tests/                # tests unitaires et d'intégration
├── config/               # paramètres par environnement (non secrets)
├── schemas/              # contrats de données et schémas
├── docs/                 # architecture, conventions, runbook, catalogue
├── infra/                # Terraform (datasets BigQuery, buckets GCS, IAM)
├── data/samples/         # jeux de données synthétiques pour la démo locale
├── requirements/         # dépendances Python
└── pipeline.yml          # configuration CI/CD
```

## Cas d'usage fil rouge : « Contrats actifs »

Le produit Data `product_contract.active_contracts_daily` (documentation §9) traverse
toutes les couches. Il est implémenté :

- en **SQL BigQuery** dans `sql/` (exécution cible sur GCP),
- en **Python pur** dans `src/yoda/` (logique testable + mode démo local sans GCP),
- orchestré par le DAG `dags/contracts_active_daily.py`.

### Démo locale (sans GCP)

```bash
make install       # installe les dépendances de dev
make demo          # exécute le pipeline complet sur data/samples/
make test          # lance tous les tests
```

La démo produit chaque couche en CSV dans `data/output/` ainsi que les rejets et les
métadonnées d'exécution (`run_id`, volumes, statut) — mêmes principes qu'en production.

### Exécution cible sur GCP

Guide complet : [docs/deploiement_gcp.md](docs/deploiement_gcp.md)

- **En un passage (Cloud Shell)** : `bash scripts/deploy_gcp.sh dev`
- **En continu (Cloud Build)** : déclencheur sur ce dépôt avec `cloudbuild.yaml`
- Le DAG `contracts_active_daily` (Composer, optionnel) orchestre : capteur fichier →
  contrôles d'ingestion → chargement raw → staging → modèle d'entreprise →
  produit Data → tests qualité → publication.

## Principes appliqués (documentation §11.1)

- **Idempotent** : chaque étape écrit par partition `(business_date, batch_id)` — une relance ne duplique pas.
- **Observable** : métadonnées d'exécution normalisées (`run_id`, volumes, rejets, durées, statut).
- **Rejouable** : tout est paramétré par date métier et lot.
- **Découplé** : ingestion, transformations techniques et règles métier séparées.
- **Testable** : règles critiques couvertes par des tests unitaires et de données.
- **Paramétrable** : environnement, chemins et datasets dans `config/<env>.yaml`, jamais en dur.
- **Sécurisé** : aucun secret dans le dépôt — Secret Manager + comptes de service par environnement.
- **Documenté** : catalogue et runbook dans `docs/`, contrats dans `schemas/`.

## Environnements

| Environnement | Usage | Données |
|---|---|---|
| DEV | développement, tests rapides | synthétiques / masquées |
| PREPROD | recette intégration, sécurité, perf | proches prod, protégées |
| PROD | exécution officielle | réelles, supervision renforcée |

## Documentation

- [Architecture détaillée](docs/architecture.md)
- [Conventions de nommage et de développement](docs/conventions.md)
- [Runbook — Contrats actifs](docs/runbook_contrats_actifs.md)
- [Catalogue — product_contract.active_contracts_daily](docs/catalogue/product_contract.active_contracts_daily.md)

> **Note** : les choix BigQuery / Cloud Composer sont l'hypothèse de travail de la
> documentation source (à confirmer avec l'équipe plateforme). Le code est structuré
> pour que le moteur d'exécution soit remplaçable (principe d'architecture modulaire).
