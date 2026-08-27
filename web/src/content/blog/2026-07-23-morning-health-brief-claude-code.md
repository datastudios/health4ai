---
title: "Automating a Morning Health Brief with Claude Code and Apple Health"
description: "How to build a useful daily health brief using get_daily_snapshot and get_hrv_trend, and schedule it to run automatically each morning."
pubDate: 2026-07-23
slug: "morning-health-brief-claude-code"
tags: ["automation", "apple-health", "claude-code", "mcp", "healthkit", "morning-routine", "hrv"]
draft: false
---

# Automating a Morning Health Brief with Claude Code and Apple Health

A morning health brief is useful when it answers two questions: how did I recover last night, and what does that tell me about today? Most health apps show you numbers. A brief that interprets those numbers saves the cognitive step.

Here's how to build one using Claude Code and health4ai.

## What a Useful Brief Covers

The core of a morning brief:

1. **Last night's sleep** — total hours, stage breakdown (Core/Deep/REM)
2. **HRV reading** — today's value vs your recent baseline
3. **Resting heart rate** — elevated or normal
4. **Today's starting point** — what the combination implies about readiness

Optional additions:
- Workout logged yesterday (was there training stress to account for?)
- Trend direction over the last week (is this an isolated dip or part of a pattern?)

## The Tools Required

The brief uses two primary tool calls:

```python
get_daily_snapshot(date="2026-06-19")  # today's date
get_hrv_trend(days=14)                 # 2 weeks of HRV for baseline context
```

`get_daily_snapshot` returns everything recorded for the day — steps so far, HRV reading, resting HR, sleep records, and any workouts. `get_hrv_trend` gives the recent baseline so today's HRV reading has context.

For a more complete brief, add:

```python
get_sleep(days=1)           # detailed sleep stage breakdown for last night
get_coaching_brief()        # full recovery + training load context
```

## Building the Prompt

In Claude Code, a simple morning brief prompt:

```
Pull today's health snapshot and my HRV trend for the last 14 days. 
Write a 3-sentence morning brief: sleep quality last night, HRV vs recent baseline, 
and what the combination suggests about training today.
```

Claude calls the two tools, processes the JSON, and returns something like:

> Sleep last night was 7h 12min with solid REM (2:18) and good deep sleep (1:05). HRV this morning is 61ms, which is above your 14-day average of 54ms — a meaningful positive signal. Recovery looks good; if you have intensity planned, this is a fine day for it.

That's the brief. Three sentences, actionable, grounded in data.

## Automating It

To run this automatically each morning, use a LaunchAgent that calls Claude in headless mode:

```bash
# Save as ~/scripts/morning-health-brief.sh
#!/bin/bash
DATE=$(date +%Y-%m-%d)
claude --print "Pull my health snapshot for $DATE and my HRV trend for 14 days. Write a 3-sentence morning health brief covering sleep quality, HRV vs recent baseline, and readiness for training today." \
  | curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=$(cat -)" \
    -d "parse_mode=Markdown"
```

Make it executable:

```bash
chmod +x ~/scripts/morning-health-brief.sh
```

Then create the LaunchAgent plist:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.health4ai.morning-brief</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/Users/yourname/scripts/morning-health-brief.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>
    <integer>7</integer>
    <key>Minute</key>
    <integer>30</integer>
  </dict>
  <key>EnvironmentVariables</key>
  <dict>
    <key>TELEGRAM_BOT_TOKEN</key>
    <string>your_token</string>
    <key>TELEGRAM_CHAT_ID</key>
    <string>your_chat_id</string>
  </dict>
</dict>
</plist>
```

Save to `~/Library/LaunchAgents/com.health4ai.morning-brief.plist` and load it:

```bash
launchctl load ~/Library/LaunchAgents/com.health4ai.morning-brief.plist
```

The brief arrives at 7:30 AM. Apple Watch's overnight HRV and sleep data will be in HealthKit and synced to Postgres by then via health4ai's `HKObserverQuery` listener.

## Timing Considerations

**Why 7:30 AM and not midnight?** Apple Watch often finalizes sleep data (including stage breakdown) during the morning wakeup sequence. Running the brief too early may miss the last hour of sleep. 7:00-8:00 AM is reliable.

**What if I slept in?** The brief is keyed to the current date, so `get_daily_snapshot(date=today)` will show whatever HRV and sleep data is in the database at run time. If you wake up at 9 AM and the brief ran at 7:30, the sleep stage data may be incomplete. You can run it again interactively.

**Data freshness:** health4ai's iOS app uses `HKObserverQuery`, which means sync happens when HealthKit pushes new data — typically within seconds of Apple Watch writing a new reading. By 7:30 AM, overnight HRV and sleep data has been in Postgres for hours.

## Extending the Brief

A few additions that work well once the basic version is running:

**Add context from yesterday:**

```
Also pull workouts from yesterday (get_workouts(days=1)) and mention any training 
that would explain elevated resting HR or suppressed HRV.
```

**Trend flag:**

```
If my HRV trend (get_hrv_trend(days=7)) is declining for 3+ days in a row, 
add a note that this warrants attention.
```

**Weekly summary on Mondays:**

Change the LaunchAgent to also trigger a different prompt on Mondays that includes `get_health_summary(days=7)` and `get_coaching_brief()` for a fuller weekly review.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
