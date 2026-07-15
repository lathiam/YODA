"""Tests des contrôles d'ingestion (porte d'entrée, documentation §6.3)."""

import pytest

from yoda.ingestion import IngestionError, check_file

HEADER = (
    "contract_id;customer_id;product_code;status;start_date;"
    "end_date;annual_premium;channel_code"
)
VALID_ROW = "CTR-1;CLI-1;AUTO01;ACTIF;2024-01-01;;100;WEB"
EXPECTED = ["contract_id", "customer_id", "product_code", "status", "start_date"]


def write(tmp_path, name, content):
    path = tmp_path / name
    path.write_text(content, encoding="utf-8")
    return path


def test_valid_file_passes_all_checks(tmp_path):
    path = write(tmp_path, "contracts.csv", HEADER + "\n" + VALID_ROW + "\n")
    result = check_file(path, EXPECTED)
    assert result.row_count == 1
    assert len(result.checksum_sha256) == 64


def test_missing_file_is_rejected(tmp_path):
    with pytest.raises(IngestionError) as exc:
        check_file(tmp_path / "absent.csv", EXPECTED)
    assert exc.value.code == "ING_001_MISSING"


def test_empty_file_is_rejected(tmp_path):
    path = write(tmp_path, "contracts.csv", "")
    with pytest.raises(IngestionError) as exc:
        check_file(path, EXPECTED)
    assert exc.value.code == "ING_002_EMPTY"


def test_wrong_extension_is_rejected(tmp_path):
    path = write(tmp_path, "contracts.txt", HEADER + "\n")
    with pytest.raises(IngestionError) as exc:
        check_file(path, EXPECTED)
    assert exc.value.code == "ING_003_EXTENSION"


def test_missing_columns_are_rejected(tmp_path):
    path = write(tmp_path, "contracts.csv", "contract_id;status\nCTR-1;ACTIF\n")
    with pytest.raises(IngestionError) as exc:
        check_file(path, EXPECTED)
    assert exc.value.code == "ING_006_COLUMNS"
    assert "customer_id" in str(exc.value)


def test_idempotence_same_content_flagged_as_duplicate(tmp_path):
    """Le même contenu reçu sous deux noms différents est détecté (double chargement)."""
    ledger = tmp_path / "ledger.json"
    content = HEADER + "\n" + VALID_ROW + "\n"
    first = write(tmp_path, "contracts_v1.csv", content)
    second = write(tmp_path, "contracts_v2.csv", content)

    assert check_file(first, EXPECTED, ledger_path=ledger).duplicate_of_batch is None
    assert check_file(second, EXPECTED, ledger_path=ledger).duplicate_of_batch == "contracts_v1.csv"


def test_replay_of_same_file_is_not_a_duplicate(tmp_path):
    """Rejouer le même fichier (reprise) n'est pas un double chargement."""
    ledger = tmp_path / "ledger.json"
    path = write(tmp_path, "contracts.csv", HEADER + "\n" + VALID_ROW + "\n")
    check_file(path, EXPECTED, ledger_path=ledger)
    assert check_file(path, EXPECTED, ledger_path=ledger).duplicate_of_batch is None
