# Conventions de nommage et de développement

Proposition alignée sur la documentation §10.3 — les normes Groupe et la
Pipeline Factory restent la référence officielle en cas de divergence.

## Datasets

| Pattern | Exemple | Couche |
|---|---|---|
| `app_<source>` | `app_impulse` | Modèle applicatif |
| `enterprise_<domaine>` | `enterprise_contract` | Modèle d'entreprise |
| `product_<domaine>` | `product_contract` | Produits Data |
| `usage_<type>[_<équipe>]` | `usage_bi` | Modèles d'usage |
| `ops` | `ops` | Exploitation transverse |

## Tables et vues

| Pattern | Exemple | Rôle |
|---|---|---|
| `raw_<objet>` | `raw_contracts` | Donnée brute, contexte d'origine conservé |
| `stg_<objet>_<qualificatif>` | `stg_contracts_clean` | Nettoyage technique |
| `<objet>` | `contracts` | Objet métier du domaine |
| `<objet>_<granularité>` | `active_contracts_daily` | Produit à granularité explicite |
| `vw_<objet>[_<usage>]` | `vw_active_contracts` | Vue d'exposition |

## Codes de règles (rejets et contrôles)

`<COUCHE>_<numéro>_<LIBELLÉ>` — préfixes : `ING_` (ingestion), `STG_` (staging),
`ENT_` (entreprise), `PRD_` (produit). Exemple : `STG_004_DATE_ORDER`.
Chaque code est documenté dans le runbook avec son diagnostic et sa correction.

## Git et revues

- Une branche par évolution : `feature/<domaine>-<sujet>`, `fix/<sujet>`.
- Merge Request obligatoire, relue par un pair, CI verte avant merge.
- Les transformations SQL, les tests et la documentation évoluent dans le même
  commit (documentation proche du code, doc §14.3).
- Messages de commit : impératif, en français, préfixés par le périmètre
  (`contrat:`, `infra:`, `qualité:`...).

## DAGs Airflow

- `dag_id` = nom du produit Data au pluriel + fréquence : `contracts_active_daily`.
- Tags obligatoires : `domaine:<x>`, `source:<y>`, `produit:<z>`, environnement.
- `owner` = équipe du domaine ; jamais de secret ni de valeur d'environnement en dur.
- `max_active_runs=1` et écritures par partition pour l'idempotence.

## Python

- `ruff` (lint) et `pytest` obligatoires en CI.
- Règles métier : fonctions pures, testées unitairement, docstring citant la
  section de la documentation source et le Data Owner validant.
- Tout rejet passe par `RejectStore` — aucune ligne écartée silencieusement.
