"""A zero must never be reportable as a fact about the user without qualification —
and a DENIAL must never be asserted without positive evidence.

HealthKit reports a denied READ as an empty result, indistinguishable from a genuinely
empty window. So an assistant reading count=0 for step count will tell the user they took
no steps. That happened on the author's own account for nearly three months.

The second half is the harder half. An over-eager accusation is worse than the bare zero
it replaces, because the guidance instructs the assistant NOT to hedge it:
  - the iPhone has no heart-rate sensor, so an iPhone-only user legitimately has zero
    heart rate and zero active energy forever
  - a brand-new user has zero of everything until the first import finishes
Both of those must NOT produce a permission claim.
"""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402


def _facts(monkeypatch, *, this_metric=False, any_data=True, wearable=True):
    monkeypatch.setattr(tools, "_absence_facts", lambda mt, uid: {
        "has_this_metric": this_metric,
        "has_any_data": any_data,
        "has_wearable": wearable,
    })


# --- nothing to explain -------------------------------------------------------

def test_nonzero_count_gets_no_note():
    """A normal answer must not be cluttered with a status block."""
    assert tools._absence_note(tools.STEPS, "u1", 5) is None


def test_ordinary_metric_zero_is_not_called_a_denial(monkeypatch):
    """Most metrics are legitimately empty. Warning on those would train users to
    ignore the warning, which costs the real case its only signal."""
    note = tools._absence_note("HKQuantityTypeIdentifierDistanceSwimming", "u1", 0)
    assert note["status"] == "empty_window"
    assert "likely_cause" not in note


# --- the denial claim, and the three things that must suppress it -------------

def test_iphone_metric_with_data_elsewhere_flags_permission(monkeypatch):
    """Steps: pipeline works, device exists by definition, never any steps. Denial."""
    _facts(monkeypatch, this_metric=False, any_data=True, wearable=True)
    note = tools._absence_note(tools.STEPS, "u1", 0)
    assert note["status"] == "never_recorded"
    assert note["likely_cause"] == "permission_not_granted"
    assert "do not tell the user this value is zero" in note["guidance"].lower()


def test_metric_with_history_is_a_gap_not_a_denial(monkeypatch):
    """Data at other times proves the pipeline works; do not cry permission."""
    _facts(monkeypatch, this_metric=True)
    note = tools._absence_note(tools.STEPS, "u1", 0)
    assert note["status"] == "empty_window"
    assert "likely_cause" not in note


def test_brand_new_account_is_not_accused(monkeypatch):
    """No data of ANY kind means the first import has not finished. Accusing a user of
    a permission problem on their first run is the worst possible first impression."""
    _facts(monkeypatch, this_metric=False, any_data=False, wearable=False)
    note = tools._absence_note(tools.STEPS, "u1", 0)
    assert note["status"] == "no_data_yet"
    assert "likely_cause" not in note
    assert "permission" not in note["guidance"].lower().split("do not")[0]


def test_wearable_metric_without_a_wearable_is_not_accused(monkeypatch):
    """The iPhone has no heart-rate sensor. Zero heart rate for an iPhone-only user is
    CORRECT, and Apple Watch attach rate is well under half — so a denial claim here
    would be wrong for the majority of users."""
    for metric in (tools.HEART_RATE, tools.ACTIVE_ENERGY):
        _facts(monkeypatch, this_metric=False, any_data=True, wearable=False)
        note = tools._absence_note(metric, "u1", 0)
        assert note["status"] == "no_recording_device", metric
        assert "likely_cause" not in note


def test_wearable_metric_with_a_wearable_is_accused(monkeypatch):
    """Evidence of a wearable plus no heart rate ever: now the denial claim is earned."""
    _facts(monkeypatch, this_metric=False, any_data=True, wearable=True)
    note = tools._absence_note(tools.HEART_RATE, "u1", 0)
    assert note["status"] == "never_recorded"


def test_db_failure_fails_toward_the_mild_note(monkeypatch):
    """This query is a new failure mode on a path that used to always succeed, and it
    fails hardest when the DB is already stressed. It must not accuse anyone then."""
    def boom(mt, uid):
        raise RuntimeError("pooler exhausted")
    monkeypatch.setattr(tools, "_absence_facts", boom)
    note = tools._absence_note(tools.STEPS, "u1", 0)
    assert note["status"] == "empty_window"
    assert "likely_cause" not in note


# --- the classification itself ------------------------------------------------

def test_iphone_intrinsic_set_holds_only_pedometer_metrics():
    """These two are written by the iPhone's own pedometer. Adding a sensor-dependent
    metric here re-creates the false-accusation bug."""
    assert tools._IPHONE_INTRINSIC_METRICS == {
        "HKQuantityTypeIdentifierStepCount",
        "HKQuantityTypeIdentifierDistanceWalkingRunning",
    }


def test_sensor_dependent_metrics_are_classified_as_wearable():
    assert tools._WEARABLE_METRICS == {
        "HKQuantityTypeIdentifierHeartRate",
        "HKQuantityTypeIdentifierActiveEnergyBurned",
    }


# --- the tenancy predicate, which nothing else covers -------------------------

def test_absence_facts_scopes_every_subquery_to_the_calling_user(monkeypatch):
    """The only new tenant-scoping in this change. Without this test a refactor could
    drop a user_id predicate — or reorder the params tuple, where user_id and
    metric_type alternate — and turn this into a cross-tenant oracle, silently, with
    the rest of the suite still green."""
    captured = {}

    class FakeCursor:
        def __enter__(self): return self
        def __exit__(self, *a): return False
        def execute(self, sql, params):
            captured["sql"] = sql
            captured["params"] = params
        def fetchone(self): return (False, False, False)

    class FakeConn:
        def cursor(self): return FakeCursor()
        def close(self): captured["closed"] = True

    monkeypatch.setattr(tools, "_connect", lambda: FakeConn())
    tools._absence_facts("METRIC_X", "user-42")

    sql, params = captured["sql"], captured["params"]
    assert sql.count("user_id = %s") == 4, "every subquery must be tenant-scoped"
    # Order matters and is easy to invert: (uid, metric, uid, metric, uid, uid, evidence)
    assert params[0] == "user-42" and params[1] == "METRIC_X"
    assert params[2] == "user-42" and params[3] == "METRIC_X"
    assert params[4] == "user-42" and params[5] == "user-42"
    assert set(params[6]) == set(tools._WEARABLE_EVIDENCE_METRICS)
    assert captured.get("closed") is True, "connection must be closed"


# --- the tool payloads --------------------------------------------------------

def test_query_metric_attaches_status_on_empty_raw(monkeypatch):
    """The tool payload itself must carry the block; a helper nobody calls is not a fix."""
    monkeypatch.setattr(tools, "_fetch_metrics", lambda *a, **k: [])
    _facts(monkeypatch, this_metric=False, any_data=True, wearable=True)
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


def test_get_metric_stats_attaches_status_when_empty(monkeypatch):
    """Second call site, previously untested."""
    monkeypatch.setattr(tools, "_daily_series_for_range", lambda *a, **k: [])
    _facts(monkeypatch, this_metric=False, any_data=True, wearable=True)
    token = tools.current_user_id.set("u1")
    try:
        out = tools.get_metric_stats(tools.STEPS, days=90)
    finally:
        tools.current_user_id.reset(token)
    assert out["data_points"] == 0
    assert out["data_status"]["status"] == "never_recorded"
