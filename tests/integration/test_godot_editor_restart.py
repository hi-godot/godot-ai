"""Exercise the real engine restart, independently of plugin migration."""

from __future__ import annotations

import json
from pathlib import Path

from tests.integration._self_update_fixture import godot_bin_or_skip, run_godot_editor


def test_headless_editor_restart_preserves_display_driver(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "headless-restart"
    project.mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Headless restart regression"\n'
        '[autoload]\nRestartDriver="*res://restart_driver.gd"\n',
        encoding="utf-8",
    )
    (project / "restart_driver.gd").write_text(
        '''@tool
extends Node

var _frames := 10

func _process(_delta: float) -> void:
    if not Engine.is_editor_hint():
        return
    _frames -= 1
    if _frames != 0:
        return
    set_process(false)
    var restarted := FileAccess.file_exists("res://first.json")
    var output := "res://second.json" if restarted else "res://first.json"
    var file := FileAccess.open(output, FileAccess.WRITE)
    if file == null:
        get_tree().quit(40)
        return
    file.store_string(JSON.stringify({
        "pid": OS.get_process_id(),
        "display": DisplayServer.get_name(),
    }))
    file.close()
    if restarted:
        get_tree().quit(0)
    else:
        EditorInterface.restart_editor(false)
''',
        encoding="utf-8",
    )
    run_godot_editor(
        project, godot, allow_headless=False, timeout=90,
        restart_completion_file="second.json",
    )
    first = json.loads((project / "first.json").read_text(encoding="utf-8"))
    second = json.loads((project / "second.json").read_text(encoding="utf-8"))
    assert first["pid"] > 1 and second["pid"] > 1
    assert first["pid"] != second["pid"], (first, second)
    assert first["display"] == second["display"] == "headless", (first, second)
