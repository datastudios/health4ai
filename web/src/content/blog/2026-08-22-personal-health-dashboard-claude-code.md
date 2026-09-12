---
title: "Using health4ai to Build a Personal Health Dashboard"
description: "Architecture for a personal health dashboard built with Claude Code and health4ai data — query patterns, output formats, and what to show vs what to leave out."
pubDate: 2026-08-22
slug: "personal-health-dashboard-claude-code"
tags: ["dashboard", "apple-health", "claude-code", "mcp", "healthkit", "health-data", "tutorial"]
draft: false
legacySetup: true
---

# Using health4ai to Build a Personal Health Dashboard

A health dashboard shows you where you are across multiple metrics at a glance. Claude Code, with health4ai's MCP tools, can generate dashboard-style output on demand — no running web server, no visualization library, just structured text you can read or pipe somewhere useful.

## What a Useful Health Dashboard Shows

The minimum useful dashboard:

- **Recovery score:** HRV trend direction, resting HR
- **Sleep last night:** total hours, stage breakdown
- **Activity (last 7 days):** avg steps, workout count
- **Trend signal:** is the primary recovery metric improving, stable, or declining?

Secondary panels:
- Long-term trend (is this week above/below your 90-day baseline?)
- Next workout guidance (based on recovery status)
- Body metrics if you track them

## The Dashboard Query

In Claude Code, a single prompt that generates a complete dashboard:

```
Build me a health dashboard for today. Use these tools in sequence:
1. get_coaching_brief() — for recovery, sleep, training load
2. get_hrv_trend(days=30) — for 30-day HRV context
3. get_metric_stats(metric_type="HKQuantityTypeIdentifierHeartRateVariabilitySDNN", days=90) — for personal baseline

Format the output as a structured dashboard with sections: Recovery, Sleep, Activity, 
Trend Context, and Guidance. Keep each section to 2-3 lines.
```

Claude runs all three tools and returns structured output. Example:

```
HEALTH DASHBOARD — 2026-08-22

RECOVERY
HRV: 61ms (7d avg: 57ms | 90d baseline: 53ms) — above baseline
Resting HR: 54 bpm — normal
Status: Good recovery day

SLEEP (last night)
Total: 7h 28min
Stages: Core 3h45m | Deep 1h12m | REM 2h31m
Quality: Good

ACTIVITY (7 days)
Avg daily steps: 9,240
Workouts: 4 (2 runs, 1 strength, 1 cycle)
Avg active energy: 680 cal/day

TREND CONTEXT
HRV this week: +4ms vs prior week (improving)
vs 90-day baseline (53ms): +8ms above baseline
vs personal p75 (59ms): above threshold — good recovery day

GUIDANCE
Recovery markers support training intensity today. 
If planning a hard session, HRV and sleep both support it.
```

## Making It a Script

To get this daily without manually prompting:

```bash
#!/bin/bash
# ~/scripts/health-dashboard.sh
DATE=$(date +%Y-%m-%d)

claude --print "Generate my health dashboard for $DATE. 
Call get_coaching_brief(), get_hrv_trend(days=30), and 
get_metric_stats(metric_type='HKQuantityTypeIdentifierHeartRateVariabilitySDNN', days=90).
Format as a clean text dashboard with sections: Recovery, Sleep, Activity, Trend Context, Guidance.
Keep each section to 2-3 lines."
```

Pipe it to a file, send it to Telegram, or display it in a terminal widget — depending on your workflow.

## Building an HTML Dashboard

If you want a visual output, Claude Code can write it:

```
Generate my health dashboard data using get_coaching_brief() and get_hrv_trend(days=30), 
then write a self-contained HTML file at ~/health-dashboard.html with:
- A header showing today's date and overall recovery status
- Metric cards for HRV, resting HR, sleep hours, and step average
- A simple inline SVG trend line for the last 30 days of HRV

Use minimal CSS — no external dependencies. Status colors: green if above 90d baseline, 
yellow if within 1 std dev below, red if more than 1 std dev below.
```

Claude generates the HTML with embedded data, writes it to the file, and you open it in a browser. No server, no npm, no framework — just a file that shows your health data.

## What to Leave Out

The temptation with dashboards is to show everything. A few panels that are usually more noise than signal:

**Point-in-time weight** — Daily weight varies 1-3 kg from hydration alone. Unless you're tracking a 30-day average, a single reading is noisy. Use `get_long_term_trend` for a monthly weight view, not `get_daily_snapshot` for today's weight.

**Absolute HRV numbers without baseline context** — "HRV: 52ms" means nothing without your personal baseline. Always include the 90-day mean (from `get_metric_stats`) for comparison. "52ms (your average: 48ms)" is informative. "52ms" alone is not.

**Every metric type in the database** — You have dozens of HealthKit metric types. A dashboard that shows all of them is a data dump, not a dashboard. Limit to the metrics you actually make decisions from: HRV, sleep, activity, and recovery status. Add others in drill-down views.

## Scheduled Dashboard via LaunchAgent

For a daily dashboard at 7:00 AM:

```xml
<!-- ~/Library/LaunchAgents/com.health4ai.dashboard.plist -->
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.health4ai.dashboard</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/yourname/scripts/health-dashboard.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key><integer>7</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
</dict>
</plist>
```

The dashboard reflects data that's already in your Postgres database — no fresh API calls to Apple, no waiting for sync. health4ai's `HKObserverQuery` listeners have been updating your database in real-time overnight, so the 7 AM dashboard has current data.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
