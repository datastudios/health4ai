"""
MCP tool implementations — reads from Postgres via psycopg2.
Routing: queries within 30 days use raw healthkit_metrics; days beyond 30 use a
healthkit_daily_summaries row where one exists and are aggregated from raw in SQL
otherwise (self-hosted projects never run compaction, so their summary tier is empty).
Calendar days follow HEALTH4AI_TZ (default UTC).

Connection: set DATABASE_URL (or its alias SUPABASE_DB_URL) to a Postgres connection
string. Nothing is auto-constructed from SUPABASE_URL or a service-role key — that key is not
the database password. An earlier version of this docstring described exactly that fallback;
_build_database_url() below refuses to build one, and says why.
"""

from datetime import datetime, date, timedelta, timezone
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
import contextvars
import os
import re
import uuid
import psycopg2
import psycopg2.extras
from dotenv import load_dotenv

load_dotenv()


def _load_timezone(name: str) -> ZoneInfo:
    """Resolve HEALTH4AI_TZ. Every calendar-day bucket in this module (daily aggregates,
    snapshots, sleep nights) follows this zone; it used to be hard-coded to the author's
    (America/New_York), which put every other user's midnight in the wrong place."""
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError) as e:
        raise RuntimeError(
            f"HEALTH4AI_TZ={name!r} is not a valid IANA time zone name "
            "(examples: UTC, America/New_York, Europe/Berlin). Unset it to use UTC."
        ) from e


TZ_NAME = os.environ.get("HEALTH4AI_TZ", "UTC")
TZ = _load_timezone(TZ_NAME)



def _build_database_url() -> str:
    """
    Resolve DATABASE_URL. Priority:
    1. DATABASE_URL env var
    2. SUPABASE_DB_URL env var (direct pooler URL with actual DB password)
    3. Raise — do not auto-construct from service role key (it's not the DB password)
    """
    url = os.environ.get("DATABASE_URL") or os.environ.get("SUPABASE_DB_URL")
    if url:
        return url

    raise RuntimeError(
        "No database connection configured. Set DATABASE_URL or SUPABASE_DB_URL."
    )


DATABASE_URL = _build_database_url()
DEFAULT_USER_ID = os.environ.get("HEALTHKIT_USER_ID", "")

PLACEHOLDER_USER_ID = "00000000-0000-0000-0000-000000000000"  # the value shipped in .env.example


def validate_user_id(raw: str | None) -> str:
    """Return the canonical UUID string, or raise ValueError naming the variable.

    Unset -> '' -> Postgres raised `invalid input syntax for type uuid` on every tool;
    left at the .env.example placeholder -> every tool answered no_data_yet. Both looked
    like a broken server rather than a missing setup step, so main.py refuses to start.
    """
    value = (raw or "").strip()
    if not value:
        raise ValueError("HEALTHKIT_USER_ID is not set")
    try:
        parsed = uuid.UUID(value)
    except ValueError:
        raise ValueError(f"HEALTHKIT_USER_ID={value!r} is not a UUID") from None
    if str(parsed) == PLACEHOLDER_USER_ID:
        raise ValueError("HEALTHKIT_USER_ID is still the .env.example placeholder")
    return str(parsed)

# Set the context var default so stdio mode works without --transport http
current_user_id = contextvars.ContextVar('current_user_id', default=DEFAULT_USER_ID)

TABLE = "healthkit_metrics"
SUMMARY_TABLE = "healthkit_daily_summaries"
RAW_CUTOFF_DAYS = 30  # beyond this, queries hit daily summaries

# Query parameter bounds — reject/clamp caller input before any DB read so a
# mistaken or hostile MCP client can't trigger unbounded scans.
MAX_DAYS = 1825       # 5 years
MAX_MONTHS = 120      # 10 years
MAX_LIMIT = 1000


def _connect():
    """Open a new psycopg2 connection. Callers are responsible for closing it.

    Timeouts are not optional here. Every call is a fresh TCP+TLS handshake to the
    pooler, the tools are synchronous functions on a bounded worker threadpool, and a
    single empty query_metric now costs two or three connections. Without
    connect_timeout a stalled connect pins its worker indefinitely, and enough of those
    stall the server for every tenant rather than just the caller who triggered it.

    statement_timeout is deliberately NOT set here. Passing it via libpq `options` is
    silently discarded by Supabase's transaction pooler: measured 2026-09-09, a
    connection opened with `-c statement_timeout=15000` reported `SHOW statement_timeout`
    = `2min`, the server default. Shipping that line would have been a fix that does
    nothing while looking like protection. If a shorter query bound is wanted, set it on
    the database role (ALTER ROLE ... SET statement_timeout) where the pooler cannot
    drop it, and verify with SHOW rather than assuming.
    """
    return psycopg2.connect(
        DATABASE_URL,
        connect_timeout=int(os.environ.get("DB_CONNECT_TIMEOUT", "5")),
    )


_summary_date_col: str | None = None


def summary_date_column() -> str:
    """Which date column this deployment's summaries table actually uses.

    health4ai is bring-your-own-backend, and the two schemas in the wild disagree:
      - supabase/bootstrap/001+002 (what a NEW self-hosting user runs) deliberately
        standardised on `summary_date`, and the summarize function writes it
      - the author's legacy project has `date`, because migration 009's
        CREATE TABLE IF NOT EXISTS silently no-opped against a pre-existing table
    This server queried `date` unconditionally, so every summary-backed tool — the
    >30-day branch of query_metric, get_long_term_trend, get_metric_stats,
    get_health_summary, compare_periods and more — raised `column "date" does not
    exist` for every user who followed the documented install. Detect instead of
    assuming; picking either name outright breaks the other half of the userbase.

    Resolved once and cached. The result is a fixed identifier from a two-element
    allowlist, never caller input, so interpolating it into SQL is safe.
    """
    global _summary_date_col
    if _summary_date_col is None:
        conn = _connect()
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT column_name FROM information_schema.columns "
                    "WHERE table_name = %s AND column_name IN ('summary_date', 'date') "
                    "ORDER BY column_name = 'summary_date' DESC LIMIT 1",
                    (SUMMARY_TABLE,),
                )
                row = cur.fetchone()
        finally:
            conn.close()
        _summary_date_col = row[0] if row else "date"
    return _summary_date_col


def _normalise_summary_rows(rows: list[dict]) -> list[dict]:
    """Expose the date column as `date` regardless of what it is called on disk,
    so every caller downstream keeps reading one key."""
    col = summary_date_column()
    if col != "date":
        for r in rows:
            r["date"] = r.get(col)
    return rows


def _clamp_days(days: int) -> int:
    """Clamp a day-window parameter to [1, MAX_DAYS]. Non-positive → 1."""
    try:
        days = int(days)
    except (TypeError, ValueError):
        return 1
    return max(1, min(days, MAX_DAYS))


def _clamp_limit(limit: int) -> int:
    """Clamp a row-limit parameter to [1, MAX_LIMIT]. Non-positive → 1."""
    try:
        limit = int(limit)
    except (TypeError, ValueError):
        return 1
    return max(1, min(limit, MAX_LIMIT))

# Common HealthKit metric type identifiers
STEPS = "HKQuantityTypeIdentifierStepCount"
HEART_RATE = "HKQuantityTypeIdentifierHeartRate"
HRV = "HKQuantityTypeIdentifierHeartRateVariabilitySDNN"
RESTING_HR = "HKQuantityTypeIdentifierRestingHeartRate"
VO2MAX = "HKQuantityTypeIdentifierVO2Max"
ACTIVE_ENERGY = "HKQuantityTypeIdentifierActiveEnergyBurned"
SLEEP = "HKCategoryTypeIdentifierSleepAnalysis"
WEIGHT = "HKQuantityTypeIdentifierBodyMass"
WORKOUT = "HKWorkoutTypeIdentifier"


def _fetch_metrics(metric_type: str, user_id: str, since: str, limit: int = 500,
                   source_filter: str | None = None) -> list[dict]:
    """
    Fetch raw healthkit_metrics rows since `since` (ISO timestamp), up to `limit`.
    Paginates in batches of 5000 to collect all rows within the limit.
    source_filter: optional substring match on source_device (ILIKE %filter%).
    """
    if source_filter:
        if not re.match(r'^[\w\s\-\.]{1,64}$', source_filter):
            raise ValueError("source_filter contains invalid characters")

    PAGE = 5000
    all_rows: list[dict] = []
    offset = 0

    conn = _connect()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            while len(all_rows) < limit:
                fetch = min(PAGE, limit - len(all_rows))
                if source_filter:
                    cur.execute(
                        f"""
                        SELECT * FROM {TABLE}
                        WHERE user_id = %s
                          AND metric_type = %s
                          AND started_at >= %s
                          AND source_device ILIKE %s
                        ORDER BY started_at DESC
                        LIMIT %s OFFSET %s
                        """,
                        (user_id, metric_type, since,
                         f"%{source_filter}%", fetch, offset),
                    )
                else:
                    cur.execute(
                        f"""
                        SELECT * FROM {TABLE}
                        WHERE user_id = %s
                          AND metric_type = %s
                          AND started_at >= %s
                        ORDER BY started_at DESC
                        LIMIT %s OFFSET %s
                        """,
                        (user_id, metric_type, since, fetch, offset),
                    )
                page = [dict(r) for r in cur.fetchall()]
                if not page:
                    break
                all_rows.extend(page)
                if len(page) < fetch:
                    break
                offset += fetch
    finally:
        conn.close()

    return all_rows


def _fetch_metrics_range(metric_type: str, user_id: str,
                         start_iso: str, end_iso: str) -> list[dict]:
    """Raw samples in [start_iso, end_iso) with pagination."""
    PAGE = 5000
    all_rows: list[dict] = []
    offset = 0

    conn = _connect()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            while True:
                cur.execute(
                    f"""
                    SELECT * FROM {TABLE}
                    WHERE user_id = %s
                      AND metric_type = %s
                      AND started_at >= %s
                      AND started_at < %s
                    ORDER BY started_at ASC
                    LIMIT %s OFFSET %s
                    """,
                    (user_id, metric_type, start_iso, end_iso, PAGE, offset),
                )
                page = [dict(r) for r in cur.fetchall()]
                if not page:
                    break
                all_rows.extend(page)
                if len(page) < PAGE:
                    break
                offset += PAGE
    finally:
        conn.close()

    return all_rows


def _fetch_metrics_snapshot(user_id: str, day_start: str, day_end: str,
                            limit: int = 1000) -> list[dict]:
    """All metric rows for a single calendar day (both bounds inclusive on started_at)."""
    conn = _connect()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                f"""
                SELECT * FROM {TABLE}
                WHERE user_id = %s
                  AND started_at >= %s
                  AND started_at < %s
                ORDER BY metric_type ASC, started_at ASC
                LIMIT %s
                """,
                (user_id, day_start, day_end, limit),
            )
            return [dict(r) for r in cur.fetchall()]
    finally:
        conn.close()


def _fetch_summaries(metric_type: str, user_id: str,
                     since_date: str, limit: int = 500) -> list[dict]:
    """Query daily summaries table for historical data."""
    col = summary_date_column()
    conn = _connect()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                f"""
                SELECT * FROM {SUMMARY_TABLE}
                WHERE user_id = %s
                  AND metric_type = %s
                  AND {col} >= %s
                ORDER BY {col} DESC
                LIMIT %s
                """,
                (user_id, metric_type, since_date, limit),
            )
            return _normalise_summary_rows([dict(r) for r in cur.fetchall()])
    finally:
        conn.close()


def _fetch_summaries_range(metric_type: str, user_id: str,
                           start_date: str, end_date: str) -> list[dict]:
    """Daily summaries in [start_date, end_date]."""
    col = summary_date_column()
    conn = _connect()
    try:
        with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            cur.execute(
                f"""
                SELECT * FROM {SUMMARY_TABLE}
                WHERE user_id = %s
                  AND metric_type = %s
                  AND {col} >= %s
                  AND {col} <= %s
                ORDER BY {col} ASC
                LIMIT 10000
                """,
                (user_id, metric_type, start_date, end_date),
            )
            return _normalise_summary_rows([dict(r) for r in cur.fetchall()])
    finally:
        conn.close()


def _fetch_raw_daily_aggregates(metric_type: str, user_id: str,
                                start_date: str, end_date: str) -> list[dict]:
    """Day-bucketed aggregates computed IN SQL from raw samples for local days
    [start_date, end_date]. Same buckets and fields as _daily_from_raw, but the window
    can be years wide: the database returns one row per day, never the samples.

    Why this exists: nothing on the self-hosted path ever writes
    healthkit_daily_summaries (the summariser is a maintainer-only job), so the
    summary tier is empty for every beta tester and every tool that reached past
    RAW_CUTOFF_DAYS silently truncated to 30 days. Postgres and zoneinfo share the
    IANA database, so `AT TIME ZONE TZ_NAME` buckets exactly as _local_date does.
    """
    start_iso, end_iso = _local_day_bounds_utc(start_date, end_date)
    conn = _connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                f"""
                SELECT (started_at AT TIME ZONE %s)::date AS day, coalesce(unit, '') AS unit,
                       avg(value), min(value), max(value), sum(value), count(value)
                FROM {TABLE}
                WHERE user_id = %s AND metric_type = %s AND value IS NOT NULL
                  AND started_at >= %s AND started_at < %s
                GROUP BY 1, 2 ORDER BY 1, 2
                LIMIT 10000
                """,
                (TZ_NAME, user_id, metric_type, start_iso, end_iso),
            )
            # GROUP BY unit as well as day, exactly as the summariser does (register D338):
            # a day stored in two units (32 g and 0.032 kg) must never be summed to 32.032.
            return [{
                "date": str(day), "unit": unit, "avg_value": round(float(a), 4),
                "min_value": float(lo), "max_value": float(hi), "sum_value": round(float(s), 4),
                "sample_count": int(n), "source": "raw",
            } for day, unit, a, lo, hi, s, n in cur.fetchall()]
    finally:
        conn.close()


# ---------------------------------------------------------------------------
# Internal helpers (no DB calls — pure logic unchanged from prior version)
# ---------------------------------------------------------------------------

def _since(days: int) -> str:
    dt = datetime.now(timezone.utc) - timedelta(days=days)
    return dt.isoformat()


def _today_local() -> date:
    return datetime.now(TZ).date()


def _local_date(iso: str) -> str:
    """Convert an ISO timestamp string to a calendar date (YYYY-MM-DD) in HEALTH4AI_TZ."""
    dt = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    return dt.astimezone(TZ).strftime("%Y-%m-%d")


def _local_day_bounds_utc(start_date: str, end_date: str) -> tuple[str, str]:
    """UTC ISO bounds [start, end) covering local days start_date..end_date inclusive."""
    start = datetime.strptime(start_date, "%Y-%m-%d").replace(tzinfo=TZ)
    end = datetime.strptime(end_date, "%Y-%m-%d").replace(tzinfo=TZ) + timedelta(days=1)
    return start.astimezone(timezone.utc).isoformat(), end.astimezone(timezone.utc).isoformat()


def _fill_days_from_raw(metric_type: str, user_id: str, start_date: str, end_date: str,
                        daily: dict[tuple[str, str], dict]) -> None:
    """Older-window gap fill, keyed on (date, unit). A day keeps its summary rows where any
    exist; every other day in [start_date, end_date] is aggregated from raw. A day is
    never taken from both tiers."""
    if start_date > end_date:
        return
    span = (date.fromisoformat(end_date) - date.fromisoformat(start_date)).days + 1
    covered = {d for d, _unit in daily if start_date <= d <= end_date}
    if len(covered) >= span:
        return
    for d in _fetch_raw_daily_aggregates(metric_type, user_id, start_date, end_date):
        if d["date"] not in covered:
            daily[(d["date"], d["unit"])] = d


def _single_unit(points: list[dict]) -> tuple[list[dict], dict]:
    """Reduce a (date, unit) series to ONE unit so a tool can present one figure per day.

    Rows keep the unit they were stored in, and a metric written in two units (32 g and
    0.032 kg on the day both app builds wrote) must never be summed or averaged across
    them. Keeps the unit with the most days (ties: alphabetical) and reports what was
    left out, so the caller can say so instead of silently mixing.
    """
    by_unit: dict[str, list[dict]] = {}
    for p in points:
        by_unit.setdefault(p.get("unit") or "", []).append(p)
    if not by_unit:
        return [], {"unit": None}
    keep = max(sorted(by_unit), key=lambda u: len(by_unit[u]))
    info: dict = {"unit": keep}
    if len(by_unit) > 1:
        info["days_in_other_units"] = {u: len(v) for u, v in by_unit.items() if u != keep}
        info["note"] = (
            "This metric is stored in more than one unit. Every figure here uses only the "
            f"unit with the most days ({keep!r}); days recorded in other units are counted "
            "under days_in_other_units and were never combined with these."
        )
    return by_unit[keep], info


def _tier_status(points: list[dict]) -> dict:
    """Which storage tier served each day of a daily series (machine-checkable)."""
    served = {"summary": 0, "raw": 0}
    for p in points:
        served[p.get("source", "raw")] = served.get(p.get("source", "raw"), 0) + 1
    return {
        "days_served_by": served,
        "note": (f"Days older than {RAW_CUTOFF_DAYS} days come from healthkit_daily_summaries "
                 "where a summary exists and are aggregated from raw samples otherwise; no "
                 "day is counted from both tiers."),
    }


def _daily_from_raw(rows: list[dict]) -> list[dict]:
    """Collapse raw samples into (day, unit) aggregates (HEALTH4AI_TZ day boundaries).
    Unit is part of the key: samples in different units are never combined."""
    daily: dict[tuple[str, str], list[float]] = {}
    for r in rows:
        if r.get("value") is None:
            continue
        key = (_local_date(str(r["started_at"])), r.get("unit") or "")
        daily.setdefault(key, []).append(float(r["value"]))
    out = []
    for (d, unit), vals in sorted(daily.items()):
        out.append({
            "date": d,
            "unit": unit,
            "avg_value": round(sum(vals) / len(vals), 4),
            "min_value": min(vals),
            "max_value": max(vals),
            "sum_value": round(sum(vals), 4),
            "sample_count": len(vals),
            "source": "raw",
        })
    return out


def _get_tiered_daily(metric_type: str, user_id: str, days: int) -> list[dict]:
    """
    Daily-aggregated series spanning `days`, transparently merging tiers:
      - recent window (<= RAW_CUTOFF_DAYS): raw samples aggregated to daily
      - older window (> RAW_CUTOFF_DAYS): pre-aggregated daily summaries
    Returns one chronological list. Each point carries source='raw'|'summary'.
    Older days without a summary (every self-hosted user: compaction never ran) are
    aggregated from raw in SQL, so the window is complete either way.
    """
    today = _today_local()
    cutoff = (today - timedelta(days=RAW_CUTOFF_DAYS)).isoformat()
    window_start = (today - timedelta(days=days)).isoformat()

    # Recent raw portion (from max(window_start, cutoff) forward, local-day aligned)
    raw_since = max(window_start, cutoff)
    raw_rows = _fetch_metrics(metric_type, user_id, _local_day_bounds_utc(raw_since, raw_since)[0],
                              limit=100000)
    daily: dict[tuple[str, str], dict] = {
        (d["date"], d["unit"]): d for d in _daily_from_raw(raw_rows) if d["date"] >= cutoff
    }

    # Historical portion — only days strictly before the raw cutoff (no overlap). Keyed on
    # (date, unit): the summariser writes one row per unit per day (register D338).
    if days > RAW_CUTOFF_DAYS:
        for s in _fetch_summaries(metric_type, user_id, window_start, limit=10000):
            s_date, unit = str(s["date"]), s.get("unit") or ""
            if s_date < cutoff:
                daily[(s_date, unit)] = {**s, "date": s_date, "unit": unit, "source": "summary"}
        older_end = (date.fromisoformat(cutoff) - timedelta(days=1)).isoformat()
        _fill_days_from_raw(metric_type, user_id, window_start, older_end, daily)

    return sorted(daily.values(), key=lambda x: (x["date"], x["unit"]))


def _weighted_mean(points: list[dict]) -> float | None:
    """Exact mean across daily points: sum(sum_value) / sum(sample_count).
    Use only for rate/level metrics (HRV, HR, VO2Max). For cumulative metrics
    (steps, energy, distance), use _daily_total_avg() instead."""
    total_sum = sum(p["sum_value"] for p in points if p.get("sum_value") is not None)
    total_n = sum(p["sample_count"] for p in points if p.get("sample_count"))
    return round(total_sum / total_n, 2) if total_n else None


def _daily_total_avg(points: list[dict]) -> float | None:
    """Average daily total for cumulative metrics (steps, energy, distance).
    Each point is one day; sum_value is the day's total. Returns mean across days."""
    totals = [p["sum_value"] for p in points if p.get("sum_value") is not None]
    return round(sum(totals) / len(totals), 1) if totals else None


# Metrics where the meaningful number is the daily total (not mean of intervals)
DISTANCE_WALKING = "HKQuantityTypeIdentifierDistanceWalkingRunning"

# Written by the iPhone's own pedometer. A user who carries the phone accumulates these
# whether or not they own any other device, so zero rows all-time really is anomalous.
_IPHONE_INTRINSIC_METRICS = {STEPS, DISTANCE_WALKING}

# Require a wearable. The iPhone has NO heart-rate sensor, and passive active-energy comes
# from a Watch. For an iPhone-only user, zero rows here is the correct and normal state --
# claiming a denied permission would accuse the majority of users of misconfiguring
# something they never touched. Verified against real data 2026-09-09: every source_device
# writing these two was a Watch, Oura, Withings or a chest strap; StepCount and
# DistanceWalkingRunning both list "iPhone".
_WEARABLE_METRICS = {HEART_RATE, ACTIVE_ENERGY}

# Types that only exist if the user has a wearable feeding the pipeline. Presence of any
# one of them is the positive evidence required before blaming a permission for an empty
# wearable metric.
_WEARABLE_EVIDENCE_METRICS = (
    HRV, RESTING_HR,
    "HKQuantityTypeIdentifierWalkingHeartRateAverage",
    "HKQuantityTypeIdentifierOxygenSaturation",
    "HKQuantityTypeIdentifierRespiratoryRate",
)

# Metrics an iPhone-carrying user necessarily accumulates. Zero rows ALL-TIME for one
# of these is not "you did nothing" -- it means the type was never shared with the app.
#
# HealthKit deliberately never reports a denied READ: a denied type returns an empty
# result identical to a genuinely empty window, so neither the iOS app nor this server
# can ask whether permission exists. The only observable signal is a metric that cannot
# be empty being empty. Without this, an assistant reading a zero confidently tells the
# user they took no steps, which is both wrong and unfalsifiable.
#
# Found the hard way: four of these were silently denied on the author's own account
# from 2026-06-17 to 2026-09-09 while every other type synced normally, and the iOS app
# reported a green "Complete" the whole time.
_ALWAYS_EXPECTED_METRICS = _IPHONE_INTRINSIC_METRICS | _WEARABLE_METRICS

_CUMULATIVE_METRICS = {
    STEPS,
    ACTIVE_ENERGY,
    "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierDistanceCycling",
    "HKQuantityTypeIdentifierBasalEnergyBurned",
    "HKQuantityTypeIdentifierAppleExerciseTime",
    "HKQuantityTypeIdentifierFlightsClimbed",
}


def _avg_daily_total_from_raw(rows: list[dict]) -> float | None:
    """For cumulative metrics: sum intervals per local calendar day, then average across
    days. Uses the unit with the most days only (see _single_unit); never adds units."""
    points, _unit = _single_unit(_daily_from_raw(rows))
    return _daily_total_avg(points)


def _daily_series_for_range(metric_type: str, user_id: str,
                             start_date: str, end_date: str) -> list[dict]:
    """Daily-aggregated series for [start_date, end_date], tier-aware.
    Dates before the raw cutoff come from daily summaries where one exists and are
    aggregated from raw otherwise; recent dates always come from raw samples."""
    cutoff = (_today_local() - timedelta(days=RAW_CUTOFF_DAYS)).isoformat()
    daily: dict[tuple[str, str], dict] = {}  # keyed on (date, unit), never date alone

    older_end = min(end_date, (date.fromisoformat(cutoff) - timedelta(days=1)).isoformat())
    if start_date <= older_end:
        for s in _fetch_summaries_range(metric_type, user_id, start_date, older_end):
            s_date, unit = str(s["date"]), s.get("unit") or ""
            daily[(s_date, unit)] = {**s, "date": s_date, "unit": unit, "source": "summary"}
        _fill_days_from_raw(metric_type, user_id, start_date, older_end, daily)

    raw_start = max(start_date, cutoff)
    if raw_start <= end_date:
        start_iso, end_iso = _local_day_bounds_utc(raw_start, end_date)
        for d in _daily_from_raw(_fetch_metrics_range(metric_type, user_id, start_iso, end_iso)):
            daily[(d["date"], d["unit"])] = d

    return sorted(daily.values(), key=lambda x: (x["date"], x["unit"]))


def _percentile(sorted_vals: list[float], p: float) -> float:
    """p-th percentile via linear interpolation. sorted_vals must be pre-sorted."""
    n = len(sorted_vals)
    if n == 0:
        return 0.0
    idx = (p / 100) * (n - 1)
    lo = int(idx)
    hi = min(lo + 1, n - 1)
    return round(sorted_vals[lo] + (idx - lo) * (sorted_vals[hi] - sorted_vals[lo]), 2)


# ---------------------------------------------------------------------------
# Public tool implementations (signatures and output format unchanged)
# ---------------------------------------------------------------------------

def get_health_summary(days: int = 7) -> dict:
    """
    Overview of key health metrics for the past N days.
    Returns avg steps, avg sleep, avg HRV, avg resting HR, workout count.
    Tier-aware: windows beyond RAW_CUTOFF_DAYS transparently merge in daily summaries for
    steps/HRV/resting HR. Sleep and workouts are never compacted, so those stay raw-only.
    """
    days = _clamp_days(days)
    uid = current_user_id.get()
    since = _since(days)

    sleep_rows = _fetch_metrics(SLEEP, uid, since)
    workout_rows = _fetch_metrics(WORKOUT, uid, since, limit=50)

    def avg(rows: list[dict]) -> float | None:
        vals = [r["value"] for r in rows if r.get("value") is not None]
        return round(sum(vals) / len(vals), 1) if vals else None

    if days > RAW_CUTOFF_DAYS:
        steps_points, steps_unit = _single_unit(_get_tiered_daily(STEPS, uid, days))
        hrv_points, _ = _single_unit(_get_tiered_daily(HRV, uid, days))
        rhr_points, _ = _single_unit(_get_tiered_daily(RESTING_HR, uid, days))

        hrv_avg = _weighted_mean(hrv_points)
        hrv_latest = hrv_points[-1]["avg_value"] if hrv_points else None
        hrv_readings = sum(p["sample_count"] for p in hrv_points)

        rhr_avg = _weighted_mean(rhr_points)
        rhr_latest = rhr_points[-1]["avg_value"] if rhr_points else None
        tier = _tier_status(steps_points + hrv_points + rhr_points)
        tier["note"] += " Counts are day-points across steps, HRV and resting HR."
    else:
        tier = None
        steps_points, steps_unit = _single_unit(_daily_from_raw(_fetch_metrics(STEPS, uid, since)))
        hrv_rows = _fetch_metrics(HRV, uid, since)
        resting_hr_rows = _fetch_metrics(RESTING_HR, uid, since)

        hrv_avg = avg(hrv_rows)
        hrv_latest = hrv_rows[0]["value"] if hrv_rows else None
        hrv_readings = len(hrv_rows)

        rhr_avg = avg(resting_hr_rows)
        rhr_latest = resting_hr_rows[0]["value"] if resting_hr_rows else None

    # Steps from (day, unit) points in both branches — one unit, never summed across units.
    steps_total = round(sum(p["sum_value"] for p in steps_points), 0) if steps_points else None
    steps_daily_avg = _daily_total_avg(steps_points)
    steps_days_with_data = len(steps_points)

    # Sleep: sum duration of "asleep" stages per day
    sleep_stages = [
        r for r in sleep_rows
        if r.get("metadata", {}) and "sleep" in str(r.get("metadata", {})).lower()
    ]

    # Steps is the headline figure an assistant quotes first, and it is one of the
    # metrics that can be silently unshared. A bare zero here becomes "you were
    # inactive" in the answer the user actually reads.
    steps_note = _absence_note(STEPS, uid, steps_days_with_data)

    return {
        "period_days": days,
        "steps": {
            "total": steps_total,
            "daily_avg": steps_daily_avg,
            "days_with_data": steps_days_with_data,
            "unit": steps_unit,
            **({"data_status": steps_note} if steps_note else {}),
        },
        "hrv_sdnn_ms": {
            "avg": hrv_avg,
            "latest": hrv_latest,
            "readings": hrv_readings,
        },
        "resting_heart_rate_bpm": {
            "avg": rhr_avg,
            "latest": rhr_latest,
        },
        "sleep": {
            "total_records": len(sleep_rows),
            "stage_records": len(sleep_stages),
        },
        "workouts": {
            "count": len(workout_rows),
            "types": list({(r.get("metadata") or {}).get("workout_type", "unknown") for r in workout_rows}),
        },
        **({"tier": tier} if tier else {}),
        "data_as_of": datetime.now(timezone.utc).isoformat(),
    }


# HKCategoryValueSleepAnalysis: 0=InBed, 1=AsleepUnspecified, 2=Awake,
# 3=AsleepCore, 4=AsleepDeep, 5=AsleepREM. Only 3/4/5 are true sleep stages.
_SLEEP_STAGE_NAMES = {3.0: "core", 4.0: "deep", 5.0: "rem"}
# Highest priority first. Anything not listed ranks below all of these and competes on
# record count. This used to be an ALLOW list of the author's two devices, which gave
# every Whoop / Garmin / Withings / iPhone-only user a null sleep total.
_SLEEP_SOURCE_PRIORITY = ("oura", "apple watch", "whoop", "garmin", "withings")


def _parse_ts(value) -> datetime:
    return value if isinstance(value, datetime) else datetime.fromisoformat(str(value).replace("Z", "+00:00"))


def _sleep_night_key(started_at) -> str:
    """A night belongs to the local day it began minus 6h (so 01:00 counts as the previous night)."""
    return (_parse_ts(started_at).astimezone(TZ) - timedelta(hours=6)).strftime("%Y-%m-%d")


def _sleep_source_rank(device: str) -> int:
    d = (device or "").lower()
    return next((i for i, name in enumerate(_SLEEP_SOURCE_PRIORITY) if name in d),
                len(_SLEEP_SOURCE_PRIORITY))


def _sleep_stage_rows_by_night(rows: list[dict]) -> dict[str, tuple[str, list[dict]]]:
    """Per night, the ONE source to trust and its stage rows: the highest-priority named
    source that has stage records that night; if none of the named ones is present, the
    source with the most stage records. Never mixes sources within a night."""
    by_night: dict[str, dict[str, list[dict]]] = {}
    for row in rows:
        if row.get("value") not in _SLEEP_STAGE_NAMES or not row.get("started_at") or not row.get("ended_at"):
            continue
        device = row.get("source_device") or "unknown"
        by_night.setdefault(_sleep_night_key(row["started_at"]), {}).setdefault(device, []).append(row)
    chosen: dict[str, tuple[str, list[dict]]] = {}
    for night, by_device in by_night.items():
        device = min(by_device, key=lambda d: (_sleep_source_rank(d), -len(by_device[d]), d))
        chosen[night] = (device, by_device[device])
    return chosen


def get_sleep(days: int = 7) -> dict:
    """
    Sleep analysis for the past N days.
    Returns per-night breakdown with stage durations (REM, Deep/Core, Light, Awake).
    One source per night (see _sleep_stage_rows_by_night): Oura > Apple Watch > Whoop >
    Garmin > Withings > whichever other source has the most stage records that night.
    """
    uid = current_user_id.get()
    since = _since(days)
    rows = _fetch_metrics(SLEEP, uid, since, limit=1000)

    nights: dict[str, dict] = {}
    for night_key, (device, stage_rows) in _sleep_stage_rows_by_night(rows).items():
        night = nights[night_key] = {
            "date": night_key, "source": device, "stages": {}, "total_minutes": 0, "segments": [],
        }
        for row in stage_rows:
            start_dt = _parse_ts(row["started_at"])
            end_dt = _parse_ts(row["ended_at"])
            duration_min = round((end_dt - start_dt).total_seconds() / 60, 1)
            stage = _SLEEP_STAGE_NAMES[row["value"]]
            night["stages"][stage] = night["stages"].get(stage, 0) + duration_min
            night["total_minutes"] += duration_min
            night["segments"].append({
                "stage": stage,
                "started_at": str(row["started_at"]),
                "ended_at": str(row["ended_at"]),
                "duration_minutes": duration_min,
            })

    sorted_nights = sorted(nights.values(), key=lambda n: n["date"], reverse=True)

    total_hours = [n["total_minutes"] / 60 for n in sorted_nights if n["total_minutes"] > 0]
    avg_hours = round(sum(total_hours) / len(total_hours), 1) if total_hours else None

    return {
        "period_days": days,
        "avg_sleep_hours": avg_hours,
        "nights": sorted_nights,
    }


def get_hrv_trend(days: int = 30) -> dict:
    """
    HRV (SDNN) trend over the past N days.
    Returns daily averages, 7-day rolling comparison, and trend direction.
    Tier-aware: windows beyond 30 days transparently use daily summaries.
    """
    days = _clamp_days(days)
    uid = current_user_id.get()
    points, unit = _single_unit(_get_tiered_daily(HRV, uid, days))

    daily_avgs = [
        {"date": p["date"], "avg_hrv_ms": round(p["avg_value"], 1), "source": p["source"]}
        for p in points if p.get("avg_value") is not None
    ]

    # Trend: compare last 7 days vs prior 7 days of daily averages
    trend = None
    if len(daily_avgs) >= 14:
        recent = [d["avg_hrv_ms"] for d in daily_avgs[-7:]]
        prior = [d["avg_hrv_ms"] for d in daily_avgs[-14:-7]]
        delta = round(sum(recent) / len(recent) - sum(prior) / len(prior), 1)
        trend = {"delta_ms": delta, "direction": "improving" if delta > 0 else "declining" if delta < 0 else "stable"}

    return {
        "period_days": days,
        "days_with_data": len(daily_avgs),
        "avg_hrv_ms": _weighted_mean(points),
        "latest_hrv_ms": daily_avgs[-1]["avg_hrv_ms"] if daily_avgs else None,
        "trend_vs_prior_week": trend,
        "unit": unit,
        "tier": _tier_status(points),
        "daily_averages": daily_avgs,
    }


def _absence_facts(metric_type: str, user_id: str) -> dict:
    """Three EXISTS checks in ONE statement on ONE connection.

    Separate helpers would open two or three connections per empty result; every
    _connect() is a fresh TCP+TLS handshake to the pooler, and an empty query_metric
    already costs one or two. Answering all three questions together keeps the added
    cost at exactly one connection.

    Both storage tables are checked for the metric: compaction deletes raw rows past
    RAW_CUTOFF_DAYS, so a metric that stopped months ago has no raw rows at all and
    would otherwise look as though it had never existed.
    """
    evidence = tuple(_WEARABLE_EVIDENCE_METRICS)
    conn = _connect()
    try:
        with conn.cursor() as cur:
            cur.execute(
                f"""
                SELECT
                  EXISTS (SELECT 1 FROM {TABLE}
                           WHERE user_id = %s AND metric_type = %s)
                  OR EXISTS (SELECT 1 FROM {SUMMARY_TABLE}
                              WHERE user_id = %s AND metric_type = %s),
                  EXISTS (SELECT 1 FROM {TABLE} WHERE user_id = %s),
                  EXISTS (SELECT 1 FROM {TABLE}
                           WHERE user_id = %s AND metric_type = ANY(%s))
                """,
                (user_id, metric_type, user_id, metric_type,
                 user_id, user_id, list(evidence)),
            )
            row = cur.fetchone()
            return {
                "has_this_metric": bool(row[0]),
                "has_any_data": bool(row[1]),
                "has_wearable": bool(row[2]),
            }
    finally:
        conn.close()


def _absence_note(metric_type: str, user_id: str, count: int) -> dict | None:
    """Explain a zero result, or return None when there is nothing to explain.

    An empty result has several causes the HealthKit API cannot tell apart, so this
    resolves them with questions the caller cannot ask. The governing rule: NEVER assert
    a denied permission without positive evidence that (a) the pipeline works for this
    user and (b) a device they own produces this type. Getting that wrong tells someone
    they misconfigured a setting they never touched, which is worse than the bare zero
    it replaced -- an assistant is instructed not to hedge it.

    Returned only when count == 0, so a normal answer is never cluttered.
    """
    if count:
        return None

    if metric_type not in _ALWAYS_EXPECTED_METRICS:
        return {
            "status": "empty_window",
            "guidance": (
                "No samples in this window. That may be genuine (this metric is not "
                "recorded continuously). Do not assert the underlying activity was zero "
                "without corroboration."
            ),
        }

    try:
        facts = _absence_facts(metric_type, user_id)
    except Exception:
        # Fail toward the mild note. This query is a new failure mode on a path that
        # used to always succeed, and it fails hardest exactly when the database is
        # already stressed -- which is not the moment to start accusing the user.
        return {
            "status": "empty_window",
            "guidance": (
                "No samples in this window, and the follow-up check could not run. "
                "Report only that this window is empty; do not infer a cause."
            ),
        }

    if facts["has_this_metric"]:
        return {
            "status": "empty_window",
            "guidance": (
                "No samples in this window, but this metric has data at other times, so "
                "the pipeline works. Treat it as a gap in this window, not as a zero."
            ),
        }

    if not facts["has_any_data"]:
        return {
            "status": "no_data_yet",
            "guidance": (
                "This account has no health data of any kind yet, so the first import "
                "has probably not finished. Say that setup looks incomplete. Do NOT "
                "suggest a permission problem, and do not report any value as zero."
            ),
        }

    if metric_type in _WEARABLE_METRICS and not facts["has_wearable"]:
        return {
            "status": "no_recording_device",
            "guidance": (
                f"{metric_type} needs a wearable -- the iPhone has no heart-rate sensor "
                "and does not record active energy on its own. Nothing in this account "
                "looks like it came from a watch or ring, so the likeliest explanation "
                "is simply that no paired device records this. Ask before asserting "
                "either that, or a permission problem. Do not report a zero."
            ),
        }

    return {
        "status": "never_recorded",
        "likely_cause": "permission_not_granted",
        "guidance": (
            f"{metric_type} has never produced a sample for this user, although other "
            "data has synced and a device that records it appears to be present. The "
            "likeliest explanation is that this type is switched off for health4ai in "
            "the Apple Health app (Sharing -> Apps). HealthKit reports a denied read as "
            "an empty result, so neither the app nor this server can confirm it any "
            "other way. Do NOT tell the user this value is zero or that they were "
            "inactive. Suggest checking that the metric is shared, then re-running the "
            "import."
        ),
    }


def query_metric(
    metric_type: str,
    days: int = 7,
    limit: int = 200,
) -> dict:
    """
    Time-series for any HealthKit metric type.
    metric_type: e.g. 'HKQuantityTypeIdentifierStepCount', 'HKQuantityTypeIdentifierHeartRate'
    Windows <= 30 days return raw samples; longer windows return daily aggregates
    (raw samples beyond 30 days are summarized and no longer stored individually).

    IMPORTANT: when count is 0 the response carries a 'data_status' block. Read it
    before answering. A zero here is NOT evidence the user did nothing: iOS reports a
    denied Health permission as an empty result, so an unshared metric and a genuinely
    inactive day look identical. If data_status.status is 'never_recorded', tell the
    user the metric is not being shared with health4ai rather than reporting a zero.
    """
    days = _clamp_days(days)
    limit = _clamp_limit(limit)
    uid = current_user_id.get()

    if days > RAW_CUTOFF_DAYS:
        points, unit = _single_unit(_get_tiered_daily(metric_type, uid, days))
        _avg_fn = _daily_total_avg if metric_type in _CUMULATIVE_METRICS else _weighted_mean
        note = _absence_note(metric_type, uid, len(points))
        return {
            "metric_type": metric_type,
            "period_days": days,
            "granularity": "daily",
            "count": len(points),
            **({"data_status": note} if note else {}),
            "unit": unit,
            "tier": _tier_status(points),
            "avg": _avg_fn(points),
            "min": min((p["min_value"] for p in points if p.get("min_value") is not None), default=None),
            "max": max((p["max_value"] for p in points if p.get("max_value") is not None), default=None),
            "daily": [
                {"date": p["date"], "avg": p["avg_value"], "min": p["min_value"],
                 "max": p["max_value"], "sum": p["sum_value"], "count": p["sample_count"],
                 "source": p["source"]}
                for p in points
            ],
        }

    since = _since(days)
    rows = _fetch_metrics(metric_type, uid, since, limit=limit)

    values = [r["value"] for r in rows if r.get("value") is not None]
    note = _absence_note(metric_type, uid, len(rows))
    return {
        "metric_type": metric_type,
        "period_days": days,
        "granularity": "raw",
        "count": len(rows),
        **({"data_status": note} if note else {}),
        "avg": round(sum(values) / len(values), 2) if values else None,
        "min": min(values) if values else None,
        "max": max(values) if values else None,
        "samples": [
            {
                "value": r["value"],
                "unit": r.get("unit"),
                "started_at": str(r["started_at"]),
                "ended_at": str(r["ended_at"]) if r.get("ended_at") else None,
                "source": r.get("source_device"),
                "metadata": r.get("metadata"),
            }
            for r in rows
        ],
    }


def get_workouts(days: int = 30, limit: int = 20) -> dict:
    """
    Recent workouts with type, duration, distance, and calories.
    """
    uid = current_user_id.get()
    since = _since(days)
    rows = _fetch_metrics(WORKOUT, uid, since, limit=limit)

    workouts = []
    for r in rows:
        meta = r.get("metadata") or {}
        workouts.append({
            "date": str(r["started_at"])[:10],
            "started_at": str(r["started_at"]),
            "workout_type": meta.get("workout_type", "unknown"),
            "duration_minutes": round(meta.get("duration_seconds", 0) / 60, 1),
            "distance_km": round(meta.get("total_distance_meters", 0) / 1000, 2) if meta.get("total_distance_meters") else None,
            "calories_burned": meta.get("total_energy_burned_cal"),
            "source": r.get("source_device"),
        })

    total_duration = sum(w["duration_minutes"] for w in workouts)
    types = {}
    for w in workouts:
        types[w["workout_type"]] = types.get(w["workout_type"], 0) + 1

    return {
        "period_days": days,
        "total_workouts": len(workouts),
        "total_duration_hours": round(total_duration / 60, 1),
        "by_type": types,
        "workouts": workouts,
    }


def get_daily_snapshot(date: str = "") -> dict:
    """
    Everything recorded for a specific date (YYYY-MM-DD). Defaults to today.
    Returns steps, sleep, workouts, HRV, resting HR, active energy, and all other metrics.
    Quantity-metric highlights are tier-aware: dates older than RAW_CUTOFF_DAYS fall back
    to healthkit_daily_summaries once compaction has deleted that day's raw rows. Sleep and
    workout fields stay raw-only (those types are never compacted, so full detail persists).
    """
    uid = current_user_id.get()
    if not date:
        date = _today_local().isoformat()

    try:
        datetime.strptime(date, "%Y-%m-%d")
    except ValueError:
        return {"error": f"Invalid date format '{date}' — expected YYYY-MM-DD"}

    # Local (HEALTH4AI_TZ) midnight boundaries, converted to UTC for the DB query
    day_start, day_end = _local_day_bounds_utc(date, date)

    rows = _fetch_metrics_snapshot(uid, day_start, day_end, limit=1000)

    # Group by metric type
    by_type: dict[str, list[dict]] = {}
    for r in rows:
        mt = r["metric_type"]
        by_type.setdefault(mt, []).append(r)

    # Summarise key metrics
    def first_val(metric: str) -> float | None:
        return by_type[metric][0]["value"] if metric in by_type else None

    def sum_val(metric: str) -> float | None:
        vals = [r["value"] for r in by_type.get(metric, []) if r.get("value")]
        return round(sum(vals), 0) if vals else None

    cutoff_date = (datetime.now(timezone.utc).date() - timedelta(days=RAW_CUTOFF_DAYS)).isoformat()
    is_historical = date < cutoff_date
    highlights_fallback_used = False

    def highlight(metric: str, cumulative: bool) -> float | None:
        nonlocal highlights_fallback_used
        val = sum_val(metric) if cumulative else first_val(metric)
        if val is not None or not is_historical:
            return val
        # Raw rows for this date have already been compacted away — fall back to the
        # daily summary (same helper _daily_series_for_range/_get_tiered_daily use elsewhere).
        srows = _fetch_summaries_range(metric, uid, date, date)
        if not srows:
            return None
        highlights_fallback_used = True
        summary_val = srows[0].get("sum_value") if cumulative else srows[0].get("avg_value")
        return round(summary_val, 1) if summary_val is not None else None

    highlights = {
        "steps": highlight(STEPS, cumulative=True),
        "active_energy_cal": highlight(ACTIVE_ENERGY, cumulative=True),
        "resting_hr_bpm": highlight(RESTING_HR, cumulative=False),
        "hrv_sdnn_ms": highlight(HRV, cumulative=False),
        "weight_kg": highlight(WEIGHT, cumulative=False),
    }

    return {
        "date": date,
        "total_records": len(rows),
        "truncated": len(rows) >= 1000,
        "truncation_note": "Use query_metric with a specific metric_type to retrieve complete data for a single metric." if len(rows) >= 1000 else None,
        "metrics_present": sorted(by_type.keys()),
        "highlights": highlights,
        "highlights_source": "daily_summaries (compacted)" if highlights_fallback_used else "raw",
        "workouts": [
            {
                "type": (r.get("metadata") or {}).get("workout_type"),
                "duration_minutes": round((r.get("metadata") or {}).get("duration_seconds", 0) / 60, 1),
                "calories": (r.get("metadata") or {}).get("total_energy_burned_cal"),
            }
            for r in by_type.get(WORKOUT, [])
        ],
        "sleep_records": len(by_type.get(SLEEP, [])),
        "all_metrics": {
            mt: [{"value": r["value"], "unit": r.get("unit"), "at": str(r["started_at"])} for r in records]
            for mt, records in by_type.items()
        },
    }


def get_long_term_trend(
    metric_type: str,
    months: int = 24,
) -> dict:
    """
    Long-term trend for any metric. Tier-aware: merges recent raw data (last 30 days,
    aggregated to daily) with historical daily summaries, so the trend has no recency gap.
    Best for multi-year / seasonal analysis.
    metric_type examples: HKQuantityTypeIdentifierHeartRateVariabilitySDNN,
                          HKQuantityTypeIdentifierRestingHeartRate,
                          HKQuantityTypeIdentifierBodyMass,
                          HKQuantityTypeIdentifierStepCount
    months: how many months of history to return (default 24)
    """
    months = max(1, min(int(months), MAX_MONTHS))
    uid = current_user_id.get()
    # months*30 can reach 3600; the day window is capped at MAX_DAYS so both caps agree.
    points, unit = _single_unit(_get_tiered_daily(metric_type, uid, _clamp_days(months * 30)))
    if not points:
        return {"metric_type": metric_type, "months": months, "data": [],
                "note": "No data found for this metric/window"}

    # Monthly buckets — weighted by sample_count for an exact monthly mean
    monthly: dict[str, list[dict]] = {}
    for p in points:
        monthly.setdefault(p["date"][:7], []).append(p)

    is_cumulative = metric_type in _CUMULATIVE_METRICS
    _avg_fn = _daily_total_avg if is_cumulative else _weighted_mean

    monthly_trend = [
        {"month": m, "avg": _avg_fn(pts), "days_with_data": len(pts),
         "sources": sorted({p["source"] for p in pts})}
        for m, pts in sorted(monthly.items())
    ]

    return {
        "metric_type": metric_type,
        "months_requested": months,
        "days_with_data": len(points),
        "overall_avg": _avg_fn(points),
        "overall_min": min((p["min_value"] for p in points if p.get("min_value") is not None), default=None),
        "overall_max": max((p["max_value"] for p in points if p.get("max_value") is not None), default=None),
        "unit": unit,
        "tier": _tier_status(points),
        "monthly_trend": monthly_trend,
        "daily_data": [
            {"date": p["date"], "avg": p.get("avg_value"), "min": p.get("min_value"),
             "max": p.get("max_value"), "count": p.get("sample_count"), "source": p["source"]}
            for p in points
        ],
    }


FRESH_HOURS = 48  # older than this and a coaching brief must not cite a number as current


def _newest_started_at(*row_lists: list[dict]) -> datetime | None:
    newest = None
    for rows in row_lists:
        for r in rows:
            ts = r.get("started_at")
            if ts is None:
                continue
            if isinstance(ts, str):
                try:
                    ts = datetime.fromisoformat(ts.replace("Z", "+00:00"))
                except ValueError:
                    continue
            if ts.tzinfo is None:
                ts = ts.replace(tzinfo=timezone.utc)
            if newest is None or ts > newest:
                newest = ts
    return newest


def _data_status(hrv: list[dict], rhr: list[dict], sleep: list[dict], workouts: list[dict],
                 steps: list[dict], now: datetime | None = None) -> dict:
    """Machine-checkable freshness for the coaching brief.

    Added 2026-09-05: the HealthKit feed had been silent for nine days and the brief still
    answered "Recovery stable" with hrv null and zero workouts, which a coaching skill read
    as a clean bill of health. Every consumer now gets the newest sample age up front.
    """
    now = now or datetime.now(timezone.utc)
    newest = _newest_started_at(hrv, rhr, sleep, workouts, steps)
    hours = round((now - newest).total_seconds() / 3600, 1) if newest else None
    if newest is None:
        status = "none"
    elif hours <= FRESH_HOURS:
        status = "fresh"
    else:
        status = "stale"
    guidance = {
        "fresh": "Data is current; numbers in this brief may be cited.",
        "stale": (f"Newest sample is older than {FRESH_HOURS}h; do not cite any number here as "
                  "current. A gap is device-not-worn unless a pipeline failure is shown."),
        "none": "No samples in the query windows; nothing in this brief describes the current state.",
    }[status]
    return {
        "status": status,
        "newest_sample_at": newest.isoformat() if newest else None,
        "hours_since_newest_sample": hours,
        "fresh_threshold_hours": FRESH_HOURS,
        "hrv_samples_14d": len(hrv),
        "sleep_rows_14d": len(sleep),
        "workouts_30d": len(workouts),
        "guidance": guidance,
    }


def get_coaching_brief() -> dict:
    """
    Pre-session coaching brief for Brett — combines recent trends across all key metrics.
    Returns a structured summary optimized for performance coaching context:
    recovery status, sleep quality, training load, and fitness trajectory.
    Call this at the start of every coaching session.
    """
    uid = current_user_id.get()

    # Recent raw data (last 14 days)
    since_14d = _since(14)
    since_30d = _since(30)
    since_7d = _since(7)

    hrv_14d = _fetch_metrics(HRV, uid, since_14d, limit=200)
    rhr_14d = _fetch_metrics(RESTING_HR, uid, since_14d, limit=50)
    sleep_14d = _fetch_metrics(SLEEP, uid, since_14d, limit=500)
    workouts_30d = _fetch_metrics(WORKOUT, uid, since_30d, limit=50)
    steps_7d = _fetch_metrics(STEPS, uid, since_7d, limit=500)
    # Tier-aware: VO2Max readings are infrequent (Watch Cardio Fitness), so the most
    # recent one is often already past RAW_CUTOFF_DAYS and would read as None from a
    # raw-only fetch even though real history exists in daily summaries.
    vo2_points = _get_tiered_daily(VO2MAX, uid, 365)
    weight_rows = _fetch_metrics(WEIGHT, uid, since_30d, limit=30)
    energy_7d = _fetch_metrics(ACTIVE_ENERGY, uid, since_7d, limit=500)
    data_status = _data_status(hrv_14d, rhr_14d, sleep_14d, workouts_30d, steps_7d)

    def avg(rows: list[dict]) -> float | None:
        vals = [r["value"] for r in rows if r.get("value") is not None]
        return round(sum(vals) / len(vals), 1) if vals else None

    def latest(rows: list[dict]) -> float | None:
        for r in rows:
            if r.get("value") is not None:
                return r["value"]
        return None

    # HRV trend: last 7d vs prior 7d
    hrv_recent = [r["value"] for r in hrv_14d[:7] if r.get("value")]
    hrv_prior = [r["value"] for r in hrv_14d[7:] if r.get("value")]
    hrv_delta = None
    hrv_status = "unknown"
    if hrv_recent and hrv_prior:
        delta = round(sum(hrv_recent)/len(hrv_recent) - sum(hrv_prior)/len(hrv_prior), 1)
        hrv_delta = delta
        hrv_status = "improving" if delta > 2 else "declining" if delta < -2 else "stable"

    # Sleep: Core+Deep+REM only (value 3/4/5), one source per night — same selection
    # as get_sleep, instead of the hard Oura filter that nulled sleep for everyone else.
    nights: dict[str, float] = {}
    for night_key, (_device, stage_rows) in _sleep_stage_rows_by_night(sleep_14d).items():
        nights[night_key] = sum(
            (_parse_ts(r["ended_at"]) - _parse_ts(r["started_at"])).total_seconds() / 3600
            for r in stage_rows
        )

    recent_nights = sorted(nights.items(), reverse=True)[:7]
    avg_sleep_h = round(sum(h for _, h in recent_nights) / len(recent_nights), 1) if recent_nights else None

    # Training load
    workout_types = {}
    total_workout_min = 0
    for w in workouts_30d:
        meta = w.get("metadata") or {}
        wtype = meta.get("workout_type", "unknown")
        workout_types[wtype] = workout_types.get(wtype, 0) + 1
        total_workout_min += meta.get("duration_seconds", 0) / 60

    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "data_status": data_status,
        "recovery": {
            "hrv_latest_ms": latest(hrv_14d),
            "hrv_7d_avg_ms": avg(hrv_14d[:7]) if hrv_14d else None,
            "hrv_trend": hrv_status,
            "hrv_delta_vs_prior_week_ms": hrv_delta,
            "resting_hr_latest_bpm": latest(rhr_14d),
            "resting_hr_7d_avg_bpm": avg(rhr_14d),
            "coaching_note": (
                "No HRV samples in the last 7 days; recovery cannot be assessed from this brief. Do not cite recovery."
                if not hrv_recent
                else "Good recovery — normal or increased training load appropriate" if hrv_status == "improving"
                else "Recovery declining — prioritize sleep, reduce intensity if trend continues" if hrv_status == "declining"
                else "Recovery stable"
            ),
        },
        "sleep": {
            "avg_hours_last_7_nights": avg_sleep_h,
            "nights_tracked": len(recent_nights),
            "quality_flag": (
                "good" if avg_sleep_h and avg_sleep_h >= 7.5
                else "borderline" if avg_sleep_h and avg_sleep_h >= 6.5
                else "poor" if avg_sleep_h
                else "no data"
            ),
        },
        "training_load_30d": {
            "total_workouts": len(workouts_30d),
            "total_hours": round(total_workout_min / 60, 1),
            "weekly_avg_workouts": round(len(workouts_30d) / 4.3, 1),
            "by_type": workout_types,
        },
        "activity_7d": {
            "avg_daily_steps": _avg_daily_total_from_raw(steps_7d),
            "avg_active_energy_cal": _avg_daily_total_from_raw(energy_7d),
        },
        "fitness_markers": {
            "vo2max_latest": vo2_points[-1]["avg_value"] if vo2_points else None,
            "vo2max_source_tier": vo2_points[-1]["source"] if vo2_points else None,
            "weight_kg_latest": latest(weight_rows),
            "weight_kg_30d_ago": weight_rows[-1]["value"] if len(weight_rows) > 1 else None,
        },
    }


def search_records(
    metric_type: str,
    days: int = 90,
    min_value: float | None = None,
    max_value: float | None = None,
    limit: int = 100,
) -> dict:
    """
    Find days where a health metric crossed a threshold.
    For cumulative metrics (steps, calories) filters on daily total.
    For rate metrics (HRV, heart rate) filters on daily average.

    Examples:
      - All days with HRV below 40ms:
          metric_type='HKQuantityTypeIdentifierHeartRateVariabilitySDNN', max_value=40
      - Days with 10k+ steps:
          metric_type='HKQuantityTypeIdentifierStepCount', min_value=10000
      - Nights under 6 hours sleep (360 min):
          metric_type='HKCategoryTypeIdentifierSleepAnalysis', max_value=360

    Results sorted highest-to-lowest so outliers surface first.
    """
    uid = current_user_id.get()
    days = _clamp_days(days)
    limit = _clamp_limit(limit)
    today = _today_local().isoformat()
    start_date = (_today_local() - timedelta(days=days)).isoformat()

    points, unit = _single_unit(_daily_series_for_range(metric_type, uid, start_date, today))
    is_cumulative = metric_type in _CUMULATIVE_METRICS
    value_key = "sum_value" if is_cumulative else "avg_value"

    matching = []
    for p in points:
        v = p.get(value_key)
        if v is None:
            continue
        if min_value is not None and v < min_value:
            continue
        if max_value is not None and v > max_value:
            continue
        matching.append({"date": p["date"], "value": round(v, 2), "source": p["source"]})

    matching.sort(key=lambda x: x["value"], reverse=True)

    return {
        "metric_type": metric_type,
        "period_days": days,
        "days_searched": len(points),
        "days_matched": len(matching),
        "filters": {"min_value": min_value, "max_value": max_value},
        "value_type": "daily_total" if is_cumulative else "daily_avg",
        "unit": unit,
        "tier": _tier_status(points),
        "results": matching[:limit],
    }


def get_metric_stats(
    metric_type: str,
    days: int = 90,
) -> dict:
    """
    Personal baseline statistics for any health metric.
    Returns min, max, mean, std dev, and percentile distribution (p10-p90).

    Use to answer: 'Is today's reading good or bad for me personally?'
    Pair with get_daily_snapshot to compare today's value against your baseline.

    The 'thresholds' field translates percentiles into plain English:
      good_day_above = your 75th percentile (a genuinely above-average day)
      poor_day_below = your 25th percentile (a below-average day worth noting)

    IMPORTANT: a data_points of 0 returns a 'data_status' block. Read it before saying
    the user has no data — for metrics like steps or heart rate, an empty result usually
    means the type is not shared with health4ai, not that nothing was recorded.
    """
    uid = current_user_id.get()
    days = _clamp_days(days)
    today = _today_local().isoformat()
    start_date = (_today_local() - timedelta(days=days)).isoformat()

    points, unit = _single_unit(_daily_series_for_range(metric_type, uid, start_date, today))
    is_cumulative = metric_type in _CUMULATIVE_METRICS
    value_key = "sum_value" if is_cumulative else "avg_value"

    values = sorted([p[value_key] for p in points if p.get(value_key) is not None])
    n = len(values)

    if n == 0:
        # "No data found" reads as a fact about the user's behaviour. For a metric that
        # cannot legitimately be empty it is a fact about permissions, and the caller
        # needs to be told which of the two this is.
        return {
            "metric_type": metric_type,
            "period_days": days,
            "data_points": 0,
            "note": "No data found for this metric in the requested window",
            "data_status": _absence_note(metric_type, uid, 0),
        }

    mean = sum(values) / n
    variance = sum((v - mean) ** 2 for v in values) / n

    return {
        "metric_type": metric_type,
        "period_days": days,
        "data_points": n,
        "value_type": "daily_total" if is_cumulative else "daily_avg",
        "unit": unit,
        "tier": _tier_status(points),
        "min": round(values[0], 2),
        "max": round(values[-1], 2),
        "mean": round(mean, 2),
        "std_dev": round(variance ** 0.5, 2),
        "percentiles": {
            "p10": _percentile(values, 10),
            "p25": _percentile(values, 25),
            "p50": _percentile(values, 50),
            "p75": _percentile(values, 75),
            "p90": _percentile(values, 90),
        },
        "thresholds": {
            "good_day_above": _percentile(values, 75),
            "poor_day_below": _percentile(values, 25),
        },
    }


def compare_periods(
    metric_type: str,
    period_a_start: str,
    period_a_end: str,
    period_b_start: str,
    period_b_end: str,
    label_a: str = "Period A",
    label_b: str = "Period B",
) -> dict:
    """
    Compare a health metric between two date ranges. Dates: YYYY-MM-DD.

    Examples:
      - Sleep before vs after starting magnesium:
          period_a = two weeks before, period_b = two weeks after
      - HRV this month vs last month:
          period_a_start='2026-05-01', period_a_end='2026-05-31',
          period_b_start='2026-06-01', period_b_end='2026-06-18'
      - Steps during a work trip vs home baseline

    Returns per-period stats and a delta showing which period was better.
    """
    label_a = str(label_a)[:32]
    label_b = str(label_b)[:32]
    uid = current_user_id.get()
    is_cumulative = metric_type in _CUMULATIVE_METRICS
    value_key = "sum_value" if is_cumulative else "avg_value"
    _avg_fn = _daily_total_avg if is_cumulative else _weighted_mean

    def _valid(start: str, end: str) -> str | None:
        try:
            s = datetime.strptime(start, "%Y-%m-%d")
            e = datetime.strptime(end, "%Y-%m-%d")
        except (TypeError, ValueError):
            return f"Dates must be YYYY-MM-DD (got '{start}', '{end}')"
        if s > e:
            return f"Start ({start}) is after end ({end})"
        if (e - s).days > MAX_DAYS:
            return f"Range exceeds {MAX_DAYS} days; narrow the window"
        return None

    for s, e in ((period_a_start, period_a_end), (period_b_start, period_b_end)):
        err = _valid(s, e)
        if err:
            return {"metric_type": metric_type, "error": err}

    def _period_stats(start: str, end: str) -> dict:
        pts, unit = _single_unit(_daily_series_for_range(metric_type, uid, start, end))
        values = sorted([p[value_key] for p in pts if p.get(value_key) is not None])
        avg = _avg_fn(pts) if pts else None
        return {
            "start": start,
            "end": end,
            "data_points": len(values),
            "avg": avg,
            "min": round(values[0], 2) if values else None,
            "max": round(values[-1], 2) if values else None,
            "unit": unit,
            "tier": _tier_status(pts),
        }

    a = _period_stats(period_a_start, period_a_end)
    b = _period_stats(period_b_start, period_b_end)

    delta = None
    pct_change = None
    verdict = "insufficient data"
    if a["avg"] is not None and b["avg"] is not None:
        delta = round(b["avg"] - a["avg"], 2)
        pct_change = round((delta / a["avg"]) * 100, 1) if a["avg"] else None
        direction = "higher" if delta > 0 else "lower" if delta < 0 else "the same"
        verdict = f"{label_b} is {direction} than {label_a}"

    # A period with no data is not a period of zero. Comparing an unshared or
    # not-yet-imported window against a populated one manufactures a dramatic
    # decline and states it as a verdict, which is worse than saying nothing.
    empty_note = None
    if a["avg"] is None or b["avg"] is None:
        empty_note = _absence_note(metric_type, uid, 0)

    return {
        "metric_type": metric_type,
        "value_type": "daily_total" if is_cumulative else "daily_avg",
        label_a: a,
        label_b: b,
        "comparison": {
            "delta": delta,
            "pct_change": pct_change,
            "verdict": verdict,
        },
        **({"data_status": empty_note} if empty_note else {}),
    }
