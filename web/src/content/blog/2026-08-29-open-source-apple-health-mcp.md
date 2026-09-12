---
title: "Why I Open-Sourced My Apple Health MCP Server"
description: "The decision to open source health4ai's MCP server — why privacy-first health data tools need public code, and what the community gets from it."
pubDate: 2026-08-29
slug: "open-source-apple-health-mcp"
tags: ["open-source", "mcp", "apple-health", "healthkit", "privacy", "community"]
draft: false
legacySetup: true
---

# Why I Open-Sourced My Apple Health MCP Server

When we decided to open source the health4ai MCP server, it wasn't primarily a marketing decision. It was the right thing to do for a tool that handles personal health data, and the reasoning is worth explaining.

## Health Data Deserves Transparency

If you're routing your heart rate, HRV, sleep stages, and body composition through a piece of software, you should be able to read that software.

This sounds obvious, and it is. But most health software — even software that advertises privacy — is closed source. You're taking the developer's word for it that they're not logging your queries, storing your data, or selling your usage patterns. For a bank account or shopping history, you might tolerate that. For your health data, the asymmetry feels wrong.

health4ai's iOS app is closed source for now (the App Store review process and third-party SDK complexity make open sourcing iOS apps harder than server-side code). But the MCP server — the piece that runs on your machine, queries your health data, and talks to the AI — is open. You can read every query it runs. You can verify it doesn't log data. You can see exactly what the tools return.

That's the minimum that should be true for health data tooling.

## The Audit Argument

Security researchers and privacy advocates can read the code. If there's something wrong — a leaky logging statement, an unintentional data exposure, an insecure default — the community finds it faster than we would internally.

We built health4ai as two developers working on a personal problem. We are not a security team. Open source doesn't guarantee security, but it adds external eyes that closed source can't have.

For a tool that accesses a database full of your most personal data, that matters.

## Forkability

The MCP server implements a specific set of tools for a specific set of metrics with a specific schema. That's the right approach for us. It's not the right approach for everyone.

Someone building a training performance tool might want to add specialized running economy metrics and expose them as distinct tools. Someone building a clinical research application might want different aggregations, different data retention, different privacy controls. A developer who wants to integrate Oura's API alongside HealthKit needs a different data model.

Open source makes these adaptations possible. You can fork, extend, and modify without waiting for us to prioritize your use case.

## What "Open Source" Actually Means Here

The MCP server ([github.com/health4ai/health4ai](https://github.com/health4ai/health4ai)) is MIT licensed. You can:

- Read the code (the point)
- Run it for personal use (the main use case)
- Modify it for your needs
- Contribute improvements back
- Build products on top of it (with attribution)

The schema — the two Postgres tables that the iOS app writes to — is public in `web/public/schema.sql`. If you want to build your own iOS app, your own sync system, or a different MCP server against the same schema, you can.

## The Community Angle

The developer community around quantified-self and health data AI is still small. If we keep the MCP server proprietary, we're the only people who can improve it. Open source means someone else can add the nutrition tools we haven't gotten to, improve the sleep analysis query for Garmin users, or fix a bug we haven't found yet.

Several open-source HealthKit projects exist — Health Bridge, Open Wearables, the vpetersson and shuyangli GitHub repos. They all handle pieces of the puzzle. None of them put iOS + Postgres + MCP together as a complete stack. health4ai's contribution is that integration.

## What We Kept Closed

The iOS app isn't open source yet. The reasons are practical:

- The App Store submission process requires code that passes Apple's review criteria
- Third-party SDKs (analytics, crash reporting) have licensing terms that complicate open sourcing
- iOS app distribution is meaningfully harder than server distribution — open sourcing without a clear contribution path creates noise without benefit

This may change. If the project reaches the scale where community iOS contributions make sense, we'll revisit it.

## The Honest Part

Open source also builds trust with the developer community, and that community is who we're building for. A developer evaluating health4ai wants to know the data path is clean before routing their biometrics through it. Reading the code is more convincing than any privacy policy.

We knew this going in. If it's also good for distribution — if open source means more developers discover health4ai, use it, and tell others about it — that's a real benefit too. The privacy argument and the community building argument aren't in conflict.

If you find something in the code that concerns you, open an issue. If you see something that could work better, open a PR. The whole point is that you can.

---

health4ai: Free while in early access.  
[Download on the App Store →](https://health4.ai)
