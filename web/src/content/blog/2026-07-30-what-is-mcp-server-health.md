---
title: "What Is an MCP Server? (And Why Your Health Data Needs One)"
description: "MCP explained for developers new to it — what the Model Context Protocol is, how MCP servers work, and why health data is a natural fit for this architecture."
pubDate: 2026-07-30
slug: "what-is-mcp-server-health"
tags: ["mcp", "model-context-protocol", "healthkit", "apple-health", "explainer", "claude-code"]
draft: false
---

# What Is an MCP Server? (And Why Your Health Data Needs One)

MCP stands for Model Context Protocol. It's a protocol Anthropic published in late 2024 that defines how AI clients (Claude Code, Cursor, any compatible tool) communicate with external data sources and services. An MCP server is a process that implements this protocol and exposes a set of callable tools to an AI client.

If that's abstract, a concrete example makes it clear.

## What an MCP Server Actually Does

When you run Claude Code, it has access to your file system and bash commands. That's useful for code. For health data, Claude has nothing — your HealthKit data isn't a file on your disk, it's in a database. Claude doesn't know the database schema, doesn't know what queries to run, and has no way to reach your Postgres instance.

An MCP server bridges this. It's a process running on your machine that:

1. Connects to your database
2. Implements a set of named functions (tools) — things like `get_health_summary(days=30)` or `get_hrv_trend(days=90)`
3. Listens for tool call requests from the AI client (via stdio or network)
4. Executes the queries and returns structured JSON

From Claude's perspective, the tools are just functions it can call. It doesn't know (or care) that `get_hrv_trend` runs a SQL query against a Postgres table. It calls the function, gets JSON back, and uses that to answer your question.

## The Protocol in Plain Terms

MCP defines three things:

**Tools** — callable functions with defined parameters and return schemas. The server advertises what tools it has, and the AI client decides when to call them.

**Resources** — static or dynamic content the server can provide. Less common for data tools, more common for document/file servers.

**Prompts** — reusable prompt templates. Niche feature, not core to most implementations.

For health data, tools are what matter. A tool has:
- A name (`get_daily_snapshot`)
- A description (what it does, when to call it)
- Parameter schema (JSON Schema)
- A return type

The AI client reads the tool descriptions to understand what's available. When you ask "what's my HRV trend?" Claude looks at the available tools, decides `get_hrv_trend` is the right one, constructs the call, and sends it to the MCP server.

## Why Health Data Specifically Needs This

Health data has properties that make MCP a natural fit:

**It's structured but multi-dimensional.** You don't want to paste 5,000 heart rate readings into a chat window. You want a function that returns the relevant aggregation for your question.

**It requires domain logic.** "What's my HRV trend?" isn't a SQL query — it's a HRV time series, a comparison between last 7 days and prior 7 days, and a direction classification. The MCP server implements that logic once, and every tool call benefits from it.

**It lives in a database, not a file.** Claude Code can read files. It can't query Postgres unless something bridges them. MCP is that bridge.

**It's personal and persistent.** Unlike a one-time file read, health data grows continuously. An MCP server backed by a database makes it queryable at any time, with any time window.

## How the AI Client Uses the Tools

When you add an MCP server to Claude Code's config and ask a health question, the sequence is:

1. Claude Code reads the tool manifest from the health4ai MCP server on startup
2. You ask: *"How was my sleep last week?"*
3. Claude identifies `get_sleep(days=7)` as the right tool
4. Claude sends the tool call to the MCP server
5. The MCP server queries your Postgres database
6. The JSON response comes back: per-night sleep stages, totals, average hours
7. Claude synthesizes the JSON into a natural-language answer

You don't write SQL. You don't parse JSON. You ask a question, and the AI handles the tool call.

## What MCP Is Not

**It's not an AI model.** MCP is a protocol, not a model. The AI intelligence (Claude, in this case) is separate from the MCP server. The MCP server is dumb — it runs queries and returns data. The reasoning happens in the AI client.

**It's not a cloud service.** MCP servers run wherever you run them. For health4ai, the MCP server runs locally on your Mac as a subprocess of Claude Code. It talks to your database over a normal database connection. Nothing about MCP requires cloud infrastructure.

**It's not proprietary to Anthropic.** The protocol is open. Claude Code, Cursor, Windsurf, and several other AI clients support it. Tools built for one MCP-compatible client work in others.

## Setting Up the MCP Server

Adding health4ai's MCP server to Claude Code takes one config block:

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

Claude Code spawns the Python process on startup. The process connects to your database and waits for tool calls. When you ask health-related questions, Claude calls the tools and returns answers.

Run `/mcp` in Claude Code to see the registered servers and their tools. You'll see the full list of health4ai tools — `get_health_summary`, `get_hrv_trend`, `get_sleep`, and the rest — with their descriptions and parameter schemas.

The protocol itself is transparent. Once you've seen MCP work once, the model is clear: tools are functions, the server is the implementation, the AI is the caller.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
