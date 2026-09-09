# health4.ai — Apple Health × AI

<p align="center">
  <img src="web/public/logo.png" alt="health4.ai logo" width="96" height="96" style="border-radius:22px" />
</p>

<p align="center">
  <strong>Ask your AI about your sleep, HRV, recovery, and fitness — in plain language.</strong><br>
  Free iOS app · Your own database · Works with any MCP client
</p>

<p align="center">
  <a href="https://health4.ai"><img src="https://img.shields.io/badge/website-health4.ai-ff2d78?style=flat-square" alt="Website" /></a>
  <a href="https://github.com/jefflitt1/health4ai/blob/main/LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/iOS-17%2B-black?style=flat-square&logo=apple" alt="iOS 17+" />
  <img src="https://img.shields.io/badge/Python-3.11%2B-blue?style=flat-square&logo=python" alt="Python 3.11+" />
  <img src="https://img.shields.io/badge/MCP-FastMCP-green?style=flat-square" alt="FastMCP" />
  <img src="https://img.shields.io/badge/Postgres-any-4169e1?style=flat-square&logo=postgresql" alt="Any Postgres" />
</p>

---

## What it does

```
iPhone HealthKit → Your Postgres database → MCP server → Any AI
```

Apple Health holds years of your biometric data — sleep stages, HRV, heart rate, workouts, VO₂ max, and 150+ other metrics. health4.ai makes all of it queryable from Claude, ChatGPT, Cursor, Ollama, or any MCP-compatible client via 8 purpose-built tools.

**You control the data.** It syncs to a Postgres database you configure — Supabase, Neon, or a local Docker container. health4.ai never stores or has access to your health data.

---

## Why it exists

| Problem | health4.ai fix |
|---------|---------------|
| Apple has no HealthKit server API — all access requires an on-device app | Native iOS app with `HKObserverQuery` + `BGTaskScheduler` background sync |
| Health Auto Export only works on the same WiFi | Your data lands in Postgres — queryable from any AI, anywhere |
| The claude.ai Apple Health connector doesn't reach Claude Code CLI or Cursor | Standard MCP (stdio) — one config block works everywhere |
| Most solutions require a managed cloud service | Bring your own Postgres: Supabase, Neon, or fully local |

---

## Demo

> Demo video coming. Here's what a typical conversation looks like:

```
You:     How was my recovery this week? Anything standing out?

Claude:  Your recovery this week was mixed but trending positive.
         • HRV averaged 58ms (Tue–Thu strong at 64–68ms; Monday low at 44ms after Saturday's long run)
         • Sleep averaged 7h 12m — Wednesday and Thursday were your best nights (7h 40m+)
         • Resting HR dropped from 54bpm Monday to 49bpm Friday — a good sign
         Recommendation: today looks like a solid day for a moderate-intensity session.
```

---

## Quick start

**Choose your Postgres backend first:**

<details>
<summary><strong>Supabase (free tier available)</strong></summary>

```bash
# 1. Create a project at supabase.com
# 2. Run the schema
psql "$DATABASE_URL" < web/public/schema.sql
# or use the Supabase dashboard SQL editor
```
</details>

<details>
<summary><strong>Neon (serverless Postgres)</strong></summary>

```bash
# 1. Create a project at neon.tech
# 2. Run the schema
psql "$DATABASE_URL" < web/public/schema.sql
```
</details>

<details>
<summary><strong>Local Docker</strong></summary>

```bash
docker run -d \
  --name health4ai-postgres \
  -e POSTGRES_PASSWORD=yourpassword \
  -p 5432:5432 \
  postgres:16
psql "postgresql://postgres:yourpassword@localhost:5432/postgres" \
  < web/public/schema.sql
```
</details>

**Then set up the MCP server:**

```bash
git clone https://github.com/jefflitt1/health4ai.git
cd health4ai

cp mcp-server/.env.example mcp-server/.env
```

Edit `mcp-server/.env`:

```env
DATABASE_URL=postgresql://...    # your Postgres connection string
HEALTHKIT_USER_ID=your_user_id   # any string to identify your data
```

**Add to your AI client:**

<details>
<summary><strong>Claude Code / Claude Desktop</strong></summary>

```json
{
  "mcpServers": {
    "health4ai": {
      "command": "python",
      "args": ["/path/to/health4ai/mcp-server/main.py"],
      "env": {
        "DATABASE_URL": "postgresql://...",
        "HEALTHKIT_USER_ID": "your_user_id"
      }
    }
  }
}
```
</details>

<details>
<summary><strong>Cursor</strong></summary>

Same block → `~/.cursor/mcp.json`
</details>

<details>
<summary><strong>Ollama (fully local — no data leaves your machine)</strong></summary>

Pair with [`mcphost`](https://github.com/mark3labs/mcphost) or [`mcp-client-for-ollama`](https://github.com/jonigl/mcp-client-for-ollama):

```bash
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```

Your health data and the model both stay on your hardware — nothing leaves your machine.
</details>

**Install the iOS app:** Configure a database and Supabase account that you control, then sign in and tap **Start Sync**. For a private TestFlight beta, follow [the tester-isolation guide](docs/TESTFLIGHT-BETA.md); never use another person's backend or credentials.

---

## MCP tools

| Tool | What it answers |
|------|----------------|
| `get_health_summary` | Overview of key metrics for the past N days |
| `get_sleep` | Per-night sleep breakdown with REM, Deep, Core stages |
| `get_hrv_trend` | Daily HRV (SDNN) with rolling comparison and trend |
| `get_daily_snapshot` | Everything recorded for a specific date |
| `get_workouts` | Recent workouts with type, duration, distance, calories |
| `query_metric` | Raw time-series for any HealthKit metric type |
| `get_long_term_trend` | Monthly aggregates over years (raw + summary tiers) |
| `get_coaching_brief` | Recovery status, sleep quality, training load, fitness markers |
| `search_records` | Find days where a metric crossed a threshold |
| `get_metric_stats` | Personal baseline: min/max/mean/percentiles |
| `compare_periods` | Compare a metric between two date ranges |

### If a metric is empty, read `data_status` before believing it

**iOS never tells an app that a Health permission was denied.** A type you have not
shared returns an *empty result*, byte-for-byte identical to a day where you genuinely
did nothing. Nothing in HealthKit's API can distinguish the two, so an assistant reading
a bare `0` will confidently tell you that you took no steps.

Tools that can return an empty result therefore attach a `data_status` block:

- `never_recorded` — this metric has **never** produced a sample for you. For steps,
  heart rate, active energy or walking distance that is not possible if the data were
  being shared, so it almost certainly is not. Open **Health → Sharing → Apps →
  health4ai**, switch the metric on, then re-run the import from the app's Home tab.
- `empty_window` — nothing in the window you asked about, but the metric has data at
  other times. A real gap, not a permission problem.

This is not hypothetical. On the author's own account, step count, heart rate, active
energy and walking distance were silently unshared for nearly three months while every
other metric synced normally, and the app displayed a green "Complete" throughout.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  iPhone                                                      │
│  HKObserverQuery + BGTaskScheduler                          │
│  → continuous background sync                               │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTPS
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  Your Postgres database (Supabase / Neon / local Docker)    │
│  healthkit_metrics · healthkit_daily_summaries              │
│  v_healthkit_daily_quantity (unified view)                  │
└──────────────────────────┬──────────────────────────────────┘
                           │ SQL (service-role key, server-side only)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│  FastMCP server  (mcp-server/main.py)                       │
│  11 tools · stdio transport                                  │
└──────────────────────────┬──────────────────────────────────┘
                           │ MCP
                           ▼
              Claude · ChatGPT · Cursor · Ollama · any client
```

**Data tiers:** queries within the last 30 days return raw samples; older data transparently switches to pre-aggregated daily summaries — so long-term trend queries stay fast regardless of data volume.

---

## Repo structure

```
health4ai/
├── ios/                         # Swift/SwiftUI iOS app (iOS 17+)
│   └── Health4AI/               # HealthKit sync engine, auth, settings
├── mcp-server/
│   ├── main.py                  # FastMCP server entry point
│   ├── tools.py                 # 11 tool implementations
│   └── .env.example             # Required environment variables
├── web/
│   ├── public/schema.sql        # Portable Postgres schema (all backends)
│   └── src/                     # Astro marketing site
├── scripts/
│   ├── import_health_export.py  # One-time XML backfill from Apple Health export
│   └── summarize_historical.py  # Backfill daily summaries table
└── docs/
    └── SETUP.md                 # Detailed setup guide
```

---

## Privacy

Your health data goes **directly from your iPhone to your Postgres database**. health4.ai never receives, stores, or has access to it. The MCP server runs locally with your own credentials — your data never touches our infrastructure.

See the [Privacy Policy](https://health4.ai/privacy) for full details.

---

## Contributing

MIT licensed. PRs welcome.

Good first areas: additional metric aggregations, multi-user support with JWT/RLS, Android, and more MCP client integration guides.

## License

MIT — see [LICENSE](LICENSE).
