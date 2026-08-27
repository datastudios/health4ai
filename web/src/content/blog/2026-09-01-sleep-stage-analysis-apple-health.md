---
title: "Sleep Stage Analysis with Apple Health and Claude"
description: "How to query and interpret Core, Deep, and REM sleep data from HealthKit using get_sleep — stage distributions, what each stage does, and how to spot patterns."
pubDate: 2026-09-01
slug: "sleep-stage-analysis-apple-health"
tags: ["sleep", "apple-health", "healthkit", "mcp", "rem", "deep-sleep", "analysis", "claude-code"]
draft: false
---

# Sleep Stage Analysis with Apple Health and Claude

Apple Watch (watchOS 9+) tracks sleep stages and writes them to HealthKit. If you also wear an Oura Ring, its stages land in HealthKit too. Either way, the data is in your database and queryable. Here's what to do with it.

## What HealthKit Stores for Sleep

Sleep data in HealthKit is stored as `HKCategoryTypeIdentifierSleepAnalysis` records. Each record is a continuous segment of a specific stage:

| Value | Stage |
|-------|-------|
| 0 | InBed |
| 1 | AsleepUnspecified |
| 2 | Awake |
| 3 | AsleepCore (N1/N2 light sleep) |
| 4 | AsleepDeep (N3 slow wave) |
| 5 | AsleepREM |

Each record has a `started_at`, `ended_at`, and a `value` (the integer stage code). A typical night might have 40-80 records — the brain cycles through stages approximately every 90 minutes, so there are multiple Core/Deep/REM segments per night.

## Querying Sleep Data

**Last week's sleep:**

```
Show me my sleep for the last 7 nights — total hours and stage breakdown per night.
```

Claude calls `get_sleep(days=7)`.

Example response for one night:

```json
{
  "date": "2026-09-01",
  "stages": {
    "core": 215.4,
    "deep": 72.1,
    "rem": 138.9
  },
  "total_minutes": 426.4,
  "segments": [
    {"stage": "core", "started_at": "2026-09-01T22:14:00Z", "ended_at": "2026-09-01T22:51:00Z", "duration_minutes": 37.0},
    {"stage": "deep", "started_at": "2026-09-01T22:51:00Z", "ended_at": "2026-09-01T23:24:00Z", "duration_minutes": 33.0},
    ...
  ]
}
```

**30-night sleep average:**

```
What's my average sleep architecture over the last month?
```

Claude calls `get_sleep(days=30)` and aggregates the stages across all 30 nights.

## Normal Sleep Architecture

For reference, typical adult sleep stage distribution per night:

| Stage | Typical % |
|-------|-----------|
| Core (N1/N2) | 50-60% |
| Deep (N3) | 15-25% |
| REM | 20-25% |

Deep sleep is front-loaded — you get the most of it in the first half of the night. REM is back-loaded — your longest REM periods are in the last 2-3 hours before waking. This is why cutting sleep short by 1-2 hours has a disproportionate impact on REM.

## Questions Worth Asking

**Deep sleep threshold:**

```
Find nights in the last 90 days where my deep sleep was under 45 minutes.
```

Claude uses `get_sleep(days=90)` and filters the nights where the `stages.deep` value is under 45 minutes.

**REM deficits:**

```
What percentage of my sleep is REM on average? How does that compare to last month?
```

Claude pulls `get_sleep(days=60)` and computes REM as a fraction of total sleep for each period.

**Stage correlation with HRV:**

```
On nights where I had less than 60 minutes of deep sleep, how was my HRV the next morning?
```

Claude has both `get_sleep` and `get_hrv_trend` data in context. It identifies nights with low deep sleep and checks the following morning's HRV. Most people see a meaningful HRV drop after low-deep-sleep nights.

**Bedtime pattern:**

```
Does the time I go to bed affect my deep sleep total?
```

Claude looks at the `started_at` timestamp of the first sleep segment each night (the sleep onset time) and correlates it with the `stages.deep` total for that night.

## Apple Watch vs Oura for Stage Tracking

Both write stages to HealthKit, but the accuracy differs:

**Apple Watch** is better at detecting sleep onset and tracking gross movements. Stage detection improved significantly in watchOS 9/10 but still lags ring-based devices in stage granularity.

**Oura Ring** has more sensors in contact with the finger (closer to arteries than the wrist), measures heart rate with higher accuracy, and generally produces more precise stage breakdowns. Its HealthKit integration writes the same stage categories (Core/Deep/REM/Awake).

If you have both, health4ai's `get_sleep` tool filters to Oura as the primary source when present (the iOS app source filters are configured for this). If you only have Apple Watch, it uses Apple Watch data.

If you're seeing different numbers than you expect, check `source_device` in the raw sleep records:

```
What were my sleep stages last night, and which device generated the data?
```

Claude uses `get_daily_snapshot(date="2026-09-01")` and looks at the sleep records' source device.

## Weekly Sleep Review Prompt

A useful weekly pattern:

```
Pull my sleep for the last 7 nights. Give me:
1. Average total sleep and stage breakdown
2. The night with the best sleep (highest deep + REM)
3. The night with the worst sleep (lowest total)
4. Any pattern you notice (e.g., weekend nights consistently shorter/longer)
```

Claude calls `get_sleep(days=7)` and does the comparison manually. Seven nights is a small enough dataset that the analysis is precise and the patterns are meaningful — not lost in a long-term average.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
