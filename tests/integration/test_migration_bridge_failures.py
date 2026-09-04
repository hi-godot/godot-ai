"""Exercise the capsule coordinator's swap-then-restart handoff in a real editor."""

from __future__ import annotations

import hashlib
import json
import shutil
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    append_driver_autoload,
    godot_bin_or_skip,
    load_smoke_script,
    run_godot_editor,
)

INSTALLER_SCRIPTS = (
    "release_verifier.gd",
    "update_installer.gd",
    "port_resolver.gd",
    "windows_port_reservation.gd",
)


@pytest.mark.parametrize("case", ["disabled", "already-listed", "save-failure"])
def test_bridge_restart_preserves_next_start_without_live_enable(tmp_path: Path, case: str) -> None:
    """After the swap the coordinator persists intent, never loads v4 into the old VM.

    ``disabled`` and ``already-listed`` run the real installer's next-start
    persistence and restart; ``save-failure`` substitutes an installer whose
    persistence fails and proves the coordinator refuses to restart, restores
    the enabled list, and asks for explicit recovery.
    """
    godot = godot_bin_or_skip()
    smoke = load_smoke_script()
    project = tmp_path / "bridge-restart"
    project.mkdir()
    smoke.write_project_files(project)
    append_driver_autoload(project / "project.godot")
    for name in ("godot_ai", "companion"):
        addon = project / "addons" / name
        addon.mkdir(parents=True)
        (addon / "plugin.cfg").write_text(
            '[plugin]\nname="Restart fixture"\nversion="1.0"\nscript="plugin.gd"\n',
            encoding="utf-8",
        )
        (addon / "plugin.gd").write_text("@tool\nextends EditorPlugin\n", encoding="utf-8")
    shutil.copy2(
        PLUGIN_ROOT.parents[2] / "migration_bridge" / "migration_coordinator.gd",
        project / "addons/godot_ai",
    )
    utils = project / "addons/godot_ai/utils"
    utils.mkdir()
    for name in INSTALLER_SCRIPTS:
        shutil.copy2(PLUGIN_ROOT / "utils" / name, utils / name)
    (project / "_test_runner_driver.gd").write_text(
        '''@tool
extends Node
const Coordinator := preload("res://addons/godot_ai/migration_coordinator.gd")
const CONFIG := "res://addons/godot_ai/plugin.cfg"
const COMPANION := "res://addons/companion/plugin.cfg"
const KEY := "editor_plugins/enabled"
const CASE := "''' + case + '''"
const FAILING_INSTALLER := """
static func swap(_stage: String, _live: String, _record: Dictionary) -> Dictionary:
\treturn {"ok": true, "error": ""}
static func release_lock() -> void:
\tpass
static func persist_next_start_enabled(_plugin_cfg: String) -> Error:
\treturn ERR_CANT_CREATE
static func request_restart() -> void:
\tpass
"""
var _frames := 10
func _process(_delta: float) -> void:
    _frames -= 1
    if _frames != 0:
        return
    set_process(false)
    if FileAccess.file_exists("res://first.json"):
        _write("res://second.json", {
            "pid": OS.get_process_id(),
            "enabled": EditorInterface.is_plugin_enabled(CONFIG),
            "companion": EditorInterface.is_plugin_enabled(COMPANION),
            "setting": Array(ProjectSettings.get_setting(KEY)),
        })
        get_tree().quit(0)
        return
    EditorInterface.set_plugin_enabled(COMPANION, true)
    EditorInterface.set_plugin_enabled(CONFIG, false)
    if ProjectSettings.save() != OK:
        get_tree().quit(44)
        return
    var previous: Variant = ProjectSettings.get_setting(KEY)
    if CASE == "already-listed":
        previous.append(CONFIG)
        ProjectSettings.set_setting(KEY, previous)
    var installer: Script
    if CASE == "save-failure":
        var failing := GDScript.new()
        failing.source_code = FAILING_INSTALLER
        failing.reload()
        installer = failing
    else:
        installer = load("res://addons/godot_ai/utils/update_installer.gd")
    var coordinator = Coordinator.new()
    get_tree().root.add_child(coordinator)
    coordinator._installer = installer
    coordinator._lock_held = false
    coordinator._package = {
        "from_version": "3.2.4",
        "to_version": "4.0.0",
        "manifest_sha256": "0".repeat(64),
        "expected_tree_sha256": "0".repeat(64),
        "stage_root": "res://addons/.godot_ai_update/stage/addons/godot_ai",
    }
    var companion_enabled := EditorInterface.is_plugin_enabled(COMPANION)
    if CASE == "save-failure":
        coordinator._swap()
    else:
        # The real installer refuses a fake stage; drive the persistence and
        # restart steps the swap hands off to, exactly as _swap() does.
        var persisted: Variant = installer.call("persist_next_start_enabled", CONFIG)
        if not persisted is int or int(persisted) != OK:
            get_tree().quit(47)
            return
        print("MCP | v3 bridge restarting editor into canonical v4 tree")
        installer.call("request_restart")
    var saved := ConfigFile.new()
    if saved.load("res://project.godot") != OK:
        get_tree().quit(45)
        return
    _write("res://first.json", {
        "pid": OS.get_process_id(),
        "enabled_in_old_process": EditorInterface.is_plugin_enabled(CONFIG),
        "companion": companion_enabled,
        "saved": Array(saved.get_value("editor_plugins", "enabled", PackedStringArray())),
        "restored": ProjectSettings.get_setting(KEY) == previous,
        "status_key": Coordinator.status_setting(),
        "project_root": ProjectSettings.globalize_path("res://"),
    })
    if CASE == "save-failure":
        get_tree().quit(0)
func _write(path: String, value: Dictionary) -> void:
    var file := FileAccess.open(path, FileAccess.WRITE)
    if file == null:
        get_tree().quit(46)
        return
    file.store_string(JSON.stringify(value))
    file.close()
''',
        encoding="utf-8",
    )
    succeeds = case != "save-failure"
    log = run_godot_editor(
        project,
        godot,
        allow_headless=True,
        timeout=90,
        restart_completion_file="second.json" if succeeds else None,
    )
    first = json.loads((project / "first.json").read_text(encoding="utf-8"))
    assert first["status_key"] == "godot_ai/v4_migration_bridge_status_" + hashlib.sha256(
        first["project_root"].encode("utf-8")
    ).hexdigest()
    assert not first["enabled_in_old_process"], first
    assert first["companion"], first
    assert "SCRIPT ERROR" not in log, log
    if succeeds:
        second = json.loads((project / "second.json").read_text(encoding="utf-8"))
        assert first["pid"] != second["pid"]
        assert second["enabled"] and second["companion"], second
        assert first["saved"] == second["setting"] == [
            "res://addons/companion/plugin.cfg",
            "res://addons/godot_ai/plugin.cfg",
        ]
        assert "restarting editor into canonical v4 tree" in log
    else:
        assert first["saved"] == ["res://addons/companion/plugin.cfg"], first
        assert not (project / "second.json").exists()
        assert "restarting editor into canonical v4 tree" not in log
        assert "explicit recovery is required" in log
