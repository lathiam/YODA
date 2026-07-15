# Formation — L'orchestration de A à Z (pour Data Engineer junior)

> **Objectif** : à la fin de ce document, tu sauras expliquer, créer, surveiller
> et dépanner une orchestration de pipeline Data — d'abord avec les **requêtes
> programmées BigQuery** (ce qui tourne déjà sur ton projet), puis avec
> **Cloud Composer / Airflow** (la cible de la mission YODA). Tout est
> pratiquable gratuitement sur ton projet `yoda-data-2026`.

---

## Partie 1 — C'est quoi, l'orchestration ? (les concepts avant les outils)

### 1.1 Le problème à résoudre

Un pipeline Data, c'est une suite d'étapes **dépendantes** :

```
fichier arrive → contrôler → charger raw → nettoyer (staging)
   → modèle d'entreprise → produit Data → tests qualité → publier
```

Sans orchestrateur, il faudrait lancer ces étapes à la main, chaque jour, dans
le bon ordre, et surveiller soi-même les échecs. L'orchestrateur est le « chef
d'orchestre » qui :

1. **Déclenche** au bon moment (tous les jours à 5h, ou quand un fichier arrive)
2. **Enchaîne** les étapes dans le bon ordre (le staging attend le raw)
3. **Réagit aux échecs** (réessayer, alerter, bloquer la suite)
4. **Trace tout** (logs, durées, historique des exécutions)

### 1.2 Les 7 mots de vocabulaire à maîtriser absolument

| Terme | Définition simple | Exemple dans YODA |
|---|---|---|
| **DAG** | *Directed Acyclic Graph* : le schéma des étapes et de leurs dépendances (flèches, jamais de boucle) | `contracts_active_daily` dans `dags/` |
| **Tâche (task)** | Une étape du DAG | `load_raw_contracts`, `build_staging` |
| **Planification (schedule)** | Quand le DAG se déclenche | `0 5 * * *` = tous les jours à 5h00 |
| **Idempotence** | Relancer ne crée PAS de doublon | on écrase la partition du jour au lieu d'ajouter |
| **Backfill / rattrapage** | Rejouer le pipeline pour des dates passées | recharger le 10, 11 et 12 juillet après un incident |
| **Capteur (sensor)** | Tâche qui attend qu'une condition soit vraie | attendre que le fichier Impulse arrive dans le bucket |
| **SLA** | Engagement de délai | « données publiées avant 7h00 » |

### 1.3 L'idempotence : LE concept qui différencie un junior d'un confirmé

Question piège classique en mission : *« Que se passe-t-il si ton pipeline est
relancé deux fois le même jour ? »*

**Mauvaise réponse** : « les données sont insérées deux fois » (doublons ! les
tableaux de bord affichent le double du portefeuille !).

**Bonne réponse** : « chaque exécution écrit dans la partition de sa date
métier en la remplaçant — `DELETE` de la partition puis `INSERT`, ou
`WRITE_TRUNCATE`. Relancer 10 fois produit exactement le même résultat. »

Regarde comment c'est fait dans notre code :

```sql
-- sql/orchestration/daily_full_chain.sql — le pattern DELETE + INSERT
DELETE FROM `...product_contract.active_contracts_daily`
WHERE snapshot_date = CURRENT_DATE();      -- 1. on efface la partition du jour

INSERT INTO `...product_contract.active_contracts_daily`
SELECT CURRENT_DATE(), ...                 -- 2. on la réécrit entièrement
```

### 1.4 La syntaxe cron (à connaître par cœur)

Les planifications s'écrivent en « cron » : 5 champs séparés par des espaces.

```
 ┌───────── minute (0-59)
 │ ┌─────── heure (0-23)
 │ │ ┌───── jour du mois (1-31)
 │ │ │ ┌─── mois (1-12)
 │ │ │ │ ┌─ jour de la semaine (0-6, 0=dimanche)
 │ │ │ │ │
 0 5 * * *     tous les jours à 05h00
 0 6 * * 1     tous les lundis à 06h00
 30 7 1 * *    le 1er de chaque mois à 07h30
 0 */4 * * *   toutes les 4 heures
```

---

## Partie 2 — Les requêtes programmées BigQuery (ce qui tourne chez toi)

### 2.1 Le principe

Une **requête programmée** (scheduled query), c'est le service d'orchestration
le plus simple de GCP : tu donnes à BigQuery un script SQL et un horaire, et
BigQuery l'exécute tout seul. Sous le capot, c'est le service **BigQuery Data
Transfer Service (DTS)** qui gère la planification.

**Forces** : gratuit, zéro infrastructure, parfait pour des chaînes 100 % SQL.
**Limites** : pas de capteur de fichier, pas de reprise ciblée par tâche, pas
de dépendances entre plusieurs requêtes programmées, logs moins riches.

### 2.2 Comment la nôtre est construite — dissèque-la

Ouvre `sql/orchestration/daily_full_chain.sql` et repère la structure :

```
1. DOMAINE CONTRAT
   CREATE OR REPLACE TABLE app_impulse.stg_contracts_clean   ← staging (nettoyage)
   CREATE OR REPLACE TABLE enterprise_contract.contracts     ← modèle d'entreprise
   DELETE + INSERT product_contract.active_contracts_daily   ← produit (idempotent)
2. DOMAINE SINISTRE (APRÈS les contrats, car il en dépend)
3. DOMAINE INTERACTION
4. INSERT dans ops.pipeline_runs                             ← journal (traçabilité)
```

Trois choses importantes à comprendre :

- **L'ordre des instructions remplace les flèches du DAG** : dans un script SQL
  multi-instructions, BigQuery exécute séquentiellement. Les sinistres sont
  écrits après les contrats parce que la jointure en a besoin.
- **`CURRENT_DATE()` est la date métier** : chaque exécution photographie « le
  jour où elle tourne ». C'est simple, mais c'est aussi la limite : pour
  rejouer une date passée (backfill), il faudrait paramétrer la date — c'est là
  qu'Airflow devient supérieur.
- **Le compte de service** : la requête ne tourne pas avec TON compte Google
  mais avec `yoda-pipeline-dev@...`. C'est une bonne pratique de sécurité : si
  tu quittes le projet, le pipeline continue de tourner ; et ses droits sont
  limités au strict nécessaire.

### 2.3 Exercice guidé n°1 — crée ta propre requête programmée à la main

Objectif : créer, sans Terraform, une petite requête programmée qui compte
chaque jour les contrats actifs et stocke le résultat.

1. Ouvre **BigQuery Studio** → colle et exécute une fois ce SQL pour créer la
   table cible :

```sql
CREATE TABLE IF NOT EXISTS `yoda-data-2026.enterprise_transverse.kpi_daily`
(kpi_date DATE, kpi_name STRING, kpi_value INT64);
```

2. Colle maintenant la requête à programmer dans l'éditeur :

```sql
DELETE FROM `yoda-data-2026.enterprise_transverse.kpi_daily`
WHERE kpi_date = CURRENT_DATE() AND kpi_name = 'contrats_actifs';

INSERT INTO `yoda-data-2026.enterprise_transverse.kpi_daily`
SELECT CURRENT_DATE(), 'contrats_actifs', COUNTIF(is_active)
FROM `yoda-data-2026.product_contract.active_contracts_daily`
WHERE snapshot_date = (SELECT MAX(snapshot_date)
                       FROM `yoda-data-2026.product_contract.active_contracts_daily`);
```

3. Clique sur **« Planifier » / « Schedule »** (bouton en haut de l'éditeur) →
   *Créer une requête programmée* :
   - Nom : `exo1-kpi-contrats-actifs`
   - Fréquence : tous les jours, 06h00
   - Laisse le reste par défaut → **Enregistrer**
4. Menu gauche → **Requêtes programmées** → ta requête → **Exécuter maintenant**
5. Vérifie : `SELECT * FROM enterprise_transverse.kpi_daily;`

👉 **Questions à te poser** (réponds avant de lire la suite) : pourquoi le
`DELETE` avant l'`INSERT` ? Que se passerait-il sans lui si tu cliques deux
fois sur « Exécuter maintenant » ? *(Réponse : doublon du KPI du jour — c'est
exactement le problème d'idempotence de la partie 1.3.)*

### 2.4 Surveiller et dépanner une requête programmée

- **Historique** : console → BigQuery → Requêtes programmées → clique sur la
  requête → onglet « Détails de l'exécution ». Chaque run est vert (succès) ou
  rouge (échec avec le message d'erreur SQL).
- **En cas d'échec**, le réflexe pro en 3 étapes :
  1. Lire le message d'erreur du run (souvent : table absente, colonne
     renommée, quota).
  2. Rejouer le SQL à la main dans BigQuery Studio pour reproduire.
  3. Corriger la cause, puis « Exécuter maintenant » — comme le script est
     idempotent, aucune crainte de doublon.
- **Notre journal maison** : `ops.pipeline_runs` trace chaque exécution avec
  les volumes. Compare `input_rows` / `output_rows` d'un jour à l'autre : une
  chute brutale = alerte.

---

## Partie 3 — Cloud Composer / Airflow (la cible de la mission YODA)

### 3.1 Pourquoi Airflow alors que les requêtes programmées marchent ?

Parce qu'un vrai pipeline de production fait plus que du SQL :

| Besoin | Requête programmée | Airflow/Composer |
|---|---|---|
| Enchaîner du SQL | ✅ | ✅ |
| **Attendre un fichier** avant de démarrer | ❌ | ✅ capteur GCS |
| Contrôler un fichier (checksum, colonnes) | ❌ | ✅ tâche Python |
| **Relancer UNE tâche** en échec (pas tout) | ❌ | ✅ |
| **Backfill** d'une plage de dates | ❌ (péniblement) | ✅ natif (`{{ ds }}`) |
| Alerter (email, Slack) finement | limité | ✅ |
| Dépendances entre plusieurs pipelines | ❌ | ✅ |
| Coût | 0 € | ~350 €/mois (Composer) |

**Composer**, c'est simplement Airflow **hébergé et géré par Google** : tu
déposes tes fichiers DAG dans un bucket GCS, Google fait tourner le serveur
Airflow pour toi.

### 3.2 L'anatomie d'un DAG Airflow — notre fichier ligne par ligne

Ouvre `dags/contracts_active_daily.py` et repère ces blocs :

**Bloc 1 : le contrat d'exécution du DAG**

```python
with DAG(
    dag_id="contracts_active_daily",   # identifiant unique
    schedule="0 5 * * *",              # cron : tous les jours 5h UTC
    start_date=datetime(2026, 1, 1),   # à partir de quand il peut tourner
    catchup=False,                     # ne PAS rattraper les dates passées au 1er déploiement
    max_active_runs=1,                 # jamais 2 exécutions en parallèle
    default_args={
        "retries": 2,                              # réessayer 2 fois avant échec
        "retry_delay": timedelta(minutes=10),      # 10 min entre les essais
        "email_on_failure": True,                  # alerter l'exploitation
    },
)
```

👉 `catchup=False` est un piège classique : sans lui, Airflow lancerait une
exécution pour CHAQUE jour entre `start_date` et aujourd'hui dès le
déploiement (des centaines de runs d'un coup !).

**Bloc 2 : le capteur — « attendre le fichier »**

```python
wait_for_file = GCSObjectExistenceSensor(
    task_id="wait_for_impulse_file",
    bucket=LANDING_BUCKET,
    object="impulse/contracts/{{ ds_nodash }}/impulse_contracts_{{ ds_nodash }}.csv",
    poke_interval=300,      # vérifie toutes les 5 minutes
    timeout=60 * 60 * 2,    # abandonne après 2 heures → alerte
    mode="reschedule",      # libère le worker entre deux vérifications (économie !)
)
```

👉 `{{ ds_nodash }}` est du **templating Jinja** : Airflow remplace cette
variable par la date d'exécution (`20260713`). C'est ÇA qui rend le backfill
possible : la même tâche, exécutée « pour le 10 juillet », cherchera
automatiquement le fichier du 10 juillet.

**Bloc 3 : les tâches de transformation** — chaque étape SQL devient un
opérateur `BigQueryInsertJobOperator` qui lit son fichier dans `sql/`.

**Bloc 4 : les tests qualité bloquants** — `BigQueryCheckOperator` exécute une
requête qui doit renvoyer « vrai », sinon la tâche échoue et **la publication
n'a jamais lieu** (les tâches suivantes ne s'exécutent pas).

**Bloc 5 : le câblage des dépendances** — les flèches du DAG :

```python
(wait_for_file >> load_raw >> build_staging >> build_enterprise
    >> build_product >> quality_checks >> publish_bi_view >> archive_file >> done)
```

`>>` se lit « puis ». `quality_checks` est une liste : les 3 contrôles tournent
**en parallèle**, et `publish_bi_view` attend qu'ils soient TOUS verts.

### 3.3 Le cycle de vie d'une exécution (ce qui se passe vraiment)

```
05h00 UTC : le scheduler Airflow crée un "DAG run" pour la date du jour
   → wait_for_impulse_file passe en "running", vérifie le bucket toutes les 5 min
   → le fichier arrive à 05h12 → capteur "success"
   → load_raw_contracts démarre... échoue (erreur réseau) → "up_for_retry"
   → 10 minutes plus tard, 2e essai → "success"
   → build_staging → build_enterprise → build_product : verts
   → les 3 qa_* tournent en parallèle : verts
   → publish_bi_view → archive_file → done : verts
06h20 : DAG run "success" — SLA 07h00 respecté ✅
```

Chaque état est visible dans l'interface web d'Airflow (la « grid view ») :
vert = succès, rouge = échec, orange = en attente de retry. Le travail
quotidien d'un Data Engineer en mission commence souvent par ce tableau.

### 3.4 Exercice guidé n°2 — fais tourner Airflow GRATUITEMENT sur ta machine

Pas besoin de payer Composer pour apprendre : Airflow est open source.

```bash
# 1. Dans un terminal (ta machine ou Cloud Shell), crée un environnement isolé
python3 -m venv airflow-lab && source airflow-lab/bin/activate
pip install "apache-airflow==2.9.*"

# 2. Démarre Airflow en mode autonome (tout-en-un, pour apprendre)
export AIRFLOW_HOME=~/airflow-lab-home
airflow standalone
# → note le mot de passe admin affiché, ouvre http://localhost:8080
```

Puis crée ton premier DAG, tout simple :

```python
# ~/airflow-lab-home/dags/mon_premier_dag.py
from datetime import datetime
from airflow import DAG
from airflow.operators.bash import BashOperator

with DAG(
    dag_id="mon_premier_dag",
    schedule="0 5 * * *",
    start_date=datetime(2026, 1, 1),
    catchup=False,
) as dag:
    extraire = BashOperator(task_id="extraire", bash_command="echo 'extraction...'")
    transformer = BashOperator(task_id="transformer", bash_command="echo 'transformation...'")
    charger = BashOperator(task_id="charger", bash_command="echo 'chargement...'")

    extraire >> transformer >> charger
```

Dans l'interface : active le DAG, clique sur ▶ (« Trigger DAG »), regarde les
cases passer au vert, clique sur une tâche → « Logs ».

**Manipulations à faire absolument** (c'est en cassant qu'on apprend) :
1. Change `bash_command` en `exit 1` sur `transformer` → observe l'échec et le
   fait que `charger` ne tourne jamais.
2. Ajoute `retries=2` à la tâche → observe l'état « up_for_retry ».
3. Fais un backfill : `airflow dags backfill mon_premier_dag -s 2026-07-01 -e 2026-07-05`
   → 5 exécutions, une par date.
4. Ajoute une 4e tâche en parallèle de `transformer` et câble
   `extraire >> [transformer, verifier] >> charger`.

### 3.5 Exercice guidé n°3 — lis notre DAG YODA comme un pro

Sans rien exécuter, ouvre `dags/contracts_active_daily.py` et réponds par
écrit (vraiment — écris tes réponses) :

1. Si le fichier Impulse n'arrive jamais, que se passe-t-il, et au bout de
   combien de temps ?
2. Pourquoi `max_bad_records=0` sur le chargement raw ? Qu'est-ce que ça
   dit de notre philosophie sur les rejets ?
3. Le test `qa_unique_contract_snapshot` échoue. Quelles tâches ne
   s'exécuteront pas ? Les rapports Power BI affichent quoi pendant ce temps ?
4. Comment rejouer uniquement la journée du 10 juillet sans toucher au reste ?
5. Où sont les mots de passe dans ce fichier ? *(Réponse attendue : nulle
   part — comptes de service et variables d'environnement, jamais de secret
   dans le code.)*

*(Solutions : 1. le capteur expire après 2h et alerte, voir le runbook ;
2. tout écart de format est un rejet tracé, jamais ignoré silencieusement ;
3. publish/archive ne tournent pas, la vue BI reste sur la dernière partition
saine — les rapports montrent J-1 plutôt que des données fausses ;
4. « Clear » du DAG run du 10 juillet dans l'interface, ou
`airflow dags backfill -s 2026-07-10 -e 2026-07-10` — grâce au templating
`{{ ds }}` et à l'idempotence, ça réécrit exactement la partition du 10.)*

---

## Partie 4 — Quand utiliser quoi ? (la réponse qu'on attendra de toi)

**Règle simple à retenir :**

- Chaîne **100 % SQL**, déclenchement à heure fixe, tolérance aux limitations
  de reprise → **requête programmée** (gratuit, simple).
- Il faut **attendre des fichiers**, faire du **Python** (contrôles, appels
  d'API), des **reprises fines**, des **backfills**, des dépendances entre
  pipelines → **Composer/Airflow**.
- Dans la mission YODA : la Pipeline Factory fournit des patterns Composer ;
  les requêtes programmées restent utiles pour des agrégats simples ou des
  environnements de développement à coût nul.

## Partie 5 — Ton plan de montée en compétences (2 semaines)

| Jour | Objectif | Support |
|---|---|---|
| 1-2 | Concepts : DAG, idempotence, cron, backfill (Partie 1) — sache les expliquer à voix haute | ce document |
| 3 | Requêtes programmées : exercice n°1 + casser/réparer | ton projet GCP |
| 4-5 | Relire `sql/orchestration/daily_full_chain.sql` et être capable de le réécrire de mémoire (structure, pas mot à mot) | le dépôt |
| 6-8 | Airflow local : exercice n°2 et ses 4 manipulations | ta machine |
| 9-10 | Lire le DAG YODA : exercice n°3, puis relire `docs/runbook_contrats_actifs.md` en te demandant « quelle tâche Airflow correspond à chaque symptôme ? » | le dépôt |
| 11-12 | Réécris TOI-MÊME un mini-DAG « sinistres » sur le modèle du DAG contrats (même sans l'exécuter : la structure compte) | `dags/` |
| 13-14 | Simule l'entretien : réponds aux 10 questions ci-dessous à voix haute | ci-dessous |

## Partie 6 — Les 10 questions qu'on te posera (entraîne-toi à voix haute)

1. C'est quoi un DAG ? Pourquoi « acyclique » ?
2. Explique l'idempotence et comment tu la garantis dans un pipeline BigQuery.
3. Que fait `catchup=False` et pourquoi c'est important au premier déploiement ?
4. Différence entre un capteur en mode `poke` et en mode `reschedule` ?
   *(poke : le worker reste occupé à attendre ; reschedule : il est libéré
   entre deux vérifications — moins de ressources consommées.)*
5. Un test qualité échoue à 5h30, le SLA est à 7h. Raconte ta matinée.
   *(diagnostic via les logs de la tâche → requête du contrôle à la main →
   identifier le lot fautif → corriger à la source → relancer la tâche —
   et prévenir les consommateurs si le SLA casse.)*
6. Comment rejouer les données du 10 au 12 juillet ?
7. Pourquoi le pipeline tourne-t-il avec un compte de service et pas ton compte ?
8. Où mets-tu les mots de passe ? *(Secret Manager, jamais dans le code ni le dépôt.)*
9. Quand choisirais-tu une requête programmée plutôt que Composer ?
10. Que traces-tu à chaque exécution et pourquoi ?
    *(run_id, batch_id, volumes in/out/rejets, statut, durées — sans ça,
    impossible de diagnostiquer ni de prouver la fraîcheur — voir §11.2 de la
    documentation YODA.)*

---

## Pour aller plus loin

- Documentation YODA du dépôt : `docs/architecture.md` (décisions techniques),
  `docs/runbook_contrats_actifs.md` (exploitation), `docs/conventions.md`
- Le code que tu peux disséquer : `dags/contracts_active_daily.py`,
  `sql/orchestration/daily_full_chain.sql`, `infra/scheduler.tf`
- Concepts Airflow officiels : cherche « Airflow concepts DAG » dans la doc
  Apache Airflow (elle est excellente et gratuite)
- Et surtout : **casse des choses sur ton projet dev**. C'est un bac à sable à
  0 € — supprime une table et regarde la requête programmée échouer, lis
  l'erreur, répare. C'est le chemin le plus rapide vers l'autonomie.
