-- Single-session reproductions for docs/health4ai-destructive-paths-review-2026-09-13.md.
-- Run by -run.sh on a THROWAWAY Postgres after -schema.sql, the committed upgrade file and -compact-v2.sql.
-- Users: a..01 = committed replace fn + LIVE summariser; a..02 = proposed compact_v2.
-- "pass" means the CLAIM in the id holds, so for R3/R3b pass = the bug reproduced.
\set ON_ERROR_STOP on
\pset format unaligned
\pset tuples_only on
CREATE TABLE IF NOT EXISTS review_results(seq serial, id text, pass bool, detail text);
TRUNCATE review_results;
DELETE FROM healthkit_daily_summaries WHERE user_id IN ('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002');
DELETE FROM healthkit_metrics         WHERE user_id IN ('a0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000002');
CREATE OR REPLACE FUNCTION review_rows(u uuid, mt text) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce(string_agg(source_device||'@'||to_char(started_at AT TIME ZONE 'UTC','MM-DD HH24:MI')||'='||value::int, ',' ORDER BY started_at, source_device), '')
  FROM healthkit_metrics WHERE user_id = u AND metric_type = mt $$;
CREATE OR REPLACE FUNCTION review_seed(u uuid, mt text, dev text, ts timestamptz, v float8) RETURNS void LANGUAGE sql AS $$
  INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at,ended_at)
  VALUES (u, mt, v, 'count', dev, ts, ts + interval '5 minutes')
  ON CONFLICT (user_id,metric_type,source_device,started_at) DO UPDATE SET value = EXCLUDED.value $$;
CREATE OR REPLACE FUNCTION review_merged(mt text, ts timestamptz, v float8) RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_array(jsonb_build_object('metric_type', mt,
    'started_at', to_char(ts AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'ended_at',   to_char((ts + interval '1 hour') AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'value', v, 'unit', 'count', 'metadata', jsonb_build_object('h4ai_aggregation','hkstatistics_cumulative_sum_hourly'))) $$;
-- merged-hour day seeding: 24 (or a range of) UTC hours of the America/New_York day d, value v each
CREATE OR REPLACE FUNCTION review_seed_day(u uuid, mt text, d date, h_from int, h_to int, v float8) RETURNS void LANGUAGE sql AS $$
  INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at,ended_at)
  SELECT u, mt, v, 'count', 'HealthKit (all sources)', ts, ts + interval '1 hour'
  FROM generate_series((d::timestamp AT TIME ZONE 'America/New_York') + h_from * interval '1 hour',
                       (d::timestamp AT TIME ZONE 'America/New_York') + h_to   * interval '1 hour', interval '1 hour') ts
  ON CONFLICT (user_id,metric_type,source_device,started_at) DO UPDATE SET value = EXCLUDED.value $$;
CREATE OR REPLACE FUNCTION review_summary(u uuid, mt text, d date) RETURNS text LANGUAGE sql AS $$
  SELECT coalesce((SELECT 'sum='||sum_value::int||' n='||sample_count FROM healthkit_daily_summaries WHERE user_id=u AND metric_type=mt AND date=d), 'none') $$;
-- Detector for the D361 residual: per-device rows sitting in an hour that also holds a merged row.
CREATE OR REPLACE FUNCTION review_double_counted(u uuid) RETURNS bigint LANGUAGE sql AS $$
  SELECT count(*) FROM healthkit_metrics d JOIN healthkit_metrics m
    ON m.user_id = d.user_id AND m.metric_type = d.metric_type AND m.source_device = 'HealthKit (all sources)'
   AND d.started_at >= m.started_at AND d.started_at < m.started_at + interval '1 hour'
  WHERE d.user_id = u AND d.source_device <> 'HealthKit (all sources)' $$;

-- ---- R1  D361: the replace is one transaction; a failing insert rolls the delete back
SELECT review_seed('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','iPhone','2021-12-28T13:05:00Z',40);
DO $$ BEGIN
  PERFORM * FROM health4ai_replace_merged_hours('a0000000-0000-0000-0000-000000000001',
    '[{"metric_type":"HKQuantityTypeIdentifierStepCount","started_at":"2021-12-28T13:00:00Z","ended_at":"2021-12-28T14:00:00Z","value":"not-a-number","unit":"count"}]');
  INSERT INTO review_results(id,pass,detail) VALUES ('R1 D361 atomic: insert failure rolls the delete back', false, 'no error raised');
EXCEPTION WHEN OTHERS THEN
  INSERT INTO review_results(id,pass,detail)
  SELECT 'R1 D361 atomic: insert failure rolls the delete back',
         review_rows('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount') = 'iPhone@12-28 13:05=40',
         SQLSTATE||' '||left(SQLERRM,60)||' rows='||review_rows('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount');
END $$;

-- ---- R5  D361: out-of-order hours and a retry are idempotent (per hour, last write wins, one row per hour)
SELECT review_seed('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','iPhone','2021-12-28T10:05:00Z',100);
SELECT review_seed('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','Apple Watch','2021-12-28T10:10:00Z',120);
SELECT review_seed('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','iPhone','2021-12-28T11:05:00Z',50);
SELECT health4ai_replace_merged_hours('a0000000-0000-0000-0000-000000000001', review_merged('HKQuantityTypeIdentifierStepCount','2021-12-28T11:00:00Z',55));
SELECT health4ai_replace_merged_hours('a0000000-0000-0000-0000-000000000001', review_merged('HKQuantityTypeIdentifierStepCount','2021-12-28T10:00:00Z',130));
INSERT INTO review_results(id,pass,detail)
SELECT 'R5 D361 out-of-order + retry: retry of hour 11 deletes 0, writes 1, rows stay one-per-hour',
       r = '(0,1)' AND review_rows('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount') = 'HealthKit (all sources)@12-28 10:00=130,HealthKit (all sources)@12-28 11:00=60,iPhone@12-28 13:05=40',
       r||' '||review_rows('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount')
FROM (SELECT health4ai_replace_merged_hours('a0000000-0000-0000-0000-000000000001', review_merged('HKQuantityTypeIdentifierStepCount','2021-12-28T11:00:00Z',60))::text AS r) x;

-- ---- R6  D361 residual: a per-device row that lands AFTER the merged post survives beside it until that hour is re-posted
SELECT review_seed('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','iPhone','2021-12-28T10:20:00Z',30);
INSERT INTO review_results(id,pass,detail)
SELECT 'R6 D361 residual: late per-device row survives beside the merged hour (detector = 1)',
       review_double_counted('a0000000-0000-0000-0000-000000000001') = 1, 'detector='||review_double_counted('a0000000-0000-0000-0000-000000000001');
SELECT health4ai_replace_merged_hours('a0000000-0000-0000-0000-000000000001', review_merged('HKQuantityTypeIdentifierStepCount','2021-12-28T10:00:00Z',150));
INSERT INTO review_results(id,pass,detail)
SELECT 'R6b D361: only a RE-POST of that hour removes it (detector back to 0)',
       review_double_counted('a0000000-0000-0000-0000-000000000001') = 0, 'detector='||review_double_counted('a0000000-0000-0000-0000-000000000001');

-- ---- R3  D362 LIVE summariser: a compacted day that receives 8 late/re-posted hours collapses to those 8
SELECT review_seed_day('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-10',0,23,100);
SELECT summarize_healthkit_metric('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-08-01');
INSERT INTO review_results(id,pass,detail)
SELECT 'R3a D362 baseline: full day compacts to sum=2400 n=24, raw deleted',
       review_summary('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-10') = 'sum=2400 n=24',
       review_summary('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-10');
SELECT review_seed_day('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-10',0,7,100);
SELECT summarize_healthkit_metric('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-08-01');
INSERT INTO review_results(id,pass,detail)
SELECT 'R3 D362 BUG: 8 late hours -> summary sum=800 n=8; the other 1600 steps are gone from both tiers',
       review_summary('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-10') = 'sum=800 n=8',
       review_summary('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-10');
-- R3b: the re-import case, a day split across a 03:00 run
SELECT review_seed_day('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-11',0,9,100);
SELECT summarize_healthkit_metric('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-08-01');
SELECT review_seed_day('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-11',10,23,100);
SELECT summarize_healthkit_metric('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-08-01');
INSERT INTO review_results(id,pass,detail)
SELECT 'R3b D362 BUG: re-import day split 10h/14h across two runs -> summary sum=1400 n=14, not 2400',
       review_summary('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-11') = 'sum=1400 n=14',
       review_summary('a0000000-0000-0000-0000-000000000001','HKQuantityTypeIdentifierStepCount','2025-06-11');

-- ---- R4  compact_v2 RECOMPUTE mode (merged type): split day, re-run, re-post, mixed day
SELECT review_seed_day('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-10',0,9,100);
SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-08-01','0 seconds');
SELECT review_seed_day('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-10',10,23,100);
SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-08-01','0 seconds');
INSERT INTO review_results(id,pass,detail)
SELECT 'R4a v2 recompute: split day 10h then 14h -> sum=2400 n=24, raw retained (24 rows)',
       review_summary('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-10') = 'sum=2400 n=24'
       AND (SELECT count(*) FROM healthkit_metrics WHERE user_id='a0000000-0000-0000-0000-000000000002') = 24,
       review_summary('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-10');
INSERT INTO review_results(id,pass,detail)
SELECT 'R4b v2 recompute: re-run with no new raw writes 0 summary rows (idempotent)', r = '(recompute,0,0,0)', r
FROM (SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-08-01','0 seconds')::text AS r) x;
SELECT review_seed_day('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-10',3,3,110);
SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-08-01','0 seconds');
INSERT INTO review_results(id,pass,detail)
SELECT 'R4c v2 recompute: hour 3 re-posted as 110 -> sum=2410, invariant 2 reports 0 mismatched days',
       review_summary('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-10') = 'sum=2410 n=24'
       AND (SELECT count(*) FROM health4ai_recompute_mismatches('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-08-01')) = 0,
       review_summary('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-10');
SELECT review_seed_day('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-12',0,23,100);
SELECT review_seed('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','iPhone','2025-06-12T14:05:00Z',30);
INSERT INTO review_results(id,pass,detail)
SELECT 'R4d v2 recompute: a day still holding a per-device row is skipped (skipped_days=1, no summary written)',
       r = '(recompute,0,0,1)' AND review_summary('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-06-12') = 'none', r
FROM (SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierStepCount','2025-08-01','0 seconds')::text AS r) x;

-- ---- R7  compact_v2 COMPACT mode (HeartRate): merge on late arrival, conservation, idempotence
INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at,ended_at)
SELECT 'a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate', 60 + i, 'count/min', 'Apple Watch',
       ('2025-06-10'::timestamp AT TIME ZONE 'America/New_York') + i * interval '1 minute', NULL FROM generate_series(0,59) i;
CREATE TEMP TABLE t0 AS SELECT * FROM health4ai_compaction_totals('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate');
SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate','2025-08-01','0 seconds');
INSERT INTO review_results(id,pass,detail)
SELECT 'R7a v2 compact: 60 samples -> sum=5370 n=60, raw 0, conservation holds',
       review_summary('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate','2025-06-10') = 'sum=5370 n=60'
       AND t.raw_rows = 0 AND t.total_rows = t0.total_rows AND abs(t.total_sum - t0.total_sum) < 1e-6,
       review_summary('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate','2025-06-10')||' totals '||t.total_rows||'/'||t.total_sum::int
FROM health4ai_compaction_totals('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate') t, t0;
INSERT INTO healthkit_metrics(user_id,metric_type,value,unit,source_device,started_at,ended_at)
SELECT 'a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate', 70, 'count/min', 'Oura',
       ('2025-06-10'::timestamp AT TIME ZONE 'America/New_York') + i * interval '1 minute', NULL FROM generate_series(100,139) i;
SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate','2025-08-01','0 seconds');
INSERT INTO review_results(id,pass,detail)
SELECT 'R7b v2 compact: 40 late samples MERGE -> sum=8170 n=100 min=60 max=119 avg=81.7',
       s.sum_value = 8170 AND s.sample_count = 100 AND s.min_value = 60 AND s.max_value = 119 AND abs(s.avg_value - 81.7) < 1e-9,
       'sum='||s.sum_value||' n='||s.sample_count||' min='||s.min_value||' max='||s.max_value||' avg='||s.avg_value
FROM healthkit_daily_summaries s WHERE user_id='a0000000-0000-0000-0000-000000000002' AND metric_type='HKQuantityTypeIdentifierHeartRate' AND date='2025-06-10';
INSERT INTO review_results(id,pass,detail)
SELECT 'R7c v2 compact: re-run touches nothing (compact,0,0,0)', r = '(compact,0,0,0)', r
FROM (SELECT health4ai_compact_metric_v2('a0000000-0000-0000-0000-000000000002','HKQuantityTypeIdentifierHeartRate','2025-08-01','0 seconds')::text AS r) x;

\pset tuples_only off
\pset format aligned
SELECT id, pass, detail FROM review_results ORDER BY seq;
SELECT count(*) FILTER (WHERE pass) AS passed, count(*) AS total FROM review_results;
