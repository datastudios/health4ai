"""Thin shim so `python main.py` from a clone still starts the MCP server."""

from health4ai.server import check_startup_config, main, mcp

__all__ = ["check_startup_config", "main", "mcp"]

if __name__ == "__main__":
    main()
