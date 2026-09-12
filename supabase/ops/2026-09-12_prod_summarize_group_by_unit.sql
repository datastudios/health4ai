-- 013_summarize_group_by_unit.sql
--
-- The daily summariser aggregated a metric ACROSS UNITS and labelled the result with
-- whichever unit string happened to sort highest:
--
--     SELECT ... SUM(value), ..., MAX(unit)
--     GROUP BY user_id, metric_type, (started_at AT TIME ZONE 'America/New_York')::date
--
-- `unit` is absent from the GROUP BY, so protein recorded as 0.032 kg and 32 g on the
-- same day summed to 32.032 and was stamped `kg`. Nothing is corrupted today — verified
-- on 2026-09-11, `count(DISTINCT unit) > 1` returns zero rows for every metric_type —
-- but the iOS unit fix in commit 926f357 (all 39 dietary types mapped explicitly, mass
-- fallback moved from kilograms to grams) creates exactly that condition on the one date
-- that carries rows written by both the old and the new build. Register D338.
--
-- A daily summary is genuinely per (user, metric_type, date, unit). This makes the key
-- say so. For the single-unit case — which is every row that exists today — behaviour is
-- identical, so the existing 48,200 rows satisfy the new index without a rewrite.
--
-- Based on the LIVE function definition read back from pg_get_functiondef, NOT on
-- 003_summarize_function.sql: the deployed version carries an EST-aligned cutoff
-- (v_cutoff_ts) that the checked-in file does not, and rebuilding from the file would
-- have silently reverted it.

-- APPLIED 2026-09-12 statement by statement through the jgle-business SQL channel, which
-- accepts exactly one statement per call, so the BEGIN/COMMIT below did not wrap the real
-- apply. Safe here, and checked first rather than assumed: pg_cron is NOT installed and
-- nothing on the estate invokes summarize_healthkit_metric on a schedule — the only callers
-- are scripts/summarize_historical.py and scripts/verify_tenant_isolation.py, both hand-run.
-- So the two windows that would otherwise matter (index dropped; new 4-column index live
-- against the old 3-column ON CONFLICT) could not be hit by a background caller.
-- Re-running this file as a whole against a fresh database is still correct and atomic.

BEGIN;

-- 1. `unit` has to be NOT NULL to sit in a unique key: NULL <> NULL in SQL, so two
--    NULL-unit rows for the same day would both insert and the upsert would never
--    collapse them. There are zero NULLs today; this keeps it that way.
UPDATE public.healthkit_daily_summaries SET unit = '' WHERE unit IS NULL;

ALTER TABLE public.healthkit_daily_summaries
    ALTER COLUMN unit SET DEFAULT '',
    ALTER COLUMN unit SET NOT NULL;

-- 2. The upsert key gains `unit`. This is a plain index, not a constraint, so DROP INDEX
--    is the right verb here.
DROP INDEX IF EXISTS public.summaries_upsert_key;

CREATE UNIQUE INDEX summaries_upsert_key
    ON public.healthkit_daily_summaries (user_id, metric_type, date, unit);

-- 3. Group by unit, and stop inventing one with MAX().
CREATE OR REPLACE FUNCTION public.summarize_healthkit_metric(
    p_user_id uuid, p_metric_type text, p_cutoff date)
RETURNS TABLE(raw_count bigint, summary_days bigint)
LANGUAGE plpgsql
SECURITY DEFINER
-- ADDED here, not preserved. Checked rather than assumed either way: the live function is
-- SECURITY DEFINER with proconfig NULL, i.e. no search_path pinned at all, and CREATE OR
-- REPLACE FUNCTION resets proconfig. Every table reference in the body is already
-- schema-qualified so there is no live hijack vector, but a SECURITY DEFINER function
-- should pin its search_path regardless, and bootstrap/002's copy already does — this
-- brings the deployed one into line with it.
SET search_path = pg_catalog, public
AS $function$
DECLARE
    v_raw_count bigint;
    v_summary_days bigint;
    v_cutoff_ts timestamptz;
BEGIN
    -- Interpret the cutoff as midnight in America/New_York, NOT midnight UTC.
    -- This makes the prune boundary align exactly with the EST day buckets used
    -- in the GROUP BY below, so a single ET day is never split across two runs
    -- (which would let ON CONFLICT overwrite a day's summary with a partial day).
    v_cutoff_ts := (p_cutoff::timestamp AT TIME ZONE 'America/New_York');

    SELECT COUNT(*) INTO v_raw_count
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < v_cutoff_ts;

    IF v_raw_count = 0 THEN
        RETURN QUERY SELECT 0::bigint, 0::bigint;
        RETURN;
    END IF;

    INSERT INTO public.healthkit_daily_summaries
        (user_id, metric_type, date, avg_value, min_value, max_value, sum_value, sample_count, unit)
    SELECT user_id, metric_type, (started_at AT TIME ZONE 'America/New_York')::date,
        AVG(value), MIN(value), MAX(value), SUM(value), COUNT(*), COALESCE(unit, '')
    FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < v_cutoff_ts
    GROUP BY user_id, metric_type, (started_at AT TIME ZONE 'America/New_York')::date,
             COALESCE(unit, '')
    ON CONFLICT (user_id, metric_type, date, unit) DO UPDATE SET
        avg_value = EXCLUDED.avg_value, min_value = EXCLUDED.min_value,
        max_value = EXCLUDED.max_value, sum_value = EXCLUDED.sum_value,
        sample_count = EXCLUDED.sample_count, summarized_at = now();
        -- `unit` is no longer assigned here: it is part of the conflict key, so
        -- EXCLUDED.unit always equals the existing value. Assigning it would be a no-op
        -- that reads as though the unit can change under an existing row.

    -- Rows written, which equals days only while a day carries a single unit. A
    -- mixed-unit day now yields one row per unit instead of one wrong row.
    GET DIAGNOSTICS v_summary_days = ROW_COUNT;

    DELETE FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < v_cutoff_ts;

    RETURN QUERY SELECT v_raw_count, v_summary_days;
END;
$function$;

-- 4. Same bug, second copy: the raw branch of the combined view aggregates without unit,
--    and the summary branch does not even select it, so no consumer of the view can tell
--    which unit a number is in. Both branches now carry it.
--
--    `unit` is appended at the END of the select list, not slotted in beside metric_type
--    where it reads better. CREATE OR REPLACE VIEW may only ADD columns to the end: the
--    existing columns must keep the same names, types and ORDER, so inserting a column in
--    the middle fails outright. The alternative is DROP VIEW + CREATE VIEW, which would
--    break anything holding a dependency on it — not worth it for cosmetics.
CREATE OR REPLACE VIEW public.v_healthkit_daily_quantity AS
SELECT user_id, date AS day, metric_type,
       avg_value, min_value, max_value, sum_value, sample_count, unit
FROM public.healthkit_daily_summaries
UNION ALL
SELECT
    user_id,
    (started_at AT TIME ZONE 'America/New_York')::date AS day,
    metric_type,
    AVG(value)::double precision   AS avg_value,
    MIN(value)::double precision   AS min_value,
    MAX(value)::double precision   AS max_value,
    SUM(value)::double precision   AS sum_value,
    COUNT(*)::integer              AS sample_count,
    COALESCE(unit, '')             AS unit
FROM public.healthkit_metrics
WHERE metric_type NOT LIKE 'HKCategoryTypeIdentifier%'
  AND metric_type NOT LIKE 'HKWorkoutTypeIdentifier%'
GROUP BY user_id, (started_at AT TIME ZONE 'America/New_York')::date, metric_type,
         COALESCE(unit, '');

COMMIT;
