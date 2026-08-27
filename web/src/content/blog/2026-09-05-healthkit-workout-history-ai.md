---
title: "HealthKit Workout History: Querying with AI"
description: "How to query your workout history from Apple Health using get_workouts — training load analysis, sport-specific breakdowns, and finding your best sessions."
pubDate: 2026-09-05
slug: "healthkit-workout-history-ai"
tags: ["workouts", "healthkit", "apple-health", "mcp", "training", "analysis", "claude-code"]
draft: false
---

# HealthKit Workout History: Querying with AI

Apple Watch logs every workout you record — running, cycling, strength training, swimming, yoga, and dozens of other types — as `HKWorkoutType` records in HealthKit. Each workout carries metadata: duration, distance, calories, and for outdoor workouts, the GPS route. All of this is in your health4ai database.

## The get_workouts Tool

```python
get_workouts(days=30, limit=20)
```

Returns a list of workouts with:
- `date` and `started_at`
- `workout_type` (e.g., "Running", "Strength Training", "Cycling")
- `duration_minutes`
- `distance_km` (for workouts with GPS distance)
- `calories_burned`
- `source` (device)

And a summary:
- `total_workouts`
- `total_duration_hours`
- `by_type` (count per workout type)

**Basic training log:**

```
Show me my workouts for the last 30 days.
```

Claude calls `get_workouts(days=30, limit=50)` and returns the list with total summary.

**Longer history with more records:**

```
Show me all my workouts for the last 6 months.
```

```python
get_workouts(days=180, limit=200)
```

The `limit` caps the number of workouts returned. For 6 months of training with 4-5 sessions per week, `limit=200` captures everything.

## Training Load Analysis

**Weekly volume:**

```
How many hours of training did I do per week over the last 2 months?
```

Claude pulls `get_workouts(days=60, limit=100)` and groups the workouts by week. It sums duration per week to show weekly training volume trends.

**Sport-specific analysis:**

```
How many running sessions have I done this year? What's the average duration?
```

Claude calls `get_workouts(days=365, limit=500)` and filters to `workout_type == "Running"`.

**Training variety:**

```
What sports have I been training and how is the time split?
```

Claude uses the `by_type` summary from `get_workouts` to show the distribution. "You've done 42 running sessions (38%), 28 strength training (25%), 19 cycling (17%), and 22 other sessions (20%) in the last 90 days."

## Finding Your Best Sessions

**Longest sessions:**

```
What were my 5 longest workouts in the last 6 months?
```

Claude pulls workout history with `get_workouts(days=180, limit=200)` and sorts by `duration_minutes` to find the top 5.

**Highest-calorie workouts:**

```
Find my 10 highest-calorie workouts.
```

Claude filters for `calories_burned` and ranks. Useful for athletes trying to understand peak training stimulus sessions.

**Workout streaks:**

```
Did I have any streaks where I trained 5+ consecutive days this year?
```

Claude has the list of workout dates from `get_workouts(days=365, limit=500)`. It checks for consecutive days with at least one logged workout.

## Connecting Workouts to Recovery

The most useful pattern: correlating training load with recovery metrics.

```
In weeks where I trained more than 6 times, how did my HRV look in the following week?
```

Claude needs:
1. `get_workouts(days=90, limit=200)` — to identify high-volume training weeks
2. `get_hrv_trend(days=90)` — to see HRV in the following week

It groups workouts by week, identifies weeks with 6+ sessions, then checks HRV in the 7-day window following each high-volume week.

This gives you a personalized view of your training-to-recovery ratio. If weeks with 6+ sessions consistently produce HRV suppression the following week, that's your threshold. If you recover cleanly, you have room to push.

**Training load before a poor recovery day:**

```
On days when my HRV was below 45ms, what did my training look like in the 48 hours before?
```

Claude uses `search_records` to find low-HRV days, then checks `get_workouts` for the preceding 2-day window for each flagged date. If hard sessions consistently precede low-HRV mornings with a 24-48 hour lag, that's a reliable pattern for your recovery timeline.

## Monthly Training Review

A structured monthly training review prompt:

```
Give me a training summary for the last 30 days:
1. Total workouts, total hours, breakdown by type
2. Weekly average workout count
3. Longest and shortest training week
4. How does this month compare to last month in volume and variety?
```

Claude uses `get_workouts(days=60, limit=200)` to cover the full comparison period, then segments by month.

Example output:

> August Training Summary
> 
> Total: 19 workouts, 22.4 hours
> Breakdown: Running 9 (47%), Strength 6 (32%), Cycling 4 (21%)
> Weekly avg: 4.8 sessions/week
> Highest week: Aug 12-18 — 6 sessions, 7.2 hours
> Lowest week: Aug 5-11 — 3 sessions, 3.4 hours (travel week visible)
> vs July: Down from 23 workouts to 19 (-17%), down from 25.1 hrs to 22.4 hrs (-11%)

That's a useful monthly review in one prompt.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
