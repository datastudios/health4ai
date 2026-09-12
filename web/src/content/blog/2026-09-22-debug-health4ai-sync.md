---
title: "How to Debug Your health4ai Sync Setup"
description: "Systematic troubleshooting for health4ai sync issues — iOS app not syncing, MCP server not starting, missing data, and stale readings."
pubDate: 2026-09-22
slug: "debug-health4ai-sync"
tags: ["debugging", "sync", "healthkit", "mcp", "troubleshooting", "setup", "health4ai"]
draft: false
legacySetup: true
---

# How to Debug Your health4ai Sync Setup

Sync issues in a system with multiple components — iOS app, Postgres database, MCP server, AI client — can have multiple root causes. Here's a systematic debugging approach.

## The Full Pipeline

```
Apple Watch → HealthKit → health4ai iOS app → Postgres DB → MCP server → Claude Code
```

Debugging is easiest when you isolate which part of the pipeline has the problem.

## Step 1: Confirm the iOS App Is Syncing

Open the health4ai app on your iPhone. The Home screen shows:

- **Sync Status card:** last sync time, next scheduled sync
- **Metrics grid:** recent data for tracked metrics
- **Error indicator:** if the last sync failed, there's a visible error state

If the last sync time is recent (within the last few minutes for a waking device with active health data), the iOS app side is working.

**Common iOS app issues:**

**"Last sync: never"** — The app hasn't completed its initial connection. Check:
- HealthKit permissions were granted (Settings → Health → Data Access & Devices → health4ai)
- The database credentials were entered correctly on the Connection screen
- Network access to your Postgres host is available (try switching from WiFi to cellular, or vice versa)

**"Connection error"** — The database connection string is wrong. Common mistakes:
- Copy-pasted the connection string with extra whitespace
- Used the wrong port (Supabase direct = 5432, pooler = 6543)
- SSL mode missing from the connection string (`?sslmode=require` for Supabase/Neon)
- Password contains special characters that need URL encoding

**Test the connection string** outside the app — paste it into `psql "$DATABASE_URL"` from your Mac terminal. If that fails, the connection string is wrong.

**Backfill stuck** — The initial backfill of historical data is a large operation. If it appears stuck, check the Supabase dashboard (or query `SELECT COUNT(*) FROM healthkit_metrics`) to see if rows are being written. The backfill runs in batches; it may be in progress even if the app appears idle.

## Step 2: Verify Data Is in the Database

Once you think the iOS app is syncing, confirm data is actually in Postgres.

In the Supabase SQL Editor (or any Postgres client):

```sql
SELECT metric_type, COUNT(*) as rows, MAX(started_at) as latest_record
FROM healthkit_metrics
WHERE user_id = 'your_user_id'
GROUP BY metric_type
ORDER BY latest_record DESC
LIMIT 10;
```

What you're looking for:
- Are there rows? (If not, the iOS app isn't writing to the database)
- Is the `latest_record` recent? (If it's days old and you should have new data, sync has stalled)

**Most recent overall record:**

```sql
SELECT MAX(started_at) as last_record
FROM healthkit_metrics
WHERE user_id = 'your_user_id';
```

If `last_record` is from hours or days ago and you've been active, sync has a problem. Go back to Step 1.

## Step 3: Test the MCP Server Directly

Before testing in Claude Code, verify the MCP server starts and can query the database:

```bash
cd /path/to/health4ai/mcp-server
python main.py
```

A working server starts and waits (no output until it receives a tool call). If it throws an error, that's your problem. Common MCP server errors:

**`No database connection configured`** — `DATABASE_URL` is not in the `.env` file or not in the environment. Check `mcp-server/.env` exists and has the correct value.

**`psycopg2.OperationalError: could not connect to server`** — Database is unreachable. The same connection string that works in the iOS app should work here. Test with `psql "$DATABASE_URL"` from the same terminal.

**`ModuleNotFoundError`** — Dependencies not installed. Run `pip install -r requirements.txt` from the `mcp-server/` directory.

**Python version issues** — health4ai requires Python 3.11+ (uses `datetime.fromisoformat` with timezone parsing). Check `python --version`.

## Step 4: Verify Claude Code Can See the Tools

In Claude Code, run:

```
/mcp
```

You should see `health4ai` listed with a green status and all 11 tools. If it's not listed:

1. The `claude_desktop_config.json` has a JSON syntax error (missing comma, wrong bracket)
2. The path to `main.py` is wrong or not absolute
3. Python in the config resolves to a different installation than where you installed dependencies

**Validate the JSON:**

```bash
python3 -c "import json; json.load(open('$HOME/Library/Application Support/Claude/claude_desktop_config.json'))"
```

If that throws a `JSONDecodeError`, fix the syntax issue.

**Test the exact command in the config:**

```bash
python /path/to/health4ai/mcp-server/main.py
```

If this fails, Claude Code will fail the same way (it runs the same command).

## Step 5: Test a Tool Call

Once Claude Code shows health4ai in the MCP list, test a simple query:

*"What metrics do you have data for in my health database?"*

Claude will call `get_daily_snapshot` or `get_health_summary` and return what's in the database. If it returns actual data, the full pipeline is working. If Claude says "I don't have any health data" or "no records found":

- The `HEALTHKIT_USER_ID` in the MCP config doesn't match the `user_id` in the database
- Run `SELECT DISTINCT user_id FROM healthkit_metrics` to see what user IDs are in the database, then update the config to match

## Common Sync Patterns That Look Like Failures

**HRV missing for today** — Apple Watch measures HRV during sleep or during a Mindfulness session. If you haven't recorded either yet today, there's no HRV data for today. This is expected.

**Steps appear low** — If the query runs before the end of the day, the day's step total is partial. This is expected.

**Sleep data shows yesterday's date** — Sleep that starts before midnight and ends after midnight gets assigned to the prior day in America/New_York timezone. A sleep session starting at 11 PM on the 14th appears as date 2026-09-14 in the database, even if you woke up on the 15th.

**Oura sleep not appearing** — `get_sleep` filters to Oura data. If Oura hasn't synced to HealthKit yet (the Oura app needs to be opened or background refresh needs to run), the sleep data won't appear. Open the Oura app to force a sync.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
