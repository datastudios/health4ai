# health4ai — Setup Guide

## Step 1: Set up a backend you control

### Supabase (recommended for the iOS app)

Use a Supabase project you own. Do not use another person's project URL,
credentials, or database account.

```bash
supabase db push
supabase functions deploy healthkit-ingest
```

The migrations include `009_healthkit_metrics_tenant_isolation.sql`, which makes
the hosted ingestion table deny direct anon/authenticated access. The Edge
Function validates the signed-in user's JWT and writes only under that user's ID.
Create your own Supabase user in your project dashboard, then enter your project
URL and anon key in the app and sign in with that user.

### Private Postgres / Neon / local Docker

The portable schema below is for a database owned by one person. It is not a
shared multi-user Supabase configuration; use the Supabase path above for the
iOS app's built-in authentication and hosted ingestion flow.

Run the schema against your chosen backend:

```bash
psql "$DATABASE_URL" < web/public/schema.sql
```

**Supabase:** get `DATABASE_URL` from Settings → Database → Connection string (URI).
**Neon:** get it from Connection Details.
**Local Docker:** `postgresql://postgres:yourpassword@localhost:5432/postgres`

If using Supabase and the schema needs to go through the Management API:

```bash
export SUPABASE_PAT="sbp_your_personal_access_token"
PROJECT_REF="your_project_ref"

curl -X POST \
  "https://api.supabase.com/v1/projects/$PROJECT_REF/database/query" \
  -H "Authorization: Bearer $SUPABASE_PAT" \
  -H "Content-Type: application/json" \
  -H "User-Agent: health4ai-setup" \
  -d @- < <(jq -Rs '{query: .}' < web/public/schema.sql)
```

## Step 2: Configure the MCP Server

```bash
cd mcp-server
cp .env.example .env
# Edit .env — add DATABASE_URL and HEALTHKIT_USER_ID

pip install -r requirements.txt
python main.py  # test it runs
```

## Step 3: Add to your AI client

**Claude Code / Claude Desktop** — add to `claude_desktop_config.json`:

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

**Cursor** — same block in `~/.cursor/mcp.json`.

**Ollama (fully local):**
```bash
mcphost --model ollama/llama3.2 \
  --mcp-server "health4ai:python /path/to/health4ai/mcp-server/main.py"
```

## Step 4: iOS App

1. Open `ios/Health4AI.xcodeproj` in Xcode
2. Set your Team in Signing & Capabilities
3. Build and run on your iPhone (iOS 17+)
4. Enter your database credentials and tap **Start Sync**

The first launch runs a full backfill of your HealthKit history — this can take a few minutes depending on data volume.

For TestFlight cohorts, also follow [Private TestFlight beta](TESTFLIGHT-BETA.md).

## Step 5: Verify

In your AI client, ask: *"Give me a health summary for the last 7 days."* You should get a response with steps, HRV, and sleep data.

Run `/mcp` in Claude Code to confirm the `health4ai` server is listed with its tools.
