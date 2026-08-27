---
title: "Apple Health HRV, Sleep, and Recovery: Letting Claude Analyze Your Training"
description: "How to use HRV, sleep stage data, and workout history together to let Claude identify recovery patterns, flag overreaching, and interpret readiness."
pubDate: 2026-08-13
slug: "apple-health-recovery-analysis-ai"
tags: ["recovery", "hrv", "sleep", "apple-health", "training", "claude-code", "mcp", "analysis"]
draft: false
---

# Apple Health HRV, Sleep, and Recovery: Letting Claude Analyze Your Training

Recovery monitoring is one of the more useful applications for continuous health data. The metrics Apple Watch captures — HRV, resting HR, sleep stages, training load — are individually meaningful and more meaningful in combination. Here's how to query and interpret them in Claude Code.

## The Recovery Picture

Three metrics form the core of recovery monitoring:

**HRV (SDNN)** — The most sensitive indicator. HRV reflects autonomic nervous system state — high and stable means the body is adapting to training stress; declining means recovery demand exceeds supply. Day-to-day variation is normal; sustained trends are the signal.

**Resting Heart Rate** — A lagging indicator compared to HRV. Resting HR elevation often appears 24-48 hours after the stressor (a hard workout, a late night, illness) and persists longer. An elevated resting HR alongside declining HRV is a stronger signal than either alone.

**Sleep** — The mechanism of recovery. Insufficient sleep suppresses HRV and elevates resting HR the following morning. Looking at sleep the night before a low-HRV day often explains it.

## Pulling the Recovery Picture in Claude

Start with the coaching brief:

```
Pull my coaching brief and give me a recovery status summary.
```

Claude calls `get_coaching_brief()`, which returns HRV (latest, 7d avg, trend direction, delta vs prior week), resting HR, sleep quality flag (good/borderline/poor based on 7-night average), and training load over the last 30 days.

Example output:

> Recovery is borderline this week. HRV has dropped 8ms from your prior week average, landing at 46ms — below your typical 52-54ms range. Resting HR is elevated at 62bpm vs your usual 55-57bpm. Sleep averaged 6.4 hours over the last 7 nights, which is below the threshold where your HRV typically stays stable. The combination points toward accumulated fatigue rather than single-event stress. I'd reduce intensity this week.

That synthesis — connecting HRV drop + resting HR elevation + sleep deficit into a recommendation — is what you get when the AI has all three data streams in context simultaneously.

## Digging Deeper: The 30-Day Picture

*"Show me my HRV and resting HR over the last 30 days. Were there any sustained suppression events?"*

Claude calls `get_hrv_trend(days=30)` and then uses `query_metric(metric_type="HKQuantityTypeIdentifierRestingHeartRate", days=30)`. Looking at both together, it can identify periods where both metrics were suppressed simultaneously (more meaningful than either alone) and flag the duration.

A 2-3 day suppression after a hard training block is normal. A 10-14 day suppression is a red flag — it suggests the training load is exceeding recovery capacity chronically, or there's an external stressor (illness, life stress, sleep disruption) compounding the picture.

## Connecting Training Load to Recovery

*"I did a lot of running in early August. Can you see that in my recovery data?"*

Claude uses:
1. `get_workouts(days=60)` — shows workout frequency and type
2. `get_hrv_trend(days=60)` — shows HRV trend over the same window

With both in context, Claude can correlate periods of high training frequency with subsequent HRV dips, and identify the lag time between hard weeks and recovery response. Most people see HRV impact 24-72 hours after hard sessions, with restoration over the following 2-5 days depending on intensity and volume.

## Finding Low-Recovery Days

*"Find any days in the last 90 days where my HRV was below 40ms."*

```python
search_records(
    metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    max_value=40,
    days=90
)
```

This returns a list of dates sorted highest-to-lowest by HRV value (so the worst days appear first). Claude can then check what the sleep and training context was for each flagged date.

*"For the three lowest HRV days, what was my sleep the night before?"*

Claude calls `get_sleep(days=90)` and cross-references the night before each flagged date. Consistent correlation (low HRV following short sleep) confirms the mechanism. Inconsistent correlation (low HRV on days with good sleep) suggests another stressor.

## The Before/After Training Block Analysis

One of the most useful patterns for athletes: compare recovery markers before, during, and after a defined training block.

*"I trained hard in weeks 3-4 of last month. Compare my HRV before that block (weeks 1-2) to after it (last week)."*

Claude uses `compare_periods`:

```python
compare_periods(
    metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN",
    period_a_start="2026-07-01",
    period_a_end="2026-07-14",
    period_b_start="2026-07-28",
    period_b_end="2026-08-10",
    label_a="Pre-block",
    label_b="Post-block"
)
```

If HRV recovered (or exceeded pre-block levels), the training stress produced adaptation. If it's still suppressed, recovery is incomplete. This is the kind of structured analysis that most training apps don't provide because they don't have the right comparison tool.

## Sleep Stage Analysis for Recovery

Deep sleep and REM serve different recovery functions. Deep sleep (N3) is associated with physical repair and hormone release. REM is associated with cognitive recovery and memory consolidation. Both matter.

*"What's my deep sleep average over the last month? Are there nights where I got below 45 minutes?"*

Claude calls `get_sleep(days=30)` and looks at the `deep` stage durations per night. It can flag nights where deep sleep was short and check whether HRV the following morning was suppressed.

*"Is there a correlation between deep sleep and next-morning HRV in my data?"*

Claude has both datasets from a single session. The correlation analysis is manual (Claude checks the night-before-to-next-morning pairs), but it produces a concrete answer: "Yes, on nights where deep sleep was under 45 minutes, your next-morning HRV averaged 44ms vs 57ms on nights with 60+ minutes of deep sleep."

That's a personalized data point that no generic health app provides.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
