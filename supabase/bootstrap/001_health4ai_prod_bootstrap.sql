-- health4ai — schema for a backend YOU control
--
-- health4ai never operates a backend for your health data. This file is the
-- schema you install in your own Supabase project (or any Postgres) so the iOS
-- app has somewhere to sync to. Run 001 then 002.
--
-- It supersedes the older numbered migrations and fixes two defects in them:
--
--   1. The sample unique key now includes source_device. Without it, a night
--      recorded by BOTH an Apple Watch and an Oura Ring collapses to a single
--      row and one device's data is silently lost. Fine for one device, wrong
--      the moment you wear two.
--
--   2. Daily rollups use YOUR time zone instead of a hardcoded America/New_York,
--      so day boundaries land where you actually live.
--
-- Run it against a project you own and nothing else. It creates tables in the
-- public schema and assumes they are yours to create.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Raw samples
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.healthkit_metrics (
  id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       uuid        NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  metric_type   text        NOT NULL,
  value         float8,
  unit          text,
  source_device text        NOT NULL DEFAULT '',
  started_at    timestamptz NOT NULL,
  ended_at      timestamptz,
  metadata      jsonb,
  synced_at     timestamptz NOT NULL DEFAULT now(),
  -- source_device IS part of the key, unlike the legacy project.
  -- healthkit-ingest carries a comment admitting the narrow key collapses
  -- same-timestamp multi-device samples to one row and calling that
  -- "acceptable for single-user personal use". This build is not single-user:
  -- a tester wearing both an Apple Watch and an Oura Ring would silently lose
  -- one device's night. NOT NULL DEFAULT '' keeps the key total — in Postgres
  -- a NULL member makes a UNIQUE constraint stop deduping.
  CONSTRAINT healthkit_metrics_user_metric_device_started_key
    UNIQUE (user_id, metric_type, source_device, started_at)
);

CREATE INDEX IF NOT EXISTS healthkit_metrics_user_time_idx
  ON public.healthkit_metrics (user_id, started_at DESC);
CREATE INDEX IF NOT EXISTS healthkit_metrics_user_type_time_idx
  ON public.healthkit_metrics (user_id, metric_type, started_at DESC);
CREATE INDEX IF NOT EXISTS healthkit_metrics_metadata_idx
  ON public.healthkit_metrics USING gin(metadata);

-- ---------------------------------------------------------------------------
-- 2. Daily rollups
-- ---------------------------------------------------------------------------
-- Column is `summary_date`. The legacy project has TWO contradictory
-- definitions of this table: 009 declares `summary_date`, while the
-- summarize function in 003 writes `date`. Live is `date`, which proves 009's
-- CREATE ... IF NOT EXISTS silently no-opped against the pre-existing table and
-- the migration file has not described that project since. One name here, and
-- the function below is written against it.
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
  -- NOT NULL because `unit` is part of the unique key below, and NULL <> NULL would
  -- let two NULL-unit rows for one day both insert and never upsert.
  unit          text        NOT NULL DEFAULT '',
  created_at    timestamptz NOT NULL DEFAULT now(),
  summarized_at timestamptz NOT NULL DEFAULT now(),
  -- `unit` is in the key: a daily summary is per (user, metric_type, date, UNIT).
  -- Without it the summariser summed a metric across units and stamped the total with
  -- MAX(unit) — 0.032 kg + 32 g of protein became 32.032 kg. Register D338.
  CONSTRAINT healthkit_daily_summaries_user_metric_date_key
    UNIQUE (user_id, metric_type, summary_date, unit)
);

CREATE INDEX IF NOT EXISTS healthkit_daily_summaries_user_date_idx
  ON public.healthkit_daily_summaries (user_id, summary_date DESC);

-- ---------------------------------------------------------------------------
-- 3. Per-user settings
-- ---------------------------------------------------------------------------
-- The legacy sleep/quantity views hardcode 'America/New_York' and an Oura-only
-- source filter. Both are Jeff's setup, not a product. A hosted build needs the
-- timezone per user or every rollup is wrong for anyone outside Eastern.
CREATE TABLE IF NOT EXISTS public.health4ai_user_settings (
  user_id    uuid        PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  time_zone  text        NOT NULL DEFAULT 'UTC',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT health4ai_user_settings_tz_valid
    CHECK (now() AT TIME ZONE time_zone IS NOT NULL)
);

-- ---------------------------------------------------------------------------
-- 4. Waitlist (with TestFlight invite state)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.health4ai_waitlist (
  id             uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email          text        NOT NULL UNIQUE,
  created_at     timestamptz NOT NULL DEFAULT now(),
  -- Explicit, recorded consent to be handed to Apple as a TestFlight tester.
  -- App Store Connect administrators can see tester email addresses, so this is
  -- a disclosure to a third party and needs a yes on the record, not an
  -- inference from "they joined a waitlist".
  consent_testflight boolean     NOT NULL DEFAULT false,
  consent_source     text,
  invite_status      text        NOT NULL DEFAULT 'pending',
  invited_at         timestamptz,
  asc_tester_id      text,
  last_error         text,
  CONSTRAINT health4ai_waitlist_email_format
    CHECK (char_length(email) <= 254 AND email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  CONSTRAINT health4ai_waitlist_invite_status_valid
    CHECK (invite_status IN ('pending','queued','invited','failed','declined','skipped')),
  -- An invited row must carry its evidence. Without this an invite run can
  -- report success while writing nothing that proves Apple accepted the tester.
  CONSTRAINT health4ai_waitlist_invited_has_evidence
    CHECK (invite_status <> 'invited' OR (invited_at IS NOT NULL AND asc_tester_id IS NOT NULL)),
  -- Consent gates the invite at the DB, not only in the invite script. A bug
  -- in that script must not be able to hand a non-consenting address to Apple.
  CONSTRAINT health4ai_waitlist_invite_requires_consent
    CHECK (invite_status NOT IN ('queued','invited') OR consent_testflight)
);

CREATE INDEX IF NOT EXISTS health4ai_waitlist_invite_status_idx
  ON public.health4ai_waitlist (invite_status, created_at);

CREATE OR REPLACE FUNCTION public.health4ai_waitlist_normalize_email()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.email := lower(btrim(NEW.email));
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_health4ai_waitlist_normalize ON public.health4ai_waitlist;
CREATE TRIGGER trg_health4ai_waitlist_normalize
  BEFORE INSERT OR UPDATE ON public.health4ai_waitlist
  FOR EACH ROW EXECUTE FUNCTION public.health4ai_waitlist_normalize_email();

COMMIT;
