---
title: "Connecting Wearables to LLMs: A Developer Guide"
description: "The full landscape of wearable → LLM integration approaches in 2026 — hardware constraints, architecture patterns, and where each solution fits."
pubDate: 2026-08-06
slug: "wearables-llm-integration"
tags: ["wearables", "llm", "healthkit", "apple-watch", "oura", "garmin", "mcp", "integration"]
draft: false
---

# Connecting Wearables to LLMs: A Developer Guide

Getting wearable health data into an LLM for analysis isn't a solved problem. The wearable ecosystem is fragmented, each manufacturer has different data access policies, and LLMs have no built-in mechanism for reading time-series sensor data. Here's a practical overview of what exists and how to build for it.

## The Core Challenge

Wearables generate sensor data. LLMs consume text and structured context. The pipeline between them has to handle:

1. **Data collection** — getting data off the device and into a queryable form
2. **Persistence** — storing it somewhere the LLM can reach
3. **Tool access** — giving the LLM a way to query the data on demand
4. **Synthesis** — turning sensor data into useful answers

Each step has real implementation complexity, and the choices at step 1 constrain what's possible at step 3.

## Hardware and API Access

The access model varies significantly by device:

**Apple Watch / HealthKit** — No server-side API. All data lives on-device in HealthKit. Access requires an iOS app with HealthKit entitlements. The upside: once an app has read permission, it can access all HealthKit data from any source (Apple Watch, Oura, Garmin — anything that writes to HealthKit).

**Oura Ring** — Has a server-side API (api.ouraring.com). You can query sleep, readiness, and activity data with an OAuth token without an iOS app. The tradeoff: Oura's API is Oura-specific and returns Oura's processed metrics, not raw sensor samples.

**Garmin** — Has a Health API for third-party developers. OAuth-based, server-side. Like Oura, returns processed data. Garmin also writes some data to HealthKit (workouts, HR, some sleep data in connected mode with iPhone).

**Whoop** — Has an API in developer preview. Returns recovery scores, strain, and sleep data. Doesn't write to HealthKit.

**Fitbit (Google)** — Has a server-side API. Writes some data to HealthKit. Google's acquisition has complicated the developer program.

**Polar, Wahoo** — Write workout data to HealthKit. Polar has a server-side API. Wahoo doesn't currently.

## Architecture Patterns

### Pattern 1: Native Web Connectors

Several AI products (Claude, ChatGPT) now have native Apple Health connectors. You link your Health app in the AI product's settings and the AI can reference your health data in chat.

**What it covers:** Non-developer users in web/mobile AI apps.

**What it doesn't cover:** Claude Code, the Claude API, n8n, custom apps, any MCP client outside the web UI. The connector is a product feature, not a protocol that extends to API clients. A developer building on the Claude API gets no benefit from the web connector.

### Pattern 2: Direct API → Context Injection

For devices with server-side APIs (Oura, Garmin, Whoop), you can fetch data from the API and inject it directly into an LLM call:

```python
import requests

# Fetch Oura sleep data
headers = {"Authorization": f"Bearer {OURA_TOKEN}"}
sleep = requests.get("https://api.ouraring.com/v2/usercollection/sleep", 
                     headers=headers).json()

# Inject into LLM context
messages = [{
    "role": "user",
    "content": f"Here's my sleep data: {sleep}. What patterns do you see?"
}]
```

This works for one-off analysis but doesn't scale well. Pasting large JSON blobs into LLM context is expensive and limited to what fits in the context window. For ongoing analysis across months of data, you need a database.

### Pattern 3: Database + MCP

The more capable architecture for ongoing use:

1. Sync wearable data to a Postgres database (using either a server-side API poller or an iOS app for HealthKit)
2. Run an MCP server that exposes typed tool functions (`get_hrv_trend`, `get_sleep`, etc.)
3. AI client calls tools on demand

This is what health4ai does for HealthKit data. The key advantage: queries aren't limited by context window size. You can ask "what's my HRV trend over the last 2 years?" and the MCP server fetches exactly the relevant aggregation from the database — not the full 2 years of raw data.

### Pattern 4: Multi-Source Database

For users with multiple devices (Apple Watch + Oura, or Garmin + Apple Watch), the most complete approach is a unified database that ingests from all sources:

- HealthKit data via iOS app (gets Apple Watch, Oura, Garmin if written to HK)
- Oura API poller for any Oura-specific metrics not in HealthKit
- Direct Garmin API for precise GPS/power data

The challenge is deduplication — if Oura writes sleep stages to HealthKit and you also pull from the Oura API, you get duplicate sleep records. Handling this requires knowing which source takes precedence for which metric.

Open Wearables is an open-source project that attempts this multi-source architecture. It handles Oura, Apple Health, and Garmin through a Docker stack. The tradeoff is setup complexity and no App Store distribution.

## Building for HealthKit Specifically

If your users are iPhone + Apple Watch users (the largest segment of serious health trackers in the US), HealthKit is where their data lives — including data from any other devices they've connected.

The requirements for a HealthKit integration:

- iOS app with HealthKit entitlements (requires Apple Developer Program)
- `HKObserverQuery` for real-time sync (not BGProcessingTask — see the [background sync article](/blog/apple-health-background-sync-ios) for why)
- A Postgres database for persistence
- An MCP server (or equivalent API layer) for LLM access

health4ai covers this specific case. For developers who want to build their own, Health Bridge (open source, by Alex Morris) handles the iOS → Postgres sync and you build the AI integration layer yourself.

## Practical Recommendation

If your goal is personal use on Apple Watch data: health4ai is the complete stack. If you want to build a product on HealthKit data: Health Bridge + your own MCP server is the right starting point for the sync layer.

If you need multi-device support (non-Apple wearables): Open Wearables for the data layer, then an MCP server on top. The Docker setup complexity is real but the architecture is correct.

If your users are on Oura or Garmin exclusively: use the server-side APIs directly, store in Postgres, build MCP tools. The iOS app requirement drops out.

The LLM integration pattern is the same regardless of data source: database, MCP tools, AI client. The hard part is the data collection layer, which varies by device.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
