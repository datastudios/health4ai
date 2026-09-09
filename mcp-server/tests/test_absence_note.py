"""A zero must never be reportable as a fact about the user without qualification.

HealthKit reports a denied READ as an empty result, indistinguishable from a genuinely
empty window (see _ALWAYS_EXPECTED_METRICS). So an assistant reading count=0 for step
count will tell the user they took no steps, and neither the user nor the assistant can
tell that the metric was simply never shared. That happened on the author's own account
for nearly three months.

These tests pin the disambiguation: never_recorded (permission) vs empty_window (gap).
"""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402


def _patch_alltime(monkeypatch, exists: bool):
    monkeypatch.setattr(tools, "_has_any_rows_alltime", lambda mt, uid: exists)


def test_nonzero_count_gets_no_note():
    """A normal answer must not be cluttered with a status block."""
    assert tools._absence_note(tools.STEPS, "u1", 5) is None


def test_always_expected_never_recorded_flags_permission(monkeypatch):
    """Zero all-time for steps is a permission fact, not a behaviour fact."""
    _patch_alltime(monkeypatch, False)
    note = tools._absence_note(tools.STEPS, "u1", 0)
    assert note["status"] == "never_recorded"
    assert note["likely_cause"] == "permission_not_granted"
    g = note["guidance"].lower()
    assert "health" in g and "shar" in g
    # The instruction not to report a zero is the entire point of the block.
    assert "do not tell the user this value is zero" in g


def test_always_expected_with_history_is_a_gap_not_a_denial(monkeypatch):
    """Steps that exist at other times mean the pipeline works; do not cry permission."""
    _patch_alltime(monkeypatch, True)
    note = tools._absence_note(tools.STEPS, "u1", 0)
    assert note["status"] == "empty_window"
    assert "likely_cause" not in note
    assert "gap" in note["guidance"].lower()


def test_ordinary_metric_zero_is_not_called_a_denial(monkeypatch):
    """Most metrics are legitimately empty. Warning on those would train users to
    ignore the warning, which costs the real case its only signal."""
    _patch_alltime(monkeypatch, False)
    note = tools._absence_note("HKQuantityTypeIdentifierDistanceSwimming", "u1", 0)
    assert note["status"] == "empty_window"
    assert "likely_cause" not in note


def test_all_four_silently_deniable_metrics_are_covered():
    """These four are the ones observed to fail this way. Losing one loses its signal."""
    assert tools._ALWAYS_EXPECTED_METRICS == {
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
    }


def test_query_metric_attaches_status_on_empty_raw(monkeypatch):
    """The tool payload itself must carry the block; a helper nobody calls is not a fix."""
    monkeypatch.setattr(tools, "_fetch_metrics", lambda *a, **k: [])
    _patch_alltime(monkeypatch, False)
    token = tools.current_user_id.set("u1")
    try:
        out = tools.query_metric(tools.STEPS, days=7)
    finally:
        tools.current_user_id.reset(token)
    assert out["count"] == 0
    assert out["data_status"]["status"] == "never_recorded"


def test_query_metric_omits_status_when_data_present(monkeypatch):
    monkeypatch.setattr(
        tools, "_fetch_metrics",
        lambda *a, **k: [{"value": 10, "unit": "count", "started_at": "2026-09-09",
                          "ended_at": None, "source_device": "iPhone", "metadata": {}}])
    token = tools.current_user_id.set("u1")
    try:
        out = tools.query_metric(tools.STEPS, days=7)
    finally:
        tools.current_user_id.reset(token)
    assert "data_status" not in out
