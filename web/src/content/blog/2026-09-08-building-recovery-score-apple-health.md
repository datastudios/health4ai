---
title: "Building a Recovery Score with Apple Health Data"
description: "How to combine HRV, resting HR, sleep, and training load into a composite recovery score using health4ai MCP tools and Claude Code."
pubDate: 2026-09-08
slug: "building-recovery-score-apple-health"
tags: ["recovery", "hrv", "sleep", "apple-health", "mcp", "claude-code", "training", "score"]
draft: false
---

# Building a Recovery Score with Apple Health Data

Oura gives you a readiness score. Whoop gives you a recovery score. These are composite metrics that combine several physiological signals into a single number. You can build the equivalent from your own HealthKit data, using health4ai tools and a scoring formula defined in Claude.

This isn't trying to replicate Oura's proprietary algorithm. It's building a recovery score that reflects your specific data, your personal baselines, and your definition of what recovery means.

## The Inputs

A useful recovery score needs at least three data streams:

1. **HRV (SDNN)** — the primary autonomic recovery signal
2. **Resting HR** — secondary cardiovascular indicator, moves more slowly than HRV
3. **Sleep quality** — the mechanism of recovery (total hours, stage distribution)

Optional additions:
- **Training load (prior 48h)** — contextualizes why recovery might be low
- **Training load (prior 7-30d)** — cumulative fatigue indicator

## Getting the Inputs

```python
get_hrv_trend(days=14)          # HRV with trend context
query_metric(                   # Resting HR
    metric_type="HKQuantityTypeIdentifierRestingHeartRate", 
    days=14
)
get_sleep(days=3)               # Last 3 nights of sleep
get_workouts(days=7)            # Recent training load
get_metric_stats(               # Personal baselines
    metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    days=90
)
```

Or use `get_coaching_brief()` which combines most of these in a single call.

## A Simple Scoring Formula

Define a scoring approach in your Claude prompt:

```
Using today's health data, compute a recovery score from 0-100 using this formula:

HRV component (40 points):
- 40 points if today's HRV is above my 90-day p75
- 30 points if between p50 and p75
- 20 points if between p25 and p50
- 10 points if below p25

Resting HR component (30 points):
- 30 points if today's resting HR is at or below my 90-day p25 (low = good)
- 20 points if between p25 and p50
- 10 points if between p50 and p75
- 5 points if above p75 (elevated)

Sleep component (30 points):
- 30 points if sleep was 7.5+ hours
- 20 points if 6.5-7.5 hours
- 10 points if 6-6.5 hours
- 5 points if under 6 hours

Call get_coaching_brief() and get_metric_stats() for my HRV baseline. 
Calculate my score and explain what's driving it.
```

Claude runs the tools, applies the formula, and returns something like:

> Recovery Score: 76/100
> 
> HRV: 58ms — above your p75 threshold of 55ms → 40/40
> Resting HR: 57 bpm — between your p50 (55) and p75 (62) → 20/30
> Sleep: 6.8 hours — borderline range → 20/30
> 
> Recovery is good overall. HRV is strong, which is the most reliable signal. 
> The 76 score is held back by modest sleep last night. 
> If you have intensity training planned, it's appropriate — but get 7.5+ hours tonight.

## Why Build Your Own vs Use a Wearable's Score

Wearable recovery scores (Oura, Whoop, Garmin Body Battery) are proprietary algorithms trained on population data. They may not reflect your specific physiology or training patterns. A few reasons to build your own:

**Customizable thresholds.** The formula above uses your personal p25/p75 as thresholds, not population averages. A reading of 52ms HRV means different things for someone whose baseline is 45ms vs someone whose baseline is 65ms. Population-based scoring misses this.

**Transparent inputs.** You know exactly which metrics went into the score and how they were weighted. When the score is low, you can see why — it's not a black box.

**Custom weighting.** If sleep consistently matters more for your recovery than HRV, weight sleep at 50% instead of 30%. If you find resting HR is noisy and HRV is more predictive for you, reduce the resting HR weight.

**Extensible.** You can add inputs over time — nutrition data if you track it, stress indicators, temperature if your wearable captures it.

## Building It Into a Daily Script

```bash
#!/bin/bash
# ~/scripts/recovery-score.sh
DATE=$(date +%Y-%m-%d)

PROMPT="Compute my recovery score for $DATE using the formula below.
Call: get_coaching_brief(), and get_metric_stats(metric_type='HKQuantityTypeIdentifierHeartRateVariabilitySDNN', days=90)

Scoring:
HRV (40pts): above p75=40, p50-p75=30, p25-p50=20, below p25=10
Resting HR (30pts): below p25=30, p25-p50=20, p50-p75=10, above p75=5
Sleep (30pts): 7.5h+=30, 6.5-7.5h=20, 6-6.5h=10, under 6h=5

Return: Score X/100, bullet points for each component, 1-sentence guidance."

claude --print "$PROMPT"
```

Run it at 7:00 AM via LaunchAgent and you have a personalized recovery score every morning without a subscription.

## Caveats

A few things to keep in mind:

**The formula is arbitrary.** The weights (40/30/30) and thresholds (p25/p75) reflect a reasonable starting point, not a validated clinical score. Oura's and Whoop's algorithms are trained on large datasets and validated against subjective recovery ratings. Yours is a heuristic.

**Single-day HRV is noisy.** HRV varies day-to-day for reasons unrelated to recovery (coffee, time of measurement, position). The trend (from `get_hrv_trend`) is more reliable than a single morning reading. Consider using the 3-day average HRV rather than today's single reading.

**Resting HR lags.** Resting HR responds to stress and training more slowly than HRV — it might stay elevated for 2-3 days after a hard session while HRV rebounds. The two metrics together tell a more complete story than either alone.

Despite these caveats, a simple composite score that you understand and that uses your personal baselines is often more actionable than a sophisticated score you can't inspect.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
