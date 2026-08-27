---
title: "HealthKit Data in Claude Desktop: Setup Guide"
description: "How to add health4ai to Claude Desktop specifically — config file location, verification steps, and the difference from Claude Code setup."
pubDate: 2026-08-18
slug: "healthkit-claude-desktop"
tags: ["claude-desktop", "healthkit", "apple-health", "mcp", "setup", "tutorial"]
draft: false
---

# HealthKit Data in Claude Desktop: Setup Guide

Claude Desktop is the macOS and Windows desktop application for Claude. It supports MCP servers using the same protocol as Claude Code, with a slightly different configuration file location. If Claude Desktop is your primary Claude client, here's the specific setup path.

## Claude Desktop vs Claude Code

Both Claude Desktop and Claude Code can use MCP servers. The difference is context:

- **Claude Desktop** is a GUI application — you chat with Claude in a window, and MCP tools are available in those conversations
- **Claude Code** is a terminal-based tool designed for coding workflows — MCP tools work in terminal sessions

For health data questions that don't involve code (checking your HRV, getting a morning brief, reviewing your sleep data), Claude Desktop is often the more natural interface. For building health data automations, writing scripts, or integrating health data into coding workflows, Claude Code makes more sense.

You can have the MCP server configured in both at the same time.

## Configuration File Location

Claude Desktop uses `claude_desktop_config.json`, stored at:

```
~/Library/Application Support/Claude/claude_desktop_config.json
```

If the file doesn't exist yet, create it. If it exists and has other MCP servers configured, add the health4ai block to the existing `mcpServers` object.

## Adding health4ai

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

Replace `/path/to/health4ai` with the absolute path to where you cloned the health4ai repository. Use the same `DATABASE_URL` and `HEALTHKIT_USER_ID` you configured for the iOS app.

After saving, **quit and relaunch Claude Desktop** (not just close the window — fully quit from the menu bar). Claude Desktop spawns MCP servers on launch.

## Verifying the Connection

In Claude Desktop, start a new conversation and ask:

*"What health tools do you have available?"*

Claude should list the health4ai tools — `get_health_summary`, `get_sleep`, `get_hrv_trend`, etc. If it doesn't, check:

1. The JSON in `claude_desktop_config.json` is valid (no trailing commas, proper nesting)
2. The path to `main.py` is correct and absolute
3. Python is available at the `python` command — if you use pyenv or conda, Claude Desktop may not have the same PATH as your terminal

For the PATH issue, use the full path to your Python interpreter:

```json
{
  "mcpServers": {
    "health4ai": {
      "command": "/usr/local/bin/python3",
      "args": ["/path/to/health4ai/mcp-server/main.py"],
      "env": {
        "DATABASE_URL": "postgresql://...",
        "HEALTHKIT_USER_ID": "your_user_id"
      }
    }
  }
}
```

Find the full path with `which python3` in your terminal.

## What's Different in Claude Desktop

The tool set is identical — `get_health_summary`, `get_hrv_trend`, `get_sleep`, `get_daily_snapshot`, and all the others work the same way.

The user experience difference: Claude Desktop conversations are more natural for open-ended health analysis. You can ask "how has my sleep been this month?" and get a formatted response without thinking about which tool Claude is calling. The tool calls happen transparently.

One practical note: Claude Desktop doesn't have a `/mcp` command like Claude Code does. To verify tools are visible, just ask Claude directly: *"What health data tools do you have access to?"*

## Running Both Claude Desktop and Claude Code

If you use both, configure the same MCP server block in both config files:

- Claude Desktop: `~/Library/Application Support/Claude/claude_desktop_config.json`
- Claude Code: `~/Library/Application Support/Claude/claude_desktop_config.json` (same file — Claude Code reads the same config)

Wait — Claude Code also reads `claude_desktop_config.json`. So configuring health4ai once in that file makes it available in both Claude Desktop and Claude Code. No duplicate configuration needed.

The MCP server process is spawned separately by each client when they launch, so both can be running simultaneously without conflicts.

## Common Use Cases in Claude Desktop

**Morning brief** — Open Claude Desktop in the morning and ask: *"Give me my health summary for today and how my HRV is trending."*

**Sleep review** — *"How was my sleep this week? Break down the stages by night."*

**Recovery check** — *"Pull my coaching brief. Should I train hard today or take it easier?"*

**Monthly review** — *"Compare my health metrics this month to last month."*

These are conversational, open-ended queries. Claude Desktop's chat interface is well suited for them. The health4ai tools handle the data retrieval; Claude handles the synthesis.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
