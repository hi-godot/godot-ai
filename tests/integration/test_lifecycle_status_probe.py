"""Exercise the real Godot status probe against delayed and refusing listeners."""

import json
import shutil
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

pytestmark = pytest.mark.editor
HTTP = "h" * 32
INSTANCE = "b" * 32

DRIVER = '''@tool
extends Node
const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")

func _ready() -> void:
    if Engine.is_editor_hint():
        run.call_deferred()

func run() -> void:
    var record := {"http": OS.get_environment("PROBE_TOKEN"),
        "instance_nonce": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
    var result := Lifecycle._probe_with_capability(
        int(OS.get_environment("PROBE_PORT")), record, 3000)
    result["matches_record"] = Lifecycle._authenticated_status_matches_record(result, record)
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(result))
    file.close()
    get_tree().quit()
'''


@pytest.mark.parametrize("authorized", [True, False], ids=["slow-authenticated", "foreign-403"])
def test_real_godot_status_probe_preserves_occupied_listener_checks(
    tmp_path: Path, authorized: bool,
) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "probe"
    shutil.copytree(PLUGIN_ROOT, project / "addons" / "godot_ai")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Status probe test"\n'
        '[autoload]\nProbeDriver="*res://driver.gd"\n', encoding="utf-8",
    )
    (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
    requests: list[tuple[str, str | None]] = []

    class Handler(BaseHTTPRequestHandler):
        # Keep explicit-length responses persistent, like the real backend.
        # An HTTP/1.0 zero-body close is safely refused by Godot but can surface
        # as response_status_8 before its status code is projected.
        protocol_version = "HTTP/1.1"

        def setup(self) -> None:
            super().setup()
            self.connection.settimeout(5)

        def do_GET(self) -> None:
            token = self.headers.get("Authorization")
            requests.append((self.path, token))
            if token != f"Bearer {HTTP}":
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            # Longer than the former 800 ms probe budget, inside the current
            # three-second allowance. Assert behavior, not a narrow timing band.
            time.sleep(1.2)
            body = json.dumps({"name": "godot-ai", "server_version": "4.0.0",
                               "ws_port": 19500, "instance_id": INSTANCE}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, _format: str, *args: object) -> None:
            pass

    with HTTPServer(("127.0.0.1", 0), Handler) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            token = HTTP if authorized else "x" * 32
            log = run_godot_editor(
                project, godot, allow_headless=False, timeout=60,
                environment={"PROBE_PORT": str(server.server_port), "PROBE_TOKEN": token},
            )
        finally:
            server.shutdown()
            worker.join(timeout=6)
        assert not worker.is_alive(), "bounded HTTP fixture must finish before teardown"
    assert "SCRIPT ERROR:" not in log
    assert requests == [("/godot-ai/status", f"Bearer {token}")]
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    assert result["status_code"] == (200 if authorized else 403), result
    assert result["matches_record"] is authorized, result
    assert result["reachable"] is authorized, result
    if authorized:
        assert result["name"] == "godot-ai"
        assert result["version"] == "4.0.0"
        assert result["instance_id"] == INSTANCE
        assert result["ws_port"] == 19500
        assert result["error"] == ""
    else:
        assert result["error"] == "http_403"
        assert result["instance_id"] == ""
