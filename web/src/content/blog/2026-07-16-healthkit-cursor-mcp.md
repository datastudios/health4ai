---
title: "Using health4ai with Cursor for Health Data Analysis"
description: "Adding the health4ai MCP server to Cursor, three practical analysis prompts, and how Cursor Composer handles multi-step health data workflows."
pubDate: 2026-07-16
slug: "healthkit-cursor-mcp"
tags: ["cursor", "mcp", "healthkit", "apple-health", "tutorial", "health-data"]
draft: false
legacySetup: true
---

# Using health4ai with Cursor for Health Data Analysis

Cursor is an MCP-compatible AI editor, which means you can connect health4ai to it the same way you connect it to Claude Code. If Cursor is your primary AI environment, this is the faster path — no context-switching to a terminal.

## Adding the MCP Server to Cursor

Create or edit `~/.cursor/mcp.json`:

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

Restart Cursor. The health4ai tools should appear in the MCP tool list — you can verify by opening the MCP panel or by asking the AI: *"What health tools do you have access to?"*

The tool set is identical to Claude Code: `get_health_summary`, `get_hrv_trend`, `get_sleep`, `get_daily_snapshot`, `get_workouts`, `get_long_term_trend`, `get_coaching_brief`, `query_metric`, `search_records`, `get_metric_stats`, and `compare_periods`.

## Three Analysis Prompts That Work Well in Cursor

### 1. Generate a Health Data Report

In Cursor's chat, with a file open for output:

*"Pull my health summary for the last 30 days and my HRV trend for 90 days. Write a structured markdown report with sections for recovery, sleep, activity, and training load. Save it to health-report-june.md."*

Cursor will call `get_health_summary(days=30)` and `get_hrv_trend(days=90)`, then write the formatted markdown directly into the file. This is faster than copying output from a terminal.

### 2. Build an Analysis Script

*"Write a Python script that calls the health4ai Postgres database directly and produces a CSV of daily HRV, sleep hours, and step count for the last 365 days. Use the connection string in my .env file."*

Cursor has your project context, so it knows where `.env` is. The output is a runnable Python script that queries `healthkit_metrics` and `healthkit_daily_summaries` — the same tables the MCP server uses. Useful if you want to do custom analysis in pandas or export to a spreadsheet.

### 3. Debugging Sync Issues

*"I think my health sync stopped working. Check what the most recent data in my database is for steps and HRV, then compare it to what today's date is and tell me how stale the data is."*

Claude in Cursor calls `get_daily_snapshot` for today and `query_metric` for recent steps data, then reports the gap between the most recent recorded date and today. This is a quick diagnostic without opening the Supabase dashboard.

## Using Cursor Composer for Multi-Step Workflows

Cursor's Composer mode (Cmd+I) handles longer, multi-step tasks better than single-turn chat. For health data analysis, this works well for anything that requires iterating on a result.

Example Composer session:

**Step 1:** *"Pull my sleep data for the last 90 nights and calculate average sleep by day of week."*

Cursor calls `get_sleep(days=90)` and processes the response to group by weekday.

**Step 2:** *"Now compare that to my HRV data for the same period. Is there a weekday pattern where certain days have higher HRV that correlates with sleep the night before?"*

Cursor calls `get_hrv_trend(days=90)` and cross-references the two datasets.

**Step 3:** *"Write this analysis to a markdown file with a summary table."*

Cursor writes the output to a file in your project.

This is the kind of multi-step analysis that's tedious to do manually (export data, open Excel, make pivot tables) but natural in Cursor Composer because the AI maintains state across steps.

## Difference from Claude Code

The tool behavior is identical — both use the same MCP protocol and the same health4ai server. The practical differences:

**Claude Code** is better for:
- Quick one-off queries in a terminal session
- Scripting and piping output to other tools
- Workflows that don't involve writing files

**Cursor** is better for:
- Analysis that produces output files (reports, scripts, CSVs)
- Multi-step analysis where you want the AI to iterate on results
- Cases where you want the health data in the context of a broader coding project

Both work. The choice is about where you spend most of your time.

## Verifying Tool Access

If Cursor isn't showing health4ai tools, check:

1. The path in `~/.cursor/mcp.json` is absolute (not relative)
2. `python` resolves to a Python installation that has the health4ai dependencies installed
3. The MCP server starts without errors: `python /path/to/health4ai/mcp-server/main.py`

Cursor sometimes caches the MCP server list — a full restart (not just reload) clears it.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
