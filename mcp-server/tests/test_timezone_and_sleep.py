"""Day buckets follow HEALTH4AI_TZ, and sleep is taken from ONE best source per night.

Why (2026-09-14): the zone was hard-coded to the author's (America/New_York), so every
other user's daily totals split at the wrong midnight; and sleep accepted only Oura or
Apple Watch, so a Whoop / Garmin / Withings / iPhone-only user had null sleep everywhere.

No database is touched: _fetch_metrics is replaced with an in-memory stub.
"""
import importlib
import os
import pathlib
import sys
from datetime import datetime, timedelta, timezone

import pytest

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402


# --- time zone --------------------------------------------------------------------

@pytest.fixture
def reload_tools(monkeypatch):
    """Reload tools with a patched environment, then restore the module for other tests."""
    def _reload(tz_name: str):
        monkeypatch.setenv("HEALTH4AI_TZ", tz_name)
        importlib.reload(tools)
        return tools
    yield _reload
    monkeypatch.undo()
    importlib.reload(tools)


SAMPLE = "2026-03-10T23:30:00+00:00"


@pytest.mark.parametrize("zone, expected_day", [
    ("UTC", "2026-03-10"),
    ("America/New_York", "2026-03-10"),   # 18:30 EST
    ("Asia/Tokyo", "2026-03-11"),         # 08:30 next morning
])
def test_daily_bucket_follows_the_variable(reload_tools, zone, expected_day):
    t = reload_tools(zone)
    assert t.TZ_NAME == zone
    assert t._local_date(SAMPLE) == expected_day
    daily = t._daily_from_raw([{"started_at": SAMPLE, "value": 1.0}])
    assert [d["date"] for d in daily] == [expected_day]
    start_iso, _ = t._local_day_bounds_utc(expected_day, expected_day)
    assert start_iso <= SAMPLE, "the local-day window must contain the sample"


def test_early_morning_sample_moves_to_previous_day_west_of_utc(reload_tools):
    t = reload_tools("America/New_York")
    assert t._local_date("2026-03-10T03:30:00+00:00") == "2026-03-09"


@pytest.mark.parametrize("bad", ["Not/AZone", "", "new york"])
def test_invalid_zone_fails_naming_the_variable(bad):
    with pytest.raises(RuntimeError, match="HEALTH4AI_TZ"):
        tools._load_timezone(bad)


def test_invalid_zone_in_environment_fails_at_import(reload_tools):
    with pytest.raises(RuntimeError, match="HEALTH4AI_TZ='Mars/Olympus'"):
        reload_tools("Mars/Olympus")


# --- sleep source selection -------------------------------------------------------

def _stage(device: str, start: datetime, minutes: int, value: float = 3.0) -> dict:
    return {
        "metric_type": tools.SLEEP, "value": value, "source_device": device, "metadata": {},
        "started_at": start.isoformat(), "ended_at": (start + timedelta(minutes=minutes)).isoformat(),
    }


NIGHT = datetime(2026, 3, 10, 23, 0, tzinfo=timezone.utc)


def _sleep_with(monkeypatch, rows):
    monkeypatch.setattr(tools, "_fetch_metrics", lambda *a, **k: list(rows))
    return tools.get_sleep(7)


def test_iphone_only_night_produces_a_sleep_total(monkeypatch):
    out = _sleep_with(monkeypatch, [
        _stage("iPhone", NIGHT, 90, value=3.0),
        _stage("iPhone", NIGHT + timedelta(minutes=90), 60, value=4.0),
        _stage("iPhone", NIGHT + timedelta(minutes=150), 30, value=0.0),  # InBed: not sleep
    ])
    assert len(out["nights"]) == 1
    night = out["nights"][0]
    assert night["source"] == "iPhone"
    assert night["total_minutes"] == 150
    assert night["stages"] == {"core": 90, "deep": 60}
    assert out["avg_sleep_hours"] == 2.5


def test_oura_and_apple_watch_same_night_uses_oura_only(monkeypatch):
    out = _sleep_with(monkeypatch, [
        _stage("Apple Watch", NIGHT, 400),
        _stage("Oura", NIGHT + timedelta(minutes=5), 300),
    ])
    assert len(out["nights"]) == 1
    assert out["nights"][0]["source"] == "Oura"
    assert out["nights"][0]["total_minutes"] == 300


def test_named_source_beats_unnamed_even_with_fewer_records(monkeypatch):
    out = _sleep_with(monkeypatch, [
        _stage("Whoop 4.0", NIGHT, 420),
        _stage("iPhone", NIGHT, 100), _stage("iPhone", NIGHT + timedelta(minutes=100), 100),
    ])
    assert out["nights"][0]["source"] == "Whoop 4.0"
    assert out["nights"][0]["total_minutes"] == 420


def test_unnamed_sources_pick_the_one_with_most_records(monkeypatch):
    out = _sleep_with(monkeypatch, [
        _stage("Polar", NIGHT, 500),
        _stage("Fitbit", NIGHT, 10), _stage("Fitbit", NIGHT + timedelta(minutes=10), 10),
        _stage("Fitbit", NIGHT + timedelta(minutes=20), 10),
    ])
    assert out["nights"][0]["source"] == "Fitbit"
    assert out["nights"][0]["total_minutes"] == 30


def test_selection_is_per_night(monkeypatch):
    out = _sleep_with(monkeypatch, [
        _stage("Oura", NIGHT, 300),
        _stage("Garmin", NIGHT + timedelta(days=1), 350),
    ])
    assert {n["source"] for n in out["nights"]} == {"Oura", "Garmin"}


def test_coaching_brief_sleep_no_longer_requires_oura(monkeypatch):
    recent = datetime.now(timezone.utc) - timedelta(days=2)
    rows = {tools.SLEEP: [_stage("iPhone", recent, 90), _stage("iPhone", recent + timedelta(minutes=90), 60)]}
    def fake_fetch(metric_type, user_id, since, limit=500, source_filter=None):
        # Honour the filter: the old brief passed source_filter="Oura", which must now be gone.
        return [r for r in rows.get(metric_type, [])
                if not source_filter or source_filter.lower() in r["source_device"].lower()]

    monkeypatch.setattr(tools, "_fetch_metrics", fake_fetch)
    monkeypatch.setattr(tools, "_get_tiered_daily", lambda *a, **k: [])
    brief = tools.get_coaching_brief()
    assert brief["sleep"]["nights_tracked"] == 1
    assert brief["sleep"]["avg_hours_last_7_nights"] == 2.5
