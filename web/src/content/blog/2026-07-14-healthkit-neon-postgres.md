---
title: "Can health4ai use Neon? Not with the iOS app"
description: "health4ai's iOS app signs in with Supabase Auth and writes through a Supabase Edge Function, so Neon and other plain Postgres hosts are not a supported backend. Here is why, and what to use instead."
pubDate: 2026-07-14
slug: "healthkit-neon-postgres"
tags: ["neon", "postgres", "supabase", "setup", "apple-health", "mcp"]
draft: false
---

# Can health4ai use Neon? Not with the iOS app

An earlier version of this post walked through setting up health4ai on Neon. That setup could not work, so this post now explains why and what to use instead.

## Why Neon doesn't work

health4ai has two halves.

- **The iOS app** reads Apple Health and sends your samples to your backend. It signs in with Supabase Auth and posts to a Supabase Edge Function called `healthkit-ingest`, which checks your token and writes rows only under your user ID.
- **The MCP server** runs on your machine and reads those rows so your AI client can query them.

The MCP server connects to Postgres directly, so on its own it could read a Neon database. The problem is the other half. Neon has no Supabase Auth and no Edge Functions, and health4ai ships no other way to get data in. A Neon database set up the way the old post described would stay empty.

The old post also told you to enter your Neon connection string in the app. The app never accepted a database connection string, and the REST / Webhook option some builds showed never synced a row. That option is being removed.

## What to use instead

A free Supabase project you own. You run one schema file, deploy one Edge Function, create one user, and point the app at it. health4ai still runs no server and never sees your data, because the project belongs to you.

The short version is in [How to Set Up health4ai with Supabase](/blog/healthkit-supabase-setup), and the full reference is the [setup guide](https://github.com/jefflitt1/health4ai/blob/main/docs/SETUP.md).

## If you already followed the old post

Nothing on that Neon database needs keeping for health4ai. It will not have received any samples. You can delete it and follow the Supabase setup from the start.
