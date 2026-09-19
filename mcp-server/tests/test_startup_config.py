"""The server must refuse to start with an unusable HEALTHKIT_USER_ID.

Why (2026-09-14): unset -> '' -> Postgres raised `invalid input syntax for type uuid` on
every tool; left at the .env.example placeholder -> every tool answered no_data_yet. Both
read as a broken server rather than a missed setup step, and the message never named the
variable. main.py now validates before the server starts and points at docs/SETUP.md.

No database is touched: importing main only registers tools on the FastMCP instance.
"""
import os
import pathlib
import sys

import pytest

os.environ.setdefault("DATABASE_URL", "postgresql://unused:unused@localhost:1/unused")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))

import main  # noqa: E402
import tools  # noqa: E402
from health4ai import server as server_mod  # noqa: E402

VALID = "9f1c2a4e-7b3d-4c5e-8a6f-0d1e2f3a4b5c"


@pytest.mark.parametrize("raw", [None, "", "   "])
def test_unset_user_id_is_rejected_naming_the_variable(raw):
    with pytest.raises(ValueError, match="HEALTHKIT_USER_ID") as exc:
        tools.validate_user_id(raw)
    assert "not set" in str(exc.value)


def test_placeholder_user_id_is_rejected():
    with pytest.raises(ValueError, match="HEALTHKIT_USER_ID") as exc:
        tools.validate_user_id(tools.PLACEHOLDER_USER_ID)
    assert "placeholder" in str(exc.value)


@pytest.mark.parametrize("raw", ["jeff@example.com", "not-a-uuid", "12345"])
def test_non_uuid_user_id_is_rejected(raw):
    with pytest.raises(ValueError, match="HEALTHKIT_USER_ID") as exc:
        tools.validate_user_id(raw)
    assert "not a UUID" in str(exc.value)


def test_valid_user_id_is_canonicalised():
    assert tools.validate_user_id(f"  {VALID.upper()} ") == VALID


@pytest.mark.parametrize("raw", ["", tools.PLACEHOLDER_USER_ID, "nope"])
def test_startup_exits_before_serving_and_points_at_setup_doc(raw, capsys):
    with pytest.raises(SystemExit) as exc:
        main.check_startup_config(raw)
    assert exc.value.code == 2
    captured = capsys.readouterr()
    assert "HEALTHKIT_USER_ID" in captured.err and "docs/SETUP.md" in captured.err
    assert captured.out == "", "stdout is the MCP channel; nothing may be printed there"


def test_startup_accepts_a_real_uuid():
    assert main.check_startup_config(VALID) == VALID


def test_hosted_auth_path_and_http_transport_are_gone():
    assert not hasattr(main, "_resolve_user_from_mcp_key")
    assert not hasattr(server_mod, "_resolve_user_from_mcp_key")
    src = pathlib.Path(server_mod.__file__).read_text()
    for token in ("healthkit_api_keys", "MCP_AUTH_ENABLED", "--transport", "http_app"):
        assert token not in src.split('"""', 2)[2], f"{token} still present in server.py code"
