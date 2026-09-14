#!/bin/bash
# Driver for docs/health4ai-destructive-paths-review-2026-09-13.md. THROWAWAY Postgres only:
#   docker run -d --name h4ai-review-pg -e POSTGRES_HOST_AUTH_METHOD=trust postgres:17-alpine
# Loads the prod-shape schema, the COMMITTED upgrade file and the v2 design, runs the single-session
# reproductions, two two-session races, a plan/timing comparison on a 1.5M-row seed, then applies
# the proposed fix and re-runs the reproductions against it.
set -euo pipefail
C=${PG_CONTAINER:-h4ai-review-pg}
D=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$D/.." && pwd)
psql() { docker exec -i "$C" psql -U postgres -X -q -v ON_ERROR_STOP=1 "$@"; }
S=HKQuantityTypeIdentifierStepCount; HR=HKQuantityTypeIdentifierHeartRate; M='HealthKit (all sources)'
UB=b0000000-0000-0000-0000-000000000001; U3=b0000000-0000-0000-0000-000000000003
U4=b0000000-0000-0000-0000-000000000004; U5=b0000000-0000-0000-0000-000000000005

echo "== 1 schema (prod shape) + committed upgrade file + v2 design"
psql < "$D/destructive-paths-review-2026-09-13-schema.sql"
psql < "$ROOT/supabase/upgrades/2026-09-13_merged_hours.sql"
psql < "$D/destructive-paths-review-2026-09-13-compact-v2.sql"
echo "== 2 single-session reproductions (committed replace fn, LIVE summariser, v2 design)"
psql < "$D/destructive-paths-review-2026-09-13-repro.sql"

echo "== 3 race A (D361): per-device row committed between the function's DELETE and its INSERT"
psql -c "INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at,ended_at) VALUES ('$UB','$S',100,'count','iPhone','2021-12-28T10:05:00Z','2021-12-28T10:10:00Z')"
psql <<SQL &
BEGIN;
DELETE FROM healthkit_metrics m USING jsonb_to_recordset('[{"metric_type":"$S","started_at":"2021-12-28T10:00:00Z"}]') AS r(metric_type text, started_at timestamptz)
 WHERE m.user_id='$UB' AND m.metric_type=r.metric_type AND m.started_at >= r.started_at AND m.started_at < r.started_at + interval '1 hour' AND m.source_device <> '$M';
SELECT pg_sleep(2);
INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at,ended_at) VALUES ('$UB','$S',130,'count','$M','2021-12-28T10:00:00Z','2021-12-28T11:00:00Z');
COMMIT;
SQL
sleep 0.7
psql -c "INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at,ended_at) VALUES ('$UB','$S',30,'count','iPhone','2021-12-28T10:20:00Z','2021-12-28T10:25:00Z')"
wait
psql -Atc "SELECT 'race A rows: '||review_rows('$UB','$S')||'  double-count detector='||review_double_counted('$UB')"

race_b() { # $1 user, $2 function call text, $3 label
  local U=$1
  psql -c "INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at) SELECT '$U','$HR',60,'count/min','Apple Watch','2025-01-01T00:00:00Z'::timestamptz + i*interval '30 seconds' FROM generate_series(1,400000) i"
  psql -c "ANALYZE healthkit_metrics"
  for i in $(seq 1 4000); do echo "INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at) VALUES ('$U','$HR',70,'count/min','late','2025-06-01T00:00:00Z'::timestamptz + $i*interval '1 second');"; done > "$RB"
  psql < "$RB" &
  sleep 0.3
  psql -Atc "SELECT '$3 run: '||($2)::text"
  wait
  psql -Atc "SELECT '$3 conservation: expected 404000 rows, have '||(t.raw_rows + t.summary_samples)||' (raw '||t.raw_rows||' + summarised '||t.summary_samples||')  LOST='||(404000 - t.raw_rows - t.summary_samples) FROM health4ai_compaction_totals('$U','$HR') t"
}
echo "== 4 race B (D362): 4,000 rows ingested while the LIVE summariser runs over 400,000"
race_b $U3 "summarize_healthkit_metric('$U3','$HR','2025-08-01')" "LIVE summariser"
echo "== 5 race B again with compact_v2 (single statement)"
race_b $U4 "health4ai_compact_metric_v2('$U4','$HR','2025-08-01','0 seconds')" "compact_v2"

echo "== 6 plan + timing: committed replace fn vs proposed fix, 1.5M-row seed for one user"
psql -c "INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at) SELECT '$U5', t.mt, 10, 'count', CASE i%3 WHEN 0 THEN 'iPhone' WHEN 1 THEN 'Apple Watch' ELSE 'Oura' END, '2014-01-01T00:00:00Z'::timestamptz + i*interval '4 minutes' FROM generate_series(1,500000) i, (VALUES ('$S'),('$HR'),('HKQuantityTypeIdentifierActiveEnergyBurned')) t(mt)"
psql -c "ANALYZE healthkit_metrics"
HOURS=$(psql -Atc "SELECT jsonb_agg(jsonb_build_object('metric_type','$S','started_at',to_char(ts,'YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'ended_at',to_char(ts+interval '1 hour','YYYY-MM-DD\"T\"HH24:MI:SS.MS\"Z\"'),'value',5,'unit','count'))::text FROM generate_series('2015-03-01T00:00:00Z'::timestamptz,'2015-03-01T00:00:00Z'::timestamptz+interval '99 hours',interval '1 hour') ts")
run_plan() {
  psql -Atc "BEGIN; EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) DELETE FROM healthkit_metrics m USING jsonb_to_recordset('$HOURS'::jsonb) AS r(metric_type text, started_at timestamptz) WHERE m.user_id='$U5' AND m.metric_type=r.metric_type AND m.started_at >= r.started_at AND m.started_at < r.started_at + interval '1 hour' AND m.source_device <> '$M'; ROLLBACK;" | grep -E 'Seq Scan|Index|Hash Join|Nested|Execution Time|Rows Removed' | sed 's/^/   committed-shape plan: /'
  psql -Atc "BEGIN; EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF) DELETE FROM healthkit_metrics m WHERE m.user_id='$U5' AND m.metric_type='$S' AND m.started_at >= '2015-03-01T00:00:00Z' AND m.started_at < '2015-03-01T00:00:00Z'::timestamptz + interval '1 hour' AND m.source_device <> '$M'; ROLLBACK;" | grep -E 'Seq Scan|Index|Execution Time' | sed 's/^/   fix-shape plan (one hour): /'
}
run_plan
time_fn() { psql -Atc "\\timing on" -c "SELECT '$1 100-hour call: '||health4ai_replace_merged_hours('$U5','$HOURS'::jsonb)::text" 2>&1 | grep -E 'call|Time'; }
time_fn "committed fn"
echo "== 7 apply proposed fix, re-time, re-run reproductions"
psql < "$D/destructive-paths-review-2026-09-13-fix-replace.sql"
time_fn "fixed fn (hours now merged, delete finds 0)"
psql -c "DELETE FROM healthkit_metrics WHERE user_id='$U5' AND source_device='$M'"
psql -c "INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at) SELECT '$U5','$S',10,'count','iPhone',ts FROM generate_series('2015-03-01T00:02:00Z'::timestamptz,'2015-03-01T00:02:00Z'::timestamptz+interval '99 hours',interval '4 minutes') ts ON CONFLICT DO NOTHING"
time_fn "fixed fn (reseeded per-device rows)"
psql < "$D/destructive-paths-review-2026-09-13-repro.sql" | tail -4
echo "== done"
