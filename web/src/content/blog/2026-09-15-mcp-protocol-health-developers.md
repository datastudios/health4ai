---
title: "The MCP Protocol Explained for Health Developers"
description: "A technical walkthrough of MCP for developers building health data integrations — protocol mechanics, tool definition, transport options, and why it fits health data."
pubDate: 2026-09-15
slug: "mcp-protocol-health-developers"
tags: ["mcp", "model-context-protocol", "healthkit", "developer", "protocol", "tools", "architecture"]
draft: false
---

# The MCP Protocol Explained for Health Developers

The Model Context Protocol (MCP) is Anthropic's open protocol for connecting AI models to external data and services. For health data developers, it's the mechanism that makes HealthKit data queryable in Claude Code, Cursor, and any other MCP-compatible AI client. Here's a technical walkthrough.

## Protocol Structure

MCP defines a client-server architecture where:

- The **MCP client** is the AI application (Claude Code, Cursor, etc.)
- The **MCP server** is a process that exposes data as tools
- Communication happens via JSON-RPC 2.0 messages

The server exposes three primitive types:

**Tools** — callable functions. The client invokes them; the server executes and returns JSON.  
**Resources** — readable data (files, database records, API responses). Less common for health data integrations.  
**Prompts** — reusable prompt templates. Rarely used in production health tools.

For health data, tools are almost always what you want.

## What a Tool Definition Looks Like

A health4ai tool in MCP's protocol format:

```json
{
  "name": "get_hrv_trend",
  "description": "HRV (SDNN) trend over the past N days. Returns daily averages, 7-day rolling comparison, and trend direction. Tier-aware: windows beyond 30 days use daily summaries.",
  "inputSchema": {
    "type": "object",
    "properties": {
      "days": {
        "type": "integer",
        "description": "Number of days to look back (default 30, max 1825)",
        "default": 30
      }
    }
  }
}
```

The AI client reads these definitions on startup. When you ask "what's my HRV trend?", the model matches your intent to the `get_hrv_trend` tool based on the name and description, constructs the input (`{"days": 30}`), and sends a `tools/call` request to the server.

## Transport: stdio vs HTTP

MCP supports two transports:

**stdio** — The client spawns the server as a subprocess and communicates via stdin/stdout. This is the most common transport for local MCP servers.

In `claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "health4ai": {
      "command": "python",
      "args": ["/path/to/mcp-server/main.py"],
      "env": {
        "DATABASE_URL": "postgresql://...",
        "HEALTHKIT_USER_ID": "user123"
      }
    }
  }
}
```

Claude Code spawns `python main.py` on startup. The server reads JSON-RPC from stdin and writes responses to stdout. When Claude Code exits, the server subprocess exits too.

**HTTP with SSE** — The server runs as an HTTP service. The client connects via Server-Sent Events for server-to-client streaming. Used when the server is remote or needs to persist independently of the client.

For health data on a personal machine, stdio is simpler and is what health4ai uses by default.

## The Tool Call Sequence

What happens when you ask Claude "what's my HRV trend for the last 30 days?":

1. **Client → Server:** `initialize` — client announces its capabilities; server responds with its protocol version and tool list

2. **Client → Server:** `tools/list` — client fetches all available tools with their schemas

3. Claude decides `get_hrv_trend(days=30)` is appropriate

4. **Client → Server:** `tools/call {"name": "get_hrv_trend", "arguments": {"days": 30}}`

5. **Server:** runs the query against Postgres, builds the response

6. **Server → Client:** Returns the JSON result

7. Claude incorporates the result into its response to you

Steps 1-2 happen at startup. Steps 3-7 happen per tool call. Multiple tool calls in one conversation each go through steps 3-7.

## Implementing a Health Tool in Python

A minimal MCP server tool implementation using the official Python SDK:

```python
from mcp.server import Server
from mcp.server.models import InitializationOptions
import mcp.types as types
import asyncio

server = Server("health4ai")

@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="get_hrv_trend",
            description="HRV trend over N days with trend direction",
            inputSchema={
                "type": "object",
                "properties": {
                    "days": {"type": "integer", "default": 30}
                }
            }
        )
    ]

@server.call_tool()
async def handle_call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    if name == "get_hrv_trend":
        from tools import get_hrv_trend
        result = get_hrv_trend(days=arguments.get("days", 30))
        return [types.TextContent(type="text", text=str(result))]
    raise ValueError(f"Unknown tool: {name}")

async def main():
    from mcp.server.stdio import stdio_server
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, InitializationOptions())

if __name__ == "__main__":
    asyncio.run(main())
```

The tool registration (`@server.list_tools()`) defines what the AI client sees. The tool handler (`@server.call_tool()`) executes the query and returns results.

## Design Considerations for Health Tools

**Description quality matters.** The AI model decides which tool to call based on the description. "Get HRV trend" is less useful than "HRV (SDNN) trend over the past N days. Returns daily averages, 7-day rolling comparison, and trend direction. Use for recovery monitoring and trend analysis." The description is training data for the model's tool selection.

**Return JSON, not text.** Return structured JSON from health tool implementations. The AI model is better at synthesizing structured data than parsing text. Return `{"avg_hrv_ms": 54.2, "trend": "improving", "daily_averages": [...]}` rather than `"Your average HRV was 54.2ms and it's improving."` — that's the AI's job.

**Validate inputs before touching the database.** Clamp `days` to a maximum (health4ai uses 1825, roughly 5 years). Validate date formats for tools that accept dates. Return an error dict rather than raising an exception — MCP clients handle error returns more gracefully than protocol-level errors.

**Handle the tiered data model.** If your schema has a raw/summary split, the tool should route transparently. The caller shouldn't need to know whether to query `healthkit_metrics` or `healthkit_daily_summaries` — that's implementation detail.

## Testing MCP Tools Without a Full Client

During development, you can test your MCP server directly by sending JSON-RPC messages via stdin:

```bash
echo '{"jsonrpc": "2.0", "method": "tools/list", "id": 1}' | python main.py
echo '{"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "get_hrv_trend", "arguments": {"days": 7}}, "id": 2}' | python main.py
```

For more comfortable testing, the `mcp` CLI (from the `mcp` Python package) provides an inspector:

```bash
pip install mcp
mcp dev main.py
```

This opens an interactive tool inspector where you can call tools and inspect responses without a full AI client.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
