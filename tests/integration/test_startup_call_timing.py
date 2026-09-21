"""Exercise startup call timing in Godot; only the backend launch is suppressed."""

import json
import re
import shutil
import socket
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PARSE_ERROR_PATTERNS,
    PLUGIN_ROOT,
    godot_bin_or_skip,
    load_smoke_script,
    run_godot_editor,
)

pytestmark = pytest.mark.editor
SECRET = "timing-private-command-and-environment"


@pytest.mark.parametrize("tracing,invalid", [(True, False), (False, False), (True, True)])
def test_startup_calls_attribute_discovery_and_preserve_refusal(tmp_path: Path, tracing, invalid):
    godot = godot_bin_or_skip()
    smoke = load_smoke_script()
    project = tmp_path / "project"
    addon = project / "addons" / "godot_ai"
    shutil.copytree(PLUGIN_ROOT, addon)
    plugin = addon / "plugin.gd"
    plugin.write_text(smoke.replace_function(
        plugin.read_text(encoding="utf-8"),
        "func _begin_startup_release() -> void:",
        'func _begin_startup_release() -> void:\n'
        '\t_startup_trace_phase("fixture_after_calls")\n'
        '\tprint("TIMING_FIXTURE | plan captured")',
    ), encoding="utf-8")
    configurator = addon / "client_configurator.gd"
    configurator.write_text(smoke.replace_function(
        configurator.read_text(encoding="utf-8"),
        "static func get_server_command() -> Array[String]:",
        'static func get_server_command() -> Array[String]:\n'
        '\tOS.delay_msec(250)\n'
        f'\treturn [{json.dumps(SECRET)}]\n',
    ), encoding="utf-8")
    with socket.socket() as http, socket.socket() as ws:
        http.bind(("127.0.0.1", 0))
        ws.bind(("127.0.0.1", 0))
        http_port, ws_port = http.getsockname()[1], ws.getsockname()[1]
    if invalid:
        ws_port = http_port
    driver = project / "addons" / "timing_driver"
    driver.mkdir()
    (driver / "plugin.cfg").write_text(
        '[plugin]\nname="Timing driver"\ndescription="Fixture"\nauthor="test"\n'
        'version="1"\nscript="driver.gd"\n', encoding="utf-8",
    )
    (driver / "driver.gd").write_text(
        '@tool\nextends EditorPlugin\n'
        'func _enter_tree() -> void:\n\t_run.call_deferred()\n'
        'func _run() -> void:\n'
        '\tvar settings := EditorInterface.get_editor_settings()\n'
        '\tsettings.set_setting("godot_ai/telemetry_enabled", false)\n'
        '\tsettings.set_setting("godot_ai/log_startup_timing", false)\n'
        '\tsettings.set_setting("godot_ai/v4_endpoint_ports", '
        f'{{"http_port": {http_port}, "ws_port": {ws_port}}})\n'
        '\tEditorInterface.set_plugin_enabled("godot_ai", true)\n'
        '\tfor _frame in 5:\n\t\tawait get_tree().process_frame\n'
        '\tprint("TIMING_FIXTURE | completed")\n'
        '\tget_tree().quit()\n', encoding="utf-8",
    )
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Startup timing fixture"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/timing_driver/plugin.cfg")\n',
        encoding="utf-8",
    )
    isolated = tmp_path / SECRET
    environment = {
        "APPDATA": str(isolated / "roaming"),
        "LOCALAPPDATA": str(isolated / "local"),
        "HOME": str(isolated / "home"),
        "USERPROFILE": str(isolated / "home"),
        "XDG_CONFIG_HOME": str(isolated / "config"),
        "GODOT_AI_DISABLE_TELEMETRY": "true",
        "GODOT_AI_STARTUP_TRACE": "1" if tracing else "0",
        "PYTHONPATH": SECRET,
    }
    for directory in ("roaming", "local", "home", "config"):
        (isolated / directory).mkdir(parents=True)
    log = run_godot_editor(project, godot, allow_headless=True, environment=environment)
    assert "TIMING_FIXTURE | completed" in log, log
    assert not any(pattern in log for pattern in PARSE_ERROR_PATTERNS), log
    trace = "\n".join(line for line in log.splitlines() if "MCP startup trace |" in line)
    assert SECRET not in trace
    assert str(tmp_path) not in trace
    if not tracing:
        assert trace == ""
        assert "TIMING_FIXTURE | plan captured" in log
        return
    begins = re.findall(r"call=(\w+) begin total_ms=(\d+)", trace)
    ends = re.findall(r"call=(\w+) end elapsed_ms=(\d+) total_ms=(\d+)", trace)
    assert [name for name, _ in begins] == [name for name, _, _ in ends], trace
    assert all(int(total) >= int(start) for (_, start), (_, _, total) in zip(begins, ends))
    if invalid:
        assert [name for name, _ in begins] == ["endpoint_override"], trace
        assert "server start blocked: Invalid godot_ai/v4_endpoint_ports" in log, log
        assert "TIMING_FIXTURE | plan captured" not in log
        return
    expected = ["endpoint_override", "endpoint_policy", "resolve_ws_port", "capability_path",
                "warm_env_snapshot", "worktree_source", "server_command",
                "http_port_reservation", "lifecycle_configure", "startup_release"]
    assert [name for name, _ in begins] == expected, trace
    duration = {name: int(elapsed) for name, elapsed, _ in ends}
    assert duration["server_command"] >= 250, trace
    command_start = trace.index("call=server_command begin")
    command_end = trace.index("call=server_command end")
    assert command_start < command_end < trace.index("call=http_port_reservation begin")
    phases = re.findall(r"phase=(\w+) delta_ms=(\d+) total_ms=(\d+)", trace)
    before, after = phases[-2:]
    assert before[0] == "dock_attached" and after[0] == "fixture_after_calls"
    assert int(after[1]) == int(after[2]) - int(before[2]) >= 250
    assert "TIMING_FIXTURE | plan captured" in log
