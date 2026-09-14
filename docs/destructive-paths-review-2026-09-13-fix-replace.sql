-- PROPOSED FIX for public.health4ai_replace_merged_hours (register D361). Drop-in: same signature,
-- same privileges, same semantics. NOT applied anywhere by the review; Jeff applies to prod, then
-- the same text goes into supabase/upgrades/ and bootstrap 002 section 5.
--
-- Why: the committed DELETE joins the whole table to jsonb_to_recordset(p_rows). The planner cannot
-- push an hour range whose bounds come from the recordset into an index scan, estimates the
-- recordset at 100 rows, and picks a hash join over a Seq Scan of healthkit_metrics
-- (production EXPLAIN 2026-09-13: "Seq Scan on healthkit_metrics m ... rows=2758559"; the
-- read-only equivalent ran 15,051 ms and read 50,597 buffers for a TWO-hour payload). PostgREST
-- runs the RPC on a session whose login role, authenticator, carries statement_timeout=8s
-- (pg_roles read 2026-09-13), so the first real merged batch is expected to fail with 57014,
-- the ingest function answers 500, and the app retries the same page for ever: no data is lost,
-- and no merged hour is ever stored.
--
-- One DELETE per hour with constant bounds plans as a range scan on
-- metrics_user_type_time_idx (user_id, metric_type, started_at): production EXPLAIN ANALYZE of
-- that shape reads ~10 buffers. p_rows is capped at 1000 by the ingest function, so the loop
-- is bounded. Still ONE transaction: a failure anywhere rolls every hour back.
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
