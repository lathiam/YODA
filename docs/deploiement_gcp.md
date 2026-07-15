# Déployer YODA sur ton projet GCP

Deux façons de lancer le déploiement — la voie rapide (Cloud Shell) et la voie
continue (déclencheur Cloud Build, l'app GitHub étant déjà installée).

## Option A — Voie rapide : Cloud Shell (5 minutes)

1. Ouvre https://console.cloud.google.com et sélectionne (ou crée) ton projet.
2. Clique sur l'icône **Cloud Shell** (>_ en haut à droite).
3. Colle :

```bash
git clone https://github.com/lathiam/YODA.git && cd YODA
git checkout claude/technical-setup-hzjojy
bash scripts/deploy_gcp.sh dev
```

Le script active les APIs, crée le bucket d'état Terraform, applique
l'infrastructure (datasets BigQuery, tables `ops`, buckets landing/archive,
compte de service IAM), charge le référentiel produits dans BigQuery, dépose le
fichier d'exemple dans le landing et affiche les contrôles post-déploiement.

Coût : quasi nul (quelques Ko de stockage BigQuery/GCS, pas de ressource facturée en continu).

## Option B — Voie continue : déclencheur Cloud Build

Chaque push sur la branche relance tests + infrastructure + données de référence
(fichier `cloudbuild.yaml` à la racine).

1. **Connecter le dépôt** : console GCP → **Cloud Build → Dépôts** →
   *Associer un dépôt* → GitHub → sélectionner `lathiam/YODA`
   (l'app « Google Cloud Build » est déjà installée sur ton GitHub).
2. **Créer le déclencheur** : **Cloud Build → Déclencheurs** → *Créer* :
   - Événement : push sur une branche
   - Dépôt : `lathiam/YODA` ; branche : `^claude/technical-setup-hzjojy$` (ou `^main$` plus tard)
   - Configuration : fichier Cloud Build → `cloudbuild.yaml`
3. **Donner les droits au compte de service Cloud Build** (une seule fois,
   dans Cloud Shell) :

```bash
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
CB_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
for ROLE in roles/bigquery.admin roles/storage.admin \
            roles/iam.serviceAccountAdmin roles/resourcemanager.projectIamAdmin; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${CB_SA}" --role="$ROLE" --condition=None
done
```

4. **Lancer** : bouton *Exécuter le déclencheur*, ou simplement pousser un commit.

## Ce qui est déployé

| Ressource | Nom | Rôle |
|---|---|---|
| Datasets BigQuery | `app_impulse`, `enterprise_referential`, `enterprise_contract`, `product_contract`, `usage_bi`, `ops` | les couches de l'architecture |
| Tables | `product_contract.active_contracts_daily` (partitionnée/clusterisée), `ops.rejects`, `ops.pipeline_runs` | produit Data + exploitation |
| Buckets | `<projet>-landing`, `<projet>-archive`, `<projet>-tfstate` | arrivée fichiers, archivage, état Terraform |
| IAM | `yoda-pipeline-<env>` + rôles minimaux | compte de service des pipelines |
| Données | `enterprise_referential.products` + fichier d'exemple dans le landing | prêt à exécuter le flux |

## Et l'orchestration Composer ?

Le DAG `dags/contracts_active_daily.py` nécessite un environnement
**Cloud Composer**, qui est la seule brique réellement coûteuse
(**~300–400 €/mois**, facturé même à l'arrêt). Recommandation : ne le créer
que lorsque tu veux la planification quotidienne réelle.

```bash
# À ne lancer qu'en connaissance du coût :
gcloud composer environments create yoda-composer-dev \
  --location europe-west1 --image-version composer-2-airflow-2
# Puis renseigner la substitution _COMPOSER_BUCKET du déclencheur Cloud Build
# avec le bucket DAGs de l'environnement créé (visible dans la console Composer).
```

En attendant, tu peux exécuter la chaîne SQL manuellement dans BigQuery Studio
(fichiers `sql/` dans l'ordre : staging → entreprise → produit → vue) ou via
des requêtes programmées BigQuery (gratuit hors octets scannés).

## Adapter les identifiants de projet

Les fichiers `infra/environments/*.tfvars` contiennent des identifiants
d'exemple (`yoda-mnv-dev`...). Le script et Cloud Build passent ton vrai
`PROJECT_ID` en variable, donc rien à modifier pour commencer. Pour figer tes
identifiants réels, mets à jour ces fichiers et `config/*.yaml`.
