---
title: "How to Get 10 Years of Apple Health Data Out of Your iPhone"
description: "Exporting Apple Health historical data via XML, what the export contains, and how health4ai's backfill imports your complete HealthKit history into Postgres on first launch."
pubDate: 2026-08-08
slug: "export-apple-health-historical-data"
tags: ["apple-health", "export", "historical-data", "healthkit", "backfill", "postgres"]
draft: false
---

# How to Get 10 Years of Apple Health Data Out of Your iPhone

If you've been wearing an Apple Watch for several years, there's a substantial dataset in HealthKit — steps, heart rate, HRV, sleep, workouts, VO2 max, and more. Apple provides a way to export this as XML, and health4ai imports it all into Postgres on first launch. Here's what's in the export and how the import works.

## The Apple Health Export

On your iPhone, go to **Health → Profile photo (top right) → Export All Health Data**. The export generates a zip file containing:

- `export.xml` — the main file with all HealthKit samples
- `export_cda.xml` — CDA-format clinical records (if you have any)
- A `workout-routes/` folder with GPX files for outdoor workouts

The `export.xml` file is large. Several years of Apple Watch data produces a file in the range of 500MB to several GB. It's an XML document where each sample is a record element with attributes for type, value, unit, start/end date, and source device.

## What's in the Export

Every HealthKit record is included:

- All quantity types (heart rate, steps, HRV, VO2 max, weight, etc.)
- All category types (sleep analysis, mindful sessions, etc.)
- All workout records with their metadata
- Correlations (blood pressure — systolic and diastolic as paired records)
- All sources and their device metadata

The date range goes back to the earliest data recorded — typically when you first set up your Apple Watch or Health app. If you've had an iPhone since 2015 and tracked steps via the pedometer, that's in there.

## health4ai's Backfill Import

On first launch, the health4ai iOS app runs a full backfill of your HealthKit history. This doesn't use the XML export — it queries HealthKit directly via the `HKSampleQuery` API to pull historical samples for each metric type. The results go into your Postgres database.

The backfill process:

1. Queries each registered metric type with no date limit (full history)
2. Writes batches to your Postgres `healthkit_metrics` table
3. Shows progress on the Home screen (sync status card)
4. Populates `healthkit_daily_summaries` for the historical data

For a dataset with 5+ years of Apple Watch data, the backfill might write 4-6 million rows. This takes a few minutes on a typical home WiFi connection to Supabase or Neon. The app runs the backfill in the background.

## What the XML Export Is Useful For

The XML export is useful as a backup and for cases where you want to work with the raw data outside health4ai. If you're building custom analysis in Python, the export gives you everything in a portable format.

For getting your data into health4ai, the iOS app's built-in backfill is simpler — no manual export, no file handling. The backfill runs automatically.

## Verifying the Backfill Completed

After the backfill completes, you can check the database to confirm the data range:

In the Supabase SQL Editor (or any Postgres client):

```sql
SELECT 
  metric_type,
  COUNT(*) as rows,
  MIN(started_at::date) as earliest,
  MAX(started_at::date) as latest
FROM healthkit_metrics
WHERE user_id = 'your_user_id'
GROUP BY metric_type
ORDER BY rows DESC
LIMIT 20;
```

You'll see the row count and date range for each metric type. For steps, you should see data going back to whenever you first had an iPhone with a motion coprocessor. For HRV, back to when you first got an Apple Watch capable of measuring it.

In Claude Code, after backfill:

```
Give me a health summary for the last 30 days.
```

Then:

```
What's my VO2 max trend over the last 3 years?
```

The second query is the one that demonstrates the backfill working — you're getting 3 years of historical data from your database, not just what the iOS app has seen since install.

## Data Volume After Backfill

For reference, typical dataset sizes after backfill:

A user with 5 years of Apple Watch (Series 4+) might see:
- ~3M+ rows in `healthkit_metrics` (heart rate alone is high-volume — continuous sampling)
- ~500K rows of sleep, workout, and activity data
- ~150K rows in `healthkit_daily_summaries` (aggregated from the raw data)

The MCP server handles this volume efficiently because queries beyond 30 days route to the pre-aggregated summary table. A 5-year trend query scans ~1,800 rows in the summary table, not 3 million rows in the metrics table.

## Historical Data You Might Not Know You Have

The export often contains data people didn't know they were tracking:

- **Audiogram data** — if you've taken a hearing test on AirPods
- **Handwashing** — if you enabled handwashing detection on Apple Watch
- **Environmental sound levels** — background noise data from Apple Watch
- **Cycle tracking** — if enabled
- **Medication logging** — if tracked in Health
- **Mental health scores** — if you've done any Apple Health mental wellbeing assessments

All of this ends up in HealthKit. After backfill, it's all queryable via `query_metric` with the appropriate HKIdentifier.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
