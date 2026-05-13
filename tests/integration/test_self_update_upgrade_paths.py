from __future__ import annotations

import shutil
from pathlib import Path

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    TEST_ZIP_NAME,
    assert_no_update_parse_errors,
    copy_addon_tree,
    create_plugin_zip,
    godot_bin_or_skip,
    load_smoke_script,
    patch_fixture_addon,
    prepare_project_shell,
    read_plugin_version,
    run_godot_editor,
    write_forward_driver,
)


def test_current_runner_upgrades_to_synthetic_next_without_parse_errors(
    tmp_path: Path,
) -> None:
    """Forward regression for the fixed runner.

    This stages current source as the installed base, builds a synthetic next
    release that adds a new file referencing a new constant on an existing
    load-surface script, and drives the real runner's `start(...)` path.
    """

    godot_bin = godot_bin_or_skip()
    smoke = load_smoke_script()
    project = tmp_path / "self-update-forward"
    base_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    next_version = smoke.bump_patch_version(base_version)
    server_version = base_version

    prepare_project_shell(project)
    write_forward_driver(project)

    base_addon = project / "addons" / "godot_ai"
    copy_addon_tree(PLUGIN_ROOT, base_addon)
    patch_fixture_addon(
        base_addon,
        version=base_version,
        server_version=server_version,
        next_version=next_version,
        skip_server_start=True,
    )

    vnext_addon = project / ".self-update-vnext" / "addons" / "godot_ai"
    copy_addon_tree(PLUGIN_ROOT, vnext_addon)
    patch_fixture_addon(
        vnext_addon,
        version=next_version,
        server_version=server_version,
        next_version=next_version,
        skip_server_start=True,
    )
    smoke.patch_vnext_hot_reload_trigger(vnext_addon / "mcp_dock.gd")
    patch_synthetic_next_shape(vnext_addon)

    zip_path = project / "_test_update_zip" / TEST_ZIP_NAME
    create_plugin_zip(vnext_addon, zip_path)

    log = run_godot_editor(project, godot_bin, allow_headless=True)

    assert_no_update_parse_errors(log)
    assert "SELF_UPDATE_TEST | synthetic handler marker synthetic_next" in log
    assert read_plugin_version(base_addon / "plugin.cfg") == next_version
    assert (base_addon / "handlers" / "self_update_synthetic_next.gd").is_file()

    shutil.rmtree(vnext_addon.parents[1], ignore_errors=True)


def patch_synthetic_next_shape(addon_dir: Path) -> None:
    error_codes = addon_dir / "utils" / "error_codes.gd"
    text = error_codes.read_text(encoding="utf-8")
    marker = 'const MISSING_REQUIRED_PARAM := "MISSING_REQUIRED_PARAM"\n'
    assert marker in text
    text = text.replace(
        marker,
        marker + 'const SYNTHETIC_NEXT_CONST := "synthetic_next"\n',
        1,
    )
    error_codes.write_text(text, encoding="utf-8")

    handler = addon_dir / "handlers" / "self_update_synthetic_next.gd"
    handler.write_text(
        """@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")


static func marker() -> String:
\treturn ErrorCodes.SYNTHETIC_NEXT_CONST
""",
        encoding="utf-8",
    )
