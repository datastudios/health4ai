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

    def test_newest_sample_wins_across_metrics(self):
        old = datetime.now(timezone.utc) - timedelta(days=9)
        newer = datetime.now(timezone.utc) - timedelta(hours=20)
        brief = self._brief_with({
            tools.HRV: [_row(tools.HRV, old, 45.0)],
            tools.WORKOUT: [_row(tools.WORKOUT, newer, 1.0, meta={"workout_type": "Run", "duration_seconds": 1200})],
        })
        self.assertEqual(brief["data_status"]["status"], "fresh")
        self.assertEqual(brief["data_status"]["workouts_30d"], 1)


if __name__ == "__main__":
    unittest.main()
