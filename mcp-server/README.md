# health4ai MCP server

Local MCP server that queries **your** Apple Health data from a Supabase/Postgres project you own. Use it with Claude Desktop, Claude Code, Cursor, or any stdio MCP client.

<!-- mcp-name: io.github.jefflitt1/health4ai -->

## Install

```bash
pip install health4ai
```

Requires Python 3.11+. From a clone of the repo you can still run the previous path:

```bash
pip install -r mcp-server/requirements.txt
python mcp-server/main.py
```

## Configure

The server talks to **your** database over stdio. Set these environment variables (or a `.env` file in the working directory):

| Variable | Required | Secret | Description |
|---|---|---|---|
| `DATABASE_URL` | yes | yes | Postgres connection string for your Supabase project (transaction pooler; database password, not the service_role key). `SUPABASE_DB_URL` is accepted as an alias. |
| `HEALTHKIT_USER_ID` | yes | no | UUID of the Supabase Auth user whose HealthKit rows to query. The server refuses to start if this is unset, not a UUID, or the `00000000-…` placeholder. |
| `HEALTH4AI_TZ` | no | no | IANA time zone for calendar-day buckets (default `UTC`). |

Full walkthrough: [docs/SETUP.md](https://github.com/jefflitt1/health4ai/blob/main/docs/SETUP.md).

## Run

After `pip install health4ai`:

```bash
health4ai
# or
python -m health4ai
```

Claude Desktop / Claude Code / Cursor (`mcp.json`):

```json
{
  "mcpServers": {
    "health4ai": {
      "command": "health4ai",
      "env": {
        "DATABASE_URL": "postgresql://...",
        "HEALTHKIT_USER_ID": "<your auth user UID>"
      }
    }
  }
}
```

From a git clone, `"command": "python"` and `"args": ["/path/to/health4ai/mcp-server/main.py"]` still work.

## License

MIT. See the repository [LICENSE](https://github.com/jefflitt1/health4ai/blob/main/LICENSE).
