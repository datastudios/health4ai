# health4ai — TestFlight Tester Checklist

Updated: 2026-09-12.

> **STOP — this checklist describes a private beta among people who can operate a
> database. Re-measured 2026-09-04 against the live systems rather than against
> this file, which disagreed with all of them.**
>
> - **Build 21 is VALID in App Store Connect.** This file previously said 17,
>   `project.pbxproj` says 15. Ask the App Store Connect API, not a file.
> - **Builds come from Xcode Cloud, not from Xcode on a laptop.** Build runs map
>   1:1 onto build numbers, each triggered by a push to `main`. There is no
>   distribution certificate on the dev machine, which is the tell.
> - **Every build up to 21 was `buildDistributionAudience: INTERNAL_ONLY`**, set
>   by the Xcode Cloud workflow's archive action. That is why external assignment
>   failed with `422 Build is not in an externally assignable state`, and it is
>   NOT patchable after upload — `PATCH /v1/builds/{id}` returns `409`. Fixed at
>   the workflow; builds from 22 on are `APP_STORE_ELIGIBLE`.
> - **The external group `Waitlist beta` now exists.** Before that the only group
>   was internal, which accepts only Apple IDs already on the developer account.
> - **The GitHub release workflow has never run** — 0 of 7 required secrets.
>
> Bring-your-own-backend is the product, not a limitation: each tester points the
> app at a backend they control, and health4ai never receives anyone's health
> data. `supabase/bootstrap/001` + `002` are the schema a tester installs in
> their own project. Prove isolation with `scripts/verify_tenant_isolation.py`.

---

## What's been done

- [x] PrivacyInfo.xcprivacy wired into Xcode build target
- [x] Team ID Z3D54X3D96 across all build configs
- [x] Privacy Policy live at https://health4.ai/privacy
- [x] App created in App Store Connect (com.jglittell.health4ai)
- [x] health4.ai cloud backend removed — app is self-hosted only (Supabase; the REST option never synced and is removed on the pre-1.0 branch)
- [x] Hosted-tier DB tables dropped from Supabase (healthkit_api_keys, healthkit_setup_codes)
- [x] Tenant-isolation migration and authenticated ingest safeguards added
- [x] New installs default to a minimal Health data scope; existing completed installs retain their current scope
- [x] Uploads happen through Xcode by hand — build 21 VALID as of 2026-09-04 (the GitHub workflow below is scaffolding, 0 of 7 secrets set)
- [x] GitHub-gated TestFlight release workflow added; see [`docs/GITHUB-TESTFLIGHT.md`](docs/GITHUB-TESTFLIGHT.md)

---

## STEP 1 — Release through GitHub (recommended)

Use the protected, manual/tagged GitHub Action described in
[`docs/GITHUB-TESTFLIGHT.md`](docs/GITHUB-TESTFLIGHT.md). It creates a unique
UTC build number, records the commit that shipped, and uploads a build eligible
for both internal and external TestFlight groups.

## Manual fallback — Archive and Upload (Xcode, ~15 min)

1. Open the `Health4AI.xcodeproj` in the release worktree
2. Top bar: scheme **Health4AI**, destination **Any iOS Device (arm64)**
3. **Product → Archive** — wait ~2–3 min
4. Organizer opens → select the new archive → **Distribute App**
5. **App Store Connect → Upload** → leave all checkboxes default → Next → Upload
6. Wait for processing in App Store Connect (~5–20 min)

---

## STEP 2 — Add the Tester (App Store Connect, ~5 min)

1. https://appstoreconnect.apple.com → your app → **TestFlight**
2. **Internal Testing** → select the processed build you intend to test
3. **Add Testers** → enter their Apple ID email
4. They get a TestFlight invite email; they install the TestFlight app and accept

> Internal testers don't need a review wait. External testers (non-Apple-ID-on-your-account) require a one-time Beta App Review (~24–48 hr). Add yourself first to confirm the build works, then add external testers.

---

## STEP 3 — What the Tester Sees

**Onboarding flow (3 steps):**
1. Welcome screen
2. Privacy explanation
3. HealthKit permission grant, with a choice of Essentials (default) or every supported type

**Connection screen:**
- One backend: a **Supabase** project the tester owns. Builds up to 28 still show a REST / Webhook option; it never synced a row.
- Paste the Project URL + anon key for a project they control → sign in as a user created in that project's dashboard → Test Connection
- No health4.ai account, no setup code, no cloud option

**What they need before testing:**
- A free Supabase project with `web/public/schema.sql` run and `healthkit-ingest` deployed — follow [`docs/SETUP.md`](docs/SETUP.md)

> Send testers to [`docs/TESTFLIGHT-BETA.md`](docs/TESTFLIGHT-BETA.md). They must use a separate Supabase project/account from Jeff's production setup, and follow [`docs/SETUP.md`](docs/SETUP.md). **Not `supabase db push`** — the numbered migrations fail on a fresh project. The legacy `web/functions/ingest.js` proxy was retired 2026-09-12.

For a small, known group, use an App Store Connect internal or external TestFlight group with email invites. A public link is only appropriate with a tester cap and acceptance criteria, because it can be forwarded. External testers require Beta App Review.

---

## KNOWN GAP — Background delivery (re-enable after the iOS 27 GM retest, register A56)

`com.apple.developer.healthkit.background-delivery` is disabled due to an iOS 27 Beta XPC crash.
When the crash is confirmed gone on the iOS 27 GM:
1. `ios/Health4AI/Health4AI.entitlements` → add `<key>com.apple.developer.healthkit.background-delivery</key><true/>`
2. `ios/Health4AI/Info.plist` → restore UIBackgroundModes + BGTaskSchedulerPermittedIdentifiers
3. Re-archive, bump build number, upload

---

## App Store listing metadata (for when you submit for public review)

**Subtitle:** Your health data, your database

**Description:**
health4ai syncs your Apple Health data directly to a Postgres database you control — no middleman, no subscription, no lock-in.

Connect a Supabase project (or compatible HTTPS endpoint) you control, grant the HealthKit access you choose, and health4ai syncs those health samples to your own database.

**Your data stays yours**
- health4ai does not provide a shared health-data backend
- All sync is device-to-your-database
- Revoke access anytime in iPhone Settings → Privacy & Security → Health

**Built for AI workflows**
Pair with the health4ai MCP server to give Claude, ChatGPT, or any AI assistant direct access to your personal health history.

**Keywords:** health data,HealthKit,Supabase,AI health,health export,personal health,health sync,HRV,sleep data
**Support URL:** https://health4.ai
**Privacy Policy URL:** https://health4.ai/privacy
**Category:** Health & Fitness | **Price:** Free | **Age Rating:** 4+

**Review Notes:**
health4ai requires HealthKit access to read Apple Health data and sync it to a user-configured Postgres database endpoint. The app does not write health data. To test, the reviewer can configure any Supabase project (free tier at supabase.com). No special test credentials are needed.
