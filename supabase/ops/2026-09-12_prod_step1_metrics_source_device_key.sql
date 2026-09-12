-- health4ai production (legacy project): converge healthkit_metrics onto bootstrap's sample key.
-- STEP 1 of 2 — ADDITIVE ONLY. Safe while the CURRENT ingest function is still live.
--
-- Why: supabase/bootstrap/001 keys samples on (user_id, metric_type, source_device, started_at),
-- so two devices recording the same instant stop collapsing into one row. The ingest function
-- upserted on (user_id, metric_type, started_at), which matched ONLY this legacy project;
-- against every bootstrap project each upsert failed 42P10 (register D353, proven end to end on
-- a local Supabase stack 2026-09-12). One key everywhere means one function works everywhere.
--
-- Rollout order is what keeps production syncing throughout:
--   STEP 1 (this file)  add the 4-column unique index ALONGSIDE the old 3-column one.
--                       The current function's 3-column target still has its arbiter.
--   DEPLOY              healthkit-ingest with onConflict user_id,metric_type,source_device,started_at.
--                       The new target now has an arbiter too.
--   STEP 2              drop the old 3-column index. Until then it still forbids two devices at
--                       one instant — today's behaviour, not a regression.
--
-- Measured before writing, 2026-09-12: 161,065 rows, 0 with NULL source_device, 0 groups that
-- would violate the 4-column key, 1 user.

ALTER TABLE public.healthkit_metrics ALTER COLUMN source_device SET DEFAULT '';

-- A NULL member makes a unique key stop deduplicating (NULL <> NULL). Zero NULLs exist; this
-- keeps it that way and makes the NOT NULL below safe.
UPDATE public.healthkit_metrics SET source_device = '' WHERE source_device IS NULL;

ALTER TABLE public.healthkit_metrics ALTER COLUMN source_device SET NOT NULL;

-- Same name as bootstrap's constraint, so both schemas read the same in \d output.
CREATE UNIQUE INDEX IF NOT EXISTS healthkit_metrics_user_metric_device_started_key
    ON public.healthkit_metrics (user_id, metric_type, source_device, started_at);
