"""Smoke checks for the PyPI package layout and MCP registry metadata."""

import json
import os
import pathlib
import sys

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

import health4ai  # noqa: E402
from health4ai.server import main as server_main  # noqa: E402
import main as main_shim  # noqa: E402

REPO_ROOT = ROOT.parent
MCP_NAME = "io.github.jefflitt1/health4ai"
MARKER = f"<!-- mcp-name: {MCP_NAME} -->"


def test_package_version():
    assert health4ai.__version__ == "0.1.0"


def test_console_script_points_at_server_main():
    pyproject = (ROOT / "pyproject.toml").read_text()
    assert 'name = "health4ai"' in pyproject
    assert 'health4ai = "health4ai.server:main"' in pyproject
    assert callable(server_main)


def test_clone_shim_reexports_server_main():
    assert main_shim.main is server_main
    assert callable(main_shim.check_startup_config)


def test_mcp_name_marker_in_package_readme():
    readme = (ROOT / "README.md").read_text()
    assert MARKER in readme


def test_server_json_matches_package():
    data = json.loads((REPO_ROOT / "server.json").read_text())
    assert data["name"] == MCP_NAME
    assert data["version"] == health4ai.__version__
    assert data["websiteUrl"] == "https://health4.ai"
    assert data["repository"]["url"] == "https://github.com/jefflitt1/health4ai"
    assert data["repository"]["source"] == "github"
    assert data["repository"]["subfolder"] == "mcp-server"
    assert len(data["description"]) <= 100
    pkg = data["packages"][0]
    assert pkg["registryType"] == "pypi"
    assert pkg["identifier"] == "health4ai"
    assert pkg["version"] == health4ai.__version__
    assert pkg["transport"]["type"] == "stdio"
    env_names = {item["name"]: item for item in pkg["environmentVariables"]}
    assert env_names["DATABASE_URL"]["isRequired"] is True
    assert env_names["DATABASE_URL"]["isSecret"] is True
    assert env_names["HEALTHKIT_USER_ID"]["isRequired"] is True
