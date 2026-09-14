"""Days older than RAW_CUTOFF_DAYS must be served even when compaction never ran.

Why (2026-09-14): nothing on the self-hosted path writes healthkit_daily_summaries (the
summariser is a maintainer-only job), so for every beta tester the summary tier was empty
and every tool that reached past 30 days silently truncated to 30. The fix aggregates the
older window from raw in SQL for days that have no summary, and never counts a day twice.

No database is touched: every fetch helper is replaced with an in-memory stub.
"""
import os
import pathlib
import sys
from datetime import timedelta

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402

CUTOFF = tools._today_local() - timedelta(days=tools.RAW_CUTOFF_DAYS)


def _day(offset_before_cutoff: int) -> str:
    return (CUTOFF - timedelta(days=offset_before_cutoff)).isoformat()


def _point(day: str, value: float, unit: str = "count") -> dict:
    return {"date": day, "unit": unit, "avg_value": value, "min_value": value, "max_value": value,
            "sum_value": value, "sample_count": 1}


def _stub(monkeypatch, summaries: list[dict], raw_aggregates: list[dict]) -> dict:
    """Recent raw is empty; summaries and raw day-aggregates come from the given lists."""
    calls = {"aggregate_windows": []}
    monkeypatch.setattr(tools, "_fetch_metrics", lambda *a, **k: [])
    monkeypatch.setattr(tools, "_fetch_metrics_range", lambda *a, **k: [])
    monkeypatch.setattr(tools, "_fetch_summaries", lambda *a, **k: [dict(s) for s in summaries])
    monkeypatch.setattr(tools, "_fetch_summaries_range",
                        lambda mt, uid, s, e: [dict(x) for x in summaries if s <= x["date"] <= e])

    def aggregate(metric_type, user_id, start_date, end_date):
        calls["aggregate_windows"].append((start_date, end_date))
        return [{**r, "source": "raw"} for r in raw_aggregates if start_date <= r["date"] <= end_date]

    monkeypatch.setattr(tools, "_fetch_raw_daily_aggregates", aggregate)
    return calls


# --- summaries empty -> raw serves the whole older window ----------------------

def test_empty_summary_tier_is_served_from_raw(monkeypatch):
    calls = _stub(monkeypatch, summaries=[],
                  raw_aggregates=[_point(_day(10), 5000), _point(_day(40), 7000)])
    points = tools._get_tiered_daily(tools.STEPS, "u1", 90)
    assert [p["date"] for p in points] == [_day(40), _day(10)]
    assert {p["source"] for p in points} == {"raw"}
    window_start = (tools._today_local() - timedelta(days=90)).isoformat()
    assert calls["aggregate_windows"] == [(window_start, _day(1))], \
        "raw aggregation must cover exactly the older window, ending the day before the cutoff"


def test_range_series_with_no_summaries_is_served_from_raw(monkeypatch):
    _stub(monkeypatch, summaries=[], raw_aggregates=[_point(_day(20), 44.0)])
    points = tools._daily_series_for_range(tools.HRV, "u1", _day(25), _day(15))
    assert [(p["date"], p["source"]) for p in points] == [(_day(20), "raw")]


# --- summaries partial -> summary wins per day, raw fills gaps, never both -------

def test_partial_summaries_are_not_double_counted(monkeypatch):
    summarised = _point(_day(10), 100)
    _stub(monkeypatch, summaries=[summarised],
          raw_aggregates=[_point(_day(10), 999), _point(_day(20), 50)])
    points = tools._get_tiered_daily(tools.STEPS, "u1", 90)
    by_date = {p["date"]: p for p in points}
    assert len(points) == 2
    assert by_date[_day(10)]["source"] == "summary" and by_date[_day(10)]["sum_value"] == 100
    assert by_date[_day(20)]["source"] == "raw" and by_date[_day(20)]["sum_value"] == 50
    assert sum(p["sum_value"] for p in points) == 150


def test_range_series_partial_summaries_not_double_counted(monkeypatch):
    _stub(monkeypatch, summaries=[_point(_day(12), 60.0)],
          raw_aggregates=[_point(_day(12), 1.0), _point(_day(13), 58.0)])
    points = tools._daily_series_for_range(tools.HRV, "u1", _day(14), _day(11))
    assert [(p["date"], p["avg_value"], p["source"]) for p in points] == [
        (_day(13), 58.0, "raw"), (_day(12), 60.0, "summary"),
    ]


def test_complete_summaries_skip_the_raw_query(monkeypatch):
    older_days = 3
    calls = _stub(monkeypatch, summaries=[_point(_day(i), 1) for i in range(1, older_days + 1)],
                  raw_aggregates=[])
    points = tools._get_tiered_daily(tools.STEPS, "u1", tools.RAW_CUTOFF_DAYS + older_days)
    assert len(points) == older_days
    assert calls["aggregate_windows"] == [], "no gap means no second query"


# --- the tier is reported to the caller ------------------------------------------

def test_query_metric_beyond_30_days_reports_which_tier_served(monkeypatch):
    _stub(monkeypatch, summaries=[_point(_day(5), 10)], raw_aggregates=[_point(_day(15), 20)])
    out = tools.query_metric(tools.STEPS, days=60)
    assert out["count"] == 2
    assert out["tier"]["days_served_by"] == {"summary": 1, "raw": 1}
    assert "no day is counted from both" in out["tier"]["note"]
