"""Real editor starts exercise client worker completion and persisted Codex config."""

import asyncio
import json
import os
import shutil
import socket
import subprocess
import sys
import time
import tomllib
from pathlib import Path

import pytest

from godot_ai.attach.ensure import BackendEnsurer
from godot_ai.transport.capability import capability_directory, read_capabilities, record_path
from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

## Needs a real Godot editor (GODOT_BIN); skipped without one and excluded
## from the iteration loop by `pytest -m "not editor"`.
pytestmark = pytest.mark.editor

PROBE = '''@tool
extends EditorPlugin

const Owner := preload("res://addons/godot_ai/utils/client_job_owner.gd")
const Registry := preload("res://addons/godot_ai/clients/_registry.gd")
var job_owner: Owner
var frames := 0
var started := Time.get_ticks_msec()
var result := {}
var stage := 0

func _enter_tree() -> void:
    # Only redirect this fixture's descriptor; never touch a user's Codex config.
    var descriptor = Registry.get_by_id("codex")
    descriptor.config_home_env = ""
    var path := ProjectSettings.globalize_path("res://isolated-codex/config.toml")
    descriptor.path_template = {"unix": path, "windows": path}
    descriptor.detect_paths = PackedStringArray([path])
    job_owner = Owner.new()
    add_child(job_owner)
    job_owner.activate()
    job_owner.mcp_action_completed.connect(_action_done)
    job_owner.status_refresh_completed.connect(_status_done)

func _process(_delta: float) -> void:
    frames += 1
    if Time.get_ticks_msec() - started > 45000:
        result["timeout_stage"] = stage
        _finish(40)
        return
    if stage == 0 and frames >= 45:
        result["pid"] = OS.get_process_id()
        result["processing_after_ready"] = job_owner.is_processing()
        stage = 1
        var request := job_owner.request_mcp_action("restart-check", "codex", "configure")
        result["accepted"] = request.get("ok", false)
        if not result.accepted:
            _finish(41)

func _action_done(request_id: String, payload: Dictionary) -> void:
    result["request_id"] = request_id
    result["action"] = payload
    stage = 2
    # Start the real status worker after the configure worker has been joined.
    job_owner.request_status_refresh(["codex"], true)

func _status_done(status: Dictionary) -> void:
    result["status"] = status
    result["snapshot"] = job_owner.snapshot()
    _finish(0)

func _finish(code: int) -> void:
    set_process(false)
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(result))
    file.close()
    get_tree().quit(code)

func _exit_tree() -> void:
    if is_instance_valid(job_owner):
        job_owner.quiesce()
        remove_child(job_owner)
        job_owner.free()
'''


def test_codex_workers_complete_after_two_ordinary_editor_restarts(tmp_path: Path) -> None:
    """Preserve activation and complete real configure/status workers on every boot."""
    godot = godot_bin_or_skip()
    project = tmp_path / "ordinary-starts"
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    probe = project / "addons/startup_probe"
    probe.mkdir()
    (probe / "plugin.cfg").write_text(
        '[plugin]\nname="Startup probe"\ndescription="Worker restart smoke"\n'
        'author="test"\nversion="1"\nscript="probe.gd"\n', encoding="utf-8",
    )
    (probe / "probe.gd").write_text(PROBE, encoding="utf-8")
    project_file = project / "project.godot"
    base = 'config_version=5\n[application]\nconfig/name="Client restart smoke"\n'
    project_file.write_text(base, encoding="utf-8")
    # Populate global script classes without starting either plugin.
    imported = subprocess.run(
        [godot, "--headless", "--editor", "--path", str(project), "--import", "--quit"],
        capture_output=True, text=True, timeout=90,
    )
    assert imported.returncode == 0, imported.stdout + imported.stderr
    project_file.write_text(
        base + '[editor_plugins]\nenabled=PackedStringArray("res://addons/startup_probe/plugin.cfg")\n',
        encoding="utf-8",
    )
    config = project / "isolated-codex/config.toml"
    config.parent.mkdir()
    config.write_text('model = "validation-sentinel"\n', encoding="utf-8")
    pids = []
    for boot in range(3):
        log = run_godot_editor(
            project, godot, allow_headless=False, timeout=90, phase=f"boot-{boot}",
            environment={"GODOT_AI_DISABLE_TELEMETRY": "true", "GODOT_AI_MODE": "user"},
        )
        assert "SCRIPT ERROR:" not in log, log
        result = json.loads((project / "result.json").read_text(encoding="utf-8"))
        print(f"ORDINARY_BOOT_{boot}: {json.dumps(result)}", flush=True)
        assert result["processing_after_ready"] is True, result
        assert result["accepted"] is True, result
        assert result["request_id"] == "restart-check", result
        assert result["action"].get("data", {}).get("status") == "ok", result
        assert result["status"]["codex"]["status"] == 1, result  # McpClient.Status.CONFIGURED
        assert result["status"]["codex"]["installed"] is True, result
        assert result["snapshot"]["refresh_completed"] is True, result
        assert result["snapshot"]["busy_actions"] == [], result
        parsed = tomllib.loads(config.read_text(encoding="utf-8"))
        assert parsed["model"] == "validation-sentinel"
        entry = parsed["mcp_servers"]["godot-ai"]
        assert "attach" in entry["args"], entry
        # Both a pinned uvx launch and a version-checked system installation
        # are supported; Windows CI has the latter on PATH.
        assert entry["command"], entry
        assert "--port" in entry["args"] and "--ws-port" in entry["args"], entry
        pids.append(result["pid"])
        (project / "result.json").unlink()
    ## Three boots produced three fresh results (each result.json is unlinked
    ## after it is read). Windows reuses process ids freely, so distinct pids
    ## are not evidence of distinct boots and are not asserted (CI saw
    ## [5036, 3004, 5036]).
    assert all(type(pid) is int and pid > 0 for pid in pids), pids


def _stop_process_tree(process: subprocess.Popen) -> None:
    """Stop the backend and everything it spawned.

    A uv-created venv's Windows ``python.exe`` is a launcher whose real
    interpreter runs as a child. ``terminate()`` alone kills the launcher and
    leaves the server alive, still holding the capability lock, which then
    fails the unlink below and leaks a listener into the next boot.
    """
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            capture_output=True,
            check=False,
        )
    else:
        process.terminate()
    try:
        process.wait(timeout=10)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5)


async def test_native_capability_record_survives_backend_restarts(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Exercise the native Windows profile path and same-user authenticated adoption."""
    godot_bin_or_skip()  # Run in the explicit real-platform smoke row.
    if os.name == "nt":
        monkeypatch.delenv("GODOT_AI_CAPABILITY_DIR", raising=False)
    else:
        monkeypatch.setenv("GODOT_AI_CAPABILITY_DIR", str(tmp_path.resolve() / "capabilities"))
    ports = []
    reservations = []
    for _ in range(2):
        reservation = socket.socket()
        reservation.bind(("127.0.0.1", 0))
        ports.append(reservation.getsockname()[1])
        reservations.append(reservation)
    for reservation in reservations:
        reservation.close()
    port, ws_port = ports
    path = record_path(port, capability_directory())
    instances = []
    for boot in range(2):
        log_path = tmp_path / f"backend-{boot}.log"
        with log_path.open("w", encoding="utf-8") as log:
            process = subprocess.Popen(
                [
                    sys.executable, "-m", "godot_ai", "--transport", "streamable-http",
                    "--port", str(port), "--ws-port", str(ws_port),
                ],
                stdout=log, stderr=log,
                env=dict(os.environ, GODOT_AI_DISABLE_TELEMETRY="true"),
            )
            try:
                deadline = time.monotonic() + 45
                while read_capabilities(port) is None and time.monotonic() < deadline:
                    assert process.poll() is None, log_path.read_text(encoding="utf-8")
                    await asyncio.sleep(0.1)
                record = read_capabilities(port)
                assert record is not None, log_path.read_text(encoding="utf-8")
                bridge = BackendEnsurer(
                    port=port, ws_port=ws_port, runtime_dir=tmp_path / "runtime",
                    health_timeout_seconds=10,
                )
                first = await bridge.ensure()
                second = await bridge.ensure()
                assert first.instance_id == second.instance_id == record.instance_nonce
                assert read_capabilities(port) == record
                instances.append(first.instance_id)
                print(f"NATIVE_BACKEND_{boot}: record readable; two authenticated adoptions passed")
            finally:
                _stop_process_tree(process)
        # Windows TerminateProcess does not run Python lifespan cleanup.
        path.unlink(missing_ok=True)
        path.with_suffix(".lock").unlink(missing_ok=True)
    assert len(set(instances)) == 2, "Each restart must publish a fresh instance"
