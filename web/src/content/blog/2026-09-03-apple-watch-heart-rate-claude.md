---
title: "Apple Watch Heart Rate Data in Claude: What to Ask"
description: "How to query resting HR, walking HR, and continuous heart rate data from HealthKit using query_metric and get_metric_stats — what each metric means and when it matters."
pubDate: 2026-09-03
slug: "apple-watch-heart-rate-claude"
tags: ["heart-rate", "apple-watch", "healthkit", "mcp", "resting-hr", "analysis", "claude-code"]
draft: false
---

# Apple Watch Heart Rate Data in Claude: What to Ask

Apple Watch captures several distinct heart rate metrics. They serve different analytical purposes, and knowing which one to query for which question matters. Here's a guide to the HealthKit heart rate data available and what to do with it in Claude.

## The Heart Rate Metrics in HealthKit

| Metric | HealthKit Identifier | What it is |
|--------|---------------------|------------|
| Resting HR | `HKQuantityTypeIdentifierRestingHeartRate` | Daily resting HR computed by Apple Watch overnight |
| Heart Rate | `HKQuantityTypeIdentifierHeartRate` | Continuous HR samples throughout the day |
| Walking HR Average | `HKQuantityTypeIdentifierWalkingHeartRateAverage` | Average HR during normal walking (fitness marker) |
| HRV (SDNN) | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` | Heart rate variability, separate metric |

These are different data streams with different query patterns.

## Resting Heart Rate

Resting HR is the most reliable daily cardiovascular indicator. Apple Watch computes it from overnight measurements when you're still and asleep — the result appears as a single daily value.

**What's normal:** Resting HR has high individual variation. Fit adults might have resting HR of 45-55 bpm. Less active adults typically run 65-75 bpm. What matters for monitoring is the trend, not the absolute number.

**What to ask:**

```
What's my resting HR trend over the last 90 days?
```

Claude calls `query_metric(metric_type="HKQuantityTypeIdentifierRestingHeartRate", days=90)`.

For a 90-day window, this returns daily aggregates with the day's resting HR value. You'll see any sustained elevations (illness, overtraining, stress) and the baseline.

**Personal baseline:**

```
What's my normal resting HR range?
```

Claude calls `get_metric_stats(metric_type="HKQuantityTypeIdentifierRestingHeartRate", days=90)` and returns your p25/p50/p75. Now "elevated" has a personal definition rather than a population reference.

**Combined with HRV:**

```
Show me my resting HR and HRV together for the last 30 days. 
Are they moving in opposite directions (which would indicate stress)?
```

High HRV + low resting HR = good recovery. Low HRV + high resting HR = recovery deficit. When both move in the same direction simultaneously, the signal is stronger.

## Continuous Heart Rate

`HKQuantityTypeIdentifierHeartRate` is sampled every few minutes during the day (more frequently during exercise). A single day might have hundreds of readings. This is useful for exercise analysis and for detecting elevations during specific activities.

**High-heart-rate days:**

```
Find days in the last 60 days where my average heart rate during the day was above 90 bpm.
```

Claude uses `search_records(metric_type="HKQuantityTypeIdentifierHeartRate", min_value=90, days=60)`. Note: `search_records` operates on daily averages, so this finds days where the *average* HR was elevated, not just peaks during exercise.

**Heart rate during a specific day:**

```
What did my heart rate look like on August 15th?
```

Claude calls `get_daily_snapshot(date="2026-08-15")` and looks at the HR records in `all_metrics`. You'll see the individual samples throughout the day — useful if you want to find when you were most active or if there was an anomalous elevation.

**Raw data for a short window:**

```
Show me my heart rate for the last 7 days.
```

Claude calls `query_metric(metric_type="HKQuantityTypeIdentifierHeartRate", days=7)`. For a 7-day window (within the 30-day raw cutoff), this returns individual samples with timestamps — every reading Apple Watch took.

## Walking Heart Rate Average

Walking HR average is a cardiovascular fitness marker. It measures your heart rate during normal-pace walking — as fitness improves, your heart can sustain the same walking pace with less effort.

**Trend over time:**

```
How has my walking heart rate average changed over the last 2 years?
```

```python
get_long_term_trend(
    metric_type="HKQuantityTypeIdentifierWalkingHeartRateAverage",
    months=24
)
```

A declining walking HR average over months indicates improving cardiovascular fitness — the same walking pace requires less cardiac output. This is complementary to VO2 max as a fitness trend indicator, and it's generated from daily walking rather than specific outdoor runs.

## Combining Heart Rate Metrics for Recovery Analysis

```
Pull my resting HR, HRV, and walking HR for the last 30 days. 
Give me a one-paragraph summary of what the combined picture shows about my cardiovascular fitness and recovery status.
```

Claude calls:
1. `query_metric(metric_type="HKQuantityTypeIdentifierRestingHeartRate", days=30)`
2. `get_hrv_trend(days=30)`
3. `query_metric(metric_type="HKQuantityTypeIdentifierWalkingHeartRateAverage", days=30)`

With all three in context, it can synthesize: resting HR reflects acute recovery status; HRV reflects autonomic nervous system state; walking HR average reflects baseline cardiovascular fitness. Improvements in all three simultaneously is a strong signal of positive adaptation.

## What to Look For

**Short-term (day-to-day):** Check resting HR. An elevation of 5+ bpm above your baseline the morning after hard training or a poor night's sleep is a standard recovery signal. Pair with HRV for a cleaner picture.

**Medium-term (weekly):** Is resting HR trending up or down? A multi-week elevation often indicates accumulated fatigue or illness. A gradual decline over weeks of consistent training indicates cardiovascular adaptation.

**Long-term (months):** Walking HR average is your fitness progress metric. If it's declining gradually over months of consistent training, that's the adaptation you're working for. If it's flat or rising despite training, the training stimulus may not be sufficient.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
