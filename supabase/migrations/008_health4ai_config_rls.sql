-- ============================================================================
-- 008_health4ai_config_rls.sql  (REWORKED 2026-07-17, Mark Vasquez / SS Security)
--
-- Remediates + reconciles: audit finding "RLS disabled entirely" on the three
-- health4.ai SEO/content-pipeline config tables:
--   public.health4ai_config, public.health4ai_content_queue,
--   public.health4ai_keyword_rankings
-- Severity (audit_findings taxonomy, re-confirmed live 2026-07-17 via
--   SELECT severity, count(*) FROM audit_findings:
--     hygiene=51, structural=41, critical=12, cosmetic=7): HYGIENE.
--   No anon/authenticated grant exists on any of the three tables and the one
--   documented anon-read feature (landing-page founding-batch countdown) was
--   never implemented -- verified 2026-07-17: the only anon fetch in
--   web/src/pages/index.astro is a POST to health4ai_waitlist, and grep of
--   web/ finds zero reads of these three tables. Process debt, not a live
--   public exposure. Hence hygiene, not structural.
--
-- WHY THIS FILE WAS REWORKED (drift reconciliation):
--   The original 008 (committed 581933d, never applied) assumed a pre-change
--   state of relrowsecurity=false with a live hermes_worker SELECT grant to be
--   "preserved". Live state has since drifted PAST those assumptions. Verified
--   live 2026-07-17 via mcp__jgle-business (l7_sql):
--     * relrowsecurity=true on ALL THREE tables (RLS was enabled by another
--       path after 2026-07-15). relforcerowsecurity=false.
--     * role_table_grants: only postgres + service_role hold grants (full CRUD
--       each). The hermes_worker grant the original file meant to preserve is
--       GONE. No anon/authenticated grant on any table.
--     * pg_policies: only ONE policy existed -- service_role_bypass on
--       health4ai_keyword_rankings (service_role, ALL, true/true). config and
--       content_queue had NO policy.
--     * pg_roles: service_role and postgres have rolbypassrls=true;
--       anon/authenticated/hermes_worker have rolbypassrls=false.
--   Live access matrix under the drifted (RLS-on) state, proven 2026-07-17
--   with SET ROLE + count(*) on health4ai_config:
--     service_role -> OK: 1 row  (the actual app / MCP / n8n read+write path)
--     anon         -> DENIED: permission denied for table health4ai_config
--     authenticated-> DENIED: permission denied for table health4ai_config
--     hermes_worker-> DENIED: permission denied for table health4ai_config
--
-- CORRECT END STATE for a single-product config table set whose ONLY consumer
-- is service_role (health4ai MCP connects via SUPABASE_SERVICE_ROLE_KEY /
-- postgres pooler; Camille's n8n content scheduler reads/writes via PostgREST
-- with the service key -- both bypass RLS):
--     * RLS ENABLED (deny-by-default for every non-bypass role).
--     * Grants: postgres + service_role only. No anon/authenticated/hermes_worker.
--     * A single explicit, self-documenting service_role ALL policy per table
--       (Supabase convention; matches the policy already present on
--       keyword_rankings). This is INERT to access -- service_role reads/writes
--       via rolbypassrls regardless -- but makes intent uniform across all
--       three tables and is defense-in-depth if bypassrls/forcerowsecurity is
--       ever changed.
--     * NO hermes_worker policy: these are NOT persona-bot-read tables, so the
--       original file's "preserve hermes_worker" intent is moot (per memory
--       hermes-worker-rls-grant-gap.md an RLS table needs BOTH a policy AND a
--       grant for a persona bot to read it; health4ai has neither and needs
--       neither).
--
-- This rewrite is fully idempotent (ENABLE RLS / REVOKE are no-ops when
-- already satisfied; DROP POLICY IF EXISTS precedes every CREATE POLICY) and
-- was APPLIED + query-back verified against live state on 2026-07-17.
--
-- Migration sequence note: 001_healthkit_schema, 002_hosted_tier,
--   003_sprint1_security, 003_summarize_function (genuine 003 collision --
--   tracked as its own audit_findings row below, not fixed here), 004..007,
--   008 (this file).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- health4ai_config
-- ---------------------------------------------------------------------------
ALTER TABLE public.health4ai_config ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.health4ai_config FROM anon;
REVOKE ALL ON public.health4ai_config FROM authenticated;

DROP POLICY IF EXISTS service_role_bypass                     ON public.health4ai_config;
DROP POLICY IF EXISTS health4ai_config_hermes_worker_select   ON public.health4ai_config;
DROP POLICY IF EXISTS health4ai_config_service_role_all       ON public.health4ai_config;
CREATE POLICY health4ai_config_service_role_all
  ON public.health4ai_config
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- health4ai_content_queue
-- ---------------------------------------------------------------------------
ALTER TABLE public.health4ai_content_queue ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.health4ai_content_queue FROM anon;
REVOKE ALL ON public.health4ai_content_queue FROM authenticated;

DROP POLICY IF EXISTS service_role_bypass                        ON public.health4ai_content_queue;
DROP POLICY IF EXISTS health4ai_content_queue_service_role_all   ON public.health4ai_content_queue;
CREATE POLICY health4ai_content_queue_service_role_all
  ON public.health4ai_content_queue
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- health4ai_keyword_rankings
-- ---------------------------------------------------------------------------
ALTER TABLE public.health4ai_keyword_rankings ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON public.health4ai_keyword_rankings FROM anon;
REVOKE ALL ON public.health4ai_keyword_rankings FROM authenticated;

-- service_role_bypass is the pre-existing (only) live policy; drop + recreate
-- under a uniform name so all three tables match.
DROP POLICY IF EXISTS service_role_bypass                          ON public.health4ai_keyword_rankings;
DROP POLICY IF EXISTS health4ai_keyword_rankings_service_role_all  ON public.health4ai_keyword_rankings;
CREATE POLICY health4ai_keyword_rankings_service_role_all
  ON public.health4ai_keyword_rankings
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

-- ============================================================================
-- Audit trail (idempotent: guarded by NOT EXISTS on pass+title).
-- NOTE: audit_findings.pass has a live CHECK constraint restricting it to
--   ('architecture','security','operability') -- it is the audit-LENS column,
--   not a free-text remediation tag. The original 008 draft used
--   pass='health4ai-rls-remediation-2026-07-15', which would have failed with
--   a 23514 check-constraint violation on the first INSERT (i.e. the original
--   file was unrunnable, independent of the RLS drift). Corrected to
--   pass='security' here; the remediation batch is referenced in the titles.
-- ============================================================================

-- Finding 1: the RLS reconciliation itself, recorded as RESOLVED because this
-- file was applied AND query-back verified in the same session (2026-07-17).
INSERT INTO audit_findings
  (pass, severity, title, description, evidence, recommendation,
   assigned_to, status, resolved_at, resolved_by, resolution_notes)
SELECT
  'security',
  'hygiene',
  'health4ai_config/content_queue/keyword_rankings: RLS posture reconciled (migration 008 idempotent rewrite)',
  'The three health4.ai SEO/content-pipeline config tables were created via ad-hoc ' ||
  'SQL-editor snippets during the 2026-06-21 SEO/AEO sprint, bypassing supabase/migrations/, ' ||
  'so they never received ENABLE ROW LEVEL SECURITY at creation. RLS was later enabled by ' ||
  'another path (state observed relrowsecurity=true on 2026-07-17) and the transient ' ||
  'hermes_worker SELECT grant the original 008 draft meant to preserve was removed. This ' ||
  'reworked migration reconciles the declared state with live reality and normalizes all ' ||
  'three tables to a single explicit service_role ALL policy.',
  'Live verification (l7_sql, 2026-07-17): pg_class.relrowsecurity=true / ' ||
  'relforcerowsecurity=false on all 3 tables; role_table_grants shows postgres + ' ||
  'service_role full CRUD only, no anon/authenticated/hermes_worker grant; access matrix via ' ||
  'SET ROLE + count(*) on health4ai_config: service_role OK (1 row), anon DENIED, ' ||
  'authenticated DENIED, hermes_worker DENIED. App/MCP/n8n all connect as service_role ' ||
  '(rolbypassrls=true) so RLS is inert to them; the sole anon call in web/src/pages/index.astro ' ||
  'is a POST to health4ai_waitlist, not a read of these tables.',
  'None outstanding for these three tables. Post-apply end state (verified 2026-07-17): RLS on, ' ||
  'one service_role ALL policy per table, no public/hermes_worker access.',
  'Mark Vasquez',
  'resolved',
  now(),
  'Mark Vasquez',
  'Applied 2026-07-17. Post-apply query-back: 3 policies present ' ||
  '(health4ai_config_service_role_all, health4ai_content_queue_service_role_all, ' ||
  'health4ai_keyword_rankings_service_role_all), all service_role/ALL/true. Re-ran access ' ||
  'matrix: service_role OK 1 row, anon/authenticated/hermes_worker all DENIED. See migration ' ||
  'header for full pre/post evidence.'
WHERE NOT EXISTS (
  SELECT 1 FROM audit_findings
  WHERE pass = 'security'
    AND title = 'health4ai_config/content_queue/keyword_rankings: RLS posture reconciled (migration 008 idempotent rewrite)'
);

-- Finding 2: the migration-numbering collision (003 used twice). Still true on
-- disk 2026-07-17; genuine housekeeping item, left OPEN, unrelated to RLS.
INSERT INTO audit_findings
  (pass, severity, title, description, evidence, recommendation, assigned_to, status)
SELECT
  'operability',
  'hygiene',
  'health4ai supabase/migrations/ has two files numbered 003 (real collision, not a typo)',
  'ventures/health4ai/supabase/migrations/ contains both 003_sprint1_security.sql and ' ||
  '003_summarize_function.sql. File mtimes confirm 003_summarize_function.sql (2026-05-21) ' ||
  'predates 003_sprint1_security.sql (2026-06-19): a genuine sequence collision, not a header ' ||
  'transcription error. This RLS migration does not rename either file (renaming an already-' ||
  'applied migration is its own risk).',
  'Directory listing 2026-07-17: 003_sprint1_security.sql (1323 bytes) and ' ||
  '003_summarize_function.sql (2038 bytes) both present and distinct.',
  'Confirm whether either file is already applied via a tracked migration ledger; if not, ' ||
  'rename one to fill the gap; if so, document the collision permanently in a ' ||
  'supabase/migrations/README.md.',
  'Camille Roux',
  'open'
WHERE NOT EXISTS (
  SELECT 1 FROM audit_findings
  WHERE pass = 'operability'
    AND title = 'health4ai supabase/migrations/ has two files numbered 003 (real collision, not a typo)'
);

-- ============================================================================
-- POST-APPLY VERIFICATION (idempotent; safe to re-run):
--   SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class
--     WHERE relname IN ('health4ai_config','health4ai_content_queue','health4ai_keyword_rankings');
--   SELECT tablename, policyname, roles, cmd, qual, with_check FROM pg_policies
--     WHERE tablename IN ('health4ai_config','health4ai_content_queue','health4ai_keyword_rankings');
--   -- Access matrix (expect service_role OK, all others DENIED):
--   --   SET ROLE <role>; SELECT count(*) FROM public.health4ai_config; RESET ROLE;
-- ============================================================================
