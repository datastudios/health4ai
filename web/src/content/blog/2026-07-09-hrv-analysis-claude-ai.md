---
title: "Analyzing HRV Trends with Claude: A Practical Guide"
description: "HRV raw numbers need context to be useful. How to use get_hrv_trend() and compare_periods to extract meaningful signal from 90+ days of HealthKit HRV data."
pubDate: 2026-07-09
slug: "hrv-analysis-claude-ai"
tags: ["hrv", "apple-health", "claude-code", "mcp", "healthkit", "recovery", "analysis"]
draft: false
---

# Analyzing HRV Trends with Claude: A Practical Guide

HRV (heart rate variability) is one of the more informative metrics Apple Watch captures — but the raw number on any given morning tells you almost nothing in isolation. 52ms means you're recovered if your baseline is 48ms. It means you're suppressed if your baseline is 62ms.

The signal is in the trend, and the trend requires history. Here's how to extract meaningful information from your HealthKit HRV data using Claude Code.

## What HealthKit Is Actually Measuring

Apple Watch measures HRV using the SDNN method — standard deviation of normal-to-normal RR intervals during a 1-minute window, typically taken during your morning wakeup alarm or a deliberate Mindfulness session. It records this as `HKQuantityTypeIdentifierHeartRateVariabilitySDNN`.

This is not the same as what some third-party apps report. Oura and Garmin use different measurement windows and calculation methods, which is why your Apple Watch HRV and your Oura HRV will differ even if both are "correct." For any single-day comparison, make sure you're comparing the same metric type from the same source.

## The get_hrv_trend() Tool

```python
get_hrv_trend(days=90)
```

This returns:

- Daily HRV averages across the window
- The overall weighted mean
- A trend comparison: last 7 days vs prior 7 days (`trend_vs_prior_week`)
- Direction: improving / declining / stable
- Delta in milliseconds

For windows longer than 30 days, the tool pulls from pre-aggregated daily summaries rather than raw samples, which means 90-day queries are fast even on multi-year datasets.

Example call and abbreviated response:

```json
{
  "period_days": 90,
  "days_with_data": 87,
  "avg_hrv_ms": 51.4,
  "latest_hrv_ms": 58.2,
  "trend_vs_prior_week": {
    "delta_ms": 4.1,
    "direction": "improving"
  },
  "daily_averages": [
    {"date": "2026-04-10", "avg_hrv_ms": 44.2, "source": "summary"},
    {"date": "2026-04-11", "avg_hrv_ms": 46.1, "source": "summary"},
    ...
    {"date": "2026-07-08", "avg_hrv_ms": 58.2, "source": "raw"}
  ]
}
```

The `source` field tells you whether each day came from raw samples (last 30 days) or pre-aggregated summaries (older data).

## Asking the Right Questions

HRV data gets useful when you ask Claude to interpret it in context. Some prompts that work well:

**Direction over the window:**

*"What's my HRV trend over the last 90 days? Break it into monthly phases and describe the direction in each."*

Claude will call `get_hrv_trend(days=90)` and segment the daily averages by month. You'll see if HRV was climbing through April, dipped in May, and recovered through June — which is a different story than a flat 90-day trend.

**Outlier identification:**

*"Were there any days in the last 90 days where my HRV dropped more than 20% below my average? What days were those?"*

Claude calls `search_records(metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN", max_value=40, days=90)` to find days below a threshold, then compares those against your average. This surfaces suppression events — travel, illness, late nights, hard training blocks.

**Before/after comparison:**

*"Compare my HRV from March to my HRV this month."*

Claude uses `compare_periods`:

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

The response includes the mean for each period, delta, and percent change — which gives you a factual answer instead of an impression.

## Correlating HRV with Sleep

HRV and sleep quality are related but not identical, and the lag matters. Poor sleep one night often shows up as suppressed HRV the next morning. A persistent pattern of short sleep shows up as a declining HRV trend over weeks.

*"Are my low-HRV mornings correlated with short sleep the night before?"*

Claude will:
1. Call `search_records` to find low-HRV days
2. Call `get_sleep(days=90)` to get per-night sleep totals
3. Manually compare the prior-night sleep for each flagged HRV date

This is where having both metrics in the same database pays off. You're not exporting CSVs and doing joins — you're asking a question in plain English.

## Correlating HRV with Training Load

Training stress suppresses HRV. That's not a problem — it's how adaptation works. The problem is sustained suppression without recovery windows, or suppression that exceeds what the training load warrants.

*"Show me my HRV trend over the last 60 days alongside my workout frequency. Do high-training weeks show up as HRV dips the following week?"*

Claude pulls both `get_hrv_trend(days=60)` and `get_workouts(days=60)` and compares the two timelines. If your heavy training weeks consistently show suppressed HRV 3-5 days later, that's a reliable signal for your personal recovery timeline.

## Getting Your Personal Baseline

Population norms for HRV are nearly useless for daily monitoring. A 35-year-old male might have an average HRV of 45ms or 75ms depending on fitness level, genetics, and measurement method. What matters is your trend relative to your own baseline.

*"What's my personal HRV baseline — what's a good day vs a bad day for me?"*

Claude calls `get_metric_stats(metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN", days=90)`:

```json
{
  "mean": 51.4,
  "percentiles": {
    "p25": 44.1,
    "p50": 51.8,
    "p75": 58.3,
    "p90": 64.2
  },
  "thresholds": {
    "good_day_above": 58.3,
    "poor_day_below": 44.1
  }
}
```

Now when you ask "is 48ms good today?" Claude can answer: that's below your median (51.8ms) and approaching your p25 threshold (44.1ms), which puts it in the borderline range for you specifically.

## What to Actually Do With This

A few practical patterns:

1. **Weekly check-in:** Every Monday, `get_hrv_trend(days=14)` to see where recovery sits heading into the week. If the delta vs prior week is negative, factor that into training intensity decisions.

2. **After disruption:** After travel, illness, or a high-stress period, `compare_periods` to quantify how much HRV dropped and how long recovery is taking.

3. **Before intensity:** Before a hard training week, `get_coaching_brief()` to get a full recovery picture. HRV + sleep + recent training load together are more predictive than any single metric.

4. **Long-term tracking:** Quarterly `get_long_term_trend(metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN", months=12)` to see whether your baseline HRV is improving over the year — which is a measure of aerobic fitness adaptation.

The data has been accumulating in HealthKit whether you were looking at it or not. The analysis is what turns the accumulation into signal.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
