---
title: "Apple Health vs Oura: Getting Both into Claude"
description: "How Apple Watch and Oura Ring data coexist in HealthKit, how health4ai handles the deduplication, and how to query each source independently."
pubDate: 2026-09-17
slug: "apple-health-vs-oura-claude"
tags: ["oura", "apple-watch", "healthkit", "mcp", "sleep", "recovery", "hrv", "deduplication"]
draft: false
---

# Apple Health vs Oura: Getting Both into Claude

If you wear both an Apple Watch and an Oura Ring, you're generating overlapping health data. Both devices track sleep stages and HRV. Both write their measurements to HealthKit. The question of which one to trust for which metric — and how health4ai handles the coexistence — is worth understanding.

## How Both Devices Write to HealthKit

Oura writes to HealthKit via its iOS app when granted permission. It writes:
- Sleep stages (Core, Deep, REM, Awake) as `HKCategoryTypeIdentifierSleepAnalysis` records
- Resting heart rate as `HKQuantityTypeIdentifierRestingHeartRate`
- HRV (SDNN) as `HKQuantityTypeIdentifierHeartRateVariabilitySDNN`
- Readiness score components (in newer firmware via Oura-specific types)

Apple Watch writes independently:
- Sleep stages (from watchOS 9+, if Sleep tracking is enabled)
- Heart rate (continuous, throughout the day and night)
- Resting HR (daily computed value)
- HRV (during sleep alarm wakeup or Mindfulness sessions)

**The overlap:** Both devices write sleep stages and HRV to the same HealthKit tables. If you naively sum them, you get double-counted data.

## How health4ai Handles the Deduplication

For sleep stage data, health4ai's `get_sleep` tool filters by source:

```python
# From tools.py:
rows = _fetch_metrics(SLEEP, uid, since, limit=500, source_filter="Oura")
```

When querying sleep stages, the tool filters to records where `source_device ILIKE '%Oura%'`. If you have Oura data, that's what `get_sleep` returns. If you don't, the filter returns nothing and you'd need to query Apple Watch sleep directly.

For HRV, the tools don't filter by source — they use whichever records are in the database. If both Apple Watch and Oura wrote HRV to HealthKit on the same morning, both appear as separate samples. The tool averages across all samples for that day, which could produce a mixed-source average.

## Which Source Is More Accurate for What

**Sleep stages:**

Oura has an edge. The finger has arteries closer to the surface than the wrist, producing higher-quality PPG (photoplethysmography) signals. Oura's sleep stage algorithms are validated more extensively than Apple Watch's for consumer devices. If you have both, Oura sleep stage data is generally more accurate.

Apple Watch sleep tracking is better than nothing if you don't have a ring, but it's more likely to misclassify short awakenings as Core sleep and to undercount deep sleep.

**HRV:**

Oura measures HRV overnight across the full sleep period and reports SDNN over a longer window. Apple Watch measures HRV during a 1-minute window at your wake-up alarm (or during an explicit Mindfulness session). The measurement contexts are different, which is why the numbers differ even if both are measuring the same physiological state.

For trend tracking (which is the useful thing to do with HRV), either source is valid as long as you use the same source consistently. Mixing Apple Watch HRV and Oura HRV readings in the same trend calculation produces noise because the measurement windows differ.

**Heart rate (daytime):**

Apple Watch wins. Continuous sampling throughout the day is Apple Watch's strength. Oura measures heart rate during sleep and periods of rest but doesn't continuously sample during daytime activity. For daytime HR trends, training heart rate zones, and active HR data, Apple Watch is the source.

**Activity (steps, calories, workouts):**

Apple Watch is the primary source. Oura doesn't track steps via GPS or measure workout GPS routes. Steps and distance data from Apple Watch are more complete.

## Querying Each Source Independently

To query sleep data from a specific source in Claude:

```
What were my sleep stages last night from my Oura Ring specifically?
```

Claude uses `get_sleep(days=1)` — which already filters to Oura when present.

To query Apple Watch sleep data:

```
Query my sleep records from last night from Apple Watch, not Oura.
```

Claude uses `query_metric(metric_type="HKCategoryTypeIdentifierSleepAnalysis", days=1)` and filters by source in the returned samples.

To see which sources wrote data on a given day:

```
Show me all data sources that wrote sleep records on September 15th.
```

Claude calls `get_daily_snapshot(date="2026-09-15")` and looks at the `source_device` field across sleep records.

## Comparing Oura and Apple Watch HRV

If you want to see how the two devices' HRV readings compare:

```
On days where both Apple Watch and Oura recorded HRV, how different are the readings?
```

Claude uses `query_metric` for HRV with a recent window and groups by source device. This is a genuinely interesting comparison — you'll typically see Oura reporting lower SDNN values than Apple Watch because Oura averages over the full night (diluting high HRV periods in deep sleep) while Apple Watch measures in a short window at wakeup (which often captures elevated morning HRV).

## Recommended Configuration

If you have both devices:

1. Let health4ai sync both — both devices write to HealthKit and both are captured
2. Use Oura sleep data for sleep analysis (the tool defaults to this)
3. Use Apple Watch for daytime activity, continuous HR, and workouts
4. For HRV trend tracking, decide which source to standardize on — Oura if you care about consistency with Oura's app, Apple Watch if you do Mindfulness sessions and want to control measurement conditions

The database contains records from both. You can query either source at any time, and the filtering is available either through the MCP tools or direct SQL.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
