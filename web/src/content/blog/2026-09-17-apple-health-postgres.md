---
title: "Apple Health → Postgres: The Own-DB Path to Claude and Cursor"
description: "Why Apple Health + your own Postgres/Supabase is the durable path for MCP agents — HealthKit sync, schema, and how it differs from export-only stacks."
pubDate: 2026-09-17
slug: "apple-health-postgres"
tags: ["apple-health", "postgres", "supabase", "healthkit", "mcp", "own-db"]
draft: false
---

# Apple Health → Postgres: The Own-DB Path to Claude and Cursor

**Apple Health Postgres** is the search phrase people use when they already know the punchline: HealthKit on the phone is not enough. They want samples in a database they control so Claude, Cursor, or a local model can query years of history with SQL-backed MCP tools.

That is the own-DB wedge. health4.ai implements it as **HealthKit → your Supabase/Postgres → local MCP**. This post is about *why* that path exists, what "Postgres" means in practice (spoiler: Supabase Auth + Edge Functions for the iOS app), and how it differs from Health Auto Export LAN MCP and neiltron-style export+npx stacks.

Setup checklist: [/setup](/setup). Comparison matrix: [/compare](/compare). Schema and ops notes: [/docs](/docs). Tool reference: [/mcp-tools](/mcp-tools).

## Why Apple Health needs a database at all

HealthKit is an on-device store. There is no Apple-hosted query API you can call from Claude Code on a laptop in another city. Every serious bridge does one of three things:

1. Keep the query surface on the phone (local MCP / same-Wi‑Fi TCP)
2. Freeze a snapshot (XML/CSV export → file-backed MCP)
3. Mirror samples into a durable store you own (**apple health postgres** / **healthkit supabase**)

Option 3 is what you want if agents should still work when your iPhone is not on the same network as your Mac, and if "last 90 days of HRV" should be a database query rather than another manual export.

A durable store also changes how you debug. When Claude returns an empty sleep night, you can open the Supabase SQL editor and ask whether the row exists, whether `source_device` filtered it out, or whether sync stopped yesterday — without re-running a phone export.

## What "own-DB" means in health4.ai

Two halves:

**iOS app** — reads HealthKit (including background delivery via `HKObserverQuery`), signs in with Supabase Auth against a project *you* create, and posts samples to your `healthkit-ingest` Edge Function. health4.ai does not host your rows.

**MCP server** — a local Python process on your machine. It connects to Postgres with `DATABASE_URL` and `HEALTHKIT_USER_ID`, then exposes tools listed on [/mcp-tools](/mcp-tools).

So when people say *apple health supabase*, they mean the supported ingest path. When they say *apple health postgres*, they mean the query surface the MCP server sees. Both are true — with an important constraint below.

The first launch still matters: the app backfills historical HealthKit samples into your project, then observer queries keep new readings flowing. That combination is the difference between "I imported once in June" and "Claude saw this morning's HRV."

## Supabase vs "any Postgres"

The MCP server speaks ordinary Postgres. The **iOS app does not**. It needs Supabase Auth and the Edge Function deploy described in [SETUP.md](https://github.com/jefflitt1/health4ai/blob/main/docs/SETUP.md). Plain Neon, RDS, or Docker Postgres alone will not receive app writes — we documented that after measuring empty databases on the old connection-string path ([Can health4ai use Neon?](/blog/healthkit-neon-postgres)).

Practical recipe:

1. Create a free Supabase project you own
2. Run [schema.sql](https://health4.ai/schema.sql) in the SQL editor
3. Deploy `healthkit-ingest` with the Supabase CLI
4. Create an Auth user; copy the UID
5. Point the TestFlight app at Project URL + anon key and sign in
6. Point the MCP `.env` at the transaction pooler URI + that UID

That is the *healthkit supabase* path end-to-end. The MCP side is still "just Postgres." Prefer the transaction pooler connection string for the MCP process if you open many short-lived tool calls; keep the database password in env, not in chat logs.

## Schema sketch (why Postgres fits)

Samples land in a flat metrics table keyed by HealthKit type identifiers, plus a daily summaries table for longer windows. Conceptually:

```sql
-- raw samples (simplified)
healthkit_metrics (
  user_id, metric_type, value, unit,
  started_at, ended_at, source_device, metadata jsonb
)

-- aged aggregates for multi-month queries
healthkit_daily_summaries (
  user_id, metric_type, summary_date,
  avg_value, min_value, max_value, sum_value, sample_count
)
```

Indexes on `(user_id, metric_type, started_at)` make the common MCP patterns cheap: last N days of HRV, sleep stages, workouts, or an arbitrary `query_metric` call. Tier-aware tools merge recent raws with older summaries so a 90-day trend does not scan every heart-rate beat.

This is also why own-DB beats a flat JSON snapshot for agent work: you can join, filter, and re-aggregate without re-exporting the phone. For a longer schema walkthrough see [Apple Health Data Schema](/blog/apple-health-data-schema) and [Supabase as a Personal Health Database](/blog/supabase-personal-health-database).

## Contrast: Health Auto Export folk stack

Health Auto Export's MCP flow is optimized around the phone as the live endpoint — often same-Wi‑Fi TCP from Mac → iPhone. That is convenient when everything stays home.

Own-DB flips the dependency: the phone *writes* when HealthKit fires; the agent *reads* your database from anywhere with network access to Supabase. You trade "no cloud project to create" for "agents keep working on travel days."

Reliability framing matters too. Background delivery via HealthKit observers is a different mechanism than opportunistic background processing. If your pain is stale morning metrics when the Mac cannot see the phone, Postgres-backed sync is the architecture that matches the failure mode. See [/compare](/compare) for the side-by-side.

## Contrast: neiltron export + npx MCP

Export-file MCP servers are excellent for demos. You leave Apple's export UI with a large XML/CSV, wrap it, often `npx` an MCP package, and ask Claude questions against that freeze-frame.

They are a weak fit when you want continuous HealthKit observer sync into **apple health postgres**. You re-export whenever freshness matters; there is no always-on warehouse unless you build one yourself.

health4.ai does not publish an npx package yet; the supported MCP install remains clone + `pip install` + config JSON (again, [/setup](/setup)). If your goal this weekend is "prove Claude can see *any* HealthKit file," export+npx wins on time-to-first-query. If your goal is "Claude Code on Monday morning with Sunday night's sleep already ingested," own-DB wins.

## What you can ask once data is in Postgres

With MCP connected:

- "Health summary for 14 days" → aggregates over your rows
- "Compare this week's sleep to last month" → multi-tool or longer-window reads
- "Show workouts with active energy over 500 kcal" → filtered history
- Direct SQL in the Supabase editor for one-off analysis the tools do not cover

Example verification prompts after setup:

1. In Claude Code, run `/mcp` and confirm `health4ai` is connected
2. Ask for a 7-day health summary
3. Spot-check one metric in the Supabase table view or SQL editor

The point of the wedge is not a prettier chart. It is that Claude and Cursor become clients of *your* warehouse — including local Ollama setups that speak MCP against the same `DATABASE_URL`.

## Privacy and operational posture

- Rows live in your Supabase project; rotate DB passwords like any other personal infra
- Row Level Security is enabled by the shipped schema so direct client access is locked down; ingest goes through the Edge Function with your Auth user
- The MCP server runs locally — review the open-source tools code before you point it at production credentials
- Back up or pause the project like any personal database; deleting the Supabase project deletes your mirrored history (HealthKit on-device remains)
- This is not a medical device. Use outputs for personal analysis, not diagnosis

## Availability honesty

- iOS app: **invite-only TestFlight**, no public App Store page yet
- No public TestFlight link — [waitlist](/#waitlist) + consent to request an invite
- MCP: clone + Python; **no npx** package yet
- Free while in early access

## When own-DB is the wrong choice

Skip this path if you refuse to create a Supabase project, if you only need a one-time research snapshot, or if you already get reliable answers from a LAN MCP and never leave home Wi‑Fi. Own-DB is operationally heavier than `npx` against an export — that cost buys continuity and remote agents.

If you are still choosing among MCP architectures (LAN phone, export file, own-DB), start with [Apple Health MCP for Claude in 2026](/blog/apple-health-mcp-for-claude-2026), then come back here when you are ready to stand up Postgres.

---

health4ai: Free while in early access. Invite-only TestFlight — not on the public App Store yet.  
[Join the waitlist →](/#waitlist)
