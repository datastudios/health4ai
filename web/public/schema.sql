-- health4ai schema v1
-- Compatible with: Supabase, Neon, local PostgreSQL 14+
-- Run: psql "$DATABASE_URL" < schema.sql
-- Docs: https://github.com/jefflitt1/health4ai

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- Raw HealthKit samples (one row per HKSample)
-- Rolling 30-day window; older data moves to healthkit_daily_summaries
CREATE TABLE IF NOT EXISTS healthkit_metrics (
    id            uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id       text        NOT NULL,
    metric_type   text        NOT NULL,  -- HKQuantityTypeIdentifier* or HKCategoryTypeIdentifier*
    value         float8,
    unit          text,                  -- 'ms', 'count/min', 'kcal', 'km', etc.
    source_device text,
    started_at    timestamptz NOT NULL,
    ended_at      timestamptz,
    metadata      jsonb,                 -- sleep stages, workout subtypes, heart rate zones, etc.
    synced_at     timestamptz DEFAULT now() NOT NULL,
    UNIQUE (user_id, metric_type, started_at)
);

CREATE INDEX IF NOT EXISTS healthkit_metrics_user_time
    ON healthkit_metrics (user_id, started_at DESC);

CREATE INDEX IF NOT EXISTS healthkit_metrics_user_type_time
    ON healthkit_metrics (user_id, metric_type, started_at DESC);

CREATE INDEX IF NOT EXISTS healthkit_metrics_metadata
    ON healthkit_metrics USING gin(metadata);

-- Daily aggregates for historical data (>30 days)
CREATE TABLE IF NOT EXISTS healthkit_daily_summaries (
    id            uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id       text        NOT NULL,
    metric_type   text        NOT NULL,
    summary_date  date        NOT NULL,
    avg_value     float8,
    min_value     float8,
    max_value     float8,
    sum_value     float8,
    sample_count  int,
    unit          text,
    created_at    timestamptz DEFAULT now(),
    UNIQUE (user_id, metric_type, summary_date)
);

CREATE INDEX IF NOT EXISTS healthkit_daily_summaries_user_date
    ON healthkit_daily_summaries (user_id, summary_date DESC);

-- Unified view: transparent query across raw + summaries
-- Use this in your MCP server / application queries
CREATE OR REPLACE VIEW v_healthkit_daily_quantity AS
  SELECT
    user_id, metric_type, summary_date AS day,
    avg_value, min_value, max_value, sum_value, sample_count, unit,
    'summary' AS source
  FROM healthkit_daily_summaries
  UNION ALL
  SELECT
    user_id, metric_type, started_at::date AS day,
    AVG(value), MIN(value), MAX(value), SUM(value), COUNT(*)::int, MAX(unit),
    'raw' AS source
  FROM healthkit_metrics
  WHERE metric_type NOT LIKE 'HKCategoryType%'
    AND metric_type NOT LIKE 'HKWorkoutType%'
  GROUP BY user_id, metric_type, started_at::date;

-- Supabase only: do not use this portable schema as a shared multi-user API.
-- The app's hosted ingestion flow uses supabase/migrations/009_healthkit_metrics_tenant_isolation.sql,
-- which creates the canonical table with auth.users ownership and deny-by-default RLS.
-- This portable schema remains suitable for a private database owned by one person.
-- ALTER TABLE healthkit_metrics ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE healthkit_daily_summaries ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY "own_data" ON healthkit_metrics FOR ALL USING (auth.uid()::text = user_id);
-- CREATE POLICY "own_data" ON healthkit_daily_summaries FOR ALL USING (auth.uid()::text = user_id);
