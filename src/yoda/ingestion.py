"""Contrôles d'ingestion — porte d'entrée standardisée (documentation §6.3).

Responsabilités implémentées : détection, intégrité (taille, checksum),
format (extension, encodage, séparateur, colonnes), idempotence (détection
de double chargement par checksum) et traçabilité.
"""

from __future__ import annotations

import csv
import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path


class IngestionError(Exception):
    """Échec d'un contrôle d'ingestion critique : le lot est refusé."""

    def __init__(self, code: str, message: str):
        self.code = code
        super().__init__(f"[{code}] {message}")


@dataclass
class FileCheckResult:
    source_file: str
    size_bytes: int
    checksum_sha256: str
    row_count: int
    columns: list[str] = field(default_factory=list)
    duplicate_of_batch: str | None = None


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_file(
    path: Path,
    expected_columns: list[str],
    expected_extension: str = ".csv",
    encoding: str = "utf-8",
    delimiter: str = ";",
    ledger_path: Path | None = None,
) -> FileCheckResult:
    """Exécute les contrôles techniques d'entrée et retourne les preuves.

    Lève IngestionError (anomalie critique, documentation §12.3 : arrêt du
    pipeline, aucune publication) si un contrôle bloquant échoue.
    """
    # Détection : présence du fichier attendu
    if not path.exists():
        raise IngestionError("ING_001_MISSING", f"Fichier attendu absent: {path}")

    # Intégrité : fichier non vide
    size = path.stat().st_size
    if size == 0:
        raise IngestionError("ING_002_EMPTY", f"Fichier vide: {path}")

    # Format : extension attendue
    if path.suffix.lower() != expected_extension:
        raise IngestionError(
            "ING_003_EXTENSION",
            f"Extension inattendue '{path.suffix}' (attendu '{expected_extension}')",
        )

    # Format : encodage et lecture des colonnes
    try:
        with open(path, encoding=encoding, newline="") as handle:
            reader = csv.reader(handle, delimiter=delimiter)
            header = next(reader, None)
            row_count = sum(1 for _ in reader)
    except UnicodeDecodeError as exc:
        raise IngestionError(
            "ING_004_ENCODING", f"Encodage invalide (attendu {encoding}): {exc}"
        ) from exc

    if header is None:
        raise IngestionError("ING_005_NO_HEADER", "Fichier sans ligne d'en-tête")

    # Format : colonnes obligatoires présentes
    missing = [c for c in expected_columns if c not in header]
    if missing:
        raise IngestionError(
            "ING_006_COLUMNS", f"Colonnes obligatoires absentes: {', '.join(missing)}"
        )

    checksum = sha256_of(path)

    # Idempotence : le même contenu ne doit pas être chargé deux fois
    duplicate_of = None
    if ledger_path is not None:
        duplicate_of = _register_in_ledger(ledger_path, path.name, checksum)

    return FileCheckResult(
        source_file=str(path),
        size_bytes=size,
        checksum_sha256=checksum,
        row_count=row_count,
        columns=header,
        duplicate_of_batch=duplicate_of,
    )


def _register_in_ledger(ledger_path: Path, file_name: str, checksum: str) -> str | None:
    """Journal des lots reçus (cible: table ops.ingestion_ledger).

    Retourne le nom du fichier déjà chargé si le checksum est connu (doublon).
    """
    ledger: dict[str, str] = {}
    if ledger_path.exists():
        ledger = json.loads(ledger_path.read_text(encoding="utf-8"))
    previous = ledger.get(checksum)
    if previous is not None and previous != file_name:
        return previous
    ledger[checksum] = file_name
    ledger_path.parent.mkdir(parents=True, exist_ok=True)
    ledger_path.write_text(json.dumps(ledger, indent=2), encoding="utf-8")
    return None


def read_csv_rows(path: Path, encoding: str = "utf-8", delimiter: str = ";") -> list[dict]:
    """Lit le fichier source en lignes brutes (couche modèle applicatif, raw)."""
    with open(path, encoding=encoding, newline="") as handle:
        return list(csv.DictReader(handle, delimiter=delimiter))
