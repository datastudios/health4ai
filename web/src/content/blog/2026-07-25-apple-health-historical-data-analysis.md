---
title: "Querying 10 Years of Apple Health Data with SQL and AI"
description: "What a decade of HealthKit data looks like in Postgres, how get_long_term_trend works for multi-year analysis, and what patterns AI surfaces that dashboards miss."
pubDate: 2026-07-25
slug: "apple-health-historical-data-analysis"
tags: ["apple-health", "historical-data", "sql", "postgres", "healthkit", "long-term-trend", "analysis"]
draft: false
---

# Querying 10 Years of Apple Health Data with SQL and AI

Apple Watch has been around since 2015. If you've worn one since then, you have nearly a decade of health data sitting in HealthKit — steps, heart rate, sleep (watchOS 9+), HRV, VO2 max, workouts, and more. Most of it has never been systematically analyzed, because the Health app shows you 7-day and 30-day windows, and there's been no good way to ask questions that span years.

That changes when the data is in Postgres.

## What 5+ Years of HealthKit Data Looks Like

health4ai's backfill imports your complete HealthKit history on first launch. The full import can produce millions of rows depending on how many metrics you've tracked and how long. A dataset with 5 years of Apple Watch data might include:

- ~5M+ raw samples in `healthkit_metrics` (Heart rate samples alone can be 500K+ rows)
- Several hundred thousand rows of workout, sleep, and activity data
- The `healthkit_daily_summaries` table aggregates this into daily averages for fast historical queries

After the first 30 days, raw samples age out of the primary query path and are replaced by the pre-aggregated daily summaries. This keeps the database size manageable while preserving the full historical record.

To check what you have:

```sql
SELECT 
  metric_type,
  COUNT(*) as sample_count,
  MIN(started_at) as earliest,
  MAX(started_at) as latest
FROM healthkit_metrics
GROUP BY metric_type
ORDER BY sample_count DESC;
```

Run this in the Supabase SQL Editor or any Postgres client.

## Using get_long_term_trend for Multi-Year Analysis

The `get_long_term_trend` tool handles windows up to 10 years (120 months) and returns monthly-bucketed averages:

```python
get_long_term_trend(
    metric_type="HKQuantityTypeIdentifierRestingHeartRate",
    months=60
)
```

Returns the monthly average resting HR for each of the last 60 months. The response includes `monthly_trend` (each month's avg, days with data, and data source) plus the full `daily_data` array if you need day-level resolution.

The `sources` field on each monthly bucket tells you whether the data came from raw samples (recent) or daily summaries (historical). This matters because the summary and raw tiers use the same underlying data — summaries are generated from raw samples before the 30-day cutoff — so there's no discontinuity in the trend.

## Four Multi-Year Queries Worth Running

**1. Resting HR over 5 years**

```
What's my resting heart rate trend over the last 5 years? Show monthly averages 
and highlight any periods of sustained elevation or improvement.
```

Claude calls `get_long_term_trend(metric_type="HKQuantityTypeIdentifierRestingHeartRate", months=60)` and returns a narrative of the monthly trend. You'll see things like: gradual improvement from 2022-2024 corresponding to a training period, a 3-month elevation spike in early 2025 (illness, high stress, travel), recovery through late 2025.

These patterns are invisible in a 30-day view.

**2. VO2 Max trajectory**

```
How has my VO2 max changed over the last 3 years? What's the overall direction?
```

```python
query_metric(metric_type="HKQuantityTypeIdentifierVO2Max", days=1095)
```

VO2 max is recorded less frequently (Apple Watch estimates it from outdoor run data), so a 3-year window might have 50-100 data points. The trend is still meaningful — you're looking at the direction of aerobic fitness over years, not day-to-day variation.

**3. Steps by year**

```
Compare my average daily steps in 2022, 2023, 2024, and 2025.
```

Claude uses `compare_periods` to pull each calendar year and compare average daily step totals:

```python
compare_periods(
    metric_type="HKQuantityTypeIdentifierStepCount",
    period_a_start="2023-01-01",
    period_a_end="2023-12-31",
    period_b_start="2024-01-01",
    period_b_end="2024-12-31",
    label_a="2023",
    label_b="2024"
)
```

**4. Seasonal patterns in HRV**

```
Does my HRV show seasonal patterns? Compare summer months to winter months 
over the last 3 years.
```

Claude uses `get_long_term_trend(metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN", months=36)` and groups the monthly data by season. Many people see lower HRV in winter (illness, disrupted routines, reduced outdoor activity) and higher HRV in summer. Whether that pattern holds for you specifically is only visible with multi-year data.

## Writing Direct SQL

For analysis that goes beyond what the MCP tools return, you can query the database directly. The schema is two tables:

**`healthkit_metrics`** — raw samples
```sql
SELECT 
  date_trunc('month', started_at) as month,
  AVG(value) as avg_hrv
FROM healthkit_metrics
WHERE metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
  AND user_id = 'your_user_id'
  AND started_at >= '2022-01-01'
GROUP BY month
ORDER BY month;
```

**`healthkit_daily_summaries`** — aggregated daily data (query this for historical work)
```sql
SELECT 
  date_trunc('year', date) as year,
  AVG(avg_value) as yearly_hrv_avg,
  COUNT(*) as days_with_data
FROM healthkit_daily_summaries
WHERE metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
  AND user_id = 'your_user_id'
GROUP BY year
ORDER BY year;
```

The daily summaries table is faster for historical aggregations because it's pre-grouped. Raw samples are better if you need the precise timestamps.

## What AI Surfaces That Dashboards Miss

The difference between looking at a chart and asking an AI to analyze the data:

**Charts:** "Your HRV was lower in Q1 2025."  
**AI with context:** "Your HRV dropped in Q1 2025 and stayed suppressed for 11 weeks, which is longer than your typical post-illness recovery. Your resting HR was also elevated during the same window. That pattern is different from your typical seasonal variation."

The AI can hold the entire multi-year dataset in context and notice things like: the January pattern you see every year vs the one that lasted unusually long. The correlation between resting HR elevation and HRV suppression. The VO2 max trajectory alongside your step trend.

These are the questions worth asking once the data is accessible. They require history. The history is already in HealthKit.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
