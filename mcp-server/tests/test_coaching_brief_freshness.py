"""get_coaching_brief must say when its inputs are stale.

Why (2026-09-05): the HealthKit feed had been silent since 2026-08-27 and the brief still
answered ``coaching_note: "Recovery stable"`` with ``hrv_latest_ms: null`` and zero workouts.
A coaching skill read that as a clean bill of health. The brief now carries a
``data_status`` block that is machine-checkable, and the recovery note refuses to describe
recovery when there are no HRV samples to describe it from.

Run:  cd mcp-server && DATABASE_URL=postgresql://unused .venv/bin/python -m unittest tests.test_coaching_brief_freshness
No database is touched: every fetch helper is replaced with an in-memory stub.
"""
import os
import sys
import unittest
from datetime import datetime, timedelta, timezone
from unittest import mock

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import tools  # noqa: E402  (import after env so module-level DATABASE_URL resolves)


def _row(metric, started, value=42.0, ended=None, meta=None):
    return {
        "metric_type": metric,
        "started_at": started.isoformat(),
        "ended_at": (ended or started + timedelta(hours=1)).isoformat(),
        "value": value,
        "metadata": meta or {},
        "source_device": "Oura",
    }


class FreshnessTests(unittest.TestCase):
    def _brief_with(self, rows_by_metric):
        def fake_fetch(metric_type, user_id, since, limit=500, source_filter=None):
            return list(rows_by_metric.get(metric_type, []))

        with mock.patch.object(tools, "_fetch_metrics", fake_fetch), \
             mock.patch.object(tools, "_get_tiered_daily", lambda *a, **k: []):
            return tools.get_coaching_brief()

    def test_no_samples_reports_none_and_refuses_recovery_claim(self):
        brief = self._brief_with({})
        self.assertIn("data_status", brief, "brief must carry a data_status block")
        self.assertEqual(brief["data_status"]["status"], "none")
        self.assertIsNone(brief["data_status"]["newest_sample_at"])
        note = brief["recovery"]["coaching_note"].lower()
        self.assertNotIn("stable", note, "no data must never read as stable recovery")
        self.assertIn("no hrv", note)

    def test_nine_day_old_samples_are_stale(self):
        old = datetime.now(timezone.utc) - timedelta(days=9)
        brief = self._brief_with({tools.HRV: [_row(tools.HRV, old, 45.0)]})
        self.assertEqual(brief["data_status"]["status"], "stale")
        self.assertGreater(brief["data_status"]["hours_since_newest_sample"], 48)
        self.assertIn("older than", brief["data_status"]["guidance"].lower())

    def test_recent_samples_are_fresh(self):
        recent = datetime.now(timezone.utc) - timedelta(hours=5)
        brief = self._brief_with({tools.HRV: [_row(tools.HRV, recent, 45.0)]})
        self.assertEqual(brief["data_status"]["status"], "fresh")
        self.assertLessEqual(brief["data_status"]["hours_since_newest_sample"], 48)

    def test_one_live_feed_no_longer_vouches_for_a_dead_one(self):
        """This replaces test_newest_sample_wins_across_metrics, which asserted the bug.

        Taking the newest sample across all feeds is only a valid summary when the
        feeds fail together, and they do not. On 2026-09-25 the workout feed had been
        dead since 2026-09-17 while heart rate, steps and sleep kept landing hourly --
        so the brief reported status "fresh", newest sample minutes old, alongside a
        training-load section built entirely from a dataset that had stopped. The old
        test made that behaviour a requirement, so the defect was protected by a
        passing suite.
        """
        old = datetime.now(timezone.utc) - timedelta(days=9)
        newer = datetime.now(timezone.utc) - timedelta(hours=20)
        brief = self._brief_with({
            tools.HRV: [_row(tools.HRV, old, 45.0)],
            tools.WORKOUT: [_row(tools.WORKOUT, newer, 1.0, meta={"workout_type": "Run", "duration_seconds": 1200})],
        })
        ds = brief["data_status"]
        self.assertEqual(ds["status"], "partial",
                         "a stopped feed beside a live one is neither fresh nor stale")
        self.assertIn("hrv", ds["stale_feeds"])
        self.assertNotIn("workouts", ds["stale_feeds"])
        self.assertEqual(ds["feeds"]["workouts"]["status"], "fresh")
        self.assertEqual(ds["workouts_30d"], 1)
        self.assertIn("hrv", ds["guidance"].lower())

    def test_empty_feed_does_not_degrade_the_status(self):
        """A rest month must not read as a broken pipeline.

        Absence with no samples at all is ambiguous and each tool's _absence_note
        resolves it with evidence this function does not have. If empties counted
        here, anyone who did not train for thirty days would get "partial" forever,
        and the warning would stop being read -- which is the failure mode this
        whole block exists to avoid.
        """
        recent = datetime.now(timezone.utc) - timedelta(hours=5)
        brief = self._brief_with({tools.HRV: [_row(tools.HRV, recent, 45.0)]})
        ds = brief["data_status"]
        self.assertEqual(ds["status"], "fresh")
        self.assertEqual(ds["stale_feeds"], [])
        self.assertEqual(ds["feeds"]["workouts"]["status"], "none")

    def test_every_feed_stopped_is_still_plain_stale(self):
        old = datetime.now(timezone.utc) - timedelta(days=9)
        brief = self._brief_with({
            tools.HRV: [_row(tools.HRV, old, 45.0)],
            tools.STEPS: [_row(tools.STEPS, old, 5000.0)],
        })
        ds = brief["data_status"]
        self.assertEqual(ds["status"], "stale",
                         "nothing live means stale, not partial")
        self.assertEqual(sorted(ds["stale_feeds"]), ["hrv", "steps"])


if __name__ == "__main__":
    unittest.main()
