---
title: "Apple Health Privacy-First AI Integration: Your Data Never Leaves Your Database"
description: "How health4ai's architecture keeps your HealthKit data in your own Postgres instance — health4ai never sees it. Why this matters in 2026."
pubDate: 2026-07-28
slug: "apple-health-private-ai"
tags: ["privacy", "apple-health", "healthkit", "postgres", "supabase", "architecture", "data-ownership"]
draft: false
---

# Apple Health Privacy-First AI Integration: Your Data Never Leaves Your Database

Health data is personal in a way that most other data isn't. Heart rate variability trends, sleep patterns, medication adherence, blood glucose readings — this is information about your body over time. The question of where it lives and who can see it deserves a direct answer.

Here's exactly how health4ai handles it.

## The Architecture

health4ai is two components:

**1. An iOS app** that reads from HealthKit on your iPhone and writes to a Postgres database you specify. The app connects to your database over TLS using a connection string you provide. It has no server of its own. There is no health4ai server that receives your data.

**2. An MCP server** that runs as a local process on your Mac. It connects to your Postgres database and exposes your health data as tool calls for Claude Code, Cursor, or any MCP-compatible client. Again: no health4ai server. The MCP server talks directly to your database.

The flow is:

```
Apple Watch → HealthKit → health4ai iOS app → your Postgres database
                                                        ↑
                                           health4ai MCP server (local, on your Mac)
                                                        ↑
                                               Claude Code / Cursor
```

health4ai is not in this chain as a data processor. Your health data goes from your iPhone to your database. That's it.

## What health4ai Never Sees

- Your health metrics
- Your database credentials (the connection string stays on your device and in your local MCP config)
- Your query history
- Which AI tools you're calling
- Anything you ask Claude about your health

The iOS app needs network access to reach your Postgres host. That's the only outbound connection the app makes. It doesn't phone home to a health4ai API. There's no analytics SDK. There's no telemetry.

## Your Database Choices and What They Mean

**Supabase (managed Postgres):** Your data lives in Supabase's infrastructure. Supabase operates under standard managed-service terms. Your data is in their data centers, but health4ai is not a processor — Supabase is your database provider, and you're the controller. If you're already using Supabase, the privacy posture is the same as any other data you store there.

**Neon (serverless Postgres):** Same model. Your data is in Neon's infrastructure. You control the database.

**Self-hosted Postgres (Docker or local):** This is the highest-privacy option. If you run Postgres locally on the same machine as the MCP server, your health data never leaves your hardware at all. The iOS app still needs to reach your Mac's IP (or a tunnel) to sync, but no third-party cloud provider sees the data.

**Local Postgres accessible only via Tailscale:** A common self-hosted setup. The iOS app connects via your Tailscale network. Traffic is encrypted point-to-point. This is air-gapped from public cloud providers entirely.

## What About the AI?

When you query your health data in Claude Code, the tool call returns JSON from your Postgres database. That JSON — your actual health metrics — goes into the Claude API request as part of the conversation context. Anthropic's standard data handling terms apply.

If this is a concern, the Ollama path described in [the local setup guide](/blog/apple-health-ollama-local) handles it: the model runs locally, the tool call returns data locally, and nothing leaves your machine. The tradeoff is model capability.

For most developers, sending health metrics to the Claude API is acceptable — it's the same data you'd share with any health analytics service, and the analysis is why you're doing this. But the option to keep it fully local exists.

## No Account Required

health4ai doesn't have user accounts. You don't create a health4ai account to use the product. The user ID in your configuration (`HEALTHKIT_USER_ID`) is a string you choose — it namespaces your data in your own database. health4ai doesn't know what value you used.

This is deliberate. An account system would require health4ai to store at least an email address and a link between you and your database. We chose not to build that. There's nothing to subpoena.

## Open Source

The MCP server is open source. You can read exactly what queries it runs, what data it returns, and what it logs. The iOS app isn't open source yet, but the data pathway is auditable: the app writes to the `healthkit_metrics` table in your database, and you can verify what's there.

If you're evaluating this for organizational use or building on top of it, the source is at [github.com/health4ai/health4ai](https://github.com/health4ai/health4ai).

## Practical Privacy Posture

For most people using health4ai:

- Apple Health data goes to their Supabase or Neon database
- The MCP server runs on their Mac and never forwards data anywhere
- AI queries go to the Claude API with health data in context
- health4ai as a company sees none of it

For people who want maximum privacy:

- Self-hosted Postgres on the same machine
- Ollama for local inference
- Tailscale for iPhone sync

Both configurations are fully supported. The architecture is the same — you're just choosing how much you trust the third-party services involved.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
