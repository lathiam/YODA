"""Pipeline Factory YODA.

Composants réutilisables pour construire les pipelines Data du comptoir MNV :
contrôles d'ingestion, transformations, tests qualité, gestion des rejets et
métadonnées d'exécution. La logique est indépendante du moteur d'exécution
(BigQuery en cible, CSV en démo locale) — principe d'architecture modulaire.
"""

__version__ = "0.1.0"
