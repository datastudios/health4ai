---
title: "How to Query Your Apple Health Data with Claude Code"
description: "Prerequisites, MCP tool verification, and five real query examples — from health summary to long-term trends — using health4ai in Claude Code."
pubDate: 2026-07-04
slug: "query-apple-health-claude-code"
tags: ["apple-health", "claude-code", "mcp", "healthkit", "tutorial", "queries"]
draft: false
---

# How to Query Your Apple Health Data with Claude Code

This assumes health4ai is installed and your iOS app has completed its initial backfill. If you haven't done setup yet, start with the [Supabase setup guide](/blog/healthkit-supabase-setup).

## Confirming the MCP Server Is Running

Before querying anything, verify Claude Code can see the health4ai tools. Run:

```
/mcp
```

You should see `health4ai` listed as a connected server with its tools. If it's not there, the MCP config block in `claude_desktop_config.json` has an issue — check the path and restart Claude Code.

The full tool list you should see:

- `get_health_summary` — overview of key metrics for N days
- `get_sleep` — per-night sleep stage breakdown
- `get_hrv_trend` — HRV time series with trend direction
- `get_daily_snapshot` — every metric for a single date
- `get_workouts` — workout history with type, duration, calories
- `get_long_term_trend` — monthly trend for any metric
- `get_coaching_brief` — recovery/sleep/training summary
- `query_metric` — arbitrary metric time series
- `search_records` — find days where a metric crossed a threshold
- `get_metric_stats` — personal baseline stats and percentiles
- `compare_periods` — compare a metric between two date ranges

## Five Queries to Run First

### 1. Health Summary (the starting point)

Ask: *"Give me a health summary for the last 30 days."*

Claude calls `get_health_summary(days=30)` and returns average daily steps, HRV, resting heart rate, active energy, and workout count for the period. This is the quickest way to see whether the pipeline is working and what your baseline looks like.

Example output Claude might present:

```
Last 30 days:
- Avg daily steps: 8,420
- Avg HRV (SDNN): 52.3 ms
- Avg resting HR: 58 bpm
- Workouts: 14 (running 8, strength 4, cycling 2)
```

### 2. HRV Trend

Ask: *"What's my HRV trend over the last 90 days? Is it improving or declining?"*

Claude calls `get_hrv_trend(days=90)` which returns daily HRV averages and a trend comparison (last 7 days vs prior 7 days). The `trend_vs_prior_week` field in the response tells Claude the delta in milliseconds and the direction.

For windows beyond 30 days, the tool transparently queries the `healthkit_daily_summaries` table rather than raw samples — so queries over 90 days are fast and don't scan millions of rows.

### 3. Sleep Breakdown

Ask: *"Show me my sleep for the last week — stage breakdown by night."*

Claude calls `get_sleep(days=7)` and returns per-night data with Core, Deep, and REM durations. The data comes from whatever source wrote sleep stages to HealthKit — Apple Watch, Oura Ring, or any other app with HealthKit write access.

Example Claude output:

```
Last 7 nights:
Jun 17: 7h 20min (Core 3:45, Deep 1:12, REM 2:23)
Jun 16: 6h 48min (Core 3:31, Deep 0:58, REM 2:19)
Jun 15: 7h 55min (Core 4:01, Deep 1:22, REM 2:32)
Average: 7h 21min
```

### 4. Daily Snapshot

Ask: *"What does my health data look like for June 15?"*

Claude calls `get_daily_snapshot(date="2026-06-15")` and returns every metric recorded that day — steps, sleep records, workouts, HRV, resting HR, active energy, weight if logged, and any other HealthKit metrics that had data. Useful for understanding a specific day in context.

### 5. Long-Term Trend

Ask: *"Show me my resting heart rate trend over the last 2 years."*

Claude calls `get_long_term_trend(metric_type="HKQuantityTypeIdentifierRestingHeartRate", months=24)` and returns monthly averages across your full history. This is where the backfill earns its value — you can see multi-year trends that would be invisible in any 30-day dashboard.

## Combining Tools in One Conversation

Claude can chain tool calls in a single conversation. A useful pattern:

*"Compare my recovery this week to my training load last month. Are they correlated?"*

Claude will typically call:
1. `get_hrv_trend(days=7)` for recent recovery
2. `get_workouts(days=30)` for training load
3. Synthesize both into a structured answer

Or for something more specific:

*"Find any days in the last 90 days where my HRV dropped below 40ms, then check what my workout load looked like in the 48 hours before each drop."*

Claude will use `search_records` to find the low-HRV days, then `query_metric` for heart rate and workout data around those dates.

## Querying Specific HealthKit Metrics

The `query_metric` tool accepts any HealthKit quantity type identifier. Some useful ones:

```python
# Steps
query_metric(metric_type="HKQuantityTypeIdentifierStepCount", days=30)

# VO2 Max
query_metric(metric_type="HKQuantityTypeIdentifierVO2Max", days=365)

# Body weight
query_metric(metric_type="HKQuantityTypeIdentifierBodyMass", days=90)

# Blood oxygen
query_metric(metric_type="HKQuantityTypeIdentifierOxygenSaturation", days=30)

# Active energy burned
query_metric(metric_type="HKQuantityTypeIdentifierActiveEnergyBurned", days=14)
```

For windows beyond 30 days, `query_metric` returns daily aggregates (avg, min, max per day). For windows within 30 days, it returns raw samples with timestamps.

## Getting Your Personal Baseline

Once you have a few months of data, `get_metric_stats` is useful for understanding what's normal for you specifically:

Ask: *"What's my personal HRV baseline — what's a good day vs a bad day for me?"*

Claude calls `get_metric_stats(metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN", days=90)` and returns your p25/p50/p75 thresholds. Now when you ask "is my HRV good today?" Claude can answer relative to your own history rather than population averages.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
