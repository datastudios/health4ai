-- health4ai — grants, RLS, and the summarize function. Run after 001.
--
-- Posture: default-deny. Every grant below is column- or row-scoped and exists
-- because a specific screen in the app needs it. The failure mode this avoids is
-- the common one: broad table grants to `authenticated` with RLS as the only
-- thing standing behind them. Nothing here is granted "to be safe".

BEGIN;

-- ---------------------------------------------------------------------------
-- 0. Start from zero
-- ---------------------------------------------------------------------------
REVOKE ALL ON public.healthkit_metrics         FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.healthkit_daily_summaries FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.health4ai_user_settings   FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.health4ai_waitlist        FROM PUBLIC, anon, authenticated;

ALTER TABLE public.healthkit_metrics         ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.healthkit_daily_summaries ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.health4ai_user_settings   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.health4ai_waitlist        ENABLE ROW LEVEL SECURITY;

-- Future tables in this schema start denied rather than inheriting Supabase's
-- default grants. Without this, a migration can REVOKE a grant while live state
-- quietly disagrees, and the file stops describing the database.
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- 1. Health data — read and delete your own; writes go through the ingest fn
-- ---------------------------------------------------------------------------
-- READ is granted, unlike legacy 009 which denied all client access. A hosted
-- consumer app has to render the user's own numbers on-device; without this the
-- Today screen has no data source and the product is a write-only pipe.
--
-- DELETE is granted deliberately: a health app must let a person destroy their
-- own data on demand, and routing that through support tickets is not a
-- privacy control. INSERT/UPDATE stay denied — the client never decides what
-- user_id a row carries. healthkit-ingest validates the JWT and stamps user_id
-- from it, then writes with the service role, which bypasses RLS.
GRANT SELECT, DELETE ON public.healthkit_metrics         TO authenticated;
GRANT SELECT, DELETE ON public.healthkit_daily_summaries TO authenticated;

CREATE POLICY metrics_own_rows ON public.healthkit_metrics
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY metrics_delete_own ON public.healthkit_metrics
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

CREATE POLICY summaries_own_rows ON public.healthkit_daily_summaries
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY summaries_delete_own ON public.healthkit_daily_summaries
  FOR DELETE TO authenticated USING (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 2. Settings — full own-row control
-- ---------------------------------------------------------------------------
GRANT SELECT, INSERT, UPDATE ON public.health4ai_user_settings TO authenticated;

CREATE POLICY settings_select_own ON public.health4ai_user_settings
  FOR SELECT TO authenticated USING (auth.uid() = user_id);
CREATE POLICY settings_insert_own ON public.health4ai_user_settings
  FOR INSERT TO authenticated WITH CHECK (auth.uid() = user_id);
CREATE POLICY settings_update_own ON public.health4ai_user_settings
  FOR UPDATE TO authenticated USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ---------------------------------------------------------------------------
-- 3. Waitlist — anon may submit an address and a consent flag, nothing else
-- ---------------------------------------------------------------------------
-- Column-level INSERT is the control that matters. With a table-level grant,
-- anyone holding the publishable key (it ships in the landing page by design)
-- could POST invite_status='invited' with a forged asc_tester_id and corrupt
-- the invite ledger. They cannot name a column they were not granted.
--
-- No SELECT for anon. The legacy table got this right and it is repeated here:
-- an email list that can be read back with a public key is a harvestable list.
GRANT INSERT (email, consent_testflight, consent_source)
  ON public.health4ai_waitlist TO anon;

CREATE POLICY waitlist_anon_insert ON public.health4ai_waitlist
  FOR INSERT TO anon WITH CHECK (true);

GRANT ALL ON public.health4ai_waitlist TO service_role;

-- ---------------------------------------------------------------------------
-- 4. Summarize function
-- ---------------------------------------------------------------------------
-- Ported from legacy 003 with two fixes: it writes `summary_date` (the legacy
-- copy wrote `date` and disagreed with the legacy table definition), and the
-- rollup day boundary comes from the user's own time zone instead of a
-- hardcoded America/New_York.
CREATE OR REPLACE FUNCTION public.summarize_healthkit_metric(
  p_user_id     uuid,
  p_metric_type text,
  p_cutoff      date
)
RETURNS TABLE(raw_count bigint, summary_days bigint)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $func$
DECLARE
  v_raw_count    bigint;
  v_summary_days bigint;
  v_tz           text;
BEGIN
  SELECT coalesce(s.time_zone, 'UTC') INTO v_tz
  FROM public.health4ai_user_settings s WHERE s.user_id = p_user_id;
  v_tz := coalesce(v_tz, 'UTC');

  SELECT count(*) INTO v_raw_count
  FROM public.healthkit_metrics
  WHERE user_id = p_user_id AND metric_type = p_metric_type
    AND started_at < p_cutoff::timestamptz;

  IF v_raw_count = 0 THEN
    RETURN QUERY SELECT 0::bigint, 0::bigint;
    RETURN;
  END IF;

  INSERT INTO public.healthkit_daily_summaries
    (user_id, metric_type, summary_date, avg_value, min_value, max_value,
     sum_value, sample_count, unit)
  -- GROUP BY carries `unit`, and the unit is no longer invented with max(). Without
  -- this a day holding one metric in two units summed across both and was labelled
  -- with whichever string sorted higher. Register D338.
  SELECT user_id, metric_type, (started_at AT TIME ZONE v_tz)::date,
         avg(value), min(value), max(value), sum(value), count(*), COALESCE(unit, '')
  FROM public.healthkit_metrics
  WHERE user_id = p_user_id AND metric_type = p_metric_type
    AND started_at < p_cutoff::timestamptz
  GROUP BY user_id, metric_type, (started_at AT TIME ZONE v_tz)::date, COALESCE(unit, '')
  ON CONFLICT (user_id, metric_type, summary_date, unit) DO UPDATE SET
    avg_value = EXCLUDED.avg_value, min_value = EXCLUDED.min_value,
    max_value = EXCLUDED.max_value, sum_value = EXCLUDED.sum_value,
    sample_count = EXCLUDED.sample_count,
    summarized_at = now();
    -- `unit` is not reassigned: it is part of the conflict key, so EXCLUDED.unit is
    -- always the existing value.

  GET DIAGNOSTICS v_summary_days = ROW_COUNT;

  DELETE FROM public.healthkit_metrics
  WHERE user_id = p_user_id AND metric_type = p_metric_type
    AND started_at < p_cutoff::timestamptz;

  RETURN QUERY SELECT v_raw_count, v_summary_days;
END;
$func$;

-- SECURITY DEFINER + a user_id PARAMETER is a lethal pairing if it is callable
-- from a client: any signed-in user could summarize (and therefore DELETE) any
-- other user's raw rows. PostgreSQL grants EXECUTE to PUBLIC by default, so the
-- revoke is required, not tidy-up. Legacy 009 learned this the same way.
REVOKE ALL ON FUNCTION public.summarize_healthkit_metric(uuid, text, date)
  FROM PUBLIC, anon, authenticated;

COMMIT;
