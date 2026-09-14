# health4ai — Setup Guide

health4ai moves your Apple Health data into a **Supabase project you own**, and a local MCP
server lets your AI client query it. health4ai runs no backend and never receives your data.

**Supabase only.** The iOS app signs in with Supabase Auth and writes through a Supabase Edge
Function (`healthkit-ingest`). Plain Postgres — Neon, a local Docker container — has neither,
and health4ai ships no other ingest path.

> Verified 2026-09-12 end to end on a fresh local Supabase stack: this schema plus this function
> accepted synced samples, and `scripts/verify_tenant_isolation.py` passed all 14 checks.

## Step 1: Create the schema

1. Create a project at [supabase.com](https://supabase.com).
2. Open the project's **SQL editor**, paste the contents of
   [`web/public/schema.sql`](../web/public/schema.sql) (also served at
   https://health4.ai/schema.sql), and run it.

`schema.sql` is generated from `supabase/bootstrap/001` + `002` by `scripts/build_schema_sql.sh`:
the tables, row-level security, and grants that deny clients direct access. Health rows can only
be written through the ingest function in Step 2.

**Do not run `supabase db push`.** The numbered files in `supabase/migrations/` are the history of
one long-lived project and do not apply to a fresh one — they fail at
`004_sleep_nightly_view.sql`.

## Step 2: Deploy the ingest function

Needs the [Supabase CLI](https://supabase.com/docs/guides/cli), logged in to your account.

```bash
git clone https://github.com/jefflitt1/health4ai.git
cd health4ai
supabase functions deploy healthkit-ingest --project-ref <your-project-ref> --no-verify-jwt
```

`--no-verify-jwt` is deliberate. The function checks the caller's Supabase token itself, rejects
anyone who is not a signed-in user of your project, and writes rows only under that user's ID.

## Step 3: Create your user

The app signs in; it does not sign up. In your project dashboard, open **Authentication → Users**,
add a user with an email and password, and copy that user's **UID** — Step 5 needs it.

## Step 4: Connect the iOS app

1. Install health4ai (TestFlight or the App Store).
2. In the **Connect** tab, enter your **Project URL** and **anon key**, both in your project's API
   settings. If the app offers a choice of backend, choose Supabase.
3. Sign in as the user from Step 3, tap **Test Connection**, then start the sync.

The first sync backfills your HealthKit history, which takes a while on a large archive.
For TestFlight cohorts, also follow [Private TestFlight beta](TESTFLIGHT-BETA.md).

## Step 5: Configure the MCP server

```bash
cp mcp-server/.env.example mcp-server/.env
# Edit .env — set DATABASE_URL and HEALTHKIT_USER_ID
pip install -r mcp-server/requirements.txt
```

- `DATABASE_URL` — your project's **Transaction pooler** connection string. The password in it is
  your **database password**, not the service_role key or the anon key.
- `HEALTHKIT_USER_ID` — the **UID** you copied in Step 3. It must be that exact UUID; an email
  address will not match anything.

`mcp-server/.env.example` documents every variable the server reads.

## Step 6: Add it to your AI client

**Claude Code / Claude Desktop** — add to `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "health4ai": {
      "command": "python",
      "args": ["/path/to/health4ai/mcp-server/main.py"],
      "env": {
        "DATABASE_URL": "postgresql://...",
        "HEALTHKIT_USER_ID": "<your auth user UID>"
      }
    }
  }
}
```

**Cursor** — same block in `~/.cursor/mcp.json`.

**Ollama (local model)** — the model runs on your hardware; your health data is still read from
your Supabase project.

```bash
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```

## Step 7: Verify

Run `/mcp` in Claude Code to confirm the `health4ai` server is listed, then ask your client:
*"Give me a health summary for the last 7 days."*

If a metric comes back empty, read its `data_status` before believing it: iOS reports a denied
Health permission as an empty result, indistinguishable from a day with no data.

### Optional: prove isolation on a fresh project

```bash
./scripts/verify_tenant_isolation.py --url https://<ref>.supabase.co \
  --publishable <anon key> --service-role <service_role key>
```

It creates two throwaway users, syncs samples as each, proves neither can read the other's rows or
write directly, deletes both, and exits non-zero if nothing was actually written. Run it only
against a project you own. The service_role key ends up in your shell history — clear it after.

## Updating an existing project

If your project was set up before 2026-09-13, do these in order. If you already ran the
2026-09-13 upgrade, run only step 4.

1. Pull the latest code in your health4ai clone: `git pull`. Redeploying from an old clone
   ships the old function again.
2. Run [`supabase/upgrades/2026-09-13_merged_hours.sql`](../supabase/upgrades/2026-09-13_merged_hours.sql)
   in the Supabase SQL editor.
3. Redeploy the function:

   ```bash
   supabase functions deploy healthkit-ingest --project-ref <your-project-ref> --no-verify-jwt
   ```

4. Run [`supabase/upgrades/2026-09-14_replace_merged_hours_per_hour.sql`](../supabase/upgrades/2026-09-14_replace_merged_hours_per_hour.sql)
   in the SQL editor. Without it, a project with more than a few months of history never
   finishes syncing activity types: the 2026-09-13 function full-scans the table and times out.

5. Force-quit and reopen the app. It asks your server what it supports once per launch.

Until you do, the app's Home screen says **Server update needed**. An iPhone and an Apple Watch
both count the same steps. Apple Health shows one figure because it merges them, and the current
app sends that merged total per hour, but only to a function that removes the per-device rows
those hours replace. An older function cannot, so the app keeps sending per-device samples and
steps, distance and energy are counted twice wherever both devices recorded them.

After the update the app re-sends those activity types' history once. Each hour it sends replaces
that hour's per-device rows, so totals correct themselves as the import runs. Don't re-run the
bootstrap files on an existing project: they create policies that already exist and fail.
