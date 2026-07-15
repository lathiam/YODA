"""Framework de tests qualité (documentation §12).

Chaque contrôle porte une dimension de qualité (complétude, unicité, validité,
cohérence, fraîcheur...) et une sévérité qui pilote le comportement de
publication : CRITIQUE bloque, ÉLEVÉE bloque avec analyse, MOYENNE publie
avec alerte, FAIBLE alimente le suivi.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime, timezone
from enum import Enum
from typing import Callable, Iterable


class Severity(str, Enum):
    CRITICAL = "CRITICAL"   # arrêt du pipeline, aucune publication, alerte immédiate
    HIGH = "HIGH"           # publication bloquée, analyse obligatoire
    MEDIUM = "MEDIUM"       # publication possible avec alerte et plan de correction
    LOW = "LOW"             # suivi qualité sans impact immédiat


BLOCKING_SEVERITIES = {Severity.CRITICAL, Severity.HIGH}


@dataclass
class CheckResult:
    check_name: str
    dimension: str
    severity: Severity
    passed: bool
    failed_count: int = 0
    total_count: int = 0
    details: str = ""


@dataclass
class QualityReport:
    results: list[CheckResult]

    @property
    def passed(self) -> bool:
        return all(r.passed for r in self.results)

    @property
    def blocking_failures(self) -> list[CheckResult]:
        return [r for r in self.results if not r.passed and r.severity in BLOCKING_SEVERITIES]

    @property
    def publishable(self) -> bool:
        """La publication n'est autorisée que sans anomalie bloquante (§12.3)."""
        return not self.blocking_failures

    def summary(self) -> str:
        lines = []
        for r in self.results:
            state = "OK " if r.passed else "KO "
            lines.append(
                f"{state}[{r.severity.value:8}] {r.check_name} "
                f"({r.dimension}) — {r.failed_count}/{r.total_count} en échec"
                + (f" — {r.details}" if r.details else "")
            )
        return "\n".join(lines)


def check_not_null(
    rows: Iterable[dict], column: str, severity: Severity = Severity.CRITICAL
) -> CheckResult:
    rows = list(rows)
    failed = [r for r in rows if r.get(column) in (None, "")]
    return CheckResult(
        check_name=f"not_null_{column}",
        dimension="complétude",
        severity=severity,
        passed=not failed,
        failed_count=len(failed),
        total_count=len(rows),
    )


def check_unique(
    rows: Iterable[dict], columns: list[str], severity: Severity = Severity.CRITICAL
) -> CheckResult:
    rows = list(rows)
    seen: set[tuple] = set()
    duplicates = 0
    for row in rows:
        key = tuple(row.get(c) for c in columns)
        if key in seen:
            duplicates += 1
        seen.add(key)
    return CheckResult(
        check_name=f"unique_{'_'.join(columns)}",
        dimension="unicité",
        severity=severity,
        passed=duplicates == 0,
        failed_count=duplicates,
        total_count=len(rows),
    )


def check_allowed_values(
    rows: Iterable[dict],
    column: str,
    allowed: set,
    severity: Severity = Severity.HIGH,
) -> CheckResult:
    rows = list(rows)
    failed = [r for r in rows if r.get(column) not in allowed]
    return CheckResult(
        check_name=f"allowed_values_{column}",
        dimension="validité",
        severity=severity,
        passed=not failed,
        failed_count=len(failed),
        total_count=len(rows),
        details=f"valeurs autorisées: {sorted(str(a) for a in allowed)[:10]}",
    )


def check_rule(
    rows: Iterable[dict],
    check_name: str,
    dimension: str,
    predicate: Callable[[dict], bool],
    severity: Severity = Severity.HIGH,
    details: str = "",
) -> CheckResult:
    """Contrôle générique : le prédicat doit être vrai pour chaque ligne."""
    rows = list(rows)
    failed = [r for r in rows if not predicate(r)]
    return CheckResult(
        check_name=check_name,
        dimension=dimension,
        severity=severity,
        passed=not failed,
        failed_count=len(failed),
        total_count=len(rows),
        details=details,
    )


def check_freshness(
    loaded_at: datetime,
    business_date: date,
    sla_hours: int,
    severity: Severity = Severity.MEDIUM,
) -> CheckResult:
    """Fraîcheur : la donnée du jour J doit être publiée dans les sla_hours après J+1 00:00."""
    if loaded_at.tzinfo is None:
        loaded_at = loaded_at.replace(tzinfo=timezone.utc)
    business_start = datetime(
        business_date.year, business_date.month, business_date.day, tzinfo=timezone.utc
    )
    elapsed_hours = (loaded_at - business_start).total_seconds() / 3600
    passed = elapsed_hours <= 24 + sla_hours
    return CheckResult(
        check_name="freshness_sla",
        dimension="fraîcheur",
        severity=severity,
        passed=passed,
        failed_count=0 if passed else 1,
        total_count=1,
        details=f"{elapsed_hours:.1f}h après début de la date métier (SLA {sla_hours}h)",
    )


def check_reconciliation(
    new_count: int,
    legacy_count: int,
    tolerance_ratio: float = 0.0,
    severity: Severity = Severity.HIGH,
) -> CheckResult:
    """Réconciliation avec le système historique (double run, documentation §18.3)."""
    gap = abs(new_count - legacy_count)
    allowed = legacy_count * tolerance_ratio
    passed = gap <= allowed
    return CheckResult(
        check_name="reconciliation_legacy_count",
        dimension="exactitude",
        severity=severity,
        passed=passed,
        failed_count=gap,
        total_count=legacy_count,
        details=f"cible={new_count}, legacy={legacy_count}, tolérance={tolerance_ratio:.1%}",
    )
