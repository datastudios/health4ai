---
title: "Supabase as a Personal Health Database: Why It Works"
description: "Why Postgres is the right choice for HealthKit data, how Supabase's free tier handles the data volume, schema overview, and RLS for privacy."
pubDate: 2026-08-11
slug: "supabase-personal-health-database"
tags: ["supabase", "postgres", "healthkit", "apple-health", "schema", "rls", "personal-database"]
draft: false
---

# Supabase as a Personal Health Database: Why It Works

The choice of database backend for HealthKit data deserves more consideration than it usually gets. Health data is time-series, has specific query patterns (recent data accessed frequently, historical data occasionally), and benefits from predictable schema. Postgres is the right tool for this. Supabase makes Postgres trivially accessible. Here's why the combination works and what you need to know about the schema.

## Why Postgres (Not a Time-Series Database)

Time-series databases (InfluxDB, TimescaleDB, QuestDB) seem like the obvious choice for sensor data. They're optimized for time-ordered inserts and time-window queries. But for personal health data, the advantages don't justify the operational complexity:

**Query patterns are mixed.** You do time-window queries ("HRV for the last 30 days") but also aggregations ("monthly averages over 2 years"), joins across metric types, and arbitrary filtering ("all days where sleep was under 6 hours"). Postgres handles all of these well. Dedicated time-series DBs are optimized for the first pattern and require more work for the others.

**Volume is manageable.** Even 5 years of Apple Watch data is a few million rows — well within Postgres's performance sweet spot with basic indexing. You're not operating at the scale where a time-series DB's ingest optimization matters.

**LLM tool integration is easier.** MCP servers and most AI integration tooling assumes a standard Postgres connection. SQL is the lingua franca. Building tool functions over Postgres is straightforward; building them over InfluxDB's Flux query language is not.

**Supabase's ecosystem.** Auth, storage, edge functions, Row Level Security, the dashboard, the MCP ecosystem — all of this is built for Postgres. You get a richer operational environment.

## Supabase Free Tier: What You Get

The Supabase free tier includes:

- 500 MB database storage
- Unlimited API requests
- 2 projects
- 7-day log retention
- Authentication (not needed for health4ai but available)
- Dashboard and SQL editor

500 MB is more than enough for years of HealthKit data. The `healthkit_metrics` table stores individual samples as rows — each row is roughly 300-400 bytes depending on the metadata. Five million rows is around 1.5-2 GB of raw data, but with compression and the tiered summary table, the active database footprint stays manageable.

If you approach the limit (you won't for personal use), Supabase Pro is $25/month for 8 GB — still inexpensive for what you get.

## The Schema

health4ai uses two tables:

### healthkit_metrics

Stores raw HealthKit samples:

```sql
CREATE TABLE healthkit_metrics (
    id          BIGSERIAL PRIMARY KEY,
    user_id     TEXT NOT NULL,
    metric_type TEXT NOT NULL,     -- HKQuantityTypeIdentifierStepCount, etc.
    value       DOUBLE PRECISION,
    unit        TEXT,
    started_at  TIMESTAMPTZ NOT NULL,
    ended_at    TIMESTAMPTZ,
    source_name TEXT,
    source_device TEXT,
    metadata    JSONB
);

CREATE INDEX ON healthkit_metrics (user_id, metric_type, started_at DESC);
```

The composite index on `(user_id, metric_type, started_at DESC)` covers the primary query pattern: "give me all HRV samples for this user in the last 30 days." Most MCP tool queries hit this index.

### healthkit_daily_summaries

Pre-aggregated daily data for historical queries:

```sql
CREATE TABLE healthkit_daily_summaries (
    id           BIGSERIAL PRIMARY KEY,
    user_id      TEXT NOT NULL,
    metric_type  TEXT NOT NULL,
    date         DATE NOT NULL,
    avg_value    DOUBLE PRECISION,
    min_value    DOUBLE PRECISION,
    max_value    DOUBLE PRECISION,
    sum_value    DOUBLE PRECISION,
    sample_count INTEGER,
    UNIQUE (user_id, metric_type, date)
);

CREATE INDEX ON healthkit_daily_summaries (user_id, metric_type, date DESC);
```

Daily summaries are generated from raw samples as they age beyond 30 days. The MCP server handles this transparently — queries beyond 30 days automatically route to this table.

## Row Level Security (Optional)

If you have more than one user accessing the same Supabase project, or if you want additional isolation, enable RLS on both tables:

```sql
ALTER TABLE healthkit_metrics ENABLE ROW LEVEL SECURITY;

CREATE POLICY "users_own_data" ON healthkit_metrics
    FOR ALL
    USING (user_id = current_setting('app.user_id')::text);
```

For a personal database used only by you, RLS adds complexity without benefit — the `user_id` filter in queries already isolates your data. For any multi-user setup (family members, or building a product), RLS is the right approach.

## Querying from the Dashboard

The Supabase SQL Editor gives you a direct query interface. Some useful queries:

**Check your metric types:**
```sql
SELECT metric_type, COUNT(*) 
FROM healthkit_metrics 
GROUP BY metric_type 
ORDER BY COUNT(*) DESC;
```

**Recent HRV samples:**
```sql
SELECT value, started_at, source_device
FROM healthkit_metrics
WHERE metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
  AND started_at >= NOW() - INTERVAL '7 days'
ORDER BY started_at DESC;
```

**Monthly average steps:**
```sql
SELECT 
  DATE_TRUNC('month', date) as month,
  AVG(avg_value)::integer as avg_daily_steps
FROM healthkit_daily_summaries
WHERE metric_type = 'HKQuantityTypeIdentifierStepCount'
GROUP BY month
ORDER BY month DESC;
```

## Connection String Details

Supabase provides two connection options relevant to health4ai:

**Direct connection** (port 5432): Use for the iOS app sync. Direct connections are appropriate for persistent connections with low parallelism.

**Transaction pooler** (port 6543): Use if you're running the MCP server in an environment where you might have many short-lived connections. The MCP server uses psycopg2, which creates a new connection per tool call by default.

The health4ai `.env` accepts either connection string. For most setups, the direct connection works fine. If you see connection limit errors (Supabase free tier allows 60 direct connections), switch to the transaction pooler at port 6543.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
