---
title: "From HealthKit to Claude: An Engineering Journey"
description: "How health4ai was built — the HKObserverQuery discovery, why existing solutions fell short, key architecture decisions, and what shipping a production iOS + MCP system taught us."
pubDate: 2026-08-15
slug: "healthkit-mcp-engineering"
tags: ["engineering", "healthkit", "mcp", "ios", "architecture", "hkobserverquery", "postgres"]
draft: false
---

# From HealthKit to Claude: An Engineering Journey

Building health4ai involved learning enough about HealthKit to know why other approaches were breaking down, then building the correct architecture from scratch. This is a technical account of those decisions.

## The Problem Start

The goal was simple: ask Claude "what's my HRV trend?" and get a real answer from real data. The alternatives I looked at first all had the same failure mode — data freshness. A morning HRV reading would show up hours later, or sometimes not until the next day. The cause turned out to be BGProcessingTask.

## Discovering HKObserverQuery

BGProcessingTask fires when iOS decides to give your app background time — idle device, charging, on WiFi. This is fine for apps that need to process data they've already collected. It's wrong for health data sync because the data generation schedule (Apple Watch recording continuously) doesn't align with iOS's background scheduling.

The correct API is `HKObserverQuery`. Here's what distinguishes it:

```swift
// This is what BGProcessingTask-based apps do:
// Register a task → wait for iOS to schedule it → fetch all pending data
// Latency: potentially hours

// This is what HKObserverQuery does:
let query = HKObserverQuery(sampleType: metric, predicate: nil) { 
    _, completion, error in
    // HealthKit just wrote new data for this metric — sync it NOW
    syncToDatabase(metric) { completion() }
}
healthStore.execute(query)
healthStore.enableBackgroundDelivery(for: metric, frequency: .immediate, withCompletion: { _, _ in })
```

The key is `enableBackgroundDelivery` with `.immediate`. This tells HealthKit to wake the app as soon as new data arrives for the registered metric — not on a schedule, but immediately when the data is written.

The practical result: when Apple Watch records your morning HRV at 6:45 AM, HealthKit fires the observer, the app syncs to Postgres in the background, and the data is in your database within seconds. Not hours.

## The iOS Background Execution Window

One complication: when HealthKit wakes your app via an observer, it gives you a limited background execution window. If you don't call the completion handler before the window expires, iOS kills the process.

For single-metric syncs, this isn't a problem — fetching and writing one metric type completes in under a second. Where it gets tricky: the backfill on first launch, which might be writing millions of rows.

The backfill runs via `BGProcessingTask` (intentionally, for the one-time initial import), which gives a longer window. Ongoing sync uses observers with immediate delivery. The two mechanisms serve different purposes.

## Schema Design

The schema decision that mattered most: one table for raw samples, one for daily aggregates.

```sql
-- Raw samples (recent data — last 30 days)
healthkit_metrics: user_id, metric_type, value, unit, started_at, ended_at, source, metadata

-- Daily aggregates (historical — beyond 30 days)  
healthkit_daily_summaries: user_id, metric_type, date, avg_value, min_value, max_value, sum_value, sample_count
```

Raw heart rate data is sampled continuously — every 5-10 seconds during activity, every few minutes at rest. Storing individual samples long-term produces tables with hundreds of millions of rows. For historical analysis (what was my average HRV in March 2024?), you don't need the raw samples — you need the daily aggregate.

The 30-day cutoff is the point where raw samples age out and daily summaries are authoritative. Recent data is raw (for precise queries); historical data is pre-aggregated (for fast queries). The MCP server routes transparently between the two tables based on the query window.

## MCP Server Architecture

The MCP server is ~1100 lines of Python. The structure is simple:

```
main.py          — MCP protocol, tool registration, request routing
tools.py         — Tool implementations, DB queries, aggregation logic
```

Each public function in `tools.py` is a tool. The function signature defines the parameters. The docstring becomes the tool description that the AI client reads to know when to call it.

The hardest part of the MCP server wasn't the tool implementations — it was getting the aggregation logic right for the tiered data model. `get_hrv_trend(days=90)` needs to merge 60 days of pre-aggregated daily summaries with 30 days of raw samples, deduplicate, sort, and compute the trend comparison. The raw and summary data have different schemas (raw has timestamps, summaries have dates) and require different aggregation methods (weighted mean for rate metrics, sum-then-average for cumulative metrics like steps).

Getting the distinction between rate metrics (HRV, heart rate) and cumulative metrics (steps, active energy) right took iteration. For rate metrics, the correct aggregate is a sample-weighted mean — not a mean of daily averages, which introduces bias when day lengths differ. For cumulative metrics, the daily total is what matters, and the aggregate is the mean of daily totals.

## What Shipping a Production iOS App Taught Us

**HealthKit permissions are per-metric.** You request permission for each type you want to read. Users can grant some and deny others. The app handles this gracefully — metrics without permission just don't sync.

**Background delivery is surprisingly reliable** — more reliable than I expected. Apple's own documentation is pessimistic about background execution reliability, but in practice, `HKObserverQuery` with immediate delivery works. The main failure mode is when the iPhone is off or out of battery, not iOS throttling.

**Connection string UX matters.** Asking users to paste a Postgres connection string is friction. The onboarding screen shows a direct link to the Supabase dashboard page where the connection string lives, with instructions. This reduced setup abandonment significantly.

**MCP testing is tedious without tooling.** Testing an MCP server requires running an MCP client and manually inspecting tool call behavior. The workflow for iteration was: edit `tools.py` → restart the MCP server → ask Claude Code to call the tool → inspect the JSON response. Not elegant, but workable.

## What We'd Do Differently

The two-table schema works, but the 30-day raw/summary cutoff is somewhat arbitrary. A sliding window where the raw data is actively summarized as it ages would be cleaner than a hard cutoff. This is on the roadmap.

The MCP server creates a new psycopg2 connection per tool call. Connection pooling would reduce latency for tools that chain multiple tool calls in sequence (the `get_coaching_brief` tool makes 8 database queries). Worth addressing if multiple rapid tool calls become the primary usage pattern.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
