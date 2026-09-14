# health4ai destructive-paths review, 2026-09-13 (register D361, D362)

Adversarial review of two paths that delete rows: the merged-hour replace (D361) and the daily
summariser (D362). Hand-escalated by Jeff. Every claim below was read back from production
(read-only) or reproduced on a throwaway Postgres 17 with the production table shape; the
reproduction files sit beside this document and are what actually ran.

**State found, not as briefed.** `ee3e023` == `origin/main`, working tree clean: the push happened.
Production already has `health4ai_replace_merged_hours` (prosecdef=false, search_path pinned,
EXECUTE service_role only, anon/authenticated false), ingest v33 per the register, **0 merged rows**,
1,241,554 per-device rows across the 14 activity types, last sync 12:20Z, 2,454,668 raw rows,
6,914 MB. `com.jgle.healthkit-summarize` is unloaded (`launchctl list` count 0).

## Verdicts

| Decision | Verdict | Why |
|---|---|---|
| Push (`ee3e023`, done) | SAFE | Nothing destructive runs until the new build syncs; the server fails closed (500, anchor not advanced). |
| Prod SQL apply (done) and **installing the build** | SAFE WITH FIX | Finding 1: the committed DELETE full-scans the table per call. Apply `-fix-replace.sql` to prod BEFORE the build is installed, and carry it into the upgrade file, bootstrap 002 section 5 and `web/public/schema.sql`. |
| Re-enabling `com.jgle.healthkit-summarize` (register D361 step 5) | HOLD | Findings 4 and 5: the live function loses rows both when a day is split across runs AND when anything syncs while it runs. Replace it with the v2 design first. |

## Findings, ranked

### 1. HIGH (D361): the replace function's DELETE is a full-table scan on every call
`DELETE ... USING jsonb_to_recordset(p_rows)` cannot push the hour range (bounds come from the
recordset) into an index. Production `EXPLAIN` with Jeff's user_id: **`Seq Scan on healthkit_metrics m
(rows=2758559)`** under a Hash Join, range applied as a Join Filter. The read-only equivalent for a
TWO-hour payload: **15,051 ms, 50,597 buffers read, 493,636 rows removed by the join filter.**
PostgREST runs the RPC on an `authenticator` session with `statement_timeout=8s` (`pg_roles`, read
2026-09-13); this repo already records 57014 on service_role RPC calls for that reason
(`scripts/summarize_historical.py:8,92,113`). Expected outcome on install: first merged batch of
each of the 14 types -> 57014 -> ingest 500 -> app retries the same page for ever. No data lost, no
merged hour ever stored, ~15 s of full scan per attempt, 14 attempts per launch. If the timeout
did not apply, ~250 calls x 15-30 s for the re-import and the app's own 60 s request timeout is
within reach.
The e2e suite (27/27) ran on a table of a few rows and could not see this.
**Proof:** `-run.sh` step 6 on 1.5M rows: committed shape `Seq Scan`, 49,998,500 rows removed by
join filter, 2,501 ms per 100-hour call; fix shape `Index Scan using metrics_user_type_time_idx`,
0.5 ms per hour, 8-9 ms per 100-hour call. Prod fix shape (read-only `EXPLAIN ANALYZE`): 4 buffers,
2.2 ms. **Fix:** `-fix-replace.sql`, one constant-bound DELETE per hour inside the same transaction;
14/14 reproductions pass unchanged against it (`-run.sh` step 7).

### 2. MEDIUM (D361): a per-device row that lands after the merged post survives beside it, for good
The function deletes then inserts; a per-device row committed after the delete (concurrent commit
in READ COMMITTED, an older build on a second device, or plainly a later post) sits beside the merged
row and is summed with it by both the summariser and MCP `_daily_from_raw`. Only a re-post of that
hour removes it, and a closed hour is re-posted only when HealthKit reports a new sample in it.
**Proof:** `-repro.sql` R6/R6b; `-run.sh` step 3 (race A) shows both rows after the interleaving.
**Recommendation:** run the detector after the re-import and as a weekly check; it must read 0:
```sql
SELECT count(*) FROM healthkit_metrics d JOIN healthkit_metrics m
  ON m.user_id=d.user_id AND m.metric_type=d.metric_type AND m.source_device='HealthKit (all sources)'
 AND d.started_at >= m.started_at AND d.started_at < m.started_at + interval '1 hour'
WHERE d.source_device <> 'HealthKit (all sources)';
```

### 3. MEDIUM (D361 x D362): history stays +67% until summaries are rebuilt, and the only rebuild path is the broken summariser
`healthkit_daily_summaries` holds 3,306 StepCount days built from per-device sums (stored 32.39M vs
today's raw 32.32M on the same days: both inflated). MCP `_get_tiered_daily` serves summaries for any
day older than 30 days, so every historical answer keeps the double count after the app's re-import,
until something recomputes the summaries from merged rows. Register step 5 proposes the live
summariser for that; findings 4-5 show why it must not be. `v_healthkit_daily_quantity` UNION ALLs
both tiers and would show such a day twice; it has no code consumers today (grep: an article and a
REVOKE), so dormant.

### 4. HIGH (D362): overwrite-then-delete loses every hour that arrived before a late remainder
`summarize_healthkit_metric` (live definition read back, md5 `8adb6894...`): INSERT..SELECT the
aggregate of raw < cutoff with `ON CONFLICT DO UPDATE SET sum_value = EXCLUDED.sum_value` (REPLACE),
then DELETE raw < cutoff. Exact rows lost: for a day already compacted from raw set A, when late
raw set B arrives the summary becomes agg(B) and A is gone from both tiers.
**Proof:** R3: 24 merged hours -> `sum=2400 n=24`; 8 hours re-posted -> **`sum=800 n=8`**, 1,600 steps
gone. R3b: re-import day split 10h/14h across two runs -> **`sum=1400`**, not 2400. Triggers: the
app's one-time history re-send, "Re-run Import", late writers (Oura, Strava, Withings), any merged
re-post of a compacted hour.

### 5. HIGH (D362): rows synced while the summariser runs are deleted without being summarised
The function's three statements take separate snapshots (READ COMMITTED, VOLATILE). Rows committed
between its INSERT..SELECT and its DELETE match the DELETE and never reach a summary.
**Proof:** `-run.sh` step 4: 4,000 rows ingested while the live function ran over 400,000:
**LOST=1,258** (raw 526 + summarised 402,216 of 404,000). Same scenario with the v2 single-statement
design: **LOST=0**. This fires whenever the app syncs during the 03:00 run, which D335 makes likely
("keep the app open").

### 6. LOW (D361): UTC hour buckets vs half-hour zones
Hours are UTC by design (HealthKitManager comment); for a BYOB user in a +5:30 / +9:30 / +5:45 zone
a UTC hour straddles local midnight and up to one hour of steps lands on the neighbouring day.
Whole-hour zones including America/New_York are unaffected. Accept and document for testers.

### 7. LOW (D361): BYOB free tier
Replacing per-device rows with hourly rows shrinks the 14 types about 5x (StepCount ~115 rows/day
per device -> <=24); dead tuples are reclaimed by autovacuum, `pg_database_size` does not shrink
until then. A project already read-only at 500 MB fails closed (500, retry). Pre-existing exposure
is the unbounded first sync (D362 note), not this change.

### Verified, no finding
Atomic: one plpgsql transaction, insert failure rolls the delete back (R1, prod fix keeps it).
Idempotent and order-free: per-hour, `ON CONFLICT DO UPDATE`, retry of a stored hour deletes 0
writes 1 (R5). Privileges on prod as designed; `p_user_id` comes from the verified JWT; anon 401
before any work (e2e). Partial hour from a device offline mid-hour: the whole-hour statistic is
re-posted when the Watch's samples arrive, self-healing while the app is opened. `synced_at` is not
touched by either upsert path, so the "quiet for 30 min" heuristic still measures new inserts only.

## D362 design: merge-safe compaction (`-compact-v2.sql`, deployed nowhere)
- **RECOMPUTE for the 14 merged types: raw is never deleted.** An hourly merged row is the compact
  form. Summaries are a derived cache rebuilt whole-day from raw; replace-on-conflict is then correct
  and late or re-posted hours fold in on the next run. Days still holding a per-device row are skipped
  and counted (`skipped_days`) so nothing is summed twice. This also closes finding 3: the recompute
  IS the rebuild, and it is safe to run at any point during the re-import.
- **COMPACT for every other quantity type: one statement.** `DELETE .. RETURNING` feeds the
  `INSERT .. ON CONFLICT DO UPDATE` that MERGES (`sum+=`, `count+=`, `least`, `greatest`,
  `avg=sum/count`), so the aggregated rows are exactly the deleted rows (no snapshot gap) and a late
  remainder is added, never substituted. Only rows older than the cutoff and quiet for `p_quiet`
  (default 24 h) are touched. `avg=sum/count` is exact while `value` is never NULL (prod: 0 of
  2,454,668).
- **Invariants.** `health4ai_compaction_totals` (conservation: `total_rows` and `total_sum` unchanged
  by a COMPACT run) and `health4ai_recompute_mismatches` (every fully-merged day older than the
  cutoff has a summary equal to its raw aggregate; must return 0 rows).
- **Re-runnable:** a second run with no new raw writes 0 rows in both modes (R4b, R7c).
- **Proof:** R4a-d, R7a-c, `-run.sh` step 5 (LOST=0 under concurrent ingest).
- **Residual, own register row:** for a COMPACT-mode type, history the app re-sends after the server
  deleted it is indistinguishable from new data and would be added twice; the app's per-type reset
  for non-merged types must not target a compacted server without a server-side rebuild of that
  type. Bootstrap projects need `summary_date` and the user time zone substituted.

## Files (all new; no existing file modified)
`destructive-paths-review-2026-09-13-schema.sql` (prod shape + live summariser verbatim),
`-fix-replace.sql` (finding 1 fix), `-compact-v2.sql` (D362 design + invariants), `-repro.sql`
(14 single-session checks), `-run.sh` (driver: races, plan, timing). Existing suites at review time:
web `node --test` 8/8, MCP `python3 -m pytest` 20/20 (the venv has no pytest; the system python does).

## Recommended order for Jeff
1. Apply `-fix-replace.sql` on prod (SQL editor, one file, re-runnable); verify with the upgrade
   file's VERIFY query and `EXPLAIN` of a one-hour DELETE showing `metrics_user_type_time_idx`.
2. Agent carries the same body into `supabase/upgrades/` (new dated file, since testers may have
   applied the first), bootstrap 002 section 5 and `web/public/schema.sql`; `/review`; push.
3. Install the build; verify merged rows arrive and the finding-2 detector reads 0.
4. Keep the summariser unloaded. Replace `summarize_healthkit_metric` with the v2 design (prod first,
   bootstrap variant after), run it by hand once with the invariants, then bootstrap the LaunchAgent.
