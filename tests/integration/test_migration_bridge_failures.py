"""Exercise worker failure -> dock/reload behavior in a real editor."""

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


@pytest.mark.parametrize("case", ["disabled", "already-listed", "save-failure", "invalid-list"])
def test_bridge_restart_preserves_next_start_without_live_enable(tmp_path: Path, case: str) -> None:
    """The real coordinator persists intent, never loads new code into the old VM."""
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
    for name in ("bridge_exec.gd", "migration_coordinator.gd"):
        shutil.copy2(
            PLUGIN_ROOT.parents[2] / "migration_bridge" / name, project / "addons/godot_ai"
        )
    (project / "_test_runner_driver.gd").write_text(
        '''@tool
extends Node
const Coordinator := preload("res://addons/godot_ai/migration_coordinator.gd")
const CONFIG := "res://addons/godot_ai/plugin.cfg"
const COMPANION := "res://addons/companion/plugin.cfg"
const KEY := "editor_plugins/enabled"
const CASE := "''' + case + '''"

class SaveFailure extends Coordinator:
    func _save_project_settings() -> Error:
        return ERR_CANT_CREATE

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
    elif CASE == "invalid-list":
        previous = "not a plugin list"
        ProjectSettings.set_setting(KEY, previous)
    var coordinator = SaveFailure.new() if CASE == "save-failure" else Coordinator.new()
    get_tree().root.add_child(coordinator)
    var companion_enabled := EditorInterface.is_plugin_enabled(COMPANION)
    coordinator._restart_into_v4()
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
    if CASE in ["save-failure", "invalid-list"]:
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
    succeeds = case in {"disabled", "already-listed"}
    log = run_godot_editor(
        project, godot, allow_headless=True, timeout=90,
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
            "res://addons/companion/plugin.cfg", "res://addons/godot_ai/plugin.cfg",
        ]
        assert "restarting editor into canonical v4 tree" in log
    else:
        assert first["saved"] == ["res://addons/companion/plugin.cfg"], first
        assert first["restored"], first
        assert not (project / "second.json").exists()
        assert "restarting editor into canonical v4 tree" not in log
        assert "explicit recovery is required" in log


@pytest.mark.parametrize("unproven", [False, True])
def test_bridge_only_retries_after_proven_termination(tmp_path: Path, unproven: bool) -> None:
    godot = godot_bin_or_skip()
    smoke = load_smoke_script()
    project = tmp_path / "bridge-failure"
    project.mkdir()
    smoke.write_project_files(project)
    append_driver_autoload(project / "project.godot")
    addon = project / "addons/godot_ai"
    shutil.copytree(PLUGIN_ROOT.parents[2] / "migration_bridge", addon)
    (addon / "plugin.cfg").write_text(
        (addon / "plugin.cfg").read_text(encoding="utf-8").replace("@VERSION@", "4.0.1"),
        encoding="utf-8",
    )
    payload = addon / "migration_payload"
    payload.mkdir()
    (payload / smoke.SMOKE_MANIFEST_NAME).write_text(
        json.dumps(
            {
                "repository": "hi-godot/godot-ai",
                "channel": "stable",
                "tag": "v4.0.1",
                "version": "4.0.1",
                "source_commit": "a" * 40,
            }
        ),
        encoding="utf-8",
    )
    # Only the process boundary is faked. Worker, signal, dock and reload are real.
    executor = addon / "bridge_exec.gd"
    source = smoke.replace_function(
        executor.read_text(encoding="utf-8"),
        "static func actor_command(version: String) -> Array[String]:",
        'static func actor_command(_version: String) -> Array[String]:\n\treturn ["fixture"]',
    )
    source = smoke.replace_function(
        source,
        "static func run(",
        "static func run(_command: Array[String], _arguments: Array[String], "
        "_timeout: int, _cancel: Callable = Callable()) -> Dictionary:\n"
        '\treturn {"ok": false, "error": "synthetic actor refusal", '
        f'"termination_unproven": {str(unproven).lower()}}}',
    )
    executor.write_text(source, encoding="utf-8")
    (project / "_test_runner_driver.gd").write_text(
        """@tool
extends Node
const CONFIG := "res://addons/godot_ai/plugin.cfg"
const UNPROVEN := """
        + str(unproven).lower()
        + """
var _deadline := 0
var _checking := false

func _ready() -> void:
	_deadline = Time.get_ticks_msec() + 20000

func _find(node: Node) -> Node:
	if node is EditorPlugin and node.get_script() != null and node.get_script().resource_path == "res://addons/godot_ai/plugin.gd":
		return node
	for child in node.get_children():
		var found := _find(child)
		if found != null:
			return found
	return null

func _process(_delta: float) -> void:
	if Time.get_ticks_msec() > _deadline:
		push_error("BRIDGE_FAILURE_TEST | timed out")
		get_tree().quit(1)
		return
	if _checking:
		return
	var plugin := _find(get_tree().root)
	if plugin == null:
		return
	var label: Label = plugin.get("_label")
	if not ("synthetic actor refusal" in label.text or "Restart Godot" in label.text):
		return
	_checking = true
	_check.call_deferred(plugin)

func _check(plugin: Node) -> void:
	var retry: Button = plugin.get("_retry")
	if retry.visible == UNPROVEN:
		get_tree().quit(2)
		return
	if UNPROVEN:
		var bridge: Variant = plugin.get("_bridge")
		plugin.call("_on_retry")
		if plugin.get("_bridge") != bridge:
			get_tree().quit(3)
			return
		EditorInterface.set_plugin_enabled(CONFIG, false)
		await get_tree().process_frame
		EditorInterface.set_plugin_enabled(CONFIG, true)
		await get_tree().process_frame
		plugin = _find(get_tree().root)
		if plugin == null or plugin.get("_bridge") != null or plugin.get("_retry").visible:
			get_tree().quit(4)
			return
	print("BRIDGE_FAILURE_TEST | retry and reload guard passed")
	get_tree().quit(0)
""",
        encoding="utf-8",
    )
    log = run_godot_editor(project, godot, allow_headless=True, timeout=45)
    assert "BRIDGE_FAILURE_TEST | retry and reload guard passed" in log
    assert "SCRIPT ERROR" not in log, log
    assert "MCP | v3 bridge: " in log
    assert log.count("MCP | v3 bridge preparing signed v4 tree") == 1
