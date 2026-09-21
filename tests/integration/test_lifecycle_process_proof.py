"""Prove actual backend ownership while an authenticated route changes PID hints."""

import json
import os
import shutil
import socket
import subprocess
import sys
import time
from pathlib import Path

import httpx
import psutil
import pytest

from godot_ai.transport.capability import read_capabilities
from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

pytestmark = pytest.mark.editor


def test_real_lifecycle_proof_revalidates_pid_hints_and_final_identity(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "proof"
    shutil.copytree(PLUGIN_ROOT, project / "addons" / "godot_ai")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Process proof test"\n'
        '[autoload]\nProofDriver="*res://driver.gd"\n', encoding="utf-8",
    )
    shutil.copyfile(Path(__file__).with_name("_lifecycle_process_proof.gd"), project / "driver.gd")
    # Allocate distinct available ports without relying on a shared fixed pair.
    with socket.socket() as http_socket, socket.socket() as ws_socket:
        http_socket.bind(("127.0.0.1", 0))
        ws_socket.bind(("127.0.0.1", 0))
        http_port, ws_port = http_socket.getsockname()[1], ws_socket.getsockname()[1]
    capability_dir = tmp_path / "local-app-data" / "godot-ai" / "capabilities"
    environment = {
        "PROOF_WORK": str(tmp_path), "GODOT_AI_DISABLE_TELEMETRY": "true",
        "LOCALAPPDATA": str(tmp_path / "local-app-data"),
        "GODOT_AI_CAPABILITY_DIR": "" if os.name == "nt" else str(capability_dir),
        "PYTHONPATH": os.pathsep.join([str(ROOT / "src"), *sys.path]),
    }
    child_env = {**os.environ, **environment}
    stale = subprocess.Popen([sys.executable, "-c", "pass"], env=child_env)
    stale.wait(timeout=10)
    command = [
        sys.executable, str(Path(__file__).with_name("_godot_ai_process_proof_backend.py")),
        "--transport", "streamable-http", "--port", str(http_port), "--ws-port", str(ws_port),
    ]
    with (tmp_path / "backend.log").open("w", encoding="utf-8") as output:
        backend = subprocess.Popen(command, env=child_env, stdout=output, stderr=subprocess.STDOUT)
        identity = None
        owned = {}

        def capture_owned() -> None:
            if identity is None:
                return
            try:
                parent = psutil.Process(backend.pid)
                assert (parent.create_time(), parent.cmdline()) == identity
                for process in [parent, *parent.children(recursive=True)]:
                    value = (process.create_time(), process.cmdline())
                    assert process.pid not in owned or owned[process.pid] == value
                    owned.setdefault(process.pid, value)
            except psutil.NoSuchProcess:
                return  # A reaped fixture grants no new cleanup authority.

        try:
            parent = psutil.Process(backend.pid)
            identity = (parent.create_time(), parent.cmdline())
            owned[backend.pid] = identity
            with httpx.Client(trust_env=False, timeout=3) as client:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    capture_owned()
                    assert backend.poll() is None, "backend exited; inspect backend.log"
                    record = read_capabilities(http_port, capability_dir)
                    if record is not None:
                        try:
                            status = client.get(f"http://127.0.0.1:{http_port}/godot-ai/status",
                                                headers={"Authorization": f"Bearer {record.http}"})
                            if (status.status_code == 200
                                    and status.json()["instance_id"] == record.instance_nonce):
                                break
                        except httpx.TransportError:
                            pass  # Binding/publication can precede HTTP readiness.
                    time.sleep(.05)
                else:
                    pytest.fail("real authenticated backend did not become ready")
                denied = client.get(f"http://127.0.0.1:{http_port}/godot-ai/status")
                assert denied.status_code == 401
            capture_owned()
            worker_record = json.loads(
                (tmp_path / "backend-process.json").read_text(encoding="utf-8")
            )
            worker_pid = int(worker_record["pid"])
            assert worker_pid in owned, "actual worker must belong to the spawned tree"
            assert any(parent.pid == os.getpid() for parent in psutil.Process(worker_pid).parents())
            (tmp_path / "processes.json").write_text(json.dumps({
                "launch_pid": os.getpid(), "worker_pid": worker_pid,
                "unrelated_pid": os.getppid(), "stale_pid": stale.pid,
                "http_port": http_port, "ws_port": ws_port,
            }))
            log = run_godot_editor(project, godot, allow_headless=False, timeout=180,
                                   environment=environment)
            assert "SCRIPT ERROR:" not in log
            result = json.loads((project / "result.json").read_text(encoding="utf-8"))
            assert result["failures"] == [], result
            assert {row["case"]: row["reason"] for row in result["rows"]} == {
                "initial_capture_failure": "identity_unavailable",
                "final_capture_failure": "identity_unavailable", "exited_launcher": "launch_gone",
                "owned_child": "ok", "changed_hint": "ok", "stale_hint_corrected": "ok",
                "unrelated_hint_corrected": "ok", "unrelated_hint_retained": "listener_pid",
                "wrong_launch_identity": "launch_replaced",
                "final_pid_changed": "final_capture_window",
            }
        finally:
            try:
                capture_owned()
                processes = []
                for pid, expected in reversed(list(owned.items())):
                    try:
                        process = psutil.Process(pid)
                        assert (process.create_time(), process.cmdline()) == expected
                        process.terminate()
                        processes.append(process)
                    except psutil.NoSuchProcess:
                        continue
                _, alive = psutil.wait_procs(processes, timeout=10)
                assert not alive, "owned backend cleanup must complete"
            finally:
                # The owned Popen handle still permits cleanup if initial
                # psutil identity acquisition failed immediately after spawn.
                if backend.poll() is None:
                    backend.terminate()
                backend.wait(timeout=10)
