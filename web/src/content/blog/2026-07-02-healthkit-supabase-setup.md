---
title: "How to Set Up health4ai with Supabase"
description: "Step by step: create a Supabase project, run the schema, deploy the ingest function, connect the iOS app, and query your Apple Health data from Claude Code."
pubDate: 2026-06-23
slug: "healthkit-supabase-setup"
tags: ["apple-health", "supabase", "setup", "healthkit", "mcp", "tutorial"]
draft: false
---

# How to Set Up health4ai with Supabase

This is the complete setup for health4ai. You need a Supabase project you own. The iOS app signs in with Supabase Auth and writes through a Supabase Edge Function, so Supabase is the only supported backend. health4ai itself runs no server and never receives your data.

> **Updated September 12, 2026.** An earlier version of this post had you run a different schema, skip the ingest function, and set `HEALTHKIT_USER_ID` to any string. That setup could not sync data. The schema and ingest function below were verified end to end on a fresh local Supabase stack before this update was published.

## What you need

- A free [Supabase](https://supabase.com) account
- The [Supabase CLI](https://supabase.com/docs/guides/cli), logged in
- Python for the MCP server
- health4ai on your iPhone

## Step 1: Create the project and run the schema

Create a new Supabase project. When it is ready, open its **SQL editor**, paste the contents of [health4.ai/schema.sql](https://health4.ai/schema.sql), and run it.

That file creates the tables, turns on row-level security, and removes direct client access. Health rows can only be written through the ingest function in the next step.

Don't use `supabase db push` for this. The numbered migrations in the repository are the history of one long-lived project and fail on a fresh one.

## Step 2: Deploy the ingest function

```bash
git clone https://github.com/jefflitt1/health4ai.git
cd health4ai
supabase functions deploy healthkit-ingest --project-ref <your-project-ref> --no-verify-jwt
```

Your project ref is the id in your project URL (`https://<ref>.supabase.co`). The `--no-verify-jwt` flag is intentional: the function checks the signed-in user's token itself and writes rows only under that user's ID.

## Step 3: Create your user

The app signs in but does not sign up. In the dashboard, open **Authentication → Users**, add a user with an email and password, and copy that user's **UID**. You will need it in Step 5.

## Step 4: Connect the iOS app

In the app's **Connect** tab, enter your **Project URL** and **anon key**, both in your project's API settings. If the app asks you to choose a backend, choose Supabase. Sign in as the user from Step 3, tap **Test Connection**, then start the sync.

The first sync backfills your Apple Health history, so give a large archive some time.

## Step 5: Configure the MCP server

```bash
cp mcp-server/.env.example mcp-server/.env
pip install -r mcp-server/requirements.txt
```

Edit `mcp-server/.env`:

```env
DATABASE_URL=postgresql://postgres.<project_ref>:<database_password>@<pooler_host>:6543/postgres
HEALTHKIT_USER_ID=<the UID from Step 3>
```

Two details trip people up.

- The password in `DATABASE_URL` is your **database password**. It is not the service_role key or the anon key.
- `HEALTHKIT_USER_ID` must be the exact UID from Step 3. An email address or username will not match any rows.

## Step 6: Add it to Claude Code

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

Run `/mcp` to confirm `health4ai` is listed, then ask: *"Give me a health summary for the last 7 days."*

## Troubleshooting

**The app can't sync.** Check that Step 2 succeeded and that you signed in as a user that exists in this project. Sync writes only through the ingest function.

**A metric comes back empty.** Read its `data_status`. iOS reports a Health permission you haven't granted as an empty result, which looks exactly like a day with no data. Turn the metric on under Health → Sharing → Apps → health4ai, then sync again.

**The MCP server doesn't start.** Run `python mcp-server/main.py` directly to see the error. Most often `DATABASE_URL` is using a key instead of the database password.

**Prove your setup is isolated.** On a fresh project, `scripts/verify_tenant_isolation.py` creates two throwaway users, syncs samples as each, confirms neither can see the other's rows, and deletes both. It fails if nothing was actually written.
