-- Throwaway-Postgres reproduction schema for docs/health4ai-destructive-paths-review-2026-09-13.md
-- PRODUCTION shape (jgle-business, read from pg_indexes / information_schema 2026-09-13), not the
-- bootstrap shape: no auth.users FK, summaries column is `date` (bootstrap: summary_date), prod
-- index names. The summariser body below is pg_get_functiondef() from production, md5
-- 8adb6894c05a4c398683dc53def8f88b, len 2537, read 2026-09-13 16:17Z. Never run this on a real project.
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='service_role') THEN CREATE ROLE service_role NOLOGIN BYPASSRLS; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='anon') THEN CREATE ROLE anon NOLOGIN; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='authenticated') THEN CREATE ROLE authenticated NOLOGIN; END IF;
END $$;
DROP TABLE IF EXISTS public.healthkit_daily_summaries;
DROP TABLE IF EXISTS public.healthkit_metrics;
CREATE TABLE public.healthkit_metrics (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL,
  metric_type   text        NOT NULL,
  value         float8,
  unit          text,
  source_device text        NOT NULL DEFAULT '',
  started_at    timestamptz NOT NULL,
  ended_at      timestamptz,
  metadata      jsonb,
  synced_at     timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT healthkit_metrics_user_metric_device_started_key UNIQUE (user_id, metric_type, source_device, started_at)
);
CREATE INDEX metrics_user_time_idx      ON public.healthkit_metrics (user_id, started_at DESC);
CREATE INDEX metrics_user_type_time_idx ON public.healthkit_metrics (user_id, metric_type, started_at DESC);
CREATE INDEX metrics_metadata_idx       ON public.healthkit_metrics USING gin (metadata);
CREATE TABLE public.healthkit_daily_summaries (
  id            uuid  PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid  NOT NULL,
  metric_type   text  NOT NULL,
  date          date  NOT NULL,
  avg_value float8, min_value float8, max_value float8, sum_value float8,
  sample_count  int   NOT NULL DEFAULT 0,
  unit          text  NOT NULL DEFAULT '',
  summarized_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX summaries_upsert_key ON public.healthkit_daily_summaries (user_id, metric_type, date, unit);
CREATE INDEX summaries_type_date_idx ON public.healthkit_daily_summaries (user_id, metric_type, date DESC);

-- LIVE production summariser, verbatim.
CREATE OR REPLACE FUNCTION public.summarize_healthkit_metric(p_user_id uuid, p_metric_type text, p_cutoff date)
 RETURNS TABLE(raw_count bigint, summary_days bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
    v_raw_count bigint;
    v_summary_days bigint;
    v_cutoff_ts timestamptz;
BEGIN
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
    GET DIAGNOSTICS v_summary_days = ROW_COUNT;
    DELETE FROM public.healthkit_metrics
    WHERE user_id = p_user_id AND metric_type = p_metric_type
      AND started_at < v_cutoff_ts;
    RETURN QUERY SELECT v_raw_count, v_summary_days;
END;
$function$;
