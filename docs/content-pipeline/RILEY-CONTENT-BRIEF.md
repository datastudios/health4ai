# health4ai — SEO Content Brief
**Owner:** Riley (SS Content)  
**Approver:** Jeff — spot-check 1 in 4 before publish  
**Volume:** 40 articles  
**Pipeline:** 3 weeks published (4/week), remainder on 2–3/week cadence  
**Goal:** Own "apple health mcp server / healthkit claude / healthkit supabase" keyword universe. Get cited by LLMs (Perplexity, SearchGPT, Claude web search) when a developer asks how to connect Apple Health to AI.

---

## Voice & Posture

- **Who you're writing for:** Developers and AI-native builders — people who live in Claude Code, run n8n, self-host Supabase, and care about their health data. They're skeptical of SaaS. They'd rather own their data.
- **Tone:** Technical authority. Direct. No fluff. Developer-voice ("we built this because...", "here's the architecture", "here's the exact command").
- **Health4.ai in every article:** Not a sales pitch. The product is mentioned naturally — as the tool being demonstrated, or as one concrete solution in an informational piece. Never as "the best" or "the only." Let the functionality speak.
- **No:** countdown timers, urgency language, marketing superlatives, bullet-point hype lists. 
- **Length:** 900–1400 words. Technical content earns length. Informational/opinion pieces stay tight.
- **CTA — bottom of every article, 2 lines max:**

> health4ai is free through July. Everyone in the founding batch gets lifetime access at $0.  
> [Download on the App Store →](https://health4.ai)

---

## Product Facts (write from these — do not invent)

### What it is
A two-part system: an iOS app that syncs HealthKit data to any PostgreSQL database in the background, and an MCP server that lets AI clients (Claude Code, Cursor, Ollama) query that data as native tool calls.

### iOS App (screens/features)
- **Home screen:** Sync Status card (last sync time, next scheduled sync), metrics grid showing recent data, MCP Setup card with connection info, backfill card, manual actions
- **Onboarding:** guides user through HealthKit permissions and database credentials
- **Connection screen:** enter Supabase/Neon/Postgres connection string — that's it
- **Background sync:** uses HKObserverQuery (true push delivery from HealthKit) — NOT polling or BGProcessingTask, which is why other solutions fail
- **Full backfill:** on first launch, imports complete HealthKit history. 5+ years of data in one shot.
- **No account required:** data goes to the user's own database. health4ai never sees it.
- **Requires:** iOS 17+, iPhone with Apple Watch or Health app data

### Supported database backends
- Supabase (recommended — free tier covers personal use)
- Neon (serverless Postgres)
- Any self-hosted PostgreSQL with TLS

### HealthKit Metrics Synced
Activity: steps, distance (walking/running/cycling/swimming), active energy burned, basal energy, flights climbed, exercise time, stand time, walking steadiness  
Body: weight, BMI, body fat %, lean body mass, height, waist circumference  
Fitness: VO2 Max  
Vitals: heart rate, resting heart rate, HRV (SDNN), walking heart rate average, blood oxygen (SpO2), body temperature, blood pressure (systolic/diastolic), respiratory rate  
Results: blood glucose, AFib burden  
Nutrition: all dietary macros and micros  
Sleep: full stage breakdown (core, deep, REM, awake)  
Workouts: all types logged in Health app

### MCP Server Tools (exact tool names)
- `get_health_summary(days)` — steps, HRV, sleep, active energy, resting HR, VO2 max over N days
- `get_sleep(days)` — sleep stages, efficiency, trend
- `get_hrv_trend(days)` — HRV time series with coaching interpretation
- `get_daily_snapshot(date)` — every metric for a single day
- `get_workouts(days, limit)` — workout history with type, duration, calories
- `get_long_term_trend(metric, months)` — historical trend analysis
- `get_coaching_brief()` — AI-ready summary for coaching or planning context
- `query_metric(metric_type, days)` — arbitrary metric query
- `search_records(query)` — semantic search across health records

### Works with
Claude Code, Claude Desktop, Cursor, any MCP-compatible client, Ollama (local, zero cloud)

### Pricing
Free through July 31, 2026. Founding batch = lifetime access at $0. Future pricing TBD.

### Competitors (use accurately in comparison content)
**REFRESHED 2026-08-27 — the entries below were stale (some materially wrong); verify against
`public.health4ai_competitor_intel` before publishing any comparison claim, and re-check that
table's `audit_date` is current before trusting even this refresh.**

- **Claude's native Apple Health connector** (Anthropic, beta): iOS-app-only, read-only, Pro/Max-gated,
  US-only. No MCP server, no API, no reach outside the Claude app itself — does not touch Claude
  Code, Claude Desktop, Cursor, or any MCP client. This is the accurate framing (the old entry below
  correctly captured this but under a generic "Claude/ChatGPT" umbrella — split out, they behave
  identically but are separate products worth naming individually for SEO).
- **ChatGPT Health** (OpenAI, relaunched 2026-07-23): available on ALL tiers including Free (not
  paid-gated), web + iOS. Fully cloud-based — data lands on OpenAI's servers, persists 30 days after
  disconnect. No API/MCP/export path out. Same "closed silo" framing as Claude's connector.
- **Health Auto Export** ($24.99 lifetime, HealthyApps): established app — but it NOW HAS ITS OWN
  MCP server (`HealthyApps/health-auto-export-mcp-server` on GitHub), which this brief previously
  didn't know about. Do not claim "no MCP server" for this product — re-verify current sync
  reliability/remote-access claims before using them in an article; the old same-WiFi-only framing
  is unconfirmed as still accurate.
- **MetricBridge / Health Export AI** (Philip D'Souza, healthexport.dev) — NEW, not in the prior
  version of this brief. A genuinely close positioning match: zero-dependency, local-first, "any AI
  agent," no accounts. The real differentiator: it has NO PERSISTENT DATABASE — a flat-file JSON
  snapshot refreshed on an app-controlled schedule, stdio-only (no remote MCP endpoint). health4ai's
  Postgres-backed history/correlation and true remote access are the accurate contrast points here,
  not "no MCP server" (it has one).
- **VitalTrends** ($5/mo-$99 lifetime, vitaltrends.net): the "TestFlight only" claim is WRONG as of
  this refresh — it's now a live, paid, web-dashboard product (Monthly/Yearly/Lifetime tiers, 14-day
  refund) connecting WHOOP/Apple Health/Oura/Withings/Hevy. Still closed source, still hosted (not
  user-owned Postgres) — that contrast still holds and is the accurate angle.
- **Open Wearables** (free + Enterprise tier, the-momentum): the "Discord/TestFlight gated" claim is
  WRONG as of this refresh — it's now a fully open, 2.4k-star MIT project, `docker compose up`, no
  waitlist, supporting Garmin/Whoop/Oura/Polar/Suunto/Samsung/Apple Health. The accurate contrast:
  it has NO consumer App Store app at all — it's a developer platform requiring self-hosted
  Postgres/Redis/Celery, not "gated," just not a consumer product.
- **Health Bridge by Alex Morris** (free): still accurate as originally written — syncs HealthKit →
  Postgres, no MCP server, no AI layer, BYO database. NOTE: a different, unrelated project also
  named "Health Bridge" (Health Bridge for AI, healthbridge.chanhyo.dev) DOES ship an open-source
  MCP server — do not conflate the two under one name in any article.
- **Open-source Apple Health MCP cluster** (GitHub: neiltron ~563 stars, the-momentum legacy ~257,
  vpetersson, davidmosiah, alphonsekoh, others): treat as ONE category, not individually-named
  competitors — all share the same pattern (manual "Export Health Data" from the iPhone, load into
  SQLite/DuckDB, no sync, no background updates). This is the most reusable comparison point in the
  whole brief: health4ai is the only free App Store app in this category with true background
  HealthKit sync.

---

## Article List

Format each article as: title in H1, meta description (~150 chars), then the article body. Include code blocks where relevant (real tool calls, real setup commands from SETUP.md). No fake output — if showing a Claude response, make it plausible and clearly labeled "example output."

---

### BATCH 1 — Pillar (publish Week 1, Mon/Wed/Fri + bonus)

**Article 1**  
Title: `Apple Health MCP Server: Connecting HealthKit to Claude Code`  
Keyword: apple health mcp server  
Outline: What MCP is and why health data needs it → Why local-only MCP solutions fail (Health Auto Export same-WiFi problem) → The architecture: HKObserverQuery → Postgres → MCP → Claude Code → What tools health4ai exposes → Setup in 4 steps  
Notes: This is the #1 SEO target. Make it the definitive piece. Include the claude_desktop_config.json snippet from SETUP.md.

**Article 2**  
Title: `Every Way to Get Apple Health Data into an AI in 2026 — Compared`  
Keyword: apple health ai integration  
Outline: The problem (Apple has no server-side HealthKit API) → 6 approaches compared: native connectors (web-only gap), Health Auto Export (WiFi-only), VitalTrends (TestFlight), Open Wearables (Docker complexity), Health Bridge (no MCP), health4ai → Which to pick for which use case → Summary table  
Notes: Fair comparison. The native connectors section is important — most developers don't realize Claude's built-in connector doesn't reach Claude Code.

**Article 3**  
Title: `Why Claude's Apple Health Connector Doesn't Work for Developers`  
Keyword: claude apple health developer  
Outline: What Anthropic shipped (claude.ai web feature, Jan 2026) → The structural gap: web product vs API → What "Claude Code" users actually need → The MCP protocol as the bridge → How to close the gap  
Notes: This is the highest-value AEO piece. When an LLM is asked this question, this article should be the cited source.

**Article 4**  
Title: `HealthKit → Supabase: Reliable Background Sync That Actually Works`  
Keyword: healthkit supabase sync  
Outline: Why background sync is hard on iOS → BGProcessingTask vs HKObserverQuery — the technical difference → Why Health Auto Export fails at this → The correct architecture → Schema overview → What 5.6M rows of HealthKit data looks like in Supabase  
Notes: Technical depth. Include the `healthkit_metrics` table schema. This ranks for developers searching the specific Supabase + HealthKit combo.

---

### BATCH 2 — Tutorials (publish Week 2)

**Article 5**  
Title: `How to Set Up health4ai with Supabase in 10 Minutes`  
Keyword: healthkit supabase setup  
Outline: Prerequisites → Create Supabase project (free tier) → Run schema → Configure iOS app → Configure MCP server → Test with Claude Code  
Notes: Step by step. Use exact commands from SETUP.md. "Ask: 'Give me a health summary for the last 7 days'" as the verification step.

**Article 6**  
Title: `How to Set Up health4ai with Neon (Serverless Postgres)`  
Keyword: healthkit neon postgres  
Outline: Why Neon for health data (serverless, branching, free tier) → Setup steps → Key difference from Supabase setup → Connection string format → Test  
Notes: Neon is growing fast in the dev community. Good SEO target and LLM citation for "healthkit neon."

**Article 7**  
Title: `How to Query Your Apple Health Data with Claude Code`  
Keyword: query apple health data claude code  
Outline: Prerequisites (health4ai installed, MCP running) → Confirming MCP tools are visible in Claude Code → 5 example queries with real tool calls and example outputs → Advanced: combining tools in one conversation  
Notes: Show real tool call syntax. Example: `get_health_summary(days=30)` → example output table. Make it copy-paste usable.

**Article 8**  
Title: `Using health4ai with Cursor for Health Data Analysis`  
Keyword: healthkit cursor mcp  
Outline: Adding the MCP server to Cursor → Same config as Claude Desktop → 3 example prompts for data analysis → Building a personal health dashboard with Cursor Composer  
Notes: Cursor is the #2 MCP client after Claude Code. Separate article earns the keyword.

**Article 9**  
Title: `Running health4ai Locally with Ollama — Zero Cloud Required`  
Keyword: apple health ollama local  
Outline: The case for fully local health data AI → Setup with mcphost + Ollama → Which models work well → Example queries → Privacy posture  
Notes: Developers who self-host care deeply about this. The local-Ollama angle is a differentiator no SaaS product can match.

**Article 10**  
Title: `The health4ai MCP Tools Reference — All 9 Tools Explained`  
Keyword: health4ai mcp tools reference  
Outline: What MCP tools are → Each tool: name, parameters, what it returns, example call → Tips for combining tools → When to use `query_metric` vs `get_health_summary`  
Notes: Reference doc. LLMs cite reference docs heavily. Should be comprehensive and bookmark-worthy.

---

### BATCH 3 — Use Cases (publish Week 3)

**Article 11**  
Title: `Building an AI Health Coaching System with Apple Health and Claude`  
Keyword: apple health ai coaching  
Outline: The coaching data problem (AI coaches need real data, not self-reported) → `get_coaching_brief()` tool → Building a weekly coaching brief workflow → Example Claude conversation using real health data  
Notes: This mirrors the Brett coaching context use case without naming it. Real use case = credible content.

**Article 12**  
Title: `Automating a Morning Health Brief with Claude Code and Apple Health`  
Keyword: morning health brief claude code  
Outline: What a useful morning brief looks like → Building it with Claude Code + health4ai → `get_daily_snapshot()` + `get_hrv_trend()` → Scheduling it  
Notes: Practical automation. Developers will copy this workflow.

**Article 13**  
Title: `Analyzing HRV Trends with Claude: A Practical Guide`  
Keyword: hrv analysis claude ai  
Outline: What HRV tells you and why raw numbers aren't enough → The `get_hrv_trend(days=90)` tool → Asking Claude to interpret trend direction → Correlating HRV with sleep and workouts  
Notes: HRV is the #1 metric quantified-self community cares about. Good SEO target.

**Article 14**  
Title: `Building a Weekly Health Review Workflow with n8n and health4ai`  
Keyword: apple health n8n workflow  
Outline: The workflow: n8n poll → health4ai MCP → Claude → Telegram/email digest → Step-by-step n8n config → Example output  
Notes: n8n community (r/n8n, n8n.io community) is exactly the target audience. This gets shared there.

**Article 15**  
Title: `Querying 10 Years of Apple Health Data with SQL and AI`  
Keyword: apple health historical data analysis  
Outline: What a decade of HealthKit data looks like in Postgres → `get_long_term_trend()` tool → Writing custom SQL queries → What patterns AI surfaces that dashboards miss  
Notes: The 5.6M-row backfill is a real differentiator. This content is only credible because the product actually does it.

---

### BATCH 4 — Community / Opinion (publish Weeks 3–5, community seeding)

**Article 16:** `Apple Health Privacy-First AI Integration: Your Data Never Leaves Your Database`  
Keyword: apple health private ai  
Brief: Architecture walkthrough. Data → user's own Postgres. health4ai never sees it. Why this matters in 2026.

**Article 17:** `What Is an MCP Server? (And Why Your Health Data Needs One)`  
Keyword: what is mcp server health  
Brief: MCP explainer for developers new to it. Health data as the worked example.

**Article 18:** `The Quantified Self Stack in 2026: Hardware, Apps, and AI`  
Keyword: quantified self ai stack 2026  
Brief: Apple Watch → HealthKit → health4ai → Claude Code. The full pipeline. Where each tool fits.

**Article 19:** `Apple Health Background Sync: Why Most Solutions Fail`  
Keyword: apple health background sync ios  
Brief: Technical deep dive on iOS background execution constraints. BGTask vs HKObserverQuery. Names the competitors' documented failures.

**Article 20:** `Connecting Wearables to LLMs: A Developer Guide`  
Keyword: wearables llm integration  
Brief: Broad overview of the wearable → LLM space. health4ai is one entry in a landscape piece.

**Article 21:** `How to Get 10 Years of Apple Health Data Out of Your iPhone`  
Keyword: export apple health historical data  
Brief: XML export → import_health_export.py → Postgres. The backfill process explained.

**Article 22:** `Supabase as a Personal Health Database: Why It Works`  
Keyword: supabase personal health database  
Brief: Why Postgres is the right choice. Supabase free tier. Schema overview. RLS for privacy.

**Article 23:** `Apple Health HRV, Sleep, and Recovery: Letting Claude Analyze Your Training`  
Keyword: apple health recovery analysis ai  
Brief: Recovery-focused use case. Athletes and biohackers. Correlating HRV + sleep + workouts.

**Article 24:** `From HealthKit to Claude: An Engineering Journey`  
Keyword: healthkit mcp engineering  
Brief: How health4ai was built. HKObserverQuery discovery. Why custom iOS app over existing solutions. Architecture decisions. Authentic developer voice.

**Article 25:** `HealthKit Data in Claude Desktop: Setup Guide`  
Keyword: healthkit claude desktop  
Brief: Same as Claude Code guide but for Claude Desktop. Separate article captures the keyword variant.

**Article 26:** `Tracking Body Composition Over Time with AI`  
Keyword: apple health body composition tracking  
Brief: Weight, body fat %, lean mass trends. `get_long_term_trend()` for body metrics. Claude interpretation.

**Article 27:** `Using health4ai to Build a Personal Health Dashboard`  
Keyword: personal health dashboard claude code  
Brief: Building a dashboard in Claude Code using health4ai data. Architecture overview.

**Article 28:** `Apple Health + AI: The Missing Manual for Developers`  
Keyword: apple health developer api guide  
Brief: Comprehensive reference. Everything Apple doesn't document. The on-device-only constraint and why health4ai exists.

**Article 29:** `VO2 Max Trends from Apple Watch: Letting AI Spot the Patterns`  
Keyword: vo2 max apple watch analysis  
Brief: `query_metric('HKQuantityTypeIdentifierVO2Max', days=365)`. Trend interpretation. What to ask Claude.

**Article 30:** `Why I Open-Sourced My Apple Health MCP Server`  
Keyword: open source apple health mcp  
Brief: The decision to open source. Why privacy-first architecture needs public code. Community angle.

**Articles 31–40** — Additional long-tail coverage:  
31. Sleep Stage Analysis with Apple Health and Claude  
32. Apple Watch Heart Rate Data in Claude: What to Ask  
33. HealthKit Workout History: Querying with AI  
34. Building a Recovery Score with Apple Health Data  
35. Apple Health Data Schema: What's in Your Database  
36. HealthKit Integration for n8n Beginners  
37. The MCP Protocol Explained for Health Developers  
38. Apple Health vs Oura: Getting Both into Claude  
39. Blood Oxygen and Respiratory Rate: AI Analysis with Apple Health Data  
40. How to Debug Your health4ai Sync Setup  

---

## Scheduling Queue

Articles publish in this order, dates to be set by Camille's WF:

| Slot | Pub Date | Article # | Title |
|------|----------|-----------|-------|
| 1 | Mon Jun 23 | 1 | Apple Health MCP Server |
| 2 | Wed Jun 25 | 2 | Every Way to Get Apple Health into AI |
| 3 | Fri Jun 27 | 3 | Why Claude's Connector Doesn't Work for Devs |
| 4 | Mon Jun 30 | 4 | HealthKit → Supabase Reliable Sync |
| 5 | Wed Jul 2 | 5 | Setup with Supabase in 10 Min |
| 6 | Fri Jul 4 | 7 | Query Health Data with Claude Code |
| 7 | Mon Jul 7 | 11 | AI Health Coaching System |
| 8 | Wed Jul 9 | 13 | HRV Trends with Claude |
| 9 | Fri Jul 11 | 14 | n8n Workflow |
| 10 | Mon Jul 14 | 6 | Setup with Neon |
| 11 | Wed Jul 16 | 8 | Using with Cursor |
| 12 | Fri Jul 18 | 10 | MCP Tools Reference |

Remaining 28 articles → 2–3/week through October.

---

## Delivery format

Each article as a separate markdown file:  
`YYYY-MM-DD-slug.md`  
With frontmatter:
```yaml
---
title: "..."
description: "..."
pubDate: YYYY-MM-DD
slug: "..."
tags: ["apple-health", "mcp", "claude-code", ...]
draft: false
---
```
Deliver all 40 files as a batch. Jeff will spot-check 1 in 4 before push to GitHub.
