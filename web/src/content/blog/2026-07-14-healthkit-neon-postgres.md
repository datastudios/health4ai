---
title: "How to Set Up health4ai with Neon (Serverless Postgres)"
description: "Neon setup walkthrough for health4ai: connection string format, schema deployment, and the key differences from a standard Postgres setup."
pubDate: 2026-07-14
slug: "healthkit-neon-postgres"
tags: ["neon", "postgres", "healthkit", "apple-health", "setup", "serverless", "mcp"]
draft: false
---

# How to Set Up health4ai with Neon (Serverless Postgres)

Neon is a serverless Postgres platform with branching, autoscaling, and a generous free tier. If you're already using Neon for other projects, it's a natural choice for health4ai's database backend. The setup is nearly identical to Supabase with one key difference: the connection string format.

## Why Neon for Health Data

Neon's serverless architecture means the database scales to zero when idle and spins up on first query. For a personal health database, this is useful — your health data doesn't need a database connection sitting open 24/7. Queries happen when Claude Code calls a tool or when your weekly n8n digest runs. The rest of the time, Neon's instance costs nothing.

The free tier supports:

- 0.5 GB storage (more than enough for years of HealthKit data)
- Autoscaling to 0 when inactive
- Database branching (useful if you want to experiment with schema changes without touching your production data)

## Step 1: Create a Neon Project

Go to [neon.tech](https://neon.tech) and create a new project. Pick a region close to you. Once provisioned, go to **Connection Details** and select **Connection string** from the dropdown. Copy the URI:

```
postgresql://[user]:[password]@[endpoint].neon.tech/[dbname]?sslmode=require
```

The `?sslmode=require` at the end is important — Neon requires SSL, and this format ensures psycopg2 uses it correctly. Don't strip the query parameter.

## Step 2: Run the Schema

```bash
git clone https://github.com/health4ai/health4ai
cd health4ai
psql "$DATABASE_URL" < web/public/schema.sql
```

Where `DATABASE_URL` is your Neon connection string. psycopg2 handles the SSL requirement automatically when `sslmode=require` is in the URL.

If you see `FATAL: remaining connection slots are reserved` — Neon's free tier limits concurrent connections. Close any other open psql sessions before running the schema.

## Step 3: Configure the MCP Server

```bash
cd mcp-server
cp .env.example .env
```

Edit `.env`:

```
DATABASE_URL=postgresql://[user]:[password]@[endpoint].neon.tech/[dbname]?sslmode=require
HEALTHKIT_USER_ID=your_user_id
```

Then install and test:

```bash
pip install -r requirements.txt
python main.py
```

The connection test queries `healthkit_metrics` on startup — you should see output confirming the table exists.

## Step 4: Add to Claude Code

The config block is identical to the Supabase setup:

```json
{
  "mcpServers": {
    "health4ai": {
      "command": "python",
      "args": ["/path/to/health4ai/mcp-server/main.py"],
      "env": {
        "DATABASE_URL": "postgresql://[user]:[password]@[endpoint].neon.tech/[dbname]?sslmode=require",
        "HEALTHKIT_USER_ID": "your_user_id"
      }
    }
  }
}
```

Restart Claude Code and run `/mcp` to confirm the server is registered.

## Step 5: iOS App

Same as any other backend — open `ios/Health4AI.xcodeproj` in Xcode, build on your iPhone (iOS 17+), and enter your Neon connection string when prompted. Tap **Start Sync** to begin the backfill.

One Neon-specific note: the first query after an idle period takes an extra second or two while the instance wakes up. This affects the very first sync after the instance has been inactive, not ongoing sync. `HKObserverQuery`-triggered syncs after the instance is warm happen at normal latency.

## Step 6: Verify

In Claude Code:

```
/mcp
```

Confirm health4ai is listed. Then: *"Give me a health summary for the last 7 days."*

You'll see Claude call `get_health_summary(days=7)` and return data from your Neon instance.

## Neon vs Supabase: Practical Differences

| | Neon | Supabase |
|---|---|---|
| Free storage | 0.5 GB | 500 MB |
| Idle behavior | Scales to zero | Always-on |
| Connection pooling | Built-in (Neon pooler) | Built-in (PgBouncer) |
| Management API | Yes | Yes |
| GUI query editor | Yes (SQL Editor) | Yes (Table Editor) |
| RLS / Auth | Available | Built-in feature |

For health4ai specifically, both work equally well. The tradeoffs are:

- Neon's scale-to-zero is nice for a database that's idle most of the time
- Supabase has a more complete managed service around the database (auth, storage, edge functions) if you plan to build anything on top
- Both have free tiers that cover personal health data volume indefinitely

## Branching for Safe Experimentation

One Neon feature worth knowing about: database branches. If you want to try schema changes or run queries against a snapshot of your data without touching the live database, you can branch from `main`:

```bash
# Neon CLI
neon branches create --name experiment --parent main
```

The branch gets its own connection string. All your health data is available (copy-on-write), and changes don't affect main. This is useful if you're experimenting with custom aggregation queries or adding indexes.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
