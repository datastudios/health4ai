"""
health4ai — MCP Server
Exposes Apple Health data from YOUR Supabase project as MCP tool calls.

Transport: stdio only (`health4ai` or `python main.py`), the way Claude Desktop,
Claude Code, Cursor and mcphost launch it. The HTTP transport and its Bearer-key
middleware were removed: the key lookup read healthkit_api_keys, which
supabase/migrations/007_drop_hosted_tier.sql dropped, so every key returned 503
and the only working path was a flag that disabled auth. Nothing in README.md or
docs/ documents HTTP use.

Startup refuses to run with an unusable HEALTHKIT_USER_ID (unset, not a UUID, or
the .env.example placeholder) — those used to surface as a Postgres uuid error or
as "no_data_yet" on every tool, which reads like a broken server rather than a
setup step.
"""

import sys

from dotenv import load_dotenv
from fastmcp import FastMCP

from health4ai.tools import (
    get_health_summary,
    get_sleep,
    get_hrv_trend,
    query_metric,
    get_workouts,
    get_daily_snapshot,
    get_long_term_trend,
    get_coaching_brief,
    search_records,
    get_metric_stats,
    compare_periods,
    current_user_id,
    validate_user_id,
    DEFAULT_USER_ID,
    TZ_NAME,
)

load_dotenv()

SETUP_DOC = "docs/SETUP.md (Step 3 and Step 5)"

mcp = FastMCP(
    name="health4ai",
    instructions="Query your Apple Health data — sleep, HRV, workouts, steps, and more.",
)

mcp.tool()(get_health_summary)
mcp.tool()(get_sleep)
mcp.tool()(get_hrv_trend)
mcp.tool()(query_metric)
mcp.tool()(get_workouts)
mcp.tool()(get_daily_snapshot)
mcp.tool()(get_long_term_trend)
mcp.tool()(get_coaching_brief)
mcp.tool()(search_records)
mcp.tool()(get_metric_stats)
mcp.tool()(compare_periods)


def check_startup_config(raw_user_id: str | None) -> str:
    """Validate HEALTHKIT_USER_ID before the server starts; returns the canonical UUID.

    Exits with status 2 and a message naming the variable on failure. Everything goes to
    stderr: stdout is the MCP stdio channel and must carry nothing but protocol frames.
    """
    try:
        return validate_user_id(raw_user_id)
    except ValueError as e:
        print(
            f"health4ai: {e}. Set HEALTHKIT_USER_ID in mcp-server/.env to the UID of your "
            f"Supabase Auth user (Authentication -> Users). See {SETUP_DOC}.",
            file=sys.stderr,
        )
        sys.exit(2)


def main() -> None:
    user_id = check_startup_config(DEFAULT_USER_ID)
    current_user_id.set(user_id)
    print(
        f"health4ai MCP server: stdio transport; day boundaries follow HEALTH4AI_TZ={TZ_NAME}; "
        f"user {user_id}",
        file=sys.stderr,
    )
    mcp.run()


if __name__ == "__main__":
    main()
