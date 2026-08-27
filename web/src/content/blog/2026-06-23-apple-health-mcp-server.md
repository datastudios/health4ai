---
title: "Apple Health MCP Server: Connecting HealthKit to Claude Code"
description: "How to connect your Apple Health data to Claude Code, Cursor, or Ollama using an MCP server and a Postgres database you control."
pubDate: 2026-06-23
slug: "apple-health-mcp-server"
tags: ["apple-health", "mcp", "claude-code", "healthkit", "supabase"]
draft: false
---

# Apple Health MCP Server: Connecting HealthKit to Claude Code

There's no official API to query Apple Health data from an AI client. HealthKit is on-device only — Apple intentionally keeps it there. If you want Claude Code, Cursor, or a local Ollama model to reason over your health data, you have to build the bridge yourself.

This is how that bridge works, and what it looks like once it's running.

## What MCP Actually Is

The Model Context Protocol is an open standard for giving AI clients access to external tools and data sources. Instead of copy-pasting data into a chat window, MCP lets the AI call tools directly — structured function calls that return real data at query time.

When you add an MCP server to Claude Code, it shows up as a set of callable tools. You can ask "what was my HRV trend last month?" and the AI doesn't hallucinate an answer — it calls `get_hrv_trend(days=30)`, gets actual data from your database, and reasons over real numbers.

For health data, this matters more than for most domains. Health metrics have personal baselines that vary wildly between people, they have seasonal patterns, and they need to be correlated across multiple signals to mean anything. An AI that can actually query your history will give you categorically different answers than one guessing from general population data.

## Why Local-Only MCP Solutions Fall Short

One existing approach — used by Health Auto Export — runs the MCP server locally on your machine and connects to your AI client over TCP on the same WiFi network. This works when your laptop and iPhone are on the same network. It stops working the moment you're in Claude Code on a remote server, in a terminal session over Tailscale, or anywhere your Mac isn't reachable.

More fundamentally: the data doesn't persist anywhere. Each query goes through the iOS app in real time. There's no database you can run SQL against, no historical analysis beyond what the app can return in one response, and no way to query 5+ years of data without hitting timeouts.

The architecture that actually works uses a database as the persistent store.

## The Architecture: HKObserverQuery → Postgres → MCP

The full stack has three layers:

**iOS app** — Registers an `HKObserverQuery` for each metric type. HealthKit delivers new samples via push notification as they're recorded by Apple Watch. The app writes them to your Postgres database over TLS. Background sync uses true push delivery from HealthKit, not a polling loop or `BGProcessingTask` — this is why the sync actually works when your phone is in your pocket.

**Postgres database** — Your data, in a schema you control. Supabase works well here because the free tier covers personal data volumes, and you get a Postgres connection string immediately. Neon or a self-hosted instance work equally well.

**MCP server** — A Python process that runs on your Mac and speaks the MCP protocol. Your AI client (Claude Code, Cursor, Ollama via mcphost) calls it as a tool server. The server queries your database and returns structured JSON.

health4ai implements this full stack: the iOS app handles HealthKit sync, and the MCP server exposes the data.

## What the MCP Tools Look Like

Once connected, Claude Code has access to nine tools:

- `get_health_summary(days)` — steps, HRV, sleep, active energy, resting HR, VO2 max over N days
- `get_sleep(days)` — per-night stage breakdown (core, deep, REM, awake)
- `get_hrv_trend(days)` — daily HRV series with trend direction vs prior week
- `get_daily_snapshot(date)` — every metric for a single calendar day
- `get_workouts(days, limit)` — workout history with type, duration, calories
- `get_long_term_trend(metric, months)` — multi-year historical trend
- `get_coaching_brief()` — recovery status, sleep quality, training load in one call
- `query_metric(metric_type, days)` — arbitrary metric by HealthKit type identifier
- `search_records(query)` — find days where a metric crossed a threshold

The `query_metric` tool takes the raw HealthKit identifier string, so you can query anything in the schema — including metrics the higher-level tools don't surface:

```python
# Query VO2 max over the last year
query_metric(
    metric_type="HKQuantityTypeIdentifierVO2Max",
    days=365
)
```

## Setup in 4 Steps

**Step 1: Run the schema against your database.**

```bash
psql "$DATABASE_URL" < web/public/schema.sql
```

Get `DATABASE_URL` from Supabase under Settings → Database → Connection string (URI), from Neon's Connection Details, or use `postgresql://postgres:yourpassword@localhost:5432/postgres` for a local Docker instance.

**Step 2: Configure the MCP server.**

```bash
cd mcp-server
cp .env.example .env
# Edit .env — add DATABASE_URL and HEALTHKIT_USER_ID

pip install -r requirements.txt
python main.py  # confirm it starts without errors
```

**Step 3: Add to `claude_desktop_config.json`.**

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

This same block works in `~/.cursor/mcp.json` for Cursor. For Ollama:

```bash
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```

**Step 4: Install the iOS app, enter your database connection string, and tap Start Sync.**

The first launch runs a full backfill of your HealthKit history. Depending on how long you've had Apple Watch, this can import several years of data in one pass.

**Verify it's working:**

```
/mcp
```

Run that in Claude Code to confirm the `health4ai` server is listed. Then ask: *"Give me a health summary for the last 7 days."* You should get real data back — steps, HRV, sleep — not a refusal or a hallucination.

## What You Can Do Once It's Running

The value isn't in any single query. It's in the fact that your AI client now has a stable, queryable record of your health data that it can reference in any conversation.

Ask Claude to compare your HRV during a high-training week versus a recovery week. Ask it to find the last 10 days you slept more than 7.5 hours and correlate that with resting heart rate. Ask it to build you a weekly brief that surfaces anything worth paying attention to.

None of that requires you to know SQL or understand HealthKit's type identifier naming convention. You ask in plain language. The tools handle the query.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
