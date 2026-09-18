"""Native Windows wildcard listeners must remain reachable from editor probes."""

import json
import shutil
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
        "unknown_suggestion": Config.suggest_free_port(port, 2048, {"known": false, "ports": []}),
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
            + 'static func windows_listener_snapshot(_t: Callable = Callable()) -> Dictionary:\n'
            + '\treturn {"known": false, "ports": []}\n\n\n'
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
