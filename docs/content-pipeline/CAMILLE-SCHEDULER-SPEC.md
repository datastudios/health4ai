# health4ai — Content Publishing Scheduler
**Owner:** Camille (SS Auto)  
**System:** n8n + CF Pages + Supabase  
**Pattern:** Same as GG SEO rank tracker approach but for publishing triggers  

---

## What this does

Publishes queued blog articles on a M/W/F schedule by triggering a CF Pages deployment. Astro filters articles by `pubDate <= today` at build time, so all 40 articles can be pushed to GitHub upfront — only articles whose date has arrived go live on deploy.

---

## Step 1: Supabase table (run once)

```sql
CREATE TABLE IF NOT EXISTS health4ai_content_queue (
  id SERIAL PRIMARY KEY,
  slug TEXT NOT NULL UNIQUE,
  title TEXT NOT NULL,
  pub_date DATE NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',
  word_count INT,
  batch INT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  published_at TIMESTAMPTZ
);

-- Seed the first 12 articles
INSERT INTO health4ai_content_queue (slug, title, pub_date, status, batch) VALUES
('apple-health-mcp-server', 'Apple Health MCP Server: Connecting HealthKit to Claude Code', '2026-06-23', 'scheduled', 1),
('apple-health-ai-compared', 'Every Way to Get Apple Health Data into an AI in 2026', '2026-06-25', 'scheduled', 1),
('claude-connector-developer-gap', 'Why Claude''s Apple Health Connector Doesn''t Work for Developers', '2026-06-27', 'scheduled', 1),
('healthkit-supabase-sync', 'HealthKit → Supabase: Reliable Background Sync That Actually Works', '2026-06-30', 'scheduled', 1),
('setup-supabase-10min', 'How to Set Up health4ai with Supabase in 10 Minutes', '2026-07-02', 'scheduled', 2),
('query-health-data-claude-code', 'How to Query Your Apple Health Data with Claude Code', '2026-07-04', 'scheduled', 2),
('ai-health-coaching', 'Building an AI Health Coaching System with Apple Health and Claude', '2026-07-07', 'scheduled', 3),
('hrv-analysis-claude', 'Analyzing HRV Trends with Claude: A Practical Guide', '2026-07-09', 'scheduled', 3),
('n8n-health-workflow', 'Building a Weekly Health Review Workflow with n8n and health4ai', '2026-07-11', 'scheduled', 3),
('setup-neon', 'How to Set Up health4ai with Neon (Serverless Postgres)', '2026-07-14', 'scheduled', 2),
('cursor-mcp-setup', 'Using health4ai with Cursor for Health Data Analysis', '2026-07-16', 'scheduled', 2),
('mcp-tools-reference', 'The health4ai MCP Tools Reference — All 9 Tools Explained', '2026-07-18', 'scheduled', 2);

-- ⚠️ PROCESS-DRIFT WARNING (added 2026-07-15, audit finding: health4ai_config RLS disabled):
-- Pasting this snippet directly into the Supabase SQL editor is the root cause of a LOW-severity
-- audit finding — health4ai_config (+ health4ai_content_queue, health4ai_keyword_rankings) shipped
-- with RLS disabled because they were created here, outside supabase/migrations/, where 001/002/006
-- all explicitly ENABLE ROW LEVEL SECURITY at CREATE time. This violates the org policy in
-- PATTERNS-supabase.md ('RLS-first: all new Supabase tables must have deny-all by default', 2026-05-12).
-- RLS was retroactively enabled via ventures/health4ai/supabase/migrations/008_health4ai_config_rls.sql
-- (2026-07-15). DO NOT copy/run this snippet again as-is — any new ad-hoc table must be created through
-- supabase/migrations/ with RLS + policies in the SAME migration, not added later.
-- Config table (if not already created)
CREATE TABLE IF NOT EXISTS health4ai_config (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

INSERT INTO health4ai_config (key, value)
VALUES ('founding_batch_end_date', '2026-07-31')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW();
```

---

## Step 2: n8n Workflow spec

**WF name:** `health4ai — Content Publisher`  
**Trigger:** Cron — `0 9 * * 1,3,5` (Mon/Wed/Fri, 9 AM ET)  
**Register in:** `agent_scheduled_jobs` (job_name: `health4ai-content-publisher`, owner: Camille, BU: JGLV)

### Node sequence:

**1. Cron trigger** — `0 9 * * 1,3,5`

**2. Check queue** — HTTP Request to Supabase REST:
```
GET /rest/v1/health4ai_content_queue
?status=eq.scheduled&pub_date=lte.{{ $now.toFormat('yyyy-MM-dd') }}&order=pub_date.asc&limit=1
Headers: apikey, Authorization (service role key)
```

**3. IF** — `{{ $json.length > 0 }}` → continue; else → stop (nothing to publish today)

**4. Trigger CF Pages deploy** — HTTP Request:
```
POST https://api.cloudflare.com/client/v4/pages/projects/health4ai/deployments
Headers: Authorization: Bearer {{ $env.CF_PAGES_API_TOKEN }}
Body: {} (empty — triggers rebuild from main branch)
```
CF Pages token needs `Pages:Edit` permission on the health4ai project.

**5. Wait 90s** — allow CF Pages build to start (don't mark published until deploy triggered)

**6. Mark published** — HTTP Request to Supabase:
```
PATCH /rest/v1/health4ai_content_queue?slug=eq.{{ $json[0].slug }}
Body: {"status": "published", "published_at": "{{ $now.toISO() }}"}
```

**7. Log to agent_job_runs** — standard JGLE pattern:
```json
{
  "job_name": "health4ai-content-publisher",
  "status": "success",
  "details": "Published: {{ $json[0].title }} ({{ $json[0].slug }})"
}
```

**8. Telegram notification** — to JGLE Alert Relay (info level):
```
health4ai blog: published "{{ $json[0].title }}" ({{ $json[0].slug }})
```

---

## Step 3: CF Pages project setup

CF Pages project name: `health4ai`  
Build command: `npm run build`  
Build output: `dist`  
Root: `web/`  
Branch: `main`  
Auto-deploy on push: YES (so Riley's article pushes also auto-deploy)

API token for the WF: create scoped token in Cloudflare dash:
- `Pages:Edit` permission
- Zone: health4.ai
- Store as `CF_PAGES_API_TOKEN` in n8n credentials

---

## Step 4: DataForSEO keyword sweep

Run a one-time keyword sweep before Week 1 content publishes. Use the existing GG SEO pattern but against health4ai seed terms.

**Seed terms:**
```
apple health mcp server
healthkit mcp claude
apple health claude code
healthkit supabase
apple health ai integration
healthkit llm
personal health data api
apple health developer api
healthkit background sync
health data claude code
mcp server health data
apple health open source
```

**Endpoints to call:**
1. `serp/google/organic/live/advanced` — check current SERP for each term (who ranks, are we there yet)
2. `keywords_data/google_ads/search_volume/live` — get monthly volume for each
3. `dataforseo_labs/google/keyword_ideas/live` — expand to related terms we haven't thought of

**Output:** write to new Supabase table `health4ai_keyword_rankings` (same schema as `gg_keyword_rankings`):
```sql
CREATE TABLE IF NOT EXISTS health4ai_keyword_rankings (
  id SERIAL PRIMARY KEY,
  keyword TEXT NOT NULL,
  rank INT,
  search_volume INT,
  keyword_difficulty INT,
  checked_at TIMESTAMPTZ DEFAULT NOW()
);
```

Weekly rank check: activate same M 6AM cron pattern as GG tracker but for health4ai seed set.  
Weekly cost estimate: ~$0.05 (12 keywords × $0.004 per check).

---

## GitHub article push process

When Riley delivers article batch:
1. Jeff spot-checks 1 in 4
2. Approved batch pushed to `~/ventures/health4ai/web/src/content/blog/`
3. `git push origin main` triggers CF Pages auto-deploy
4. Articles with `pubDate` in the future are built but filtered by Astro's date check — they're in the repo but not visible until their pub_date

This means all 40 articles can be pushed at once. The scheduler's CF Pages build trigger is a belt-and-suspenders to ensure the day's article goes live even if no other push happened that day.
