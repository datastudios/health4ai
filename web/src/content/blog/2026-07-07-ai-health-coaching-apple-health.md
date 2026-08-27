---
title: "Building an AI Health Coaching System with Apple Health and Claude"
description: "How to use real HealthKit data — not self-reported numbers — as the foundation for AI coaching context. Using get_coaching_brief() and building a weekly workflow."
pubDate: 2026-07-07
slug: "ai-health-coaching-apple-health"
tags: ["apple-health", "ai-coaching", "healthkit", "claude-code", "mcp", "hrv", "recovery"]
draft: false
---

# Building an AI Health Coaching System with Apple Health and Claude

AI coaching tools have a data problem. They ask you to self-report: how did you sleep? How did the workout feel? Rate your energy on a scale of 1-10. The problem is that self-reporting is noisy, biased toward recent events, and disconnected from the underlying physiology.

Apple Watch has been measuring your HRV, resting heart rate, sleep stages, and VO2 max for years. That data is in HealthKit. The question is how to get it into your AI coaching context in a form that's actually useful.

## What Real Coaching Data Looks Like

A useful coaching brief has a few components:

1. **Recovery status** — HRV trend, resting HR, sleep quality
2. **Training load** — workout frequency, type, volume over the last 30 days
3. **Fitness trajectory** — VO2 max trend, body composition
4. **Today's readiness** — are the markers pointing toward training or recovery?

All of this exists in HealthKit. None of it requires self-reporting.

## The get_coaching_brief() Tool

health4ai exposes a `get_coaching_brief()` tool specifically designed to produce AI-ready coaching context. It pulls 14 days of HRV and sleep, 30 days of workouts and activity, and calculates trend direction before returning a structured summary.

Call it at the start of a coaching session:

```
get_coaching_brief()
```

Example output (abbreviated):

```json
{
  "recovery": {
    "hrv_latest_ms": 58.2,
    "hrv_7d_avg_ms": 54.1,
    "hrv_trend": "improving",
    "hrv_delta_vs_prior_week_ms": 4.3,
    "resting_hr_latest_bpm": 55,
    "coaching_note": "Good recovery — normal or increased training load appropriate"
  },
  "sleep": {
    "avg_hours_last_7_nights": 7.4,
    "quality_flag": "good"
  },
  "training_load_30d": {
    "total_workouts": 16,
    "total_hours": 18.3,
    "weekly_avg_workouts": 3.7,
    "by_type": {"Running": 8, "Strength Training": 5, "Cycling": 3}
  },
  "fitness_markers": {
    "vo2max_latest": 48.2,
    "weight_kg_latest": 83.4
  }
}
```

The `coaching_note` field translates the HRV trend into a training recommendation Claude can work with. When HRV is improving and resting HR is stable, the data supports pushing harder. When HRV is declining and resting HR is elevated, the data points toward pulling back.

## Building a Weekly Coaching Session

Here's a workflow that runs each Monday to set training intent for the week:

**Step 1: Pull the brief**

In Claude Code, start the session with:

*"Pull my coaching brief and summarize where I am recovery-wise heading into this week."*

Claude calls `get_coaching_brief()` and translates the JSON into a plain-English recovery status.

**Step 2: Extend with trend context**

*"Now look at my HRV trend over the last 90 days. What's the overall direction?"*

Claude calls `get_hrv_trend(days=90)` and compares the monthly averages against the recent 7-day window. If HRV has been climbing over 3 months but dipped this week, that's a different story than a 3-month decline.

**Step 3: Connect to training load**

*"Given that training load, am I in a build phase or recovery phase right now?"*

Claude has both the workout data (from the coaching brief's `training_load_30d`) and the recovery data (HRV trend) to answer this. It can flag whether the ratio of training stress to recovery markers looks sustainable.

**Step 4: Set weekly targets**

*"Given what the data shows, what would you recommend for this week's training structure?"*

Now Claude is working from actual physiological data rather than your subjective sense of how last week went. The recommendation is grounded.

## Example: A Full Coaching Conversation

Here's what this looks like in practice. This is a representative example — the numbers are plausible but not from a specific real session.

---

**Prompt:** *"Run my coaching brief and give me a Monday readiness check."*

**Claude (after calling get_coaching_brief()):**

> Recovery looks solid heading into the week. HRV is at 58ms, which is up 4ms from last week — that's a meaningful improvement. Resting HR is 55bpm and stable. Sleep averaged 7.4 hours over the last 7 nights with good stage distribution. Training load last month was 16 workouts across running, strength, and cycling.
> 
> The data is pointing toward a productive training week. If you have intensity planned, this is a good window for it.

**Prompt:** *"What did my HRV look like in April? I had a heavy travel month."*

**Claude (after calling get_hrv_trend(days=90)):**

> In April your HRV dropped from a monthly average of 52ms to 44ms — about a 15% decline. Resting HR was elevated during the same window. That correlates with the pattern you'd expect from travel stress, disrupted sleep, and schedule compression. It recovered through May and June.

---

This kind of session is only possible when the AI has access to the actual data. Self-reported numbers don't capture the April HRV dip. HealthKit does.

## Correlating Metrics Across Tools

The real value comes from combining tools. A few patterns that work well:

**HRV + sleep correlation:**

*"Are my low-HRV days correlated with poor sleep the night before?"*

Claude uses `search_records` to find low-HRV days, then calls `get_sleep(days=90)` and compares the prior-night sleep for each flagged date.

**Training load + recovery:**

*"In months where I worked out more than 5 times per week, how did my HRV trend?"*

Claude pulls `get_workouts(days=180)` and `get_hrv_trend(days=180)` and looks for the correlation manually.

**Baseline comparison:**

*"Compare my HRV from this training block to my baseline last fall."*

Claude uses `compare_periods` with the two date ranges you specify.

## What This Isn't

This isn't a replacement for a human coach who understands your context, goals, and situation. It's a data layer that makes any coaching — human or AI — better. When your coach asks how recovery has been, you can answer with 90 days of HRV data instead of "pretty good, I think."

The AI doesn't need to interpret the data for you to benefit from having it. Knowing that your HRV dropped 20% in April and recovered through May tells you something. Having that data available when you're planning a heavy training block tells you whether the timing is right.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
