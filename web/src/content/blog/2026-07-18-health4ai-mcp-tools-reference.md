---
title: "The health4ai MCP Tools Reference — All 11 Tools Explained"
description: "Complete reference for every health4ai MCP tool: parameters, return structure, example calls, and when to use each one."
pubDate: 2026-07-18
slug: "health4ai-mcp-tools-reference"
tags: ["mcp", "healthkit", "apple-health", "reference", "tools", "claude-code"]
draft: false
---

# The health4ai MCP Tools Reference — All 11 Tools Explained

health4ai exposes 11 MCP tools. Here's what each one does, its parameters, what it returns, and when to reach for it instead of another tool.

## Architecture Note

The MCP server uses a two-tier storage architecture:

- **Raw data (last 30 days):** `healthkit_metrics` table — individual HealthKit samples with timestamps
- **Summarized data (beyond 30 days):** `healthkit_daily_summaries` table — pre-aggregated daily values

Most tools handle this transparently. When a tool queries a 90-day window, it reads from the summary table for days 30-90 and from raw samples for the last 30 days, merges them, and returns a single coherent series. This is why long-window queries are fast.

---

## get_health_summary(days)

**What it does:** Returns an overview of key health metrics for the past N days — steps, HRV, resting HR, and workouts.

**Parameters:**
- `days` (int, default 7) — how many days to look back

**Returns:** Avg daily steps, HRV mean and latest, resting HR mean and latest, workout count and types.

**When to use:** Starting point for any health conversation. Fast, broad, doesn't require knowing which metric you care about. Good for "how have I been doing" questions.

**Example:**
```python
get_health_summary(days=30)
```

---

## get_sleep(days)

**What it does:** Per-night sleep breakdown with Core, Deep, and REM stage durations for each night.

**Parameters:**
- `days` (int, default 7)

**Returns:** Average sleep hours across the window, and a list of nights with per-stage durations (in minutes), total minutes, and individual segment records.

**When to use:** Any sleep-specific question. More detailed than the sleep summary in `get_health_summary`. Note: only returns stage data if a source that writes sleep stages to HealthKit is present (Apple Watch in watchOS 9+, Oura, etc.).

**Example:**
```python
get_sleep(days=14)
```

---

## get_hrv_trend(days)

**What it does:** HRV (SDNN) time series with daily averages, overall mean, and trend direction (last 7 days vs prior 7 days).

**Parameters:**
- `days` (int, default 30)

**Returns:** `avg_hrv_ms`, `latest_hrv_ms`, `days_with_data`, `trend_vs_prior_week` (delta + direction), and a `daily_averages` array.

**When to use:** Recovery monitoring. HRV trend analysis. Before intensity decisions. Better than `query_metric` for HRV because it calculates the trend comparison automatically.

**Example:**
```python
get_hrv_trend(days=90)
```

---

## get_daily_snapshot(date)

**What it does:** Every HealthKit record for a specific calendar date — all metric types, all values, all sources.

**Parameters:**
- `date` (str, YYYY-MM-DD, default today)

**Returns:** Total record count, highlights (steps, active energy, resting HR, HRV, weight), workout details, sleep record count, and `all_metrics` dict with every metric type recorded that day.

**When to use:** "What happened on this specific day?" questions. Also useful for debugging sync — if a day looks thin, you can see what metrics have data and which don't.

**Example:**
```python
get_daily_snapshot(date="2026-06-15")
```

---

## get_workouts(days, limit)

**What it does:** Recent workouts with type, duration, distance, and calories burned.

**Parameters:**
- `days` (int, default 30)
- `limit` (int, default 20) — max workouts to return

**Returns:** Total workout count, total hours, breakdown by type, and a list of individual workouts with date, type, duration, distance, and calories.

**When to use:** Training log questions. Load analysis. Checking workout frequency by type. Works with any workout type logged in the Health app (running, strength, cycling, swimming, etc.).

**Example:**
```python
get_workouts(days=30, limit=50)
```

---

## get_long_term_trend(metric_type, months)

**What it does:** Monthly-aggregated trend for any HealthKit metric over multi-month windows.

**Parameters:**
- `metric_type` (str) — HealthKit quantity type identifier
- `months` (int, default 24)

**Returns:** Overall avg, min, max, monthly trend array (each month: avg, days with data, data sources), and full daily data points.

**When to use:** Seasonal analysis. Year-over-year comparisons. "Has my resting HR improved over the last 2 years?" questions. The monthly bucketing makes multi-year trends readable.

**Example:**
```python
get_long_term_trend(
    metric_type="HKQuantityTypeIdentifierRestingHeartRate",
    months=24
)
```

Common metric type identifiers:
- Steps: `HKQuantityTypeIdentifierStepCount`
- HRV: `HKQuantityTypeIdentifierHeartRateVariabilitySDNN`
- Resting HR: `HKQuantityTypeIdentifierRestingHeartRate`
- VO2 Max: `HKQuantityTypeIdentifierVO2Max`
- Weight: `HKQuantityTypeIdentifierBodyMass`
- Active energy: `HKQuantityTypeIdentifierActiveEnergyBurned`

---

## get_coaching_brief()

**What it does:** Structured pre-session coaching summary combining recovery, sleep, training load, activity, and fitness markers.

**Parameters:** None.

**Returns:** Recovery block (HRV latest/7d avg/trend/coaching note, resting HR), sleep block (7-night avg, quality flag), training load (30d workouts, hours, type breakdown, weekly avg), 7d activity (avg steps, avg active energy), fitness markers (VO2 max, weight).

**When to use:** Start of any coaching or performance planning session. The `coaching_note` field translates HRV trend into a plain-English training recommendation.

**Example:**
```python
get_coaching_brief()
```

---

## query_metric(metric_type, days, limit)

**What it does:** Raw time series for any HealthKit metric type.

**Parameters:**
- `metric_type` (str) — HealthKit identifier
- `days` (int, default 7)
- `limit` (int, default 200) — applies to raw-mode queries only

**Returns:** For windows ≤30 days: raw samples with timestamps. For windows >30 days: daily aggregates (avg, min, max per day).

**When to use:** Any metric not covered by a dedicated tool. Blood oxygen, body fat %, blood glucose, respiratory rate, nutrition data, flights climbed — anything in HealthKit can be queried with this tool.

**Example:**
```python
# Blood oxygen last 7 days (raw samples)
query_metric(metric_type="HKQuantityTypeIdentifierOxygenSaturation", days=7)

# VO2 max over 1 year (daily aggregates)
query_metric(metric_type="HKQuantityTypeIdentifierVO2Max", days=365)
```

---

## search_records(metric_type, days, min_value, max_value, limit)

**What it does:** Finds days where a metric crossed a threshold. For cumulative metrics (steps, calories), filters on daily total. For rate metrics (HRV, heart rate), filters on daily average.

**Parameters:**
- `metric_type` (str)
- `days` (int, default 90)
- `min_value` (float, optional)
- `max_value` (float, optional)
- `limit` (int, default 100)

**Returns:** Matching days sorted highest-to-lowest, with date, value, and data source.

**When to use:** Finding outliers and anomalies. "Show me days where my HRV was below 40ms." "Find my 10 highest step count days." "What nights was my sleep under 6 hours?"

**Example:**
```python
# Days with HRV below 40ms in last 90 days
search_records(
    metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    max_value=40,
    days=90
)

# Days with 12,000+ steps
search_records(
    metric_type="HKQuantityTypeIdentifierStepCount",
    min_value=12000,
    days=90
)
```

---

## get_metric_stats(metric_type, days)

**What it does:** Personal baseline statistics — min, max, mean, std dev, and percentile distribution (p10 through p90) for any metric.

**Parameters:**
- `metric_type` (str)
- `days` (int, default 90)

**Returns:** Data point count, min, max, mean, std dev, percentiles (p10/p25/p50/p75/p90), and `thresholds` dict with `good_day_above` (p75) and `poor_day_below` (p25).

**When to use:** "Is today's reading good or bad for me?" questions. Pair with `get_daily_snapshot` to compare today against your personal baseline.

**Example:**
```python
get_metric_stats(
    metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    days=90
)
```

---

## compare_periods(metric_type, period_a_start, period_a_end, period_b_start, period_b_end, label_a, label_b)

**What it does:** Compares a health metric between two arbitrary date ranges.

**Parameters:**
- `metric_type` (str)
- `period_a_start`, `period_a_end` (str, YYYY-MM-DD)
- `period_b_start`, `period_b_end` (str, YYYY-MM-DD)
- `label_a`, `label_b` (str, optional) — friendly names for the periods

**Returns:** Per-period stats (avg, min, max, data points) and a comparison block (delta, pct_change, verdict).

**When to use:** Before/after comparisons. "Did my sleep improve after I started going to bed earlier?" "How did my HRV compare during vacation vs a normal work week?"

**Example:**
```python
compare_periods(
    metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    period_a_start="2026-03-01",
    period_a_end="2026-03-31",
    period_b_start="2026-06-01",
    period_b_end="2026-06-18",
    label_a="March",
    label_b="June"
)
```

---

## Tool Selection Guide

| Question type | Tool to reach for |
|---|---|
| "How have I been doing overall?" | `get_health_summary` |
| "How was my sleep?" | `get_sleep` |
| "What's my HRV doing?" | `get_hrv_trend` |
| "What happened on [date]?" | `get_daily_snapshot` |
| "What workouts did I do?" | `get_workouts` |
| "Long-term trend for [metric]?" | `get_long_term_trend` |
| "What's my recovery status?" | `get_coaching_brief` |
| "What's [specific metric] data?" | `query_metric` |
| "Find days where [threshold]?" | `search_records` |
| "Is today normal for me?" | `get_metric_stats` |
| "Compare [period A] vs [period B]?" | `compare_periods` |

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
