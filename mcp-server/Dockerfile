# Exists for Glama's MCP-directory introspection (commit cb65793); the documented setup
# path is `python main.py` (or the `health4ai` console script) launched by the MCP client
# over stdio, not a container.
# The image runs the same stdio server; the MCP client attaches to the container's stdin.
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Only the server modules. .dockerignore additionally keeps .env, .venv and tests out.
COPY main.py tools.py ./
COPY health4ai ./health4ai

# Required at runtime (never baked in):
#   docker run -i -e DATABASE_URL=postgresql://... -e HEALTHKIT_USER_ID=<uuid> \
#              [-e HEALTH4AI_TZ=America/New_York] health4ai-mcp
# The server refuses to start without a usable HEALTHKIT_USER_ID.
CMD ["python", "main.py"]
