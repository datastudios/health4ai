---
title: "Apple Health Data Schema: What's in Your Database"
description: "The complete health4ai database schema — healthkit_metrics and healthkit_daily_summaries tables, HealthKit type identifiers, and how to query them directly."
pubDate: 2026-09-10
slug: "apple-health-data-schema"
tags: ["schema", "postgres", "healthkit", "apple-health", "sql", "database", "reference"]
draft: false
---

# Apple Health Data Schema: What's in Your Database

Understanding the health4ai database schema lets you write custom SQL queries, build dashboards directly on the database, and debug sync issues. Here's a complete reference.

## Two Tables

health4ai uses a two-tier storage architecture:

- `healthkit_metrics` — raw HealthKit samples, retained for 30 days
- `healthkit_daily_summaries` — pre-aggregated daily data for all historical data

Beyond 30 days, raw samples are no longer individually stored — the daily summary captures the aggregate. This keeps the database size manageable while preserving the analytical signal.

## healthkit_metrics

```sql
CREATE TABLE healthkit_metrics (
    id            BIGSERIAL PRIMARY KEY,
    user_id       TEXT NOT NULL,
    metric_type   TEXT NOT NULL,
    value         DOUBLE PRECISION,
    unit          TEXT,
    started_at    TIMESTAMPTZ NOT NULL,
    ended_at      TIMESTAMPTZ,
    source_name   TEXT,
    source_device TEXT,
    metadata      JSONB,
    created_at    TIMESTAMPTZ DEFAULT NOW()
);

-- Primary query index
CREATE INDEX idx_healthkit_metrics_user_type_time 
  ON healthkit_metrics (user_id, metric_type, started_at DESC);

-- Source filtering (used for sleep deduplication)
CREATE INDEX idx_healthkit_metrics_source 
  ON healthkit_metrics (user_id, metric_type, source_device);
```

**Columns:**

| Column | Type | Description |
|--------|------|-------------|
| `user_id` | TEXT | User identifier (matches HEALTHKIT_USER_ID env var) |
| `metric_type` | TEXT | HealthKit quantity/category type identifier |
| `value` | DOUBLE PRECISION | Numeric value (null for some workout records) |
| `unit` | TEXT | HealthKit unit string (count/min, ms, %, etc.) |
| `started_at` | TIMESTAMPTZ | Sample start time (UTC) |
| `ended_at` | TIMESTAMPTZ | Sample end time (null for instantaneous samples) |
| `source_name` | TEXT | App that wrote the sample (e.g., "Health", "Oura") |
| `source_device` | TEXT | Device model string (e.g., "Apple Watch Series 9") |
| `metadata` | JSONB | Additional data — workout type, duration, distance, etc. |

**Workout records** store their detail in the `metadata` JSONB column:

```json
{
  "workout_type": "Running",
  "duration_seconds": 2340.0,
  "total_distance_meters": 5820.0,
  "total_energy_burned_cal": 387.0
}
```

**Sleep records** use integer values for stage codes:
- 0 = InBed
- 2 = Awake
- 3 = AsleepCore
- 4 = AsleepDeep
- 5 = AsleepREM

## healthkit_daily_summaries

```sql
CREATE TABLE healthkit_daily_summaries (
    id            BIGSERIAL PRIMARY KEY,
    user_id       TEXT NOT NULL,
    metric_type   TEXT NOT NULL,
    date          DATE NOT NULL,
    avg_value     DOUBLE PRECISION,
    min_value     DOUBLE PRECISION,
    max_value     DOUBLE PRECISION,
    sum_value     DOUBLE PRECISION,
    sample_count  INTEGER,
    UNIQUE (user_id, metric_type, date)
);

CREATE INDEX idx_healthkit_daily_summaries_user_type_date
  ON healthkit_daily_summaries (user_id, metric_type, date DESC);
```

**Columns:**

| Column | Description |
|--------|-------------|
| `date` | Calendar date (America/New_York timezone) |
| `avg_value` | Mean of all samples that day |
| `min_value` | Minimum sample value that day |
| `max_value` | Maximum sample value that day |
| `sum_value` | Sum of all samples (used for cumulative metrics: steps, energy) |
| `sample_count` | Number of raw samples that contributed |

## Common HealthKit Type Identifiers

### Activity
| Metric | Identifier |
|--------|-----------|
| Steps | `HKQuantityTypeIdentifierStepCount` |
| Distance (walk/run) | `HKQuantityTypeIdentifierDistanceWalkingRunning` |
| Distance (cycling) | `HKQuantityTypeIdentifierDistanceCycling` |
| Active energy | `HKQuantityTypeIdentifierActiveEnergyBurned` |
| Basal energy | `HKQuantityTypeIdentifierBasalEnergyBurned` |
| Exercise time | `HKQuantityTypeIdentifierAppleExerciseTime` |
| Stand time | `HKQuantityTypeIdentifierAppleStandTime` |
| Flights climbed | `HKQuantityTypeIdentifierFlightsClimbed` |

### Vitals
| Metric | Identifier |
|--------|-----------|
| Heart rate | `HKQuantityTypeIdentifierHeartRate` |
| Resting HR | `HKQuantityTypeIdentifierRestingHeartRate` |
| Walking HR avg | `HKQuantityTypeIdentifierWalkingHeartRateAverage` |
| HRV (SDNN) | `HKQuantityTypeIdentifierHeartRateVariabilitySDNN` |
| Blood oxygen | `HKQuantityTypeIdentifierOxygenSaturation` |
| Respiratory rate | `HKQuantityTypeIdentifierRespiratoryRate` |

### Body
| Metric | Identifier |
|--------|-----------|
| Weight | `HKQuantityTypeIdentifierBodyMass` |
| BMI | `HKQuantityTypeIdentifierBodyMassIndex` |
| Body fat % | `HKQuantityTypeIdentifierBodyFatPercentage` |
| Lean mass | `HKQuantityTypeIdentifierLeanBodyMass` |
| VO2 Max | `HKQuantityTypeIdentifierVO2Max` |

### Sleep and Workouts
| Metric | Identifier |
|--------|-----------|
| Sleep analysis | `HKCategoryTypeIdentifierSleepAnalysis` |
| Workouts | `HKWorkoutTypeIdentifier` |

## Example Queries

**All metric types in your database:**
```sql
SELECT metric_type, COUNT(*) as rows,
       MIN(started_at)::date as earliest,
       MAX(started_at)::date as latest
FROM healthkit_metrics
WHERE user_id = 'your_user_id'
GROUP BY metric_type
ORDER BY rows DESC;
```

**Monthly HRV averages (from daily summaries):**
```sql
SELECT DATE_TRUNC('month', date) as month,
       ROUND(AVG(avg_value)::numeric, 1) as avg_hrv_ms,
       COUNT(*) as days_with_data
FROM healthkit_daily_summaries
WHERE user_id = 'your_user_id'
  AND metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
GROUP BY month
ORDER BY month DESC;
```

**Recent sleep stage records:**
```sql
SELECT started_at, ended_at, value,
       ROUND((EXTRACT(EPOCH FROM (ended_at - started_at)) / 60)::numeric, 1) as duration_min,
       CASE value::int
         WHEN 3 THEN 'Core'
         WHEN 4 THEN 'Deep'
         WHEN 5 THEN 'REM'
         WHEN 2 THEN 'Awake'
       END as stage
FROM healthkit_metrics
WHERE user_id = 'your_user_id'
  AND metric_type = 'HKCategoryTypeIdentifierSleepAnalysis'
  AND value IN (2, 3, 4, 5)
  AND started_at >= NOW() - INTERVAL '7 days'
ORDER BY started_at DESC;
```

**Workout list with metadata:**
```sql
SELECT started_at::date as date,
       metadata->>'workout_type' as type,
       ROUND((metadata->>'duration_seconds')::numeric / 60, 0) as duration_min,
       ROUND((metadata->>'total_distance_meters')::numeric / 1000, 2) as distance_km,
       ROUND((metadata->>'total_energy_burned_cal')::numeric) as calories
FROM healthkit_metrics
WHERE user_id = 'your_user_id'
  AND metric_type = 'HKWorkoutTypeIdentifier'
  AND started_at >= NOW() - INTERVAL '30 days'
ORDER BY started_at DESC;
```

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
