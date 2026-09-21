"""Keep Godot's native shared progress dialog alive through plugin teardown."""

import json
import shutil
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    load_smoke_script,
    run_godot_editor,
)

pytestmark = pytest.mark.editor


def test_progress_dialog_survives_real_plugin_disable_and_class_scan(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "progress-dialog"
    addon = project / "addons" / "godot_ai"
    shutil.copytree(PLUGIN_ROOT, addon)
    # Exercise production teardown without starting a server or configuring clients.
    (addon / "fixture_plugin.gd").write_text(
        '@tool\nextends "res://addons/godot_ai/plugin.gd"\n'
        '\nfunc _enter_tree() -> void:\n'
        '\t_dock = load("res://addons/godot_ai/mcp_dock.gd").new()\n'
        '\tadd_control_to_dock(DOCK_SLOT_RIGHT_UL, _dock)\n', encoding="utf-8",
    )
    cfg = addon / "plugin.cfg"
    cfg.write_text(cfg.read_text(encoding="utf-8").replace(
        'script="plugin.gd"', 'script="fixture_plugin.gd"'), encoding="utf-8")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Progress dialog lifetime"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")\n'
        '[autoload]\nProgressDriver="*res://driver.gd"\n', encoding="utf-8",
    )
    shutil.copyfile(Path(__file__).with_name("_progress_dialog_lifetime.gd"), project / "driver.gd")
    smoke = load_smoke_script()
    smoke.prepare_isolated_client_environment(project, base_version="4.0.4", http_port=0, ws_port=0)
    environment = smoke.godot_child_environment(project)
    environment.update({
        "APPDATA": str(tmp_path / "roaming"),
        "XDG_DATA_HOME": str(tmp_path / "data"),
        "XDG_CACHE_HOME": str(tmp_path / "cache"),
    })
    log = run_godot_editor(
        project, godot, allow_headless=False, timeout=90,
        environment=environment,
    )
    assert "SCRIPT ERROR:" not in log, log
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    assert result["failures"] == [], result
    assert result["progress_id_before"] == result["progress_id_after"]
    assert result["old_dialog_destroyed"]
    assert result["class_registered"]
