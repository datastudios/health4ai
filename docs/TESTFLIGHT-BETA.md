# Private TestFlight beta

> **Scope note added 2026-09-04.** The steps below are correct for a beta where
> each tester operates their own Supabase project, which is how health4ai works.
> Two mechanical prerequisites were missing when this was written and are now in
> place: an EXTERNAL beta group (an internal group accepts only Apple IDs already
> on the developer account) and builds marked `APP_STORE_ELIGIBLE` rather than
> `INTERNAL_ONLY`. Beta App Review still has to pass before anyone outside the
> team can install.
>
> The "required test evidence" section at the bottom is no longer a manual
> checklist: `scripts/verify_tenant_isolation.py` runs it, and fails if it proves
> isolation while writing zero rows.
>
> **Corrected 2026-09-12.** Until then the script could not run at all (a missing
> `import os`), and the setup this file described could not sync a single row
> (register D353). Both are fixed: the setup below was run end to end on a fresh
> Supabase stack and the script passed all 14 checks.

## Privacy boundary

Each tester must use a Supabase project and Supabase account that they control.
Do not give a tester Jeff's project URL, anon key, account, service-role key, or
database credentials. A TestFlight group distributes the app binary; it is not a
shared health-data environment.

For the current bring-your-own-backend beta, health4ai does not provision an
account or backend for the tester. The tester follows [docs/SETUP.md](SETUP.md): creates
their own Supabase project, runs `web/public/schema.sql` in its SQL editor (generated from
`supabase/bootstrap`), deploys `healthkit-ingest` with `--no-verify-jwt`, creates their
Supabase user in their own dashboard, then enters only their own project URL and anon key
in the app and signs in. **Not `supabase db push`** — the numbered migrations do not apply
to a fresh project.

## Invite safely

1. Upload a build with no prefilled endpoint, credentials, or test account.
2. In App Store Connect, create an **External Testing** group named `Private BYOB beta`.
3. Add the build and wait for Beta App Review approval.
4. Prefer individual email invitations for controlled access. App Store Connect
   administrators will see those email addresses.
5. If tester email must not appear in App Store Connect, use a public link with
   a small tester limit and platform criteria. Treat that link as shareable and
   disable it immediately when the cohort is full.
6. Give each tester the checklist below. Do not collect their Supabase credentials,
   Apple Health data, account email, or screenshots containing health data.

## Tester acceptance checklist

- Install the build on a device that has never been configured with Jeff's backend.
- Confirm the Connection screen is blank on first launch.
- Configure only a tester-owned Supabase project and account.
- Choose the default **Core activity, sleep & recovery** permission scope first.
- Confirm a sync succeeds and that the tester's database has only their own rows.
- Use **Erase Local Data & Configuration**, reinstall, and confirm no endpoint,
  credentials, account email, or sync history remains.

## Required test evidence before a wider beta

In a disposable, non-Jeff Supabase project, create two test accounts using
synthetic data. For each account, verify that an authenticated request to
`rest/v1/healthkit_metrics` is denied, while a valid `healthkit-ingest` call
writes rows only under that JWT's user ID. This proves the test measured the
isolation boundary, not merely a successful sync.
