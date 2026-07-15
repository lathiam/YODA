"""Tests du framework qualité (dimensions, sévérités, publication — doc §12)."""

from yoda.quality import (
    QualityReport,
    Severity,
    check_allowed_values,
    check_not_null,
    check_reconciliation,
    check_rule,
    check_unique,
)


def test_not_null_detects_missing_values():
    rows = [{"contract_id": "CTR-1"}, {"contract_id": ""}, {"contract_id": None}]
    result = check_not_null(rows, "contract_id")
    assert not result.passed
    assert result.failed_count == 2
    assert result.severity is Severity.CRITICAL


def test_unique_detects_duplicates_on_composite_key():
    rows = [
        {"contract_id": "CTR-1", "snapshot_date": "2026-07-13"},
        {"contract_id": "CTR-1", "snapshot_date": "2026-07-13"},
        {"contract_id": "CTR-1", "snapshot_date": "2026-07-12"},
    ]
    result = check_unique(rows, ["contract_id", "snapshot_date"])
    assert not result.passed
    assert result.failed_count == 1


def test_allowed_values_flags_out_of_referential():
    rows = [{"product_code": "AUTO01"}, {"product_code": "INCONNU"}]
    result = check_allowed_values(rows, "product_code", {"AUTO01"})
    assert not result.passed and result.failed_count == 1


def test_generic_rule_check():
    rows = [{"a": 1, "b": 2}, {"a": 5, "b": 2}]
    result = check_rule(rows, "a_before_b", "cohérence", lambda r: r["a"] <= r["b"])
    assert not result.passed and result.failed_count == 1


def test_reconciliation_with_legacy(tolerance_zero=True):
    assert check_reconciliation(new_count=100, legacy_count=100).passed
    assert not check_reconciliation(new_count=98, legacy_count=100).passed
    assert check_reconciliation(new_count=98, legacy_count=100, tolerance_ratio=0.05).passed


class TestPublicationDecision:
    """§12.3 : la sévérité pilote le blocage de la publication."""

    def ok(self, name, severity):
        return check_rule([], name, "test", lambda r: True, severity)

    def ko(self, name, severity):
        return check_rule([{"x": 1}], name, "test", lambda r: False, severity)

    def test_all_green_is_publishable(self):
        report = QualityReport([self.ok("a", Severity.CRITICAL), self.ok("b", Severity.LOW)])
        assert report.passed and report.publishable

    def test_critical_failure_blocks_publication(self):
        report = QualityReport([self.ko("a", Severity.CRITICAL)])
        assert not report.publishable

    def test_high_failure_blocks_publication(self):
        report = QualityReport([self.ko("a", Severity.HIGH)])
        assert not report.publishable

    def test_medium_failure_publishes_with_alert(self):
        report = QualityReport([self.ko("a", Severity.MEDIUM)])
        assert not report.passed
        assert report.publishable  # publication possible avec alerte

    def test_low_failure_publishes(self):
        report = QualityReport([self.ko("a", Severity.LOW)])
        assert report.publishable
