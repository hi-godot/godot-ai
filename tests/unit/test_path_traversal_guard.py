"""Source-structure regression tests for the path-traversal fix (issue #347, audit-v2 #3).

Before this fix, `script_handler.gd` and `filesystem_handler.gd` validated
resource paths only with `path.begins_with("res://")`, which accepts payloads
like `res://../etc/passwd.gd`. The fix adds `McpPathValidator` and replaces
every prefix-check call site in the named handlers with a validator call
that additionally rejects `..` substrings and boundary-violating paths.

These tests pin the structure so a future refactor can't silently
reintroduce the bare `begins_with("res://")` pattern in the affected
handlers (where every `path` originates from agent input and lands at a
real disk write or read).
"""

from __future__ import annotations

from pathlib import Path

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
PATH_VALIDATOR = PLUGIN_ROOT / "utils" / "path_validator.gd"
SCRIPT_HANDLER = PLUGIN_ROOT / "handlers" / "script_handler.gd"
FILESYSTEM_HANDLER = PLUGIN_ROOT / "handlers" / "filesystem_handler.gd"


def test_path_validator_file_exists() -> None:
    assert PATH_VALIDATOR.exists(), (
        "McpPathValidator must live at utils/path_validator.gd — handlers "
        "depend on the project-wide class_name to delegate path validation."
    )


def test_path_validator_declares_class_name() -> None:
    """Project-wide class_name lets handlers reference McpPathValidator without preload."""
    source = PATH_VALIDATOR.read_text()
    assert "class_name McpPathValidator" in source


def test_path_validator_implements_layered_checks() -> None:
    """The validator must implement every layer from issue #347's fix shape:
    non-empty, res:// prefix, no `..` substring, globalize-simplify
    normalisation, and boundary verification against the project root.

    Each layer catches a different escape vector — losing any of them silently
    weakens the security boundary without a single test failing on a single bad input.
    """
    source = PATH_VALIDATOR.read_text()
    # 1) non-empty guard — without this, an empty path silently passes the
    # prefix check (since "".begins_with("res://") is false, the prefix
    # error fires, but the message would name the wrong layer).
    assert "is_empty()" in source, (
        "validator must reject empty paths explicitly so the error message "
        "names the missing-param layer rather than the prefix layer."
    )
    # 2) prefix check
    assert 'begins_with("res://")' in source, "validator must check res:// prefix"
    # 3) literal `..` substring rejection — the cheap defence-in-depth layer
    assert '".." in path' in source, "validator must reject any path containing '..'"
    # 4) globalize → simplify normalisation
    assert "ProjectSettings.globalize_path" in source
    assert "simplify_path()" in source
    # 5) boundary verification against the project root
    assert "res_root" in source, (
        "validator must compare the simplified globalised path against the "
        "simplified project root — a missing boundary check lets encoded "
        "traversal payloads through even after `..` substring rejection."
    )


def test_script_handler_uses_path_validator_at_every_entry_point() -> None:
    """Every handler entry that takes a `path` param must delegate to McpPathValidator.

    Drift here is a security regression — if a future change re-inlines the
    bare prefix check, agent input flows back into the file write/read
    primitives without the `..` and boundary guards.
    """
    source = SCRIPT_HANDLER.read_text()
    # No bare prefix check remains in this file.
    assert 'begins_with("res://")' not in source, (
        'script_handler.gd must not contain bare `begins_with("res://")` '
        "checks — replace with McpPathValidator.validate_resource_path."
    )
    # Each listed entry point (issue #347) calls the validator.
    for func_name in ("create_script", "read_script", "patch_script", "find_symbols"):
        assert f"func {func_name}" in source, f"{func_name} missing from script_handler"
    # The validator helper is referenced — surface area covers all four entry
    # points; counting calls catches a partial revert.
    validator_calls = source.count("McpPathValidator.validate_resource_path")
    assert validator_calls >= 4, (
        f"script_handler.gd should call McpPathValidator.validate_resource_path "
        f"at least 4 times (create_script, read_script, patch_script, find_symbols); "
        f"found {validator_calls}"
    )


def test_filesystem_handler_uses_path_validator_at_every_entry_point() -> None:
    source = FILESYSTEM_HANDLER.read_text()
    assert 'begins_with("res://")' not in source, (
        'filesystem_handler.gd must not contain bare `begins_with("res://")` '
        "checks — replace with McpPathValidator.validate_resource_path."
    )
    for func_name in ("read_file", "write_file", "reimport"):
        assert f"func {func_name}" in source
    validator_calls = source.count("McpPathValidator.validate_resource_path")
    assert validator_calls >= 3, (
        f"filesystem_handler.gd should call McpPathValidator.validate_resource_path "
        f"at least 3 times (read_file, write_file, reimport); found {validator_calls}"
    )
