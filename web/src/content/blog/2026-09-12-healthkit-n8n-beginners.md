---
title: "HealthKit Integration for n8n Beginners"
description: "How to connect Apple Health data to n8n workflows — the architecture options, a practical weekly digest example, and common n8n patterns for health data automation."
pubDate: 2026-09-12
slug: "healthkit-n8n-beginners"
tags: ["n8n", "healthkit", "apple-health", "automation", "workflow", "tutorial", "beginners"]
draft: false
legacySetup: true
---

# HealthKit Integration for n8n Beginners

n8n is an open-source workflow automation platform. If you self-host it (or use n8n Cloud), you can build workflows that pull health data, process it, and route it to Telegram, email, Slack, or anywhere else. Here's how to connect Apple Health to n8n.

## The Architecture

n8n can't talk to HealthKit directly. HealthKit is on-device, Apple only. The path to n8n is:

```
Apple Watch → HealthKit → health4ai iOS app → your Postgres database → n8n
```

From n8n's perspective, your health data is in a Postgres database. That's a standard integration n8n handles well.

You have two options for getting health data into n8n:

**Option A: Direct Postgres queries** — Use n8n's built-in Postgres node. Connect to your Supabase or Neon database with your connection string. Write SQL to pull the data you want. No extra setup required if you have health4ai installed.

**Option B: HTTP to health4ai tools** — Run a lightweight FastAPI wrapper around health4ai's MCP tools (see the [n8n workflow article](/blog/apple-health-n8n-workflow)). n8n calls your HTTP endpoint; the endpoint runs the tool and returns structured JSON.

For beginners, Option A (direct Postgres) is simpler. For more structured output that doesn't require you to write SQL aggregation queries, Option B is cleaner.

## Setting Up the Postgres Connection in n8n

1. In n8n, go to **Credentials → Add Credential → Postgres**
2. Enter your database connection details:
   - Host: your Supabase or Neon hostname
   - Port: 5432 (direct) or 6543 (Supabase pooler)
   - Database: `postgres`
   - User: `postgres`
   - Password: your database password
   - SSL: required (for Supabase/Neon)
3. Save and test the connection

## A Simple Weekly Health Digest Workflow

This workflow runs every Monday, pulls last week's health data from Postgres, and sends a summary to Telegram.

**Nodes:**

1. **Cron trigger:** `0 8 * * 1`

2. **Postgres — Get HRV data:**
```sql
SELECT 
  AVG(avg_value)::numeric(10,1) as avg_hrv,
  MIN(avg_value)::numeric(10,1) as min_hrv,
  MAX(avg_value)::numeric(10,1) as max_hrv,
  COUNT(*) as days_with_data
FROM healthkit_daily_summaries
WHERE user_id = 'your_user_id'
  AND metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
  AND date >= CURRENT_DATE - INTERVAL '7 days'
```

3. **Postgres — Get step data:**
```sql
SELECT 
  ROUND(AVG(sum_value)) as avg_daily_steps,
  SUM(sum_value) as total_steps_week
FROM healthkit_daily_summaries
WHERE user_id = 'your_user_id'
  AND metric_type = 'HKQuantityTypeIdentifierStepCount'
  AND date >= CURRENT_DATE - INTERVAL '7 days'
```

4. **Postgres — Get workout count:**
```sql
SELECT COUNT(*) as workout_count
FROM healthkit_metrics
WHERE user_id = 'your_user_id'
  AND metric_type = 'HKWorkoutTypeIdentifier'
  AND started_at >= NOW() - INTERVAL '7 days'
```

5. **Set — Build the message:**
```javascript
{
  message: `Weekly Health Digest — ${new Date().toLocaleDateString('en-US', {month: 'long', day: 'numeric'})}\n\nHRV: ${$node["Get HRV"].json.avg_hrv}ms avg (range: ${$node["Get HRV"].json.min_hrv}–${$node["Get HRV"].json.max_hrv}ms)\nAvg daily steps: ${$node["Get Steps"].json.avg_daily_steps.toLocaleString()}\nWorkouts: ${$node["Get Workouts"].json.workout_count}`
}
```

6. **Telegram — Send message**

The output:

```
Weekly Health Digest — September 15

HRV: 54.2ms avg (range: 44.1–68.3ms)
Avg daily steps: 8,420
Workouts: 4
```

Simple, factual, automated.

## Data Freshness and Timing

health4ai's `HKObserverQuery` sync means your Postgres database has current data — Monday morning's digest includes Sunday's workouts and overnight HRV/sleep.

One timing consideration: if you run the cron at 8:00 AM Monday, Apple Watch's overnight HRV measurement (typically recorded during your morning wake-up) may have just been written. If you wake up at 7:55 AM and the cron fires at 8:00, Sunday night's HRV might not be in the database yet. Running the digest at 8:30 AM is safer.

## Common n8n Health Patterns

**Threshold alerts:**

```sql
SELECT avg_value, date
FROM healthkit_daily_summaries
WHERE user_id = 'your_user_id'
  AND metric_type = 'HKQuantityTypeIdentifierHeartRateVariabilitySDNN'
  AND date = CURRENT_DATE - 1
  AND avg_value < 40
```

If this returns a row, send an alert: yesterday's HRV was below threshold. Wire to an IF node — if the query returns results, send alert; if not, do nothing.

**Monthly trend report:**

```sql
SELECT 
  DATE_TRUNC('month', date) as month,
  ROUND(AVG(avg_value)::numeric, 1) as avg_hrv,
  ROUND(AVG(CASE WHEN metric_type = 'HKQuantityTypeIdentifierRestingHeartRate' 
    THEN avg_value END)::numeric, 1) as avg_resting_hr
FROM healthkit_daily_summaries
WHERE user_id = 'your_user_id'
  AND metric_type IN (
    'HKQuantityTypeIdentifierHeartRateVariabilitySDNN',
    'HKQuantityTypeIdentifierRestingHeartRate'
  )
  AND date >= CURRENT_DATE - INTERVAL '6 months'
GROUP BY month
ORDER BY month DESC
```

Send this as a monthly health summary email.

**AI synthesis of weekly data:**

Extend the weekly digest workflow with a Claude API call that synthesizes the numbers into a paragraph. Pass your health data JSON to Claude (via HTTP Request node to the Anthropic API) and return a 2-3 sentence natural-language summary instead of raw numbers. The [n8n workflow article](/blog/apple-health-n8n-workflow) has the full HTTP Request node configuration.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
