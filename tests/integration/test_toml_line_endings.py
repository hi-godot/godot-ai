"""Parse actual Godot-written client files without universal-newline translation."""

import json
import shutil
import tomllib
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip, run_godot_editor

pytestmark = pytest.mark.editor

DRIVER = '''@tool
extends Node
func _ready() -> void:
    if Engine.is_editor_hint():
        run.call_deferred()
func run() -> void:
    var results := {}
    for name in ["fresh", "existing", "append", "remove"]:
        var client = load("res://addons/godot_ai/clients/codex.gd").new()
        var path := ProjectSettings.globalize_path("res://" + name + ".toml")
        client.config_home_env = ""
        client.path_template = {"unix": path, "windows": path, "darwin": path, "linux": path}
        if name == "remove":
            results[name] = McpTomlStrategy.remove(client, "godot-ai")
        else:
            results[name] = McpTomlStrategy.configure(client, "godot-ai", "", {
                "ok": true, "command": "uvx", "args": ["godot-ai@4.0.4", "attach"]})
        var before := FileAccess.get_file_as_bytes(path)
        var repeated: Dictionary
        if name == "remove":
            repeated = McpTomlStrategy.remove(client, "godot-ai")
        else:
            repeated = McpTomlStrategy.configure(client, "godot-ai", "", {
                "ok": true, "command": "uvx", "args": ["godot-ai@4.0.4", "attach"]})
        results[name]["repeat_status"] = repeated.get("status")
        results[name]["stable"] = before == FileAccess.get_file_as_bytes(path)
    var receipt := FileAccess.open("res://result.json", FileAccess.WRITE)
    receipt.store_string(JSON.stringify(results))
    receipt.close()
    get_tree().quit()
'''


def test_toml_writes_preserve_crlf_user_values_and_valid_final_newline(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "toml-lines"
    shutil.copytree(PLUGIN_ROOT, project / "addons" / "godot_ai")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="TOML lines"\n'
        '[autoload]\nDriver="*res://driver.gd"\n', encoding="utf-8")
    (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
    user = ('enabled = false\r\nstartup_timeout_sec = 91\r\n'
            'enabled_tools = [\r\n  "scene_get_hierarchy",\r\n  "editor_state",\r\n]\r\n'
            'note = """first\r\nsecond"""\r\ntool_timeout_sec = 777\r\n')
    entry = '[mcp_servers.godot_ai]\r\ncommand = "uvx"\r\nargs = ["godot-ai@3.2.5", "attach"]\r\n'
    other = '[other]\r\nkeep = "untouched"\r\n'
    for name, source in {"existing": entry + user, "append": other,
                         "remove": entry + user + other}.items():
        raw = source.encode("utf-8")
        tomllib.loads(raw.decode("utf-8"))
        (project / f"{name}.toml").write_bytes(raw)
    log = run_godot_editor(project, godot, allow_headless=False, timeout=90,
                           environment={"GODOT_AI_DISABLE_TELEMETRY": "true"})
    assert "SCRIPT ERROR:" not in log
    results = json.loads((project / "result.json").read_bytes())
    assert set(results) == {"fresh", "existing", "append", "remove"}
    for name, result in results.items():
        assert result["status"] == "ok", (name, result)
        assert result["repeat_status"] == "ok", (name, result)
        assert result["stable"], (name, result)
        raw = (project / f"{name}.toml").read_bytes()
        assert raw.endswith(b"\n"), (name, raw)
        parsed = tomllib.loads(raw.decode("utf-8"))
        if name == "remove":
            assert parsed == {"other": {"keep": "untouched"}}
            assert raw == other.encode("utf-8")
        else:
            server = parsed["mcp_servers"]["godot-ai"]
            assert server["command"] == "uvx"
            assert server["args"] == ["godot-ai@4.0.4", "attach"]
            if name == "existing":
                assert server["enabled"] is False
                assert server["startup_timeout_sec"] == 91
                assert server["tool_timeout_sec"] == 777
                assert server["enabled_tools"] == ["scene_get_hierarchy", "editor_state"]
                assert server["note"] == "first\nsecond"
                assert b'note = """first\r\nsecond"""\r\n' in raw
            if name == "append":
                assert parsed["other"] == {"keep": "untouched"}
                assert raw.startswith(other.encode("utf-8"))
