-- Upgrade an EXISTING health4ai project: merged hourly totals replace per-device rows.
-- For any project created from supabase/bootstrap (or web/public/schema.sql) before 2026-09-13,
-- including the maintainer's production project. New projects already get this from bootstrap 002,
-- whose section 5 this file copies exactly. Register D361.
--
-- Why: the app now sends HealthKit's merged total per UTC hour for activity types that an iPhone and
-- a Watch both record (steps, distance, energy, flights, exercise/move/stand time). Without this
-- function the ingest function cannot remove the per-device rows those hours replace, and the app
-- keeps sending per-device samples, which count the same steps twice.
--
-- HOW: paste into the Supabase SQL editor and run, THEN redeploy the function:
--   supabase functions deploy healthkit-ingest --no-verify-jwt
-- In that order. The new function calls this one; deployed first, a merged-hours batch fails with a
-- 500 until this exists (the app retries, nothing is lost). Re-running bootstrap 002 instead fails on
-- its existing policies. Safe to re-run: CREATE OR REPLACE, and REVOKE/GRANT are idempotent.
--
-- VERIFY after running:
--   SELECT p.prosecdef, p.proconfig, has_function_privilege('authenticated', p.oid, 'EXECUTE') AS auth_exec,
--          has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_exec,
--          has_function_privilege('service_role', p.oid, 'EXECUTE') AS service_exec
--   FROM pg_proc p WHERE p.proname = 'health4ai_replace_merged_hours';
--   expected: prosecdef=false, proconfig={search_path=pg_catalog, public}, auth_exec=false,
--             anon_exec=false, service_exec=true
BEGIN;

-- ---------------------------------------------------------------------------
-- 5. Merged hourly totals replace per-device rows
-- ---------------------------------------------------------------------------
-- For activity types that several devices record at the same moment (steps, distance,
-- energy, flights, exercise/move/stand time) the app sends HealthKit's merged total per UTC
-- hour, labelled source_device 'HealthKit (all sources)'. Rows already stored per device for
-- that hour would be summed on top of it: an iPhone and a Watch counting the same steps is
-- how 2021 came to read 67% high. So the hour's per-device rows are deleted and the merged
-- row written in ONE transaction; done as two requests, a failure between them left the hour
-- either double-counted or empty. A per-device row belongs to the hour its started_at falls
-- in, so a sample crossing a boundary is replaced when the hour it started in arrives.
-- Register D361.
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
  v_deleted bigint;
  v_written bigint;
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'p_user_id is required';
  END IF;
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array';
  END IF;

  DELETE FROM public.healthkit_metrics m
  USING jsonb_to_recordset(p_rows) AS r(metric_type text, started_at timestamptz)
  WHERE m.user_id = p_user_id
    AND m.metric_type = r.metric_type
    AND m.started_at >= r.started_at
    AND m.started_at <  r.started_at + interval '1 hour'
    AND m.source_device <> 'HealthKit (all sources)';
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  INSERT INTO public.healthkit_metrics
    (user_id, metric_type, value, unit, source_device, started_at, ended_at, metadata)
  SELECT p_user_id, r.metric_type, r.value, r.unit, 'HealthKit (all sources)',
         r.started_at, r.ended_at, r.metadata
  FROM jsonb_to_recordset(p_rows) AS r(metric_type text, value double precision, unit text,
                                       started_at timestamptz, ended_at timestamptz, metadata jsonb)
  ON CONFLICT (user_id, metric_type, source_device, started_at) DO UPDATE SET
    value = EXCLUDED.value, unit = EXCLUDED.unit,
    ended_at = EXCLUDED.ended_at, metadata = EXCLUDED.metadata;
    -- The same columns the ingest function's PostgREST upsert sets; synced_at keeps its
    -- insert-time default there too.
  GET DIAGNOSTICS v_written = ROW_COUNT;

  RETURN QUERY SELECT v_deleted, v_written;
END;
$func$;

-- A user_id PARAMETER on a function a client could call would let any signed-in user delete
-- any other user's rows, and PostgreSQL grants EXECUTE to PUBLIC by default. Only the ingest
-- function calls this, with the service role, after verifying the caller's JWT itself.
REVOKE ALL ON FUNCTION public.health4ai_replace_merged_hours(uuid, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health4ai_replace_merged_hours(uuid, jsonb) TO service_role;

COMMIT;
