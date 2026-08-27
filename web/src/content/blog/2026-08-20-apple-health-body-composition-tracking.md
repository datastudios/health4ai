---
title: "Tracking Body Composition Over Time with AI"
description: "How to query weight, body fat percentage, and lean mass trends from Apple Health using get_long_term_trend and compare_periods for multi-month analysis."
pubDate: 2026-08-20
slug: "apple-health-body-composition-tracking"
tags: ["body-composition", "weight", "apple-health", "healthkit", "mcp", "long-term-trend", "analysis"]
draft: false
---

# Tracking Body Composition Over Time with AI

Apple Watch doesn't measure body composition directly, but the Health app accepts data from compatible smart scales (Withings, Renpho, Eufy), manual entry, and Dexafit scans. If you log this data, it's in HealthKit alongside your activity and recovery metrics. Here's how to query and interpret it.

## What's Available in HealthKit

Body composition metrics that sync to HealthKit (depending on your scale or logging method):

| Metric | HealthKit Identifier |
|--------|---------------------|
| Weight (body mass) | `HKQuantityTypeIdentifierBodyMass` |
| Body fat % | `HKQuantityTypeIdentifierBodyFatPercentage` |
| Lean body mass | `HKQuantityTypeIdentifierLeanBodyMass` |
| BMI | `HKQuantityTypeIdentifierBodyMassIndex` |
| Waist circumference | `HKQuantityTypeIdentifierWaistCircumference` |

If you have a Withings Body+ or similar scale with HealthKit integration, all of these sync automatically. If you track manually in the Health app, weight and body fat % (if estimated) are typically what's recorded.

## Long-Term Weight Trend

```
Show me my weight trend over the last 2 years.
```

Claude calls `get_long_term_trend(metric_type="HKQuantityTypeIdentifierBodyMass", months=24)`.

This returns monthly average weight — the right view for body composition tracking. Day-to-day weight variation is mostly hydration and digestive contents (1-3 kg of normal variation). Monthly averages filter this noise and show the actual trend.

Example monthly trend (abbreviated):

```json
{
  "monthly_trend": [
    {"month": "2024-09", "avg": 86.2, "days_with_data": 18},
    {"month": "2024-10", "avg": 85.8, "days_with_data": 22},
    {"month": "2024-11", "avg": 85.1, "days_with_data": 24},
    ...
    {"month": "2026-06", "avg": 83.4, "days_with_data": 19}
  ],
  "overall_avg": 84.7,
  "overall_min": 82.1,
  "overall_max": 87.9
}
```

Claude translates this: "You've trended from 86.2 kg in September 2024 to 83.4 kg in June 2026 — a gradual 2.8 kg reduction over 21 months at roughly 0.13 kg/month average rate."

## Body Fat % Trend

If your scale measures body fat % and writes it to HealthKit:

```
How has my body fat percentage changed over the last year?
```

Claude calls `get_long_term_trend(metric_type="HKQuantityTypeIdentifierBodyFatPercentage", months=12)`.

Body fat % is more meaningful than weight alone — two people at the same weight can be at very different body compositions, and weight reduction without fat loss (water, muscle) doesn't indicate the change you care about.

## Comparing Body Composition Across Two Periods

```
Compare my body composition from last summer to this summer.
```

```python
compare_periods(
    metric_type="HKQuantityTypeIdentifierBodyMass",
    period_a_start="2025-06-01",
    period_a_end="2025-08-31",
    period_b_start="2026-06-01",
    period_b_end="2026-08-15",
    label_a="Summer 2025",
    label_b="Summer 2026"
)
```

The response includes the mean weight for each period, delta, and percent change. Follow up with the same call for body fat % if you have that data.

## Connecting Body Composition to Training

Weight and body composition data become more useful when connected to your training and recovery data:

```
Show me my weight trend alongside my workout frequency over the last 6 months. 
Did periods with more training correlate with weight changes?
```

Claude pulls `get_long_term_trend` for weight and `get_workouts(days=180)` for training, then looks for correlations. This isn't a causation claim — other variables (diet, water retention, stress) affect weight — but visible patterns in the data are worth noting.

```
During my heavy training block in March-April, how did my weight and resting HR trend?
```

Heavy training blocks often show temporary weight gain (muscle glycogen loading, inflammation) followed by adaptation and body composition improvement. Having the weight trend alongside resting HR shows whether training stress and physical adaptation are moving in expected directions.

## Daily Snapshot for Body Metrics

For a specific day:

```
What were my body metrics on June 1st?
```

Claude calls `get_daily_snapshot(date="2026-06-01")` and extracts the body composition values from `highlights.weight_kg` and from the `all_metrics` dict for body fat % and lean mass if recorded.

## Getting Your Personal Baseline

```
What's my weight baseline — what's a typical range for me over the last 6 months?
```

Claude calls `get_metric_stats(metric_type="HKQuantityTypeIdentifierBodyMass", days=180)`:

```json
{
  "mean": 83.8,
  "std_dev": 1.2,
  "percentiles": {
    "p25": 82.9,
    "p50": 83.7,
    "p75": 84.6,
    "p90": 85.4
  },
  "thresholds": {
    "good_day_above": 84.6,
    "poor_day_below": 82.9
  }
}
```

The baseline tells you what's normal day-to-day variation vs a real trend signal. A single reading of 85.4 kg (your p90) might look alarming but is within your normal range. A monthly average of 85.4 kg after being at 83 kg for 6 months is a real signal.

## Lean Mass Tracking

If you have lean body mass data from a smart scale with bioelectrical impedance:

```
How has my lean mass changed over the last year? Is it trending up or down?
```

```python
get_long_term_trend(
    metric_type="HKQuantityTypeIdentifierLeanBodyMass",
    months=12
)
```

Lean mass preservation or gain during a weight reduction phase is the goal for most body recomposition efforts. Weight alone doesn't tell you this. If weight went down 3 kg and lean mass stayed flat, that's body fat reduction. If lean mass also dropped, the deficit was too aggressive or protein/training wasn't adequate.

These questions only have answers when you have the data. If your scale writes lean mass to HealthKit and health4ai is syncing it to Postgres, the analysis is a one-sentence prompt away.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
