-- PROPOSED merge-safe compaction (register D362). DESIGN SKETCH, deployed nowhere. Would replace the
-- call in scripts/summarize_historical.py with: SELECT * FROM health4ai_compact_metric_v2(u, type, cutoff).
-- Written for the PRODUCTION table shape (summaries.date); bootstrap projects use summary_date and
-- the user's own time zone (bootstrap 002 section 4) and need the same two substitutions there.
--
-- What is wrong today (proven in -repro.sql R3/R3b and -run.sh race B): summarize_healthkit_metric
-- REPLACES a day's summary with whatever raw exists at run time, then deletes that raw; a day that
-- was already compacted and receives late or re-posted rows collapses to the late remainder, and
-- rows committed between its INSERT..SELECT and its DELETE (separate snapshots in READ COMMITTED)
-- are deleted without ever being summarised.
--
-- Two modes, chosen by metric type:
--  RECOMPUTE, the 14 merged-hour types: raw is NEVER deleted. A merged hourly row is already the
--    compact form (<= 24 rows/day/type; per-device StepCount averages ~115/day in production). The
--    daily summary is a derived cache rebuilt whole-day from raw, so replace-on-conflict is correct,
--    and any late or re-posted hour is folded in on the next run. A day still holding a per-device
--    row is skipped and counted: summing it double-counts, and its existing (per-device) summary is
--    left as it is until the app's history re-send has replaced that day.
--  COMPACT, every other quantity type: ONE statement aggregates and deletes exactly the same rows
--    (DELETE .. RETURNING feeds the INSERT), so there is no snapshot gap, and the summary is MERGED
--    on conflict (sum+=, count+=, min=least, max=greatest, avg=sum/count) so a late remainder is
--    added to the day, never substituted for it. Only rows older than the cutoff AND quiet for
--    p_quiet are touched. avg_value = sum/count is exact while value is never NULL (production: 0
--    NULL values in 2,454,668 rows, 2026-09-13).
--  Both modes are idempotent: a second run with no new raw writes 0 summary rows.
--  RESIDUAL, out of scope here: for a COMPACT-mode type, history that the app re-sends AFTER the
--  server deleted it is indistinguishable from new data and would be added twice. The app's
--  per-type reset for non-merged types must not be pointed at a compacted server without a
--  server-side rebuild of that type; register that as its own row.
CREATE OR REPLACE FUNCTION public.health4ai_compact_metric_v2(
  p_user_id     uuid,
  p_metric_type text,
  p_cutoff      date,
  p_quiet       interval DEFAULT interval '24 hours',
  p_tz          text     DEFAULT 'America/New_York'
)
RETURNS TABLE(mode text, raw_rows bigint, summary_rows bigint, skipped_days bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $func$
DECLARE
  v_cutoff_ts timestamptz := (p_cutoff::timestamp AT TIME ZONE p_tz);
  v_raw       bigint := 0;
  v_sum       bigint := 0;
  v_skipped   bigint := 0;
  c_merged    constant text := 'HealthKit (all sources)';
  c_merged_types constant text[] := ARRAY[
    'HKQuantityTypeIdentifierStepCount','HKQuantityTypeIdentifierDistanceWalkingRunning',
    'HKQuantityTypeIdentifierDistanceCycling','HKQuantityTypeIdentifierDistanceSwimming',
    'HKQuantityTypeIdentifierDistanceWheelchair','HKQuantityTypeIdentifierDistanceDownhillSnowSports',
    'HKQuantityTypeIdentifierPushCount','HKQuantityTypeIdentifierSwimmingStrokeCount',
    'HKQuantityTypeIdentifierFlightsClimbed','HKQuantityTypeIdentifierActiveEnergyBurned',
    'HKQuantityTypeIdentifierBasalEnergyBurned','HKQuantityTypeIdentifierAppleExerciseTime',
    'HKQuantityTypeIdentifierAppleMoveTime','HKQuantityTypeIdentifierAppleStandTime'];
BEGIN
  IF p_metric_type = ANY (c_merged_types) THEN
    SELECT count(*) INTO v_skipped FROM (
      SELECT 1 FROM public.healthkit_metrics
      WHERE user_id = p_user_id AND metric_type = p_metric_type AND started_at < v_cutoff_ts
      GROUP BY (started_at AT TIME ZONE p_tz)::date
      HAVING bool_or(source_device <> c_merged)) s;

    INSERT INTO public.healthkit_daily_summaries
      (user_id, metric_type, date, avg_value, min_value, max_value, sum_value, sample_count, unit)
    SELECT user_id, metric_type, (started_at AT TIME ZONE p_tz)::date,
           avg(value), min(value), max(value), sum(value), count(*), coalesce(unit, '')
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type AND started_at < v_cutoff_ts
    GROUP BY user_id, metric_type, (started_at AT TIME ZONE p_tz)::date, coalesce(unit, '')
    HAVING bool_and(source_device = c_merged)
    ON CONFLICT (user_id, metric_type, date, unit) DO UPDATE SET
      avg_value = EXCLUDED.avg_value, min_value = EXCLUDED.min_value, max_value = EXCLUDED.max_value,
      sum_value = EXCLUDED.sum_value, sample_count = EXCLUDED.sample_count, summarized_at = now()
    WHERE healthkit_daily_summaries.sum_value    IS DISTINCT FROM EXCLUDED.sum_value
       OR healthkit_daily_summaries.sample_count IS DISTINCT FROM EXCLUDED.sample_count
       OR healthkit_daily_summaries.min_value    IS DISTINCT FROM EXCLUDED.min_value
       OR healthkit_daily_summaries.max_value    IS DISTINCT FROM EXCLUDED.max_value;
    GET DIAGNOSTICS v_sum = ROW_COUNT;
    RETURN QUERY SELECT 'recompute'::text, 0::bigint, v_sum, v_skipped;
    RETURN;
  END IF;

  WITH del AS (
    DELETE FROM public.healthkit_metrics m
    WHERE m.user_id = p_user_id AND m.metric_type = p_metric_type
      AND m.started_at < v_cutoff_ts
      AND m.synced_at < now() - p_quiet
    RETURNING m.user_id, m.metric_type, m.value, m.unit, m.started_at
  ), agg AS (
    SELECT user_id, metric_type, (started_at AT TIME ZONE p_tz)::date AS d, coalesce(unit, '') AS unit,
           sum(value) AS s, min(value) AS mn, max(value) AS mx, count(*) AS c
    FROM del GROUP BY 1, 2, 3, 4
  ), ins AS (
    INSERT INTO public.healthkit_daily_summaries
      (user_id, metric_type, date, avg_value, min_value, max_value, sum_value, sample_count, unit)
    SELECT user_id, metric_type, d, s / nullif(c, 0), mn, mx, s, c, unit FROM agg
    ON CONFLICT (user_id, metric_type, date, unit) DO UPDATE SET
      sum_value    = coalesce(healthkit_daily_summaries.sum_value, 0) + coalesce(EXCLUDED.sum_value, 0),
      sample_count = healthkit_daily_summaries.sample_count + EXCLUDED.sample_count,
      min_value    = least(healthkit_daily_summaries.min_value, EXCLUDED.min_value),
      max_value    = greatest(healthkit_daily_summaries.max_value, EXCLUDED.max_value),
      avg_value    = (coalesce(healthkit_daily_summaries.sum_value, 0) + coalesce(EXCLUDED.sum_value, 0))
                     / nullif(healthkit_daily_summaries.sample_count + EXCLUDED.sample_count, 0),
      summarized_at = now()
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM del), (SELECT count(*) FROM ins) INTO v_raw, v_sum;
  RETURN QUERY SELECT 'compact'::text, v_raw, v_sum, 0::bigint;
END;
$func$;
REVOKE ALL ON FUNCTION public.health4ai_compact_metric_v2(uuid, text, date, interval, text) FROM PUBLIC, anon, authenticated;

-- INVARIANT 1 (COMPACT mode): conservation. Run before and after; total_rows and total_sum must not
-- change (sum to float tolerance). Data can move from raw to summary, never disappear.
CREATE OR REPLACE FUNCTION public.health4ai_compaction_totals(p_user_id uuid, p_metric_type text)
RETURNS TABLE(raw_rows bigint, raw_sum double precision, summary_samples bigint,
              summary_sum double precision, total_rows bigint, total_sum double precision)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $func$
  SELECT r.c, r.s, s.c, s.s, r.c + s.c, coalesce(r.s, 0) + coalesce(s.s, 0)
  FROM (SELECT count(*) AS c, sum(value) AS s FROM public.healthkit_metrics
        WHERE user_id = p_user_id AND metric_type = p_metric_type) r,
       (SELECT coalesce(sum(sample_count), 0)::bigint AS c, sum(sum_value) AS s
        FROM public.healthkit_daily_summaries
        WHERE user_id = p_user_id AND metric_type = p_metric_type) s
$func$;

-- INVARIANT 2 (RECOMPUTE mode): every fully-merged day older than the cutoff has a summary equal
-- to its raw aggregate. Must return 0 rows after a run.
CREATE OR REPLACE FUNCTION public.health4ai_recompute_mismatches(
  p_user_id uuid, p_metric_type text, p_cutoff date, p_tz text DEFAULT 'America/New_York')
RETURNS TABLE(day date, unit text, raw_sum double precision, summary_sum double precision,
              raw_rows bigint, summary_samples integer)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = pg_catalog, public AS $func$
  WITH raw AS (
    SELECT (started_at AT TIME ZONE p_tz)::date AS d, coalesce(unit, '') AS u,
           sum(value) AS s, count(*) AS c
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < (p_cutoff::timestamp AT TIME ZONE p_tz)
    GROUP BY 1, 2 HAVING bool_and(source_device = 'HealthKit (all sources)'))
  SELECT raw.d, raw.u, raw.s, s.sum_value, raw.c, s.sample_count
  FROM raw LEFT JOIN public.healthkit_daily_summaries s
    ON s.user_id = p_user_id AND s.metric_type = p_metric_type AND s.date = raw.d AND s.unit = raw.u
  WHERE s.id IS NULL OR abs(coalesce(s.sum_value, 0) - coalesce(raw.s, 0)) > 1e-6 OR s.sample_count <> raw.c
$func$;
