---
title: "Building a Weekly Health Review Workflow with n8n and health4ai"
description: "How to wire n8n to health4ai's MCP server and Claude to generate a weekly health digest delivered to Telegram or email. Step-by-step workflow config."
pubDate: 2026-07-11
slug: "apple-health-n8n-workflow"
tags: ["n8n", "apple-health", "automation", "healthkit", "mcp", "claude", "workflow"]
draft: false
---

# Building a Weekly Health Review Workflow with n8n and health4ai

A weekly health digest that runs automatically is more useful than a dashboard you have to remember to open. Here's how to build one using n8n, health4ai's MCP server, and Claude — with delivery to Telegram or email.

## What the Workflow Does

Every Monday morning:
1. n8n triggers the workflow on a cron schedule
2. An HTTP node calls health4ai's MCP tools via the MCP server
3. Claude synthesizes the data into a weekly digest
4. n8n delivers the digest to Telegram (or email)

The digest covers: 7-day HRV trend, average sleep, workout count and types, step average, and a one-paragraph readiness summary.

## Prerequisites

- health4ai MCP server running on your Mac (see [setup guide](/blog/healthkit-supabase-setup))
- n8n self-hosted or n8n Cloud
- Claude API key (via Anthropic console)
- Your health4ai MCP server accessible from n8n (same machine, or network-accessible)

## Architecture Choice: MCP vs Direct DB

You have two options for getting health data into n8n:

**Option A: Direct Postgres query** — n8n's Postgres node queries your `healthkit_metrics` table directly. Simpler to set up, but you're writing SQL and handling the aggregation yourself.

**Option B: HTTP to MCP server** — n8n makes an HTTP POST to your MCP server, which runs the tool logic and returns structured JSON. This is what we'll build here, because the MCP server handles the tiered query routing (raw vs summary tables) and the business logic correctly.

To expose the MCP server over HTTP for n8n, you need a lightweight wrapper. health4ai's `main.py` runs as a stdio MCP server by default. For n8n integration, run it with the HTTP transport option or wrap it in a simple FastAPI endpoint.

The simplest approach: expose one endpoint per tool call.

```python
# simple_api.py — run alongside main.py for n8n integration
from fastapi import FastAPI
from tools import get_health_summary, get_hrv_trend, get_sleep, get_workouts

app = FastAPI()

@app.post("/health-summary")
def health_summary(days: int = 7):
    return get_health_summary(days=days)

@app.post("/hrv-trend")
def hrv_trend(days: int = 7):
    return get_hrv_trend(days=days)

@app.post("/sleep")
def sleep(days: int = 7):
    return get_sleep(days=days)

@app.post("/workouts")
def workouts(days: int = 30):
    return get_workouts(days=days)
```

Run with: `uvicorn simple_api:app --host 0.0.0.0 --port 8765`

## n8n Workflow Structure

The workflow has 6 nodes:

```
[Cron] → [HTTP: health-summary] → [HTTP: hrv-trend] → [HTTP: sleep] → [Claude] → [Telegram]
```

### Node 1: Cron Trigger

Set to: `0 8 * * 1` (Monday 8:00 AM in your local timezone)

### Node 2: HTTP Request — Health Summary

```
Method: POST
URL: http://localhost:8765/health-summary
Query parameters: days=7
```

The response JSON includes `steps.daily_avg`, `hrv_sdnn_ms.avg`, `resting_heart_rate_bpm.avg`, and `workouts.count`.

### Node 3: HTTP Request — HRV Trend

```
Method: POST
URL: http://localhost:8765/hrv-trend
Query parameters: days=14
```

Pull 14 days to get the trend direction (last 7 vs prior 7).

### Node 4: HTTP Request — Sleep

```
Method: POST
URL: http://localhost:8765/sleep
Query parameters: days=7
```

The response includes `avg_sleep_hours` for the week.

### Node 5: Claude — Synthesize Digest

Use n8n's HTTP Request node to call the Anthropic API:

```
Method: POST
URL: https://api.anthropic.com/v1/messages
Headers:
  x-api-key: {{ $env.ANTHROPIC_API_KEY }}
  anthropic-version: 2023-06-01
  content-type: application/json

Body (JSON):
{
  "model": "claude-haiku-4-5",
  "max_tokens": 1024,
  "messages": [{
    "role": "user",
    "content": "Write a concise Monday health digest based on this data. Be direct — no fluff. 3-4 sentences. Data: {{ JSON.stringify($node['HTTP: health-summary'].json) }} HRV trend: {{ JSON.stringify($node['HTTP: hrv-trend'].json) }} Sleep: {{ JSON.stringify($node['HTTP: sleep'].json) }}"
  }]
}
```

Use `claude-haiku-4-5` here — it's fast and inexpensive for a structured synthesis task. The response will be in `content[0].text`.

### Node 6: Telegram

Use n8n's Telegram node with your bot token. Send to your personal chat ID:

```
Message: {{ $node['Claude'].json.content[0].text }}
```

## Example Digest Output

The Claude synthesis from this workflow produces something like:

> Weekly health check — Monday Jun 30. HRV averaged 54ms this week, up 6ms from the prior week — recovery is trending in the right direction. Sleep averaged 7.1 hours with 14 tracked nights across 7 days. You logged 4 workouts (2 runs, 1 strength, 1 cycle) and hit 8,200 avg daily steps. Load and recovery look balanced heading into the week.

It's not a wall of numbers. It's a paragraph you can actually act on.

## Scheduling Considerations

**Cron timing:** 8 AM Monday works well because Sunday night's sleep data will be in HealthKit by then. Running it at midnight would sometimes miss the final hours of the sleep session.

**Data freshness:** health4ai's iOS app uses `HKObserverQuery` for real-time push sync, so when the cron fires Monday morning, your Sunday data is already in Postgres. You're not waiting for a background processing window.

**Error handling:** Add an error branch in n8n that sends a Telegram message if any HTTP node fails. The most common failure is the health4ai API server not running — worth knowing about.

## Extending the Workflow

Once the basic digest is working, common extensions:

- Add `get_long_term_trend` data to show whether this week's HRV is above or below your 90-day baseline
- Send a different message if HRV trend is declining (a low-recovery flag)
- Add the workout detail from `get_workouts(days=7)` for a training log summary
- Deliver to email via SMTP node instead of (or in addition to) Telegram

The workflow structure stays the same — it's just more HTTP nodes feeding more data to Claude.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
