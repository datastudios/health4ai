---
title: "Running health4ai Locally with Ollama — Zero Cloud Required"
description: "How to connect health4ai's MCP server to Ollama via mcphost for a fully local, zero-cloud health data AI setup. Privacy posture and model recommendations."
pubDate: 2026-07-21
slug: "apple-health-ollama-local"
tags: ["ollama", "local-ai", "healthkit", "apple-health", "mcp", "privacy", "llama"]
draft: false
---

# Running health4ai Locally with Ollama — Zero Cloud Required

If you self-host and care about data locality, running health4ai with Ollama is the configuration where your health data never touches a cloud AI service. The data lives in your Postgres database. The MCP server runs on your Mac. The model runs on your Mac. Queries happen entirely on your hardware.

This is an option, not the only path. Claude Code is faster and more capable for complex analysis. But for developers who want full data sovereignty, the local stack works.

## What You Need

- health4ai installed and syncing (see the [setup guide](/blog/healthkit-supabase-setup))
- [Ollama](https://ollama.ai) installed on your Mac
- `mcphost` — a Go binary that bridges Ollama and MCP servers

## Installing mcphost

mcphost is a command-line tool that runs an Ollama model with MCP server support. Install it:

```bash
brew install mark3labs/mcphost/mcphost
```

Or build from source:

```bash
go install github.com/mark3labs/mcphost@latest
```

Verify it's installed:

```bash
mcphost --version
```

## Pulling a Model

For health data analysis, a model with strong instruction-following and JSON handling works better than a pure chat model. Some options:

```bash
# Llama 3.2 — good balance of speed and capability
ollama pull llama3.2

# Qwen 2.5 — strong at structured data tasks
ollama pull qwen2.5:7b

# Mistral — fast, good for structured queries
ollama pull mistral
```

For the kind of work health4ai tools return (JSON health summaries, trend data), any of these works. If you have a Mac with Apple Silicon and 16GB+ RAM, 7B models run at usable speeds. The 8B Llama 3.2 is around 30-40 tokens/sec on an M3 Pro.

## Running mcphost with health4ai

```bash
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```

Replace `/path/to/health4ai` with your actual path. The `--mcp-server` flag takes the format `name:command`.

If your MCP server needs environment variables (it does — `DATABASE_URL` and `HEALTHKIT_USER_ID`):

```bash
DATABASE_URL="postgresql://..." \
HEALTHKIT_USER_ID="your_id" \
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```

Or put them in the `.env` file in the `mcp-server/` directory — the server loads `.env` on startup via python-dotenv.

## Testing the Connection

Once mcphost starts, you get an interactive prompt. Test it:

```
> What health tools do you have available?
```

The model should list the health4ai tools. Then:

```
> Give me a health summary for the last 7 days.
```

The model calls `get_health_summary(days=7)`, gets the JSON response, and returns a natural-language summary.

## What Works Well vs What Doesn't

**Works well:**
- Health summaries and trend descriptions
- Simple questions with a clear tool call: "What's my HRV trend?" → `get_hrv_trend`
- Daily snapshot queries
- Sleep and workout summaries

**Works less well with smaller models:**
- Multi-step analysis requiring multiple tool calls in sequence
- Precise before/after comparisons using `compare_periods` (sometimes fails to construct the date parameters correctly)
- Complex reasoning that requires the model to synthesize multiple data sources

7B models have real capability limits for agentic tool use. Claude or GPT-4 class models are meaningfully better at multi-hop tool chains and at making correct parameter decisions for tools like `search_records` (which requires choosing the right threshold values). For straightforward health queries, local models are fine.

## Privacy Posture

With this setup:

- Your HealthKit data is in your Postgres database (Supabase, Neon, or local Docker)
- The MCP server runs as a local process on your Mac
- Ollama runs the model locally — no API calls to Anthropic, OpenAI, or anyone else
- Queries and responses are local — nothing leaves your machine except the database connection to your Postgres host

If your Postgres is also local (Docker on the same Mac), the setup is entirely air-gapped from cloud services. If you're using Supabase or Neon, your health data queries go to their servers, but the AI inference is local.

This is the highest-privacy configuration available. For health data, some people care about this. For most developers, the tradeoff (slower, less capable) isn't worth it — but the option is there.

## Running as a Background Service

If you want mcphost available without starting it manually:

```bash
# Create a LaunchAgent plist
cat > ~/Library/LaunchAgents/com.health4ai.mcphost.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.health4ai.mcphost</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/mcphost</string>
    <string>--model</string>
    <string>ollama/llama3.2</string>
    <string>--mcp-server</string>
    <string>health4ai:python /path/to/health4ai/mcp-server/main.py</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>DATABASE_URL</key>
    <string>postgresql://...</string>
    <key>HEALTHKIT_USER_ID</key>
    <string>your_id</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/com.health4ai.mcphost.plist
```

This starts mcphost at login and keeps it running.

---

health4ai: Free while in early access. Everyone in the founding batch gets lifetime access at $0.  
[Download on the App Store →](https://health4.ai)
