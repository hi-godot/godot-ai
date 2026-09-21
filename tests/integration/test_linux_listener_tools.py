"""Linux launch prerequisites use the editor PATH without caching a missing tool."""

from __future__ import annotations

import json
import shutil
import sys
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip, run_godot_editor

pytestmark = pytest.mark.editor

DRIVER = """@tool
extends Node
const Ports := preload("res://addons/godot_ai/utils/port_resolver.gd")
const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
func _ready() -> void:
    if Engine.is_editor_hint(): run.call_deferred()
func run() -> void:
    var original := OS.get_environment("PATH")
    OS.set_environment("PATH", ProjectSettings.globalize_path("res://bin"))
    var initial := Ports.listener_tools_problem()
    var manager := Lifecycle.new()
    var marker := ProjectSettings.globalize_path("res://unexpected-launch")
    var payload := {"http_port": 8000, "server_command": ["/bin/sh",
        ProjectSettings.globalize_path("res://spawn.sh"), marker],
        "pid_file": ProjectSettings.globalize_path("res://existing.pid")}
    var available := OS.get_environment("LISTENER_TOOL")
    var missing := {}
    if available.is_empty():
        missing = manager._effect_launch(payload)
    else:
        assert(DirAccess.remove_absolute("res://bin/" + available) == OK)
    var after_removal := Ports.listener_tools_problem()
    var file := FileAccess.open("res://bin/ss", FileAccess.WRITE)
    file.store_string("#!/bin/sh\\nexit 0\\n")
    file.close()
    var ignored: Array = []
    assert(OS.execute("/bin/chmod", ["+x", ProjectSettings.globalize_path("res://bin/ss")],
        ignored) == 0)
    var after_install := Ports.listener_tools_problem()
    OS.set_environment("PATH", original)
    manager = null
    file = FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"initial": initial, "missing": missing,
        "after_removal": after_removal, "after_install": after_install,
        "spawned": FileAccess.file_exists(marker),
        "pid_file": FileAccess.get_file_as_string("res://existing.pid")}))
    file.close()
    get_tree().quit()
"""


@pytest.mark.parametrize("available", ["", "ss", "lsof"])
@pytest.mark.skipif(sys.platform != "linux", reason="Linux PATH")
def test_linux_listener_prerequisite_refuses_before_spawn_and_recovers(
    tmp_path: Path,
    available: str,
) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "listener-tools"
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    commands = project / "bin"
    commands.mkdir()
    if available:
        tool = commands / available
        tool.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        tool.chmod(0o700)
    (project / "spawn.sh").write_text('printf launched > "$1"\n', encoding="utf-8")
    (project / "existing.pid").write_text("preserved", encoding="utf-8")
    (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
    (project / "project.godot").write_text(
        'config_version=5\n[autoload]\nDriver="*res://driver.gd"\n',
        encoding="utf-8",
    )
    environment = {"LISTENER_TOOL": available, "GODOT_AI_DISABLE_TELEMETRY": "true"}
    for name in ("HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
        directory = tmp_path / name.lower()
        directory.mkdir()
        environment[name] = str(directory)
    log = run_godot_editor(project, godot, allow_headless=True, environment=environment)
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "result.json").read_bytes())
    if available:
        assert result["initial"] == "", result
    else:
        assert result["missing"]["ok"] is False, result
        assert result["missing"]["reason"] == "listener_tools_missing", result
        assert result["missing"]["message"] == result["initial"], result
    assert "Install lsof or iproute2" in result["after_removal"], result
    assert "retry" in result["after_removal"], result
    assert result["after_install"] == "", result
    assert not result["spawned"] and result["pid_file"] == "preserved", result
