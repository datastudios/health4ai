---
title: "Apple Health + AI: The Missing Manual for Developers"
description: "Everything Apple doesn't document about HealthKit for developers building AI integrations — the on-device constraint, data access patterns, and why the architecture matters."
pubDate: 2026-08-25
slug: "apple-health-developer-api-guide"
tags: ["apple-health", "healthkit", "developer", "api", "architecture", "mcp", "ios"]
draft: false
---

# Apple Health + AI: The Missing Manual for Developers

Apple's HealthKit documentation is complete for iOS developers building fitness apps. It's not written for developers trying to build AI tools that work with health data, and the gaps cause real confusion. This is what's missing from the official docs.

## The Fundamental Constraint Nobody Warns You About

HealthKit has no server-side API.

If you've built integrations with other health platforms — Oura, Garmin, Fitbit — you're used to OAuth + REST: get a token, call an endpoint, get JSON. Apple doesn't have this. There is no `api.apple.com/healthkit/user/123/steps` endpoint. There is no webhook when new data arrives. There is no way to access HealthKit data without an iOS app running on the user's device.

This is documented, but the implications aren't explained:

1. Any application that wants to read a user's HealthKit data must ship an iOS app
2. The iOS app must request explicit per-metric-type permission from the user
3. Background sync requires implementing `HKObserverQuery` correctly — not BGProcessingTask (see below)
4. There is no way to access historical HealthKit data without the user's device

No amount of OAuth flow design, API key management, or server infrastructure changes this. You need the iOS app.

## Why BGProcessingTask Is Wrong for Health Sync

The standard iOS background task API is `BGProcessingTask`. It's used for all kinds of background work: syncing databases, processing images, running scheduled uploads. Most developers reach for it when building HealthKit sync because it's the standard background execution primitive.

For health sync, it's the wrong choice because of when it fires: when the device is idle, charging, and on WiFi. A user who unplugs their phone in the morning, uses it all day, and plugs it in at night won't see BGProcessingTask fire until evening. All the health data written throughout the day is stale in your database until then.

The correct API for HealthKit is `HKObserverQuery`. Register an observer for each metric type with `enableBackgroundDelivery(frequency: .immediate)`. HealthKit calls your completion handler immediately when new data is written for that type — not on iOS's schedule, but on HealthKit's schedule.

The practical difference: with BGProcessingTask, morning HRV arrives in your database when iOS decides to give you background time. With HKObserverQuery + immediate delivery, it arrives within seconds of Apple Watch recording it.

## The HealthKit Data Model

Each HealthKit sample is one of three types:

**HKQuantitySample** — A numeric measurement with a unit. Steps (`HKQuantityTypeIdentifierStepCount`), heart rate (`HKQuantityTypeIdentifierHeartRate`), HRV (`HKQuantityTypeIdentifierHeartRateVariabilitySDNN`), weight, VO2 max, etc. Has a start time, end time, value, unit, and source.

**HKCategorySample** — A categorical observation. Sleep analysis (`HKCategoryTypeIdentifierSleepAnalysis`) is the main one developers care about. The `value` is an integer enum (0=InBed, 1=AsleepUnspecified, 2=Awake, 3=AsleepCore, 4=AsleepDeep, 5=AsleepREM).

**HKWorkout** — A workout session with metadata: type, duration, distance, energy burned, heart rate zones if available.

These are stored in HealthKit and accessible via `HKSampleQuery`, `HKObserverQuery`, and related APIs. The schema in your database should mirror this structure — metric type as a string identifier, value, unit, start/end timestamps, source device.

## Permission Model

HealthKit permissions are granted per-type, per-direction (read/write), and revocable at any time in Settings. The app requests permission; the user grants or denies each type individually.

For an AI integration tool, you typically want read permission for:
- `HKQuantityTypeIdentifierStepCount`
- `HKQuantityTypeIdentifierHeartRate`
- `HKQuantityTypeIdentifierHeartRateVariabilitySDNN`
- `HKQuantityTypeIdentifierRestingHeartRate`
- `HKQuantityTypeIdentifierVO2Max`
- `HKQuantityTypeIdentifierActiveEnergyBurned`
- `HKCategoryTypeIdentifierSleepAnalysis`
- `HKWorkoutType`
- Any body metrics your users care about

The user can grant all of these or a subset. Your sync should handle partial permissions gracefully — metrics without permission simply don't sync, rather than failing.

## Data Sources and Deduplication

Multiple apps can write the same metric type to HealthKit. If both Apple Watch and Oura are tracking sleep, both write `HKCategoryTypeIdentifierSleepAnalysis` records. If you sum them, you get double-counted sleep.

Deduplication strategy:

- For sleep: pick one authoritative source (Oura if present, else Apple Watch). Filter by `sourceDevice` or `sourceName` in your query.
- For heart rate: Apple Watch continuous sampling is typically the most complete. Oura doesn't write continuous HR to HealthKit.
- For steps: if multiple sources exist (Apple Watch + third-party), Apple Watch is usually the primary source and HealthKit attempts to deduplicate.

health4ai handles sleep deduplication by filtering to the Oura source when pulling sleep stages via `HKObserverQuery`. If Oura isn't present, Apple Watch stages are used.

## Building for the MCP Layer

Once you have data in Postgres, the MCP server layer is the bridge to AI clients. The key design decisions:

**Expose domain-level tools, not raw table access.** A tool called `get_hrv_trend(days=30)` is more useful than `query_sql(sql="SELECT...")`. The AI knows when to call `get_hrv_trend` for recovery analysis. It doesn't know your schema.

**Handle aggregation in the tool.** The tool should return pre-computed answers: daily averages, trend direction, baselines. Don't return raw rows and expect the AI to aggregate — it's slow and unreliable for large windows.

**Route across data tiers transparently.** Recent data (last 30 days) comes from raw samples. Historical data comes from pre-aggregated daily summaries. The tool should handle this routing so the caller doesn't need to know which table to query.

**Validate and clamp parameters.** `days=99999` is a valid call from a confused LLM. Your tool should clamp it to your maximum window (5 years is health4ai's limit) rather than running a table scan.

These principles translate directly to reliable tool call behavior when used from Claude Code, Cursor, or any other MCP client.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
