-- health4ai production (legacy project): STEP 2 of 2 — drop the legacy 3-column upsert key.
--
-- Run ONLY after BOTH are true:
--   1. STEP 1 is applied (the guard below refuses otherwise), and
--   2. healthkit-ingest with onConflict 'user_id,metric_type,source_device,started_at' is
--      deployed AND a real sync has been seen writing rows through it.
-- Dropping this while the old function is still live would make every production upsert fail
-- 42P10 — the exact failure this change exists to remove, moved onto production.
--
-- Needs the Supabase SQL editor: the agent SQL channel refuses DROP. Register D353.
--
-- Paste and run this whole file as ONE execution. The guard only protects the DROP when the DO
-- block and the DROP run in the same transaction; run as separate executions, the DROP is unguarded.
--
-- ROLLBACK HAZARD: once this has run, redeploying the OLD ingest function (3-column onConflict)
-- makes every production upsert fail 42P10 — the original outage, moved onto production. A
-- function rollback after STEP 2 must be paired with recreating the legacy index:
--   CREATE UNIQUE INDEX metrics_upsert_key ON public.healthkit_metrics (user_id, metric_type, started_at);
-- and that will itself fail if two devices have since written the same metric at the same instant.

BEGIN;

DO $$
BEGIN
    IF to_regclass('public.healthkit_metrics_user_metric_device_started_key') IS NULL THEN
        RAISE EXCEPTION 'STEP 1 not applied: the 4-column key is missing. Refusing to drop the only upsert key.';
    END IF;
END
$$;

DROP INDEX IF EXISTS public.metrics_upsert_key;

COMMIT;
