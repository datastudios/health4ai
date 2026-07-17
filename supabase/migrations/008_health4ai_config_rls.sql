-- ============================================================================
-- 008_health4ai_config_rls.sql
-- Remediates: audit finding "RLS disabled entirely" on public.health4ai_config
-- Severity (parent finding scale, credentials/security-alert vocabulary): LOW
-- Severity (audit_findings table vocabulary, confirmed live 2026-07-15 via
--   SELECT severity, count(*) FROM audit_findings GROUP BY severity:
--     hygiene=48, structural=35, critical=10, cosmetic=7): HYGIENE
--   Reconciliation: LOW/no-live-exploit-path findings map to hygiene in this
--   taxonomy; HIGH/exploitable-now maps to structural; confirmed compromise
--   maps to critical; pure doc/formatting drift maps to cosmetic. No
--   anon/authenticated grant exists on health4ai_config today and the one
--   documented anon-read feature was never implemented (verified against
--   /Users/jgl/ventures/health4ai/web/src/ 2026-07-15) -- process debt, not a
--   live public exposure. Hence hygiene, not structural.
--
-- Migration sequence note (re-verified 2026-07-15 via directory listing):
--   001_healthkit_schema.sql, 002_hosted_tier.sql, 003_sprint1_security.sql,
--   003_summarize_function.sql, 004_sleep_nightly_view.sql,
--   005_biometrics_combined_view.sql, 006_waitlist_table.sql,
--   007_drop_hosted_tier.sql, 008_health4ai_config_rls.sql (this file).
--   003 is duplicated on TWO real files, not a typo in this header -- file
--   mtimes confirm 003_summarize_function.sql (May 21 2026) predates
--   003_sprint1_security.sql (Jun 19 2026): an unresolved sequence collision,
--   not a copy/paste error here. This migration does NOT rename either file
--   (both may already be applied against prod; renaming an applied migration
--   file is its own risk, out of scope for an RLS fix). The collision is
--   opened as its own tracked audit_findings row below (see insert 3)
--   instead of being silently fixed or silently ignored.
-- ============================================================================

-- 1. Enable RLS (deny-all by default the moment this runs; no policy below
--    grants public/authenticated access, so anon/authenticated remain fully
--    locked out immediately on execution).
ALTER TABLE public.health4ai_config ENABLE ROW LEVEL SECURITY;

-- 2. Explicit, idempotent REVOKE for anon/authenticated. Confirmed via live
--    information_schema.role_table_grants query (2026-07-15) that neither
--    role currently holds any grant on this table -- these REVOKEs are
--    defense-in-depth / self-documenting, not a live change.
REVOKE ALL ON public.health4ai_config FROM anon;
REVOKE ALL ON public.health4ai_config FROM authenticated;

-- 3. Preserve the one real, currently-working non-superuser read path:
--    hermes_worker holds a live SELECT grant (confirmed 2026-07-15) though
--    it has never been gated by a policy because RLS was off. This policy
--    scopes it to exactly what the live grant already allows: SELECT only.
--    postgres/service_role need no policy -- both have rolbypassrls=true.
DROP POLICY IF EXISTS health4ai_config_hermes_worker_select ON public.health4ai_config;
CREATE POLICY health4ai_config_hermes_worker_select
  ON public.health4ai_config
  FOR SELECT
  TO hermes_worker
  USING (true);

-- ============================================================================
-- Audit trail: log this remediation + two adjacent open items as trackable
-- rows (audit_findings), not prose. All three use the REAL taxonomy values
-- confirmed live above (hygiene/structural/critical/cosmetic).
-- ============================================================================

-- Finding 1: close out the parent finding for health4ai_config itself.
-- Status left open, not resolved -- this file has been drafted but NOT
-- executed against the live DB as part of drafting it. Whoever applies this
-- migration must run the verification queries below and paste the literal
-- output into resolution_notes before flipping status to resolved.
INSERT INTO audit_findings
  (pass, severity, title, description, evidence, recommendation, assigned_to, status)
VALUES (
  'health4ai-rls-remediation-2026-07-15',
  'hygiene',
  'health4ai_config: RLS disabled entirely (remediated, pending live verification)',
  'health4ai_config was created via an ad-hoc SQL-editor snippet in ' ||
  'docs/content-pipeline/CAMILLE-SCHEDULER-SPEC.md and FOUNDING-BATCH-COPY.md ' ||
  '(2026-06-21 SEO/AEO sprint) instead of supabase/migrations/, so it never ' ||
  'received ENABLE ROW LEVEL SECURITY. Parent finding severity LOW maps to ' ||
  'hygiene here -- no anon/authenticated grant exists and the one documented ' ||
  'anon-read feature (landing-page countdown) was never implemented in web/src/.',
  'Pre-change (2026-07-15): pg_class.relrowsecurity=false, relforcerowsecurity=false; ' ||
  'pg_policies returns 0 rows; role_table_grants shows postgres (full), ' ||
  'service_role (full), hermes_worker (SELECT only), no anon/authenticated grants. ' ||
  'Both ad-hoc doc snippets annotated in this same change with a process-drift ' ||
  'warning pointing back at this migration (real edits applied 2026-07-15 to ' ||
  'CAMILLE-SCHEDULER-SPEC.md and FOUNDING-BATCH-COPY.md, not just proposed text).',
  'Apply this migration file, then run the two verification queries below and ' ||
  'paste the literal output plus timestamp and operator into resolution_notes ' ||
  'before setting status=resolved.',
  'Mark Vasquez',
  'open'
);

-- Finding 2: sibling tables with the identical defect, confirmed live 2026-07-15.
INSERT INTO audit_findings
  (pass, severity, title, description, evidence, recommendation, assigned_to, status)
VALUES (
  'health4ai-rls-remediation-2026-07-15',
  'hygiene',
  'health4ai_content_queue and health4ai_keyword_rankings: same RLS-disabled defect as health4ai_config',
  'Created via the same 2026-06-21 ad-hoc SQL-editor snippets as health4ai_config. ' ||
  'Not remediated by this migration -- out of scope, needs its own follow-up.',
  'Live query 2026-07-15: pg_class shows relrowsecurity=false for both tables; ' ||
  'role_table_grants shows the identical postgres/service_role/hermes_worker(SELECT) ' ||
  'pattern with no anon/authenticated grants on either table.',
  'Draft and apply a follow-up migration mirroring the policy scope above once ' ||
  'the consumer pattern for each table is verified the same way this finding was.',
  'Camille Roux',
  'open'
);

-- Finding 3: the migration-numbering collision itself (003 used twice).
INSERT INTO audit_findings
  (pass, severity, title, description, evidence, recommendation, assigned_to, status)
VALUES (
  'health4ai-rls-remediation-2026-07-15',
  'hygiene',
  'health4ai supabase/migrations/ has two files numbered 003 (real collision, not a typo)',
  'ventures/health4ai/supabase/migrations/ contains both 003_sprint1_security.sql ' ||
  'and 003_summarize_function.sql. File mtimes confirm 003_summarize_function.sql ' ||
  '(2026-05-21) predates 003_sprint1_security.sql (2026-06-19): a genuine sequence ' ||
  'collision, not a header transcription error.',
  'Directory listing 2026-07-15: 003_sprint1_security.sql (Jun 19 15:47, 1323 bytes), ' ||
  '003_summarize_function.sql (May 21 16:20, 2038 bytes). Both present and distinct; ' ||
  'neither renamed by this migration to avoid disturbing already-applied history.',
  'Confirm whether either file is already applied via a tracked migration ledger; ' ||
  'if not, rename one to fill the gap, if so, document the collision permanently ' ||
  'in a supabase/migrations/README.md.',
  'Camille Roux',
  'open'
);

-- ============================================================================
-- POST-APPLY VERIFICATION (run after applying the statements above; this
-- file has not been executed against the DB as part of drafting it). Paste
-- literal output into resolution_notes of finding 1 before marking resolved.
-- ============================================================================

-- SELECT relrowsecurity, relforcerowsecurity
--   FROM pg_class WHERE relname = 'health4ai_config';
-- SELECT policyname, roles, cmd, qual
--   FROM pg_policies WHERE tablename = 'health4ai_config';
-- BEGIN;
--   SET LOCAL ROLE hermes_worker;
--   SELECT * FROM public.health4ai_config;
-- ROLLBACK;

-- ============================================================================
-- Close-out UPDATE template (run only after the output above is captured):
-- ============================================================================
-- UPDATE audit_findings
-- SET status = 'resolved',
--     resolved_at = now(),
--     resolved_by = '<Mark Vasquez or applying operator>',
--     resolution_notes = '<paste literal verification output here, with timestamp>'
-- WHERE title = 'health4ai_config: RLS disabled entirely (remediated, pending live verification)'
--   AND pass = 'health4ai-rls-remediation-2026-07-15';
