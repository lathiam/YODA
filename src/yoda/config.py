"""Chargement de la configuration par environnement.

L'environnement, les chemins et les datasets ne sont jamais codés en dur
(principe « paramétrable », documentation §11.1). Les secrets ne transitent
jamais par ces fichiers : ils sont résolus au runtime via Secret Manager.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

CONFIG_DIR = Path(__file__).resolve().parents[2] / "config"
VALID_ENVIRONMENTS = ("dev", "preprod", "prod")


@dataclass(frozen=True)
class Settings:
    environment: str
    gcp: dict[str, Any] = field(default_factory=dict)
    datasets: dict[str, str] = field(default_factory=dict)
    local: dict[str, str] = field(default_factory=dict)
    quality: dict[str, Any] = field(default_factory=dict)
    alerting: dict[str, Any] = field(default_factory=dict)

    def dataset(self, name: str) -> str:
        if name not in self.datasets:
            raise KeyError(f"Dataset inconnu dans la configuration: {name}")
        return self.datasets[name]


def load_settings(environment: str, config_dir: Path | None = None) -> Settings:
    if environment not in VALID_ENVIRONMENTS:
        raise ValueError(
            f"Environnement invalide '{environment}'. Attendu: {', '.join(VALID_ENVIRONMENTS)}"
        )
    path = (config_dir or CONFIG_DIR) / f"{environment}.yaml"
    with open(path, encoding="utf-8") as handle:
        raw = yaml.safe_load(handle)
    return Settings(
        environment=raw["environment"],
        gcp=raw.get("gcp", {}),
        datasets=raw.get("datasets", {}),
        local=raw.get("local", {}),
        quality=raw.get("quality", {}),
        alerting=raw.get("alerting", {}),
    )
