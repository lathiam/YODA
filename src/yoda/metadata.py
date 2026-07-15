"""Métadonnées d'exécution normalisées (documentation §11.2).

Chaque exécution de pipeline produit un enregistrement homogène permettant
l'observabilité, le diagnostic et la reprise idempotente : run_id, batch_id,
source, date métier, volumes, rejets, statut et erreur éventuelle.
"""

from __future__ import annotations

import json
import uuid
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from enum import Enum
from pathlib import Path


class RunStatus(str, Enum):
    PENDING = "PENDING"
    SUCCESS = "SUCCESS"
    PARTIAL = "PARTIAL"
    FAILED = "FAILED"


@dataclass
class RunMetadata:
    pipeline_name: str
    source_name: str
    source_file: str
    business_date: str
    batch_id: str
    run_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    start_time: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    end_time: str | None = None
    input_rows: int = 0
    output_rows: int = 0
    reject_rows: int = 0
    status: RunStatus = RunStatus.PENDING
    error_code: str | None = None
    error_message: str | None = None

    def finish(
        self,
        status: RunStatus,
        error_code: str | None = None,
        error_message: str | None = None,
    ) -> None:
        self.end_time = datetime.now(timezone.utc).isoformat()
        self.status = status
        self.error_code = error_code
        self.error_message = error_message

    def to_dict(self) -> dict:
        data = asdict(self)
        data["status"] = self.status.value
        return data

    def write_json(self, directory: Path) -> Path:
        """Persiste le journal d'exécution (cible: table ops.pipeline_runs)."""
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"run_{self.pipeline_name}_{self.business_date}_{self.run_id}.json"
        path.write_text(
            json.dumps(self.to_dict(), indent=2, ensure_ascii=False), encoding="utf-8"
        )
        return path


def make_batch_id(source_name: str, business_date: str, source_file: str) -> str:
    """Identifiant de lot déterministe : la même arrivée produit le même batch_id.

    Le déterminisme est la base de l'idempotence — un fichier retraité écrase
    sa propre partition au lieu de créer un doublon.
    """
    stem = Path(source_file).name
    return f"{source_name}_{business_date}_{stem}"
