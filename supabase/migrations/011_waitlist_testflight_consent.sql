-- health4ai — waitlist: TestFlight invite consent + invite ledger
--
-- Columns match supabase/bootstrap/001, so the table is portable between
-- projects unchanged.
--
-- WHY CONSENT IS A COLUMN AND NOT AN ASSUMPTION. Inviting someone to TestFlight
-- discloses their email address to App Store Connect, where administrators can
-- read it. The privacy policy currently says the waitlist address is used
-- "solely to notify you at App Store launch", which does not describe handing it
-- to Apple. So the flag is recorded per row, with its source, and the invite
-- path is gated on it in the database rather than only in the script that reads
-- the table.

BEGIN;

ALTER TABLE public.health4ai_waitlist
  ADD COLUMN IF NOT EXISTS consent_testflight boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS consent_source     text,
  ADD COLUMN IF NOT EXISTS invite_status      text NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS invited_at         timestamptz,
  ADD COLUMN IF NOT EXISTS asc_tester_id      text,
  ADD COLUMN IF NOT EXISTS last_error         text;

ALTER TABLE public.health4ai_waitlist
  DROP CONSTRAINT IF EXISTS health4ai_waitlist_invite_status_valid;
ALTER TABLE public.health4ai_waitlist
  ADD CONSTRAINT health4ai_waitlist_invite_status_valid
  CHECK (invite_status IN ('pending','queued','invited','failed','declined','skipped'));

-- An 'invited' row must carry the evidence that Apple accepted the tester.
-- Without this an invite run can report success while recording nothing.
ALTER TABLE public.health4ai_waitlist
  DROP CONSTRAINT IF EXISTS health4ai_waitlist_invited_has_evidence;
ALTER TABLE public.health4ai_waitlist
  ADD CONSTRAINT health4ai_waitlist_invited_has_evidence
  CHECK (invite_status <> 'invited' OR (invited_at IS NOT NULL AND asc_tester_id IS NOT NULL));

-- The real guard: a bug in the invite script must not be able to hand a
-- non-consenting address to Apple.
ALTER TABLE public.health4ai_waitlist
  DROP CONSTRAINT IF EXISTS health4ai_waitlist_invite_requires_consent;
ALTER TABLE public.health4ai_waitlist
  ADD CONSTRAINT health4ai_waitlist_invite_requires_consent
  CHECK (invite_status NOT IN ('queued','invited') OR consent_testflight);

CREATE INDEX IF NOT EXISTS health4ai_waitlist_invite_status_idx
  ON public.health4ai_waitlist (invite_status, created_at);

-- Rows that predate the consent checkbox stay consent_testflight = false. Ask
-- them, and let them answer. Backfilling the column to true would defeat the
-- entire reason it exists.

-- anon may submit an address and its consent flag. Column-level, so a caller
-- holding the publishable key cannot POST invite_status='invited' with a forged
-- asc_tester_id and corrupt the ledger.
REVOKE INSERT ON public.health4ai_waitlist FROM anon;
GRANT INSERT (email, consent_testflight, consent_source)
  ON public.health4ai_waitlist TO anon;

-- Test rows. A waitlist accumulates the operator's own probe addresses, and
-- counting them as demand or mailing them as subscribers are both wrong. Mark
-- them once, here, rather than filtering them in every consumer:
--
--   UPDATE public.health4ai_waitlist SET invite_status = 'skipped'
--   WHERE email IN ( ...your own test addresses... );

COMMIT;
