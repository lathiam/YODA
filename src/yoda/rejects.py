"""Gestion des rejets (documentation §11.3).

Un rejet n'est jamais une ligne perdue : il est conservé avec la donnée
originale, le motif, la règle en échec, le lot et un statut de reprise.
Cible GCP : table ops.rejects, partitionnée par date de rejet.
"""

from __future__ import annotations

import csv
import json
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path


@dataclass
class Reject:
    batch_id: str
    pipeline_name: str
    rule_code: str
    error_message: str
    source_record: dict
    reject_id: str = field(default_factory=lambda: uuid.uuid4().hex)
    rejected_at: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )
    retry_status: str = "PENDING"


class RejectStore:
    def __init__(self, pipeline_name: str, batch_id: str):
        self.pipeline_name = pipeline_name
        self.batch_id = batch_id
        self.rejects: list[Reject] = []

    def add(self, record: dict, rule_code: str, error_message: str) -> None:
        self.rejects.append(
            Reject(
                batch_id=self.batch_id,
                pipeline_name=self.pipeline_name,
                rule_code=rule_code,
                error_message=error_message,
                source_record=record,
            )
        )

    def __len__(self) -> int:
        return len(self.rejects)

    def write_csv(self, directory: Path) -> Path | None:
        """Persiste les rejets du lot pour analyse et reprise ciblée."""
        if not self.rejects:
            return None
        directory.mkdir(parents=True, exist_ok=True)
        path = directory / f"rejects_{self.pipeline_name}_{self.batch_id}.csv"
        fieldnames = [
            "reject_id", "batch_id", "pipeline_name", "rule_code",
            "error_message", "rejected_at", "retry_status", "source_record",
        ]
        with open(path, "w", encoding="utf-8", newline="") as handle:
            writer = csv.DictWriter(handle, fieldnames=fieldnames, delimiter=";")
            writer.writeheader()
            for reject in self.rejects:
                row = {k: getattr(reject, k) for k in fieldnames if k != "source_record"}
                # default=str : les rejets aval portent des valeurs déjà typées
                # (dates, Decimal) qu'il faut conserver lisibles telles quelles
                row["source_record"] = json.dumps(
                    reject.source_record, ensure_ascii=False, default=str
                )
                writer.writerow(row)
        return path
