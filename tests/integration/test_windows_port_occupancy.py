"""Native Windows wildcard listeners must remain reachable from editor probes."""

import json
import shutil
import socket
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

pytestmark = pytest.mark.editor

DRIVER = """@tool
extends Node
const Ports := preload("res://addons/godot_ai/utils/port_resolver.gd")
const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const Config := preload("res://addons/godot_ai/client_configurator.gd")
func _ready() -> void:
    if Engine.is_editor_hint(): run.call_deferred()
func run() -> void:
    var port := int(OS.get_environment("TEST_HTTP_PORT"))
    var result := {
        "bindable": Ports.can_bind_local_port(port),
        "occupancy": Ports.windows_port_occupancy(port),
        "in_use": Ports.is_port_in_use(port),
        "status": Lifecycle._probe_with_capability(port, {"http": "test-token"}, 3000),
        "unknown_suggestion": Config.suggest_free_port(
            port, 2048, {"known": false, "listeners": {}}),
    }
    if not OS.has_environment("TEST_QUERY_FAILURE"):
        var snapshot := Ports.windows_listener_snapshot()
        result["suggested"] = Config.suggest_free_port(port, 2048, snapshot)
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(result))
    get_tree().quit()
"""


class StatusHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        authorized = self.headers.get("Authorization") == "Bearer test-token"
        body = json.dumps(
            {
                "name": "godot-ai",
                "server_version": "4.1.0",
                "instance_id": "test-instance",
                "ws_port": 19954,
            }
        ).encode()
        self.send_response(200 if authorized else 401)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass


@pytest.mark.skipif(sys.platform != "win32", reason="Windows bind semantics")
@pytest.mark.parametrize(
    ("host", "query_failure"), [("127.0.0.1", False), ("0.0.0.0", False), ("0.0.0.0", True)]
)
def test_windows_authenticated_probe_and_port_selection(
    tmp_path: Path,
    host: str,
    query_failure: bool,
) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "occupancy"
    addon = project / "addons/godot_ai"
    shutil.copytree(PLUGIN_ROOT, addon)
    if query_failure:
        resolver = addon / "utils/port_resolver.gd"
        source = resolver.read_text(encoding="utf-8")
        start = source.index("static func windows_listener_snapshot(")
        end = source.index("static func windows_port_occupancy(", start)
        source = (
            source[:start]
            + "static func windows_listener_snapshot(_t: Callable = Callable()) -> Dictionary:\n"
            + '\treturn {"known": false, "listeners": {}}\n\n\n'
            + source[end:]
        )
        resolver.write_text(source, encoding="utf-8")
    (project / "project.godot").write_text(
        'config_version=5\n[autoload]\nDriver="*res://driver.gd"\n', encoding="utf-8"
    )
    (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    if query_failure:
        environment["TEST_QUERY_FAILURE"] = "1"
    with ThreadingHTTPServer((host, 0), StatusHandler) as server:
        port = server.server_address[1]
        environment["TEST_HTTP_PORT"] = str(port)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            log = run_godot_editor(project, godot, allow_headless=False, environment=environment)
        finally:
            server.shutdown()
            thread.join(timeout=5)
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    assert result["bindable"] == (host == "0.0.0.0"), result
    assert result["occupancy"] == (0 if query_failure else 2), result
    assert result["in_use"] is True, result
    assert result["status"]["reachable"] is True, result
    assert result["status"]["status_code"] == 200, result
    assert result["status"]["instance_id"] == "test-instance", result
    assert result["unknown_suggestion"] == 0, result
    if not query_failure:
        assert result["suggested"] > 0 and result["suggested"] != port, result


FEEDBACK_DRIVER = """@tool
extends Node
const Ports := preload("res://addons/godot_ai/utils/port_resolver.gd")
const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const States := preload("res://addons/godot_ai/utils/mcp_server_state.gd")
const Config := preload("res://addons/godot_ai/client_configurator.gd")
const Picker := preload("res://addons/godot_ai/dock_panels/port_picker_panel.gd")
const Plugin := preload("res://addons/godot_ai/plugin.gd")
const Dock := preload("res://addons/godot_ai/mcp_dock.gd")
func _ready() -> void:
    if Engine.is_editor_hint(): run.call_deferred()
func run() -> void:
    var port := int(OS.get_environment("TEST_HTTP_PORT"))
    var result := {}
    var kernel := Ports.windows_snapshot_from_netstat(0, [
        "TCP 0.0.0.0:12345 0.0.0.0:0 LISTENING 0\\n"
        + "TCP 0.0.0.0:12346 0.0.0.0:0 LISTENING 42\\n"])
    result["kernel_known"] = kernel.known
    result["kernel_occupancy"] = Ports.windows_port_occupancy(12345, kernel)
    var manager := Lifecycle.new()
    Ports.query_count = 0
    var payload := {"http_port": port, "expected_ws_port": port + 1,
        "expected_version": "4.1.0", "timeout_ms": 100}
    result["probe"] = manager._effect_probe(payload)
    result["probe_queries"] = Ports.query_count
    Ports.query_failure = true
    Ports.query_count = 0
    result["unknown_probe"] = manager._effect_probe(payload)
    result["unknown_queries"] = Ports.query_count
    result["unknown_state"] = Lifecycle._dock_state(Lifecycle.BLOCKED, "port_occupancy_unknown")
    result["foreign_state"] = States.FOREIGN_PORT
    Ports.query_count = 0
    Ports.wait_for_port_free(port, 0.4)
    result["wait_queries"] = Ports.query_count
    var plugin := Plugin.new()
    plugin._normal_start_released = true
    plugin._lifecycle.configure({"http_port": port, "ws_port": port + 1,
        "expected_version": "4.1.0", "probe_timeout_ms": 100, "defer_effects": false})
    result["restart_accepted"] = plugin.restart_or_start_managed_server()
    result["restart_status"] = plugin.get_server_status()
    plugin._lifecycle = null
    plugin.free()
    var pending_plugin := Plugin.new()
    pending_plugin._normal_start_released = true
    pending_plugin._lifecycle.configure({"automatic_effects": false})
    pending_plugin._lifecycle.start_server()
    var pending: Dictionary = pending_plugin._lifecycle.episode_snapshot()
    pending_plugin.restart_or_start_managed_server()
    result["pending_preserved"] = pending_plugin._lifecycle.episode_snapshot() == pending
    pending_plugin._lifecycle = null
    pending_plugin.free()
    var dock := Dock.new()
    dock._build_ui()
    dock.present_lifecycle_snapshot(result.restart_status)
    dock._update_status()
    result["dock_heading"] = dock._status_label.text
    result["dock_body"] = dock._crash_output.get_parsed_text()
    dock.free()
    var picker := Picker.new()
    picker.setup()
    picker.port_in_use_probe = func(_port: int) -> bool: return true
    var empty := Ports.windows_snapshot_from_netstat(0, [
        "TCP 127.0.0.1:12345 127.0.0.1:12 ESTABLISHED 42\\n"])
    picker.seed_suggested_ports(0, empty)
    result["picker_http"] = int(picker._spinbox.value)
    result["picker_ws"] = int(picker._ws_spinbox.value)
    result["configured_http"] = Config.http_port()
    result["configured_ws"] = Config.ws_port()
    picker.free()
    Ports.query_failure = false
    Ports.query_count = 0
    Ports.fail_on_query = 2
    result["endpoints_before"] = Config.v4_endpoint_ports_status()
    result["upgrade"] = Config.prepare_major_upgrade_endpoints("3.2.4", "4.1.0")
    result["upgrade_queries"] = Ports.query_count
    result["endpoints_after"] = Config.v4_endpoint_ports_status()
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(result))
    get_tree().quit()
"""


@pytest.mark.skipif(sys.platform != "win32", reason="Windows listener discovery")
def test_windows_listener_feedback_regressions(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "feedback"
    addon = project / "addons/godot_ai"
    shutil.copytree(PLUGIN_ROOT, addon)
    resolver = addon / "utils/port_resolver.gd"
    source = resolver.read_text(encoding="utf-8")
    start = source.index("static func windows_listener_snapshot(")
    end = source.index("static func windows_port_occupancy(", start)
    source = (
        source[:start]
        + "static var query_count := 0\nstatic var query_failure := false\n"
        + "static var fail_on_query := 0\n"
        + "static func windows_listener_snapshot(_trace: Callable = Callable()) -> Dictionary:\n"
        + "\tquery_count += 1\n"
        + "\tif query_failure or query_count == fail_on_query:\n"
        + '\t\treturn {"known": false, "listeners": {}}\n'
        + '\tvar port := int(OS.get_environment("TEST_HTTP_PORT")) + 1\n'
        + "\treturn windows_snapshot_from_netstat(0, [\n"
        + '\t\t"TCP 0.0.0.0:%d 0.0.0.0:0 LISTENING 42\\n" % port])\n\n\n'
        + source[end:]
    )
    resolver.write_text(source, encoding="utf-8")
    lifecycle = addon / "utils/server_lifecycle.gd"
    source = lifecycle.read_text(encoding="utf-8")
    start = source.index("func _read_capability(")
    end = source.index("static func probe_live_server_status(", start)
    source = (
        source[:start]
        + 'func _read_capability(_port: int) -> Dictionary:\n\treturn {"http": "test-token"}\n\n\n'
        + source[end:]
    )
    lifecycle.write_text(source, encoding="utf-8")
    (project / "project.godot").write_text(
        'config_version=5\n[autoload]\nDriver="*res://driver.gd"\n', encoding="utf-8"
    )
    (project / "driver.gd").write_text(FEEDBACK_DRIVER, encoding="utf-8")
    with socket.socket() as free_port:
        free_port.bind(("127.0.0.1", 0))
        port = free_port.getsockname()[1]
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true", "TEST_HTTP_PORT": str(port)}
    for key in ("APPDATA", "LOCALAPPDATA"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    log = run_godot_editor(project, godot, allow_headless=False, environment=environment)
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    expected = {
        "kernel_known": True,
        "kernel_occupancy": 2,
        "probe_queries": 1,
        "unknown_queries": 1,
        "wait_queries": 1,
    }
    failures = {key: result[key] for key, value in expected.items() if result[key] != value}
    assert not failures, (failures, result)
    assert result["probe"]["reason"] == "ws_occupied", result
    assert result["unknown_probe"]["reason"] == "port_occupancy_unknown", result
    assert "occupied by another process" not in result["unknown_probe"]["message"], result
    assert result["unknown_state"] == result["foreign_state"], result
    assert result["picker_http"] == result["configured_http"], result
    assert result["picker_ws"] == result["configured_ws"], result
    assert result["restart_accepted"] is True, result
    assert result["restart_status"]["episode_reason"] == "port_occupancy_unknown", result
    assert result["pending_preserved"] is True, result
    assert result["dock_heading"] == "Windows port discovery unavailable", result
    assert "Windows could not query listening ports" in result["dock_body"], result
    assert "occupied by another process" not in result["dock_body"], result
    assert result["upgrade_queries"] == 2, result
    assert result["upgrade"]["ok"] is False, result
    assert "Windows could not query listening ports" in result["upgrade"]["error"], result
    assert result["endpoints_before"] == result["endpoints_after"], result
