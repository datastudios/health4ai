"""get_workouts must say when the feed has stopped, even while returning workouts.

Why (2026-09-25): every workout in this account was written by a one-time bulk import
and the newest is 2026-09-17; runs on the 22nd and the 24th exist in Strava and in this
database's own raw heart rate, but produced no workout row. `get_workouts(days=30)` still
answered with a full, healthy-looking list, because the only thing that qualified an
answer was `_absence_note`, and `_absence_note` returns None the moment count > 0.

So the one shape the check could not catch was the shape the data was actually in: a
window full of history from a feed that had died. A caller reading that list has no way
to learn the feed stopped, and the natural reading of "no runs since the 17th" is that
the user stopped running.

No database is touched: the fetch helper is replaced with an in-memory stub.
"""
import pathlib
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import tools  # noqa: E402


def _workout(started, minutes=30):
    return {
        "metric_type": tools.WORKOUT,
        "started_at": started.isoformat(),
        "ended_at": (started + timedelta(minutes=minutes)).isoformat(),
        "value": minutes * 60,
        "source_device": "Apple Watch",
        "metadata": {
            "workout_type": "Running",
            "duration_seconds": minutes * 60,
            "total_distance_meters": 5000.0,
            "total_energy_burned_cal": 400.0,
        },
    }


def _workouts_with(monkeypatch, rows):
    monkeypatch.setattr(tools, "_fetch_metrics",
                        lambda mt, uid, since, limit=500, source_filter=None: list(rows))
    # Must never be consulted on this path -- these workouts are not a zero.
    monkeypatch.setattr(tools, "_absence_facts",
                        lambda mt, uid: (_ for _ in ()).throw(AssertionError("not a zero")))
    return tools.get_workouts(days=30)


def test_stopped_feed_is_flagged_although_workouts_are_returned(monkeypatch):
    stale = datetime.now(timezone.utc) - timedelta(days=14)
    out = _workouts_with(monkeypatch, [_workout(stale), _workout(stale - timedelta(days=2))])

    assert out["total_workouts"] == 2, "the real workouts are still returned"
    assert "data_status" in out, "a full list from a dead feed must still be qualified"
    assert out["data_status"]["status"] == "feed_stale"
    assert out["data_status"]["days_since_newest_workout"] >= 13
    # The guidance has one job: stop the reader turning missing rows into a claim
    # about the person.
    assert "not evidence" in out["data_status"]["guidance"]


def test_live_feed_is_not_cluttered_with_a_warning(monkeypatch):
    recent = datetime.now(timezone.utc) - timedelta(days=1)
    out = _workouts_with(monkeypatch, [_workout(recent)])
    assert out["total_workouts"] == 1
    assert "data_status" not in out, "a healthy answer must carry no status block"


def test_boundary_is_the_declared_cadence_not_a_hidden_constant(monkeypatch):
    """The threshold must come from _FEED_CADENCE_DAYS, so the brief and this tool
    cannot drift into disagreeing about when the same feed is dead."""
    limit = tools._FEED_CADENCE_DAYS["workouts"]
    just_inside = datetime.now(timezone.utc) - timedelta(days=limit, hours=-6)
    assert "data_status" not in _workouts_with(monkeypatch, [_workout(just_inside)])

    just_outside = datetime.now(timezone.utc) - timedelta(days=limit, hours=6)
    assert _workouts_with(monkeypatch, [_workout(just_outside)])["data_status"]["status"] \
        == "feed_stale"
