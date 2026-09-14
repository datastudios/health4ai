-- Upgrade an EXISTING health4ai project: the merged-hour replace function, one DELETE per hour.
-- For any project that ran supabase/upgrades/2026-09-13_merged_hours.sql, or was created from
-- bootstrap / web/public/schema.sql between 2026-09-13 and 2026-09-14. New projects get this
-- body from bootstrap 002 section 5, which this file copies exactly. Register D361.
--
-- Why: the 2026-09-13 body deleted with a single DELETE .. USING jsonb_to_recordset(p_rows).
-- The planner cannot push an hour range whose bounds come from the recordset into an index,
-- so it full-scanned healthkit_metrics on every call (production EXPLAIN 2026-09-13: Seq Scan,
-- 15 s for a two-hour payload). PostgREST runs the RPC under an 8 s statement timeout, so on a
-- project with real history the first merged batch of each activity type failed with 57014,
-- the ingest function answered 500 and the app retried the same page for ever. No data was
-- lost; no merged hour was ever stored. One DELETE per hour with constant bounds plans as an
-- index range scan on metrics_user_type_time_idx (production: 4 buffers, ~2 ms per hour).
-- Same signature, privileges, atomicity (one transaction) and idempotency as before.
--
-- HOW: paste into the Supabase SQL editor and run. No function redeploy is needed: the
-- healthkit-ingest function deployed on or after 2026-09-13 already calls this RPC.
-- Safe to re-run: CREATE OR REPLACE, and REVOKE/GRANT are idempotent.
--
-- VERIFY after running (expected: has_loop=true, prosecdef=false,
-- proconfig={search_path=pg_catalog, public}, auth_exec=false, anon_exec=false, service_exec=true):
--   SELECT (p.prosrc ~ 'LOOP') AS has_loop, p.prosecdef, p.proconfig,
--          has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_exec,
--          has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
--          has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_exec
--   FROM pg_proc p WHERE p.proname = 'health4ai_replace_merged_hours';
BEGIN;

CREATE OR REPLACE FUNCTION public.health4ai_replace_merged_hours(
  p_user_id uuid,
  p_rows    jsonb
)
RETURNS TABLE(deleted_count bigint, written_count bigint)
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog, public
AS $func$
DECLARE
  v_deleted bigint := 0;
  v_written bigint;
  v_n       bigint;
  r         record;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  FOR r IN
    SELECT DISTINCT x.metric_type, x.started_at
    FROM jsonb_to_recordset(p_rows) AS x(metric_type text, started_at timestamptz)
  LOOP
    DELETE FROM public.healthkit_metrics m
    WHERE m.user_id = p_user_id
      AND m.metric_type = r.metric_type
      AND m.started_at >= r.started_at
      AND m.started_at <  r.started_at + interval '1 hour'
      AND m.source_device <> 'HealthKit (all sources)';
    GET DIAGNOSTICS v_n = ROW_COUNT;
    v_deleted := v_deleted + v_n;
  END LOOP;

  INSERT INTO public.healthkit_metrics
    (user_id, metric_type, value, unit, source_device, started_at, ended_at, metadata)
  SELECT p_user_id, x.metric_type, x.value, x.unit, 'HealthKit (all sources)',
         x.started_at, x.ended_at, x.metadata
  FROM jsonb_to_recordset(p_rows) AS x(metric_type text, value double precision, unit text,
                                       started_at timestamptz, ended_at timestamptz, metadata jsonb)
  ON CONFLICT (user_id, metric_type, source_device, started_at) DO UPDATE SET
    value = EXCLUDED.value, unit = EXCLUDED.unit,
    ended_at = EXCLUDED.ended_at, metadata = EXCLUDED.metadata;
  GET DIAGNOSTICS v_written = ROW_COUNT;

  RETURN QUERY SELECT v_deleted, v_written;
END;
$func$;

REVOKE ALL ON FUNCTION public.health4ai_replace_merged_hours(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health4ai_replace_merged_hours(uuid, jsonb) TO service_role;

COMMIT;
