#!/usr/bin/env python3
"""
Summarize HealthKit raw QUANTITY data older than CUTOFF_MONTHS into daily aggregates.

Calls the server-side public.health4ai_compact_metric_v2() Postgres function
(supabase/ops/2026-09-14_prod_compact_metric_v2.sql, register D362). For the 14 merged-hour
activity types it RECOMPUTES the daily summary from raw and never deletes raw; for every
other quantity type it COMPACTS in one statement that merges into an existing day rather
than replacing it. The previous function, summarize_healthkit_metric, replaced a day's
summary with whatever raw existed at run time and then deleted that raw, which lost every
hour that had arrived before a late remainder (measured 2026-09-14: it ran mid re-import).
Invoked via the Supabase Management API SQL endpoint rather than PostgREST RPC, whose 8 s
statement timeout aborts multi-million-row types.

DEFAULT IS --merged-only. COMPACT mode for the non-merged types is withheld until the
re-sent-history residual has a guard: after a fresh install the app re-sends a type's full
history, and rows re-sent for a day the server already compacted are indistinguishable
from new data, so a merge would add them twice. Pass --all-types only when no re-import
is in flight (synced_at quiet for 24 h) and no type has been reset since its last run.

EXCLUDED from summarization (kept raw indefinitely):
  - Category types (HKCategoryTypeIdentifier*) — sleep stages, symptoms. Their value
    is categorical and the metadata payload (sleep_stage) would be destroyed by averaging.
  - Workout type (HKWorkoutTypeIdentifier) — metadata (type, duration, distance, calories)
    is the payload; very low volume so no need to compress.

USAGE:
  python summarize_historical.py            # dry run — counts only, no changes
  python summarize_historical.py --execute  # runs the transactional summarization

Only run after the backfill is confirmed complete.
"""

import argparse
import os
from datetime import date, timedelta

import httpx
from dotenv import load_dotenv

load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), "../mcp-server/.env"))

SUPABASE_URL = os.environ["SUPABASE_URL"]
SERVICE_ROLE_KEY = os.environ["SUPABASE_SERVICE_ROLE_KEY"]
SUPABASE_PAT = os.environ["SUPABASE_PAT"]
USER_ID = os.environ["HEALTHKIT_USER_ID"]
PROJECT_REF = SUPABASE_URL.replace("https://", "").replace(".supabase.co", "")
MGMT_URL = f"https://api.supabase.com/v1/projects/{PROJECT_REF}/database/query"
MGMT_HEADERS = {"Authorization": f"Bearer {SUPABASE_PAT}", "Content-Type": "application/json"}
CUTOFF_MONTHS = 1

HEADERS = {
    "apikey": SERVICE_ROLE_KEY,
    "Authorization": f"Bearer {SERVICE_ROLE_KEY}",
    "Content-Type": "application/json",
}
API = f"{SUPABASE_URL}/rest/v1"


def cutoff_date() -> str:
    return (date.today() - timedelta(days=CUTOFF_MONTHS * 30)).isoformat()


def is_summarizable(metric_type: str) -> bool:
    """Only high-volume quantity types are safe to aggregate to daily stats."""
    if metric_type.startswith("HKCategoryTypeIdentifier"):
        return False
    if metric_type == "HKWorkoutTypeIdentifier":
        return False
    return True


def types_before(cutoff: str) -> list[str]:
    # PostgREST enforces a max-rows cap (~5000) regardless of limit=. Paging rows
    # to discover distinct types is non-deterministic. Use a server-side RPC instead.
    PAT = os.environ.get("SUPABASE_PAT", "")
    if not PAT:
        raise RuntimeError(
            "SUPABASE_PAT not set. Required for exact distinct-type query via Management API.\n"
            "Add SUPABASE_PAT=sbp_... to .env"
        )
    project_ref = SUPABASE_URL.replace("https://", "").replace(".supabase.co", "")
    resp = httpx.post(
        f"https://api.supabase.com/v1/projects/{project_ref}/database/query",
        headers={"Authorization": f"Bearer {PAT}", "Content-Type": "application/json"},
        json={"query": (
            "SELECT DISTINCT metric_type FROM public.healthkit_metrics "
            f"WHERE user_id = $user${USER_ID}$user$ "
            f"AND started_at < $cutoff${cutoff}T00:00:00+00:00$cutoff$::timestamptz"
        )},
        timeout=120,
    )
    resp.raise_for_status()
    rows = resp.json()
    if not isinstance(rows, list):
        raise RuntimeError(f"Unexpected response from Management API: {rows}")
    return sorted(r["metric_type"] for r in rows)


def count_raw(metric_type: str, cutoff: str) -> int:
    # count=estimated uses planner stats for large tables (instant); exact counts
    # over millions of rows hit the PostgREST statement timeout (error 57014).
    resp = httpx.get(
        f"{API}/healthkit_metrics",
        headers={**HEADERS, "Prefer": "count=estimated"},
        params={
            "user_id": f"eq.{USER_ID}",
            "metric_type": f"eq.{metric_type}",
            "started_at": f"lt.{cutoff}T00:00:00+00:00",
            "select": "id",
            "limit": 1,
        },
        timeout=60,
    )
    resp.raise_for_status()
    # Content-Range header: "0-0/12345" (estimate)
    cr = resp.headers.get("content-range", "*/0")
    tail = cr.split("/")[-1]
    return int(tail) if tail.isdigit() else 0


MERGED_TYPES = frozenset({
    "HKQuantityTypeIdentifierStepCount", "HKQuantityTypeIdentifierDistanceWalkingRunning",
    "HKQuantityTypeIdentifierDistanceCycling", "HKQuantityTypeIdentifierDistanceSwimming",
    "HKQuantityTypeIdentifierDistanceWheelchair", "HKQuantityTypeIdentifierDistanceDownhillSnowSports",
    "HKQuantityTypeIdentifierPushCount", "HKQuantityTypeIdentifierSwimmingStrokeCount",
    "HKQuantityTypeIdentifierFlightsClimbed", "HKQuantityTypeIdentifierActiveEnergyBurned",
    "HKQuantityTypeIdentifierBasalEnergyBurned", "HKQuantityTypeIdentifierAppleExerciseTime",
    "HKQuantityTypeIdentifierAppleMoveTime", "HKQuantityTypeIdentifierAppleStandTime",
})  # mirrors c_merged_types in health4ai_compact_metric_v2 and HealthKitManager.doubleCountedActivityIdentifiers


def summarize(metric_type: str, cutoff: str) -> dict:
    """Run compaction via Management API to bypass PostgREST statement timeout."""
    import re
    if not re.match(r'^HK[A-Za-z0-9]+TypeIdentifier[A-Za-z0-9]+$', metric_type):
        raise ValueError(f"Unexpected metric_type value: {metric_type!r}")
    sql = f"SELECT * FROM public.health4ai_compact_metric_v2($u${USER_ID}$u$, $m${metric_type}$m$, $c${cutoff}$c$)"
    resp = httpx.post(MGMT_URL, headers=MGMT_HEADERS, json={"query": sql}, timeout=600)
    resp.raise_for_status()
    return resp.json()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    parser.add_argument("--all-types", action="store_true",
                        help="also COMPACT the non-merged quantity types (see module docstring before using)")
    args = parser.parse_args()

    cutoff = cutoff_date()
    print(f"Cutoff: {cutoff} ({CUTOFF_MONTHS} months ago)")
    print(f"Mode: {'EXECUTE' if args.execute else 'DRY RUN'}\n")

    all_types = types_before(cutoff)
    summarizable = [t for t in all_types if is_summarizable(t)]
    skipped = [t for t in all_types if not is_summarizable(t)]
    withheld = [] if args.all_types else [t for t in summarizable if t not in MERGED_TYPES]
    if not args.all_types:
        summarizable = [t for t in summarizable if t in MERGED_TYPES]

    print(f"{len(all_types)} types have data before cutoff")
    print(f"  {len(summarizable)} to process ({'all quantity types' if args.all_types else 'merged-hour types only, RECOMPUTE'})")
    print(f"  {len(withheld)} withheld until --all-types (compact-mode residual): {', '.join(withheld) if withheld else 'none'}")
    print(f"  {len(skipped)} kept raw (category/workout): {', '.join(skipped) if skipped else 'none'}\n")

    total_raw = 0
    total_days = 0
    for mt in summarizable:
        if not args.execute:
            n = count_raw(mt, cutoff)
            total_raw += n
            verb = "recomputed into daily summaries (raw kept)" if mt in MERGED_TYPES else "compacted (raw deleted)"
            print(f"  [dry-run] {mt}: {n:,} raw rows would be {verb}")
            continue

        result = summarize(mt, cutoff)
        if result:
            mode = result[0].get("mode", "?")
            raw = result[0].get("raw_rows", 0)
            days = result[0].get("summary_rows", 0)
            skipped_days = result[0].get("skipped_days", 0)
            total_raw += raw
            total_days += days
            tail = "raw kept" if mode == "recompute" else "raw deleted"
            extra = f", {skipped_days} days skipped (per-device rows still present)" if skipped_days else ""
            print(f"  {mt}: {mode}: {raw:,} raw rows -> {days} daily summaries written ({tail}{extra})")

    print(f"\nTotal raw rows {'would be' if not args.execute else ''} processed: {total_raw:,}")
    if args.execute:
        print(f"Total daily summary rows written: {total_days:,}")
    else:
        print("\nRe-run with --execute to apply (server-side, one transaction per type).")


if __name__ == "__main__":
    main()
