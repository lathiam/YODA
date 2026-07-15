# Runbook — pipeline `contracts_active_daily`

Produit Data : `product_contract.active_contracts_daily`
SLA : publication avant **07:00 UTC** (déclenchement 05:00 UTC).
Consommateurs : vue `usage_bi.vw_active_contracts` (Power BI), jeux Data Science.

## Symptômes et diagnostics

### 1. Le capteur `wait_for_impulse_file` expire (timeout 2 h)

- **Impact** : produit non rafraîchi ; les rapports affichent J-1.
- **Diagnostic** : vérifier la présence du fichier dans
  `gs://yoda-mnv-<env>-landing/impulse/contracts/<YYYYMMDD>/`.
- **Correction** : si le fichier est en retard côté producteur, contacter
  l'équipe Impulse / BPCE-IT (contrat de données :
  `schemas/data_contract_impulse_contracts.yaml`, fenêtre d'arrivée 05:00).
- **Reprise** : dès le fichier déposé, relancer le DAG run du jour
  (`airflow dags trigger -e <date>` ou interface Composer). Idempotent.

### 2. Échec `load_raw_contracts` ou contrôle d'ingestion `ING_*`

| Code | Cause probable | Action |
|---|---|---|
| `ING_001_MISSING` | fichier absent au chargement | voir symptôme 1 |
| `ING_002_EMPTY` | fichier vide livré | demander une relivraison au producteur |
| `ING_003_EXTENSION` / `ING_004_ENCODING` | format non conforme au contrat | rejeter le lot, notifier le producteur, ne pas corriger à la main |
| `ING_006_COLUMNS` | changement de schéma non annoncé | escalade Data Steward : violation du contrat de données (préavis 30 j) |
| doublon checksum | même contenu livré deux fois | aucun impact (idempotent) ; vérifier avec le producteur |

### 3. Taux de rejet au-dessus du seuil (`PIPELINE_BLOCKED`)

- **Impact** : publication bloquée volontairement (qualité non garantie).
- **Diagnostic** : `SELECT rule_code, COUNT(*) FROM ops.rejects WHERE batch_id = '<batch>' GROUP BY 1` —
  en local, consulter `data/output/ops/rejects/`.
- **Correction** : selon le `rule_code` dominant (voir tableau des codes dans
  `docs/conventions.md`). Une dérive massive de `STG_002_UNKNOWN_STATUS`
  signale souvent un nouveau statut côté Impulse : faire valider le mapping par
  le Data Owner avant de l'ajouter.
- **Reprise** : après correction (relivraison ou évolution validée), relancer
  le DAG run de la date concernée.

### 4. Échec d'un contrôle qualité `qa_*`

- **Impact** : publication bloquée, la vue BI reste sur la dernière partition saine.
- **Diagnostic** : la requête du contrôle en échec est dans le DAG ; l'exécuter
  manuellement pour identifier les lignes fautives.
- **Correction** : remonter à la partition staging du jour, identifier le lot,
  corriger à la source (jamais dans la cible), relancer.

### 5. Écart de réconciliation avec le legacy (phase double run)

- **Impact** : bascule suspendue pour ce périmètre.
- **Diagnostic** : comparer par segment (produit, statut, canal, date) —
  requêtes de réconciliation de la documentation §18.3.
- **Action** : chaque écart doit être expliqué et accepté formellement par le
  métier avant le Go/No Go. Écart non expliqué = No Go.

## Escalade

| Composant | Contact |
|---|---|
| Fichier source, livraison | Équipe Impulse / BPCE-IT (mise à disposition fichiers) |
| Règles métier, seuils qualité | Data Owner domaine Contrat |
| Plateforme GCP, IAM, Composer | Équipe plateforme / Cloud Engineering |
| Pipeline, transformations | Data Engineers domaine Contrat (astreinte) |

## Vérifications post-reprise

1. Statut du DAG run : succès complet.
2. `ops.pipeline_runs` : volumes cohérents avec la veille (±10 %).
3. `SELECT COUNT(*) FROM product_contract.active_contracts_daily WHERE snapshot_date = '<date>'` > 0.
4. Rafraîchissement du rapport Power BI de contrôle.
5. Clôturer l'incident avec cause racine et action préventive (doc §16.2).
