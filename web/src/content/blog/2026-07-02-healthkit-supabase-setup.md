---
title: "How to Set Up health4ai with Supabase in 10 Minutes"
description: "Step-by-step: create a Supabase project, run the schema, configure the iOS app, and start querying your Apple Health data in Claude Code."
pubDate: 2026-06-23
slug: "healthkit-supabase-setup"
tags: ["apple-health", "supabase", "setup", "healthkit", "mcp", "tutorial"]
draft: false
---

# How to Set Up health4ai with Supabase in 10 Minutes

This is the complete setup walkthrough for health4ai with Supabase as your database backend. Supabase is the recommended option — their free tier covers personal use indefinitely, and the managed Postgres instance means you're not running another daemon locally.

By the end of this you'll have your Apple Health data syncing to Postgres and queryable from Claude Code.

## What You Need Before Starting

- An iPhone running iOS 17 or later with Apple Watch data (or Health app data from any source)
- Xcode installed on your Mac (for the iOS app build)
- Claude Code or Claude Desktop installed
- About 10 minutes

## Step 1: Create a Supabase Project

Go to [supabase.com](https://supabase.com) and create a new project. The free tier gives you a Postgres instance, connection pooling, and enough storage for years of health data. Pick any region — your iPhone will be sending data over TLS regardless.

Once the project is provisioned, go to **Settings → Database → Connection string** and copy the URI. It looks like:

```
postgresql://postgres:[password]@db.[project-ref].supabase.co:5432/postgres
```

That's your `DATABASE_URL`. Keep it handy for the next steps.

## Step 2: Run the Schema

Clone the health4ai repository and run the schema against your Supabase instance:

```bash
git clone https://github.com/health4ai/health4ai
cd health4ai
psql "$DATABASE_URL" < web/public/schema.sql
```

This creates the `healthkit_metrics` table (raw samples) and `healthkit_daily_summaries` table (pre-aggregated historical data), plus indexes. The schema is straightforward — no proprietary extensions, just standard Postgres.

If `psql` isn't installed locally and you'd rather use the Supabase Management API:

```bash
export SUPABASE_PAT="sbp_your_personal_access_token"
PROJECT_REF="your_project_ref"

curl -X POST \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -H "User-Agent: health4ai-setup" \
  -d @- < <(jq -Rs '{query: .}' < web/public/schema.sql)
```

Get your personal access token from Supabase → Account → Access Tokens. The project ref is the subdomain of your Supabase URL.

## Step 3: Configure the MCP Server

```bash
cd mcp-server
cp .env.example .env
```

Open `.env` and add two values:

```
DATABASE_URL=postgresql://postgres:[password]@db.[project-ref].supabase.co:5432/postgres
HEALTHKIT_USER_ID=your_user_id
```

The `HEALTHKIT_USER_ID` is any string you choose — it namespaces your data in the database. Use something like your name or "jeff". Then install dependencies and run a quick test:

```bash
pip install -r requirements.txt
python main.py
```

If it starts without errors, the database connection is working.

## Step 4: Add to Claude Code

Add the MCP server to your `claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "health4ai": {
      "command": "python",
      "args": ["/path/to/health4ai/mcp-server/main.py"],
      "env": {
        "DATABASE_URL": "postgresql://...",
        "HEALTHKIT_USER_ID": "your_user_id"
      }
    }
  }
}
```

Replace `/path/to/health4ai` with the absolute path to where you cloned the repo. Restart Claude Code, then run `/mcp` to confirm the server is registered. You'll see the health4ai tools listed.

## Step 5: Build and Run the iOS App

Open `ios/Health4AI.xcodeproj` in Xcode. Set your Development Team in **Signing & Capabilities** (a free Apple Developer account works). Build and run on your iPhone.

On first launch, the app walks you through:

1. **HealthKit permissions** — grant access to the metrics you want synced (steps, HRV, sleep, workouts, etc.)
2. **Database credentials** — paste your `DATABASE_URL` and `HEALTHKIT_USER_ID`
3. **Start Sync** — triggers the full backfill of your HealthKit history

The backfill imports your complete history — if you've had an Apple Watch for a few years, this is 5+ years of data. It runs in the background and can take a few minutes. You'll see the sync status on the Home screen. The app uses `HKObserverQuery` for ongoing sync, which means new data from Apple Watch pushes immediately rather than waiting for a background processing window.

## Step 6: Verify Everything Works

In Claude Code, ask:

*"Give me a health summary for the last 7 days."*

Claude will call `get_health_summary(days=7)` against your Supabase database and return steps, HRV, resting heart rate, and workout count. If you see real numbers from your Health app data, the full pipeline is working.

You can also run more targeted queries:

- *"What's my HRV trend over the last 30 days?"* → `get_hrv_trend(days=30)`
- *"Show me my sleep breakdown for last night."* → `get_sleep(days=1)`
- *"What workouts did I do this month?"* → `get_workouts(days=30)`

## What's in the Database

After backfill, you can query the `healthkit_metrics` table directly in the Supabase dashboard to see what was imported. Each row is a HealthKit sample: metric type (as an HKQuantityTypeIdentifier string), value, unit, started_at, ended_at, source device, and metadata.

For a multi-year dataset you might see several million rows in `healthkit_metrics`. The MCP server transparently routes queries older than 30 days to the `healthkit_daily_summaries` table, which has the same data pre-aggregated to reduce query cost.

## Troubleshooting

**MCP server doesn't start:** Check that `DATABASE_URL` in `.env` is correct and that Supabase is accessible from your network. Run `python main.py` directly to see the error.

**No data after backfill:** The backfill runs in the background — check the Home screen in the iOS app. If the sync status shows errors, verify the connection string is correct and HealthKit permissions were granted.

**Claude doesn't see the tools:** Run `/mcp` in Claude Code. If health4ai isn't listed, the config block in `claude_desktop_config.json` has a syntax error or the path is wrong.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
