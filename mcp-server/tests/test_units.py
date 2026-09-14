"""A metric stored in two units on one day must never be summed across units or lose a row.

Why (2026-09-14 review, register D338): the summariser keys a daily row on
(user_id, metric_type, date, unit) — the iOS unit fix (commit 926f357) creates exactly one
date carrying 32 g and 0.032 kg. The raw fallback grouped by day only (32.032), and every
merge keyed on the date string alone, so the second summary row silently overwrote the
first. Now every bucket and merge is keyed on (date, unit), and a tool that presents one
figure per day keeps one unit and says so.

No database is touched: every fetch helper is replaced with an in-memory stub.
"""
import os
import pathlib
import sys
from datetime import timedelta

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402

PROTEIN = "HKQuantityTypeIdentifierDietaryProtein"
CUTOFF = tools._today_local() - timedelta(days=tools.RAW_CUTOFF_DAYS)


def _day(offset_before_cutoff: int) -> str:
    return (CUTOFF - timedelta(days=offset_before_cutoff)).isoformat()


def _point(day: str, unit: str, value: float) -> dict:
    return {"date": day, "unit": unit, "avg_value": value, "min_value": value,
            "max_value": value, "sum_value": value, "sample_count": 1}


def _raw(day: str, unit: str, value: float) -> dict:
    return {"started_at": f"{day}T12:00:00+00:00", "value": value, "unit": unit}


def _stub(monkeypatch, *, recent_raw=(), summaries=(), raw_aggregates=()):
    monkeypatch.setattr(tools, "_fetch_metrics", lambda *a, **k: list(recent_raw))
    monkeypatch.setattr(tools, "_fetch_metrics_range", lambda *a, **k: list(recent_raw))
    monkeypatch.setattr(tools, "_fetch_summaries", lambda *a, **k: [dict(s) for s in summaries])
    monkeypatch.setattr(tools, "_fetch_summaries_range",
                        lambda mt, uid, s, e: [dict(x) for x in summaries if s <= x["date"] <= e])
    monkeypatch.setattr(tools, "_fetch_raw_daily_aggregates",
                        lambda mt, uid, s, e: [{**r, "source": "raw"} for r in raw_aggregates
                                               if s <= r["date"] <= e])


# --- raw window: two units on one day stay two rows ---------------------------------

def test_daily_from_raw_keeps_units_apart():
    today = tools._today_local().isoformat()
    points = tools._daily_from_raw([_raw(today, "g", 32.0), _raw(today, "kg", 0.032)])
    assert [(p["date"], p["unit"], p["sum_value"]) for p in points] == [
        (today, "g", 32.0), (today, "kg", 0.032),
    ]


def test_avg_daily_total_never_adds_units():
    today = tools._today_local().isoformat()
    rows = [_raw(today, "g", 32.0), _raw(today, "kg", 0.032), _raw(_day(-1), "g", 30.0)]
    # 'g' has the most days, so the average is over g days only: (32 + 30) / 2
    assert tools._avg_daily_total_from_raw(rows) == 31.0


# --- summary window: two summary rows on one date, neither overwritten ---------------

def test_two_summary_rows_same_date_both_survive_merge(monkeypatch):
    _stub(monkeypatch, summaries=[_point(_day(5), "g", 32.0), _point(_day(5), "kg", 0.032)])
    points = tools._get_tiered_daily(PROTEIN, "u1", 90)
    assert [(p["date"], p["unit"], p["sum_value"], p["source"]) for p in points] == [
        (_day(5), "g", 32.0, "summary"), (_day(5), "kg", 0.032, "summary"),
    ]


def test_raw_fallback_rows_keep_units_and_do_not_touch_summarised_days(monkeypatch):
    _stub(monkeypatch,
          summaries=[_point(_day(5), "g", 40.0)],
          raw_aggregates=[_point(_day(5), "kg", 9.9),           # summarised day: ignored
                          _point(_day(9), "g", 32.0), _point(_day(9), "kg", 0.032)])
    points = tools._get_tiered_daily(PROTEIN, "u1", 90)
    assert [(p["date"], p["unit"], p["sum_value"], p["source"]) for p in points] == [
        (_day(9), "g", 32.0, "raw"), (_day(9), "kg", 0.032, "raw"), (_day(5), "g", 40.0, "summary"),
    ]


def test_range_series_keys_on_date_and_unit(monkeypatch):
    _stub(monkeypatch,
          summaries=[_point(_day(3), "g", 1.0), _point(_day(3), "kg", 2.0)],
          raw_aggregates=[_point(_day(4), "g", 3.0), _point(_day(4), "kg", 4.0)])
    points = tools._daily_series_for_range(PROTEIN, "u1", _day(4), _day(3))
    assert len(points) == 4
    assert sorted((p["date"], p["unit"]) for p in points) == [
        (_day(4), "g"), (_day(4), "kg"), (_day(3), "g"), (_day(3), "kg"),
    ]


# --- one figure per day: keep one unit, never combine, and say so ---------------------

def test_single_unit_keeps_majority_unit_and_reports_the_rest():
    points = [_point(_day(1), "g", 1), _point(_day(2), "g", 1), _point(_day(2), "kg", 1)]
    kept, info = tools._single_unit(points)
    assert {p["unit"] for p in kept} == {"g"} and len(kept) == 2
    assert info["unit"] == "g"
    assert info["days_in_other_units"] == {"kg": 1}
    assert "never combined" in info["note"]


def test_single_unit_is_silent_when_only_one_unit():
    assert tools._single_unit([_point(_day(1), "count", 5)])[1] == {"unit": "count"}
    assert tools._single_unit([]) == ([], {"unit": None})


def test_query_metric_daily_uses_one_unit_and_says_so(monkeypatch):
    _stub(monkeypatch, summaries=[_point(_day(5), "g", 32.0), _point(_day(5), "kg", 0.032),
                                  _point(_day(6), "g", 30.0)])
    out = tools.query_metric(PROTEIN, days=60)
    assert out["count"] == 2 and out["unit"]["unit"] == "g"
    assert out["max"] == 32.0, "kg row must not be summed into or compared with the g rows"
    assert out["unit"]["days_in_other_units"] == {"kg": 1}


# --- get_long_term_trend cap agrees with MAX_DAYS ------------------------------------

def test_long_term_trend_day_window_is_capped_at_max_days(monkeypatch):
    seen = {}

    def fake_tiered(metric_type, user_id, days):
        seen["days"] = days
        return []

    monkeypatch.setattr(tools, "_get_tiered_daily", fake_tiered)
    tools.get_long_term_trend(tools.HRV, months=tools.MAX_MONTHS)
    assert seen["days"] == tools.MAX_DAYS
