"""Tests des règles métier du domaine Contrat (documentation §9.4)."""

from datetime import date
from decimal import Decimal

from yoda.rejects import RejectStore
from yoda.transformations.contracts import (
    build_active_contracts_daily,
    build_enterprise_contracts,
    clean_contracts,
    is_active,
)

REFERENTIAL = {"AUTO01", "AUTO02", "HAB01", "SANTE01"}


def make_raw(**overrides):
    row = {
        "contract_id": "CTR-1",
        "customer_id": "CLI-1",
        "product_code": "AUTO01",
        "status": "EN_COURS",
        "start_date": "2024-01-01",
        "end_date": "",
        "annual_premium": "450.00",
        "channel_code": "WEB",
        "event_timestamp": "2026-07-12T08:00:00",
    }
    row.update(overrides)
    return row


def store():
    return RejectStore("test", "batch-test")


class TestCleanContracts:
    def test_valid_row_is_cleaned_and_typed(self):
        rejects = store()
        rows = clean_contracts([make_raw()], rejects)
        assert len(rows) == 1 and len(rejects) == 0
        assert rows[0]["contract_status"] == "ACTIVE"
        assert rows[0]["start_date"] == date(2024, 1, 1)
        assert rows[0]["annual_premium"] == Decimal("450.00")

    def test_missing_required_field_goes_to_rejects(self):
        rejects = store()
        rows = clean_contracts([make_raw(customer_id="")], rejects)
        assert rows == []
        assert rejects.rejects[0].rule_code == "STG_001_MISSING_FIELD"

    def test_unknown_status_goes_to_rejects(self):
        rejects = store()
        clean_contracts([make_raw(status="BIZARRE")], rejects)
        assert rejects.rejects[0].rule_code == "STG_002_UNKNOWN_STATUS"

    def test_end_before_start_goes_to_rejects(self):
        rejects = store()
        clean_contracts([make_raw(start_date="2024-04-01", end_date="2023-01-01")], rejects)
        assert rejects.rejects[0].rule_code == "STG_004_DATE_ORDER"

    def test_french_decimal_comma_is_accepted(self):
        rejects = store()
        rows = clean_contracts([make_raw(annual_premium="95,50")], rejects)
        assert rows[0]["annual_premium"] == Decimal("95.50")

    def test_negative_premium_goes_to_rejects(self):
        rejects = store()
        clean_contracts([make_raw(annual_premium="-10")], rejects)
        assert rejects.rejects[0].rule_code == "STG_006_NEGATIVE_PREMIUM"


class TestBuildEnterpriseContracts:
    def test_deduplication_keeps_latest_event(self):
        """Réémission/doublon : seul le dernier événement du contrat est conservé."""
        rejects = store()
        stg = clean_contracts(
            [
                make_raw(status="ACTIF", event_timestamp="2026-07-12T10:00:00"),
                make_raw(status="RESILIE", end_date="2026-07-01",
                         event_timestamp="2026-07-12T14:30:00"),
            ],
            rejects,
        )
        result = build_enterprise_contracts(stg, REFERENTIAL, rejects)
        assert len(result) == 1
        assert result[0]["contract_status"] == "TERMINATED"

    def test_unknown_product_code_goes_to_rejects(self):
        rejects = store()
        stg = clean_contracts([make_raw(product_code="INCONNU9")], rejects)
        result = build_enterprise_contracts(stg, REFERENTIAL, rejects)
        assert result == []
        assert rejects.rejects[0].rule_code == "ENT_001_UNKNOWN_PRODUCT"

    def test_source_system_is_stamped(self):
        rejects = store()
        stg = clean_contracts([make_raw()], rejects)
        result = build_enterprise_contracts(stg, REFERENTIAL, rejects)
        assert result[0]["source_system"] == "IMPULSE"


class TestActiveRule:
    """Règle métier d'activité (§9.4) — cas nominaux et cas limites."""

    SNAPSHOT = date(2026, 7, 13)

    def contract(self, **overrides):
        base = {
            "contract_status": "ACTIVE",
            "start_date": date(2024, 1, 1),
            "end_date": None,
        }
        base.update(overrides)
        return base

    def test_active_contract_without_end_date(self):
        assert is_active(self.contract(), self.SNAPSHOT) is True

    def test_suspended_contract_is_not_active(self):
        assert is_active(self.contract(contract_status="SUSPENDED"), self.SNAPSHOT) is False

    def test_future_start_date_is_not_active_yet(self):
        assert is_active(self.contract(start_date=date(2026, 8, 1)), self.SNAPSHOT) is False

    def test_terminated_in_past_is_not_active(self):
        c = self.contract(contract_status="ACTIVE", end_date=date(2026, 5, 31))
        assert is_active(c, self.SNAPSHOT) is False

    def test_end_date_equals_snapshot_is_still_active(self):
        c = self.contract(end_date=self.SNAPSHOT)
        assert is_active(c, self.SNAPSHOT) is True

    def test_start_date_equals_snapshot_is_active(self):
        c = self.contract(start_date=self.SNAPSHOT)
        assert is_active(c, self.SNAPSHOT) is True


class TestSnapshot:
    def test_snapshot_has_product_schema_and_batch_id(self):
        rejects = store()
        stg = clean_contracts([make_raw()], rejects)
        enterprise = build_enterprise_contracts(stg, REFERENTIAL, rejects)
        snapshot = build_active_contracts_daily(enterprise, date(2026, 7, 13), "batch-42")
        row = snapshot[0]
        assert row["snapshot_date"] == date(2026, 7, 13)
        assert row["is_active"] is True
        assert row["ingestion_batch_id"] == "batch-42"
        assert row["source_system"] == "IMPULSE"
