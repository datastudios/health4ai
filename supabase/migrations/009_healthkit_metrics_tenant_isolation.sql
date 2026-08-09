-- health4ai: canonical hosted ingestion table and tenant isolation
--
-- The iOS app authenticates with a Supabase JWT and the Edge Function stamps
-- user_id from that JWT. Clients do not need direct table access. This migration
-- deliberately denies anon/authenticated access, so a shared Supabase project
-- cannot expose one user's health data to another through PostgREST.

CREATE TABLE IF NOT EXISTS public.healthkit_metrics (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  metric_type   text        NOT NULL,
  value         float8,
  unit          text,
  source_device text,
  started_at    timestamptz NOT NULL,
  ended_at      timestamptz,
  metadata      jsonb,
  synced_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT healthkit_metrics_user_metric_started_key
    UNIQUE (user_id, metric_type, started_at)
);

CREATE INDEX IF NOT EXISTS healthkit_metrics_user_time_idx
  ON public.healthkit_metrics (user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS healthkit_metrics_user_type_time_idx
  ON public.healthkit_metrics (user_id, metric_type, started_at DESC);
CREATE INDEX IF NOT EXISTS healthkit_metrics_metadata_idx
  ON public.healthkit_metrics USING gin(metadata);

CREATE TABLE IF NOT EXISTS public.healthkit_daily_summaries (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  metric_type   text        NOT NULL,
  summary_date  date        NOT NULL,
  avg_value     float8,
  min_value     float8,
  max_value     float8,
  sum_value     float8,
  sample_count  integer,
  unit          text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT healthkit_daily_summaries_user_metric_date_key
    UNIQUE (user_id, metric_type, summary_date)
);

CREATE INDEX IF NOT EXISTS healthkit_daily_summaries_user_date_idx
  ON public.healthkit_daily_summaries (user_id, summary_date DESC);

ALTER TABLE public.healthkit_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.healthkit_daily_summaries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.healthkit_metrics FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.healthkit_daily_summaries FROM PUBLIC, anon, authenticated;

-- This legacy SECURITY DEFINER helper accepts a user_id parameter and is not an
-- app-facing RPC. PostgreSQL grants EXECUTE to PUBLIC by default, which would
-- otherwise let an authenticated caller target another user's rows.
REVOKE ALL ON FUNCTION public.summarize_healthkit_metric(uuid, text, date)
  FROM PUBLIC, anon, authenticated;

-- PostgreSQL views may run with the owner's privileges. The existing views are
-- maintenance/query conveniences, not app-facing API resources.
DO $$
BEGIN
  IF to_regclass('public.v_healthkit_daily_quantity') IS NOT NULL THEN
    REVOKE ALL ON TABLE public.v_healthkit_daily_quantity FROM PUBLIC, anon, authenticated;
  END IF;
  IF to_regclass('public.v_healthkit_sleep_nightly') IS NOT NULL THEN
    REVOKE ALL ON TABLE public.v_healthkit_sleep_nightly FROM PUBLIC, anon, authenticated;
  END IF;
END
$$;

-- A pre-009 project may have been initialized from the portable single-user
-- schema, which stores user_id as text. Refuse to present that as hosted,
-- tenant-isolated mode: create a fresh Supabase project and run migrations.
DO $$
DECLARE
  metrics_user_id_type text;
  summaries_user_id_type text;
BEGIN
  SELECT data_type INTO metrics_user_id_type
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'healthkit_metrics' AND column_name = 'user_id';
  SELECT data_type INTO summaries_user_id_type
  FROM information_schema.columns
  WHERE table_schema = 'public' AND table_name = 'healthkit_daily_summaries' AND column_name = 'user_id';
  IF metrics_user_id_type <> 'uuid' OR summaries_user_id_type <> 'uuid' THEN
    RAISE EXCEPTION 'health4ai hosted mode requires UUID user_id columns; create a fresh Supabase project and run migrations';
  END IF;
END
$$;

-- No authenticated-user policy by design. All app writes go through
-- healthkit-ingest, which validates the JWT and uses the service role only
-- after deriving user_id from that JWT. service_role bypasses RLS in Supabase.
