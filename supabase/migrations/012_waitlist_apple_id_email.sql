-- health4ai — waitlist: the Apple ID email is not the waitlist email
--
-- TestFlight invites go to the address attached to the tester's Apple ID, which
-- is very often NOT the address they used to join a waitlist. This is the single
-- biggest support burden for every TestFlight-distributed app: the invite lands
-- in an inbox the person never checks, and they write in asking where it is.
--
-- The 2026-09-05 heads-up email asked people to reply with the account they use
-- for the App Store. Record it here, separately, and let the invite path prefer
-- it. NULL means "not supplied" — fall back to the waitlist address.

BEGIN;

ALTER TABLE public.health4ai_waitlist
  ADD COLUMN IF NOT EXISTS apple_id_email text;

ALTER TABLE public.health4ai_waitlist
  DROP CONSTRAINT IF EXISTS health4ai_waitlist_apple_id_email_format;
ALTER TABLE public.health4ai_waitlist
  ADD CONSTRAINT health4ai_waitlist_apple_id_email_format
  CHECK (apple_id_email IS NULL
         OR (char_length(apple_id_email) <= 254 AND apple_id_email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'));

-- Normalise alongside the primary address.
CREATE OR REPLACE FUNCTION public.health4ai_waitlist_normalize_email()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.email := lower(btrim(NEW.email));
  IF NEW.apple_id_email IS NOT NULL THEN
    NEW.apple_id_email := lower(btrim(NEW.apple_id_email));
  END IF;
  RETURN NEW;
END;
$$;

-- Not granted to anon: this is set by the operator from a reply, never by the
-- public form.

COMMIT;
