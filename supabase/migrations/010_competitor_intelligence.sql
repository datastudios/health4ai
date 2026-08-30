-- 010: Competitor product intelligence — structured, repeatable competitive audits for health4ai.
-- Same pattern as GrandkidsGuide's grand_directory.competitor_intel (2026-08-27): one row per
-- competitor per audit_date, so re-running the audit adds a trend row instead of overwriting.
-- Column names are generalized from GG's version (which used "counties_covered"/"seo_signals" —
-- geography/SEO-specific) since health4ai's competitive axis is MCP-client reach and discovery
-- channel (App Store/GitHub), not geography. Quantitative health4ai's OWN keyword rank tracking
-- already exists at public.health4ai_keyword_rankings — this table does NOT duplicate that; it's
-- competitor-facing qualitative intel only, matching the one-tool-per-purpose convention already
-- established by config/content_queue/keyword_rankings in this project.

CREATE TABLE IF NOT EXISTS public.health4ai_competitor_intel (
  id BIGSERIAL PRIMARY KEY,
  competitor_slug TEXT NOT NULL CHECK (competitor_slug IN (
    'claude_apple_health_connector', 'chatgpt_health', 'health_auto_export',
    'metricbridge_health_export_ai', 'vitaltrends', 'open_wearables',
    'health_bridge_alex_morris', 'oss_apple_health_mcp_cluster'
  )),
  competitor_name TEXT NOT NULL,
  domain TEXT NOT NULL,
  -- 'platform' = first-party AI vendor feature (Claude/ChatGPT); 'product' = a named competing
  -- app/tool; 'category' = a cluster of small similar entrants tracked as one row, not each individually
  threat_tier TEXT NOT NULL CHECK (threat_tier IN ('platform', 'product', 'category')),
  -- which MCP clients/surfaces the competitor's data is actually reachable from; empty = closed silo
  reaches_mcp_clients TEXT[] NOT NULL DEFAULT '{}',
  is_active_competitor BOOLEAN NOT NULL DEFAULT TRUE,
  audit_date DATE NOT NULL,
  product_and_features TEXT NOT NULL,
  platform_pricing_distribution JSONB NOT NULL DEFAULT '{}'::jsonb,
  discovery_signals JSONB NOT NULL DEFAULT '{}'::jsonb,
  positioning_vs_product TEXT NOT NULL,
  opportunities TEXT NOT NULL,
  confidence TEXT NOT NULL CHECK (confidence IN ('high', 'medium', 'low')),
  research_method TEXT NOT NULL DEFAULT 'websearch_snippets',
  collected_by TEXT NOT NULL DEFAULT 'jglv-team-research',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (competitor_slug, audit_date)
);

CREATE INDEX IF NOT EXISTS health4ai_competitor_intel_latest_idx
  ON public.health4ai_competitor_intel (competitor_slug, audit_date DESC);

-- RLS posture matches health4ai_config/content_queue/keyword_rankings (migration 008): the only
-- consumer is service_role (MCP/n8n content pipeline). No anon/authenticated grant.
ALTER TABLE public.health4ai_competitor_intel ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS health4ai_competitor_intel_service_role_all ON public.health4ai_competitor_intel;
CREATE POLICY health4ai_competitor_intel_service_role_all
  ON public.health4ai_competitor_intel
  FOR ALL
  TO service_role
  USING (true)
  WITH CHECK (true);

REVOKE ALL ON public.health4ai_competitor_intel FROM anon;
REVOKE ALL ON public.health4ai_competitor_intel FROM authenticated;
