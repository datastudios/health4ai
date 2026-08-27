---
title: "HealthKit → Supabase: Reliable Background Sync That Actually Works"
description: "Why iOS background sync is hard, why BGProcessingTask fails, and how HKObserverQuery with a Postgres backend is the only architecture that holds up in practice."
pubDate: 2026-06-23
slug: "healthkit-supabase-sync"
tags: ["healthkit", "supabase", "background-sync", "ios", "postgres", "mcp"]
draft: false
---

# HealthKit → Supabase: Reliable Background Sync That Actually Works

Getting HealthKit data syncing reliably to a remote database is harder than it looks. iOS has a set of background execution mechanisms, and the wrong one will give you data that's hours or days stale. The right one gives you near-real-time delivery.

Here's the technical difference, why most solutions use the wrong approach, and what the correct architecture looks like.

## Why Background Sync Is Hard on iOS

iOS aggressively limits what apps can do in the background. This is by design — unbounded background execution would destroy battery life. Apple provides a set of controlled mechanisms, each with different constraints:

**`BGProcessingTask`** — Intended for maintenance work like database cleanup or large uploads. iOS schedules these opportunistically, typically when the device is charging and idle. In practice, you might get one invocation per day, or none. You have no control over when it runs.

**`BGAppRefreshTask`** — Short-lived background execution (30 seconds) for fetching content. iOS throttles these based on how often the user opens the app. Low-usage apps get very few invocations.

**`HKObserverQuery`** — A HealthKit-specific mechanism where HealthKit itself delivers a notification to your app when new data matching a registered query type is added. This is push delivery from HealthKit. When your Apple Watch syncs a new HRV reading to your iPhone, HealthKit calls your registered observer immediately.

The practical difference: `BGProcessingTask` runs when iOS decides it's convenient. `HKObserverQuery` runs when HealthKit has new data. For a sync system where you want your Supabase database to reflect current readings, only one of these works.

## Why Health Auto Export's Sync Fails

Health Auto Export — the most established app in this space — uses background processing for sync rather than HealthKit observer queries. This is why users report their data in the MCP server being hours out of date.

It's not a bug in the implementation — it's the ceiling of what `BGProcessingTask` can provide. When you ask the MCP server for your HRV from this morning's Apple Watch reading, the server returns what was synced during the last background processing window. If iOS didn't schedule one today, you don't have today's data.

The same constraint applies to polling-based architectures more broadly. Any sync that works by "check for new data on a schedule" is at iOS's mercy on what that schedule actually looks like.

## The Correct Architecture: HKObserverQuery

health4ai's iOS app registers an `HKObserverQuery` for each metric type it tracks. The call looks roughly like this:

```swift
let query = HKObserverQuery(sampleType: sampleType, predicate: nil) { _, completionHandler, error in
    guard error == nil else { completionHandler(); return }
    // HealthKit delivered new data — sync it now
    Task { await syncRecentSamples(for: sampleType) }
    completionHandler()
}
healthStore.execute(query)
healthStore.enableBackgroundDelivery(for: sampleType, frequency: .immediate) { _, _ in }
```

`enableBackgroundDelivery` with `.immediate` frequency tells HealthKit to wake the app as soon as new data arrives — not on a schedule, not when the device is charging, but immediately when the sample is recorded.

This means when your Apple Watch finishes an HRV measurement and syncs it to your iPhone, HealthKit fires the observer, your app wakes, and the reading is in Supabase within seconds. The Home screen in the app shows "Last sync" and "Next sync" timestamps — in practice, "next sync" is "as soon as your watch records something."

## The Schema

The `healthkit_metrics` table stores raw samples:

```sql
CREATE TABLE IF NOT EXISTS healthkit_metrics (
    id            uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id       text        NOT NULL,
    metric_type   text        NOT NULL,  -- HKQuantityTypeIdentifier* or HKCategoryTypeIdentifier*
    value         float8,
    unit          text,                  -- 'ms', 'count/min', 'kcal', 'km', etc.
    source_device text,
    started_at    timestamptz NOT NULL,
    ended_at      timestamptz,
    metadata      jsonb,                 -- sleep stages, workout subtypes, etc.
    synced_at     timestamptz DEFAULT now() NOT NULL,
    UNIQUE (user_id, metric_type, started_at)
);
```

The `metadata` jsonb column stores type-specific fields — sleep stage values, workout type identifiers, heart rate zone data. The schema is intentionally flat: all metric types land in one table, differentiated by `metric_type`, which mirrors HealthKit's own type identifier naming convention (`HKQuantityTypeIdentifierHeartRateVariabilitySDNN`, `HKCategoryTypeIdentifierSleepAnalysis`, etc.).

For historical data beyond 30 days, samples are aggregated into `healthkit_daily_summaries`:

```sql
CREATE TABLE IF NOT EXISTS healthkit_daily_summaries (
    id            uuid        DEFAULT gen_random_uuid() PRIMARY KEY,
    user_id       text        NOT NULL,
    metric_type   text        NOT NULL,
    summary_date  date        NOT NULL,
    avg_value     float8,
    min_value     float8,
    max_value     float8,
    sum_value     float8,
    sample_count  int,
    unit          text,
    UNIQUE (user_id, metric_type, summary_date)
);
```

The MCP server's query layer is tier-aware: windows within 30 days read raw samples from `healthkit_metrics`; longer windows transparently merge daily summaries with recent raws. A query for `get_hrv_trend(days=90)` spans both tables without you needing to know which is which.

## What 5.6M Rows of HealthKit Data Looks Like

The full backfill on first launch imports your complete HealthKit history. For someone who has worn Apple Watch for a few years, this is a significant data volume — 5+ years of readings across 30+ metric types runs into millions of rows.

The three indexes on `healthkit_metrics` make this usable:

```sql
CREATE INDEX IF NOT EXISTS healthkit_metrics_user_time
    ON healthkit_metrics (user_id, started_at DESC);

CREATE INDEX IF NOT EXISTS healthkit_metrics_user_type_time
    ON healthkit_metrics (user_id, metric_type, started_at DESC);

CREATE INDEX IF NOT EXISTS healthkit_metrics_metadata
    ON healthkit_metrics USING gin(metadata);
```

The composite `(user_id, metric_type, started_at DESC)` index means queries like "give me all HRV readings for this user in the last 30 days" go straight to the right rows. The GIN index on `metadata` supports queries into the jsonb fields — workout types, sleep stage values, zone data.

In Supabase, the free tier (500MB database) handles personal data volumes comfortably. The daily summaries table keeps the raw table from growing indefinitely — samples older than 30 days are aggregated and the originals can be pruned.

## Running the Schema

```bash
psql "$DATABASE_URL" < web/public/schema.sql
```

That single command creates both tables, all three indexes, and a unified view (`v_healthkit_daily_quantity`) that unions raw and summary data. For Supabase specifically, you can also apply it via the Management API if your connection string doesn't have direct psql access:

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

Once the schema is in place and the iOS app is configured with your connection string, the sync starts immediately. The first backfill runs in the background — the app's Home screen shows a progress indicator with the record count and how far back it's reached. After that, `HKObserverQuery` keeps it current automatically.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
