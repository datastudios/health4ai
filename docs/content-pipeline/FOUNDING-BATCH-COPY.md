# health4ai — Founding Batch Copy

## The positioning
Don't frame it as a discount. Frame it as a founding story with a real commitment.
Developers are allergic to fake urgency. They're not allergic to a genuine "early = better deal" signal.

---

## Landing page banner (above nav or top of hero)

**Option A — minimal:**
```
health4ai is free through July. Founding batch gets lifetime access. →
```

**Option B — with more context:**
```
Summer launch: health4ai is free through July 31.
Everyone who downloads during this period gets lifetime access at $0 — permanently.
```

---

## Hero CTA button text
```
Get it free — founding batch
```
Sub-label (below button):
```
Free through July · Founding batch gets lifetime access
```

---

## "What is the founding batch?" section (FAQ or modal)

```
What does "founding batch" mean?

health4ai launched in June 2026. We don't know yet what the right 
price is — but we know early users are taking a bet on us, and that's 
worth something.

Everyone who downloads before August 1 is in the founding batch. 
That means health4ai is free for you, forever. Not a trial. Not a 
promotional period. Free.

When we launch paid plans, founding batch users are grandfathered 
at $0. We'll keep the date live below so you can see exactly how 
much time is left.

[Founding batch closes: July 31, 2026]
```

---

## End-of-article CTA (Riley uses this in every blog post)

```
health4ai is free through July. Everyone in the founding batch 
gets lifetime access at $0.
[Download on the App Store →](https://health4.ai)
```

---

## Reddit / community post closing line

```
Launching free through July — founding batch gets lifetime access.
```

---

## HN Show HN copy

```
Show HN: health4ai – Open-source HealthKit → Postgres → MCP server for Claude Code

I built this because I wanted to ask Claude about my health data from Claude Code, 
not just from claude.ai's web UI. The native Apple Health connector Anthropic ships 
is a web feature — it doesn't reach Claude Code, n8n, or any MCP client outside 
the browser.

The product is two parts:
1. An iOS app (open source) that syncs HealthKit to any Postgres database in the 
   background using HKObserverQuery — not polling, actual push delivery
2. An MCP server (also open source) that gives Claude Code, Cursor, and Ollama 
   9 tools to query that data: health summaries, sleep, HRV trends, workouts, 
   daily snapshots, coaching briefs, arbitrary metric queries

Supports Supabase, Neon, or self-hosted Postgres. Data goes to your database — 
we never see it.

Free through July. Founding batch gets lifetime access.

GitHub: https://github.com/jefflitt1/health4ai
App: https://health4.ai
```

---

## Configurable end date

The founding batch end date is stored in Supabase:
```sql
-- ⚠️ PROCESS-DRIFT WARNING (added 2026-07-15, audit finding: health4ai_config RLS disabled):
-- Pasting this snippet directly into the Supabase SQL editor is the root cause of a LOW-severity
-- audit finding — health4ai_config (+ health4ai_content_queue, health4ai_keyword_rankings) shipped
-- with RLS disabled because they were created here, outside supabase/migrations/, where 001/002/006
-- all explicitly ENABLE ROW LEVEL SECURITY at CREATE time. This violates the org policy in
-- PATTERNS-supabase.md ('RLS-first: all new Supabase tables must have deny-all by default', 2026-05-12).
-- RLS was retroactively enabled via ventures/health4ai/supabase/migrations/008_health4ai_config_rls.sql
-- (2026-07-15). DO NOT copy/run this snippet again as-is — any new ad-hoc table must be created through
-- supabase/migrations/ with RLS + policies in the SAME migration, not added later. NOTE: the anon-read
-- landing-page fetch described below (line ~121, 'Fetch via Supabase anon key... public') was never
-- implemented in web/src/ as of 2026-07-15 — do not assume an anon grant exists; verify live grants
-- (information_schema.role_table_grants) before adding one.
-- Run once
CREATE TABLE IF NOT EXISTS health4ai_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO health4ai_config (key, value)
VALUES ('founding_batch_end_date', '2026-07-31')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

To extend to August 31: single SQL update, no redeploy.

Landing page reads this value via Supabase anon key (read-only, public).
