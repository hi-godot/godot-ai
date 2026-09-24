"""Actual POSIX signals must leave no authenticated backend bootstrap record."""
from __future__ import annotations

import http.client
import json
import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

from godot_ai.transport.capability import read_capabilities, record_path

pytestmark = pytest.mark.skipif(os.name != "posix", reason="POSIX signal exit semantics")
ROOT = Path(__file__).resolve().parents[2]


def _environment(tmp_path):
    env = dict(os.environ)
    for name in ("GODOT_AI_HTTP_CAPABILITY", "GODOT_AI_WS_TOKEN", "GODOT_AI_OWNER_PID"):
        env.pop(name, None)
    env.update(PYTHONPATH=str(ROOT / "src"), GODOT_AI_DISABLE_TELEMETRY="true",
               GODOT_AI_CAPABILITY_DIR=str(tmp_path / "capabilities"))
    return env


def _status(port, token=None):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
    try:
        connection.request("GET", "/godot-ai/status", headers=(
            {} if token is None else {"Authorization": "Bearer " + token}))
        response = connection.getresponse()
        body = response.read()
        return response.status, json.loads(body) if response.status == 200 else None
    finally:
        connection.close()


@pytest.mark.parametrize("transport", ["streamable-http", "sse"])
def test_sigterm_cleans_real_backend_record_and_preserves_signal_exit(tmp_path, transport):
    with socket.socket() as http_socket, socket.socket() as ws_socket:
        http_socket.bind(("127.0.0.1", 0))
        ws_socket.bind(("127.0.0.1", 0))
        port, ws_port = http_socket.getsockname()[1], ws_socket.getsockname()[1]
    directory = tmp_path / "capabilities"
    with (tmp_path / "backend.log").open("wb") as log:
        child = subprocess.Popen(
            [sys.executable, "-m", "godot_ai", "--transport", transport,
             "--port", str(port), "--ws-port", str(ws_port)],
            env=_environment(tmp_path), stdout=log, stderr=subprocess.STDOUT,
        )
    try:
        status_attempts = 0
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            assert child.poll() is None, "backend exited; inspect backend.log"
            record = read_capabilities(port, directory)
            if record is not None:
                try:
                    status_attempts += 1
                    if status_attempts == 1:
                        # Publication can precede HTTP binding; exercise that retry every run.
                        raise ConnectionRefusedError("fixture startup refusal")
                    status, data = _status(port, record.http)
                except (OSError, http.client.HTTPException):
                    time.sleep(.05)
                    continue
                if status == 200:
                    assert data["instance_id"] == record.instance_nonce
                    assert data["ws_port"] == ws_port
                    break
            time.sleep(.05)
        else:
            pytest.fail("authenticated backend never became ready")
        assert status_attempts >= 2
        assert _status(port)[0] == 401
        assert record_path(port, directory).exists()
        child.send_signal(signal.SIGTERM)
        assert child.wait(timeout=15) == -signal.SIGTERM
        assert not record_path(port, directory).exists()
        assert read_capabilities(port, directory) is None
        with socket.socket() as released_http, socket.socket() as released_ws:
            released_http.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            released_ws.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            released_http.bind(("127.0.0.1", port))
            released_ws.bind(("127.0.0.1", ws_port))
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)


def test_sigterm_during_startup_unwinds_owned_claim_before_signal_exit(tmp_path):
    script = tmp_path / "early.py"
    marker = tmp_path / "claim-held"
    cleaned = tmp_path / "cleaned"
    with socket.socket() as http_socket, socket.socket() as ws_socket:
        http_socket.bind(("127.0.0.1", 0))
        ws_socket.bind(("127.0.0.1", 0))
        port, ws_port = http_socket.getsockname()[1], ws_socket.getsockname()[1]
    script.write_text(
        "import asyncio\nfrom pathlib import Path\n"
        "from godot_ai import main\n"
        "import godot_ai.server as server\n"
        "original_acquire = server.acquire_port_claim\n"
        "claims = []\n"
        "class ObservedClaim:\n"
        "    def __init__(self, actual):\n"
        "        self.actual = actual\n"
        "    def release(self):\n"
        "        self.actual.release()\n"
        f"        Path({str(cleaned)!r}).touch()\n"
        "def acquire(*args, **kwargs):\n"
        "    claim = ObservedClaim(original_acquire(*args, **kwargs))\n"
        "    claims.append(claim)\n"
        "    return claim\n"
        "async def blocked_ready(self):\n"
        "    assert len(claims) == 1\n"
        f"    Path({str(marker)!r}).touch()\n"
        "    await asyncio.Event().wait()\n"
        "server.acquire_port_claim = acquire\n"
        "server.GodotWebSocketServer.wait_until_ready = blocked_ready\n"
        f"main(['--transport', 'streamable-http', '--port', '{port}', "
        f"'--ws-port', '{ws_port}'])\n", encoding="utf-8",
    )
    with (tmp_path / "early.log").open("wb") as log:
        child = subprocess.Popen(
            [sys.executable, str(script)], env=_environment(tmp_path),
            stdout=log, stderr=subprocess.STDOUT,
        )
    try:
        deadline = time.monotonic() + 30
        while not marker.exists():
            assert child.poll() is None, "startup exited; inspect early.log"
            assert time.monotonic() < deadline, "startup never held the real claim"
            time.sleep(.02)
        assert not record_path(port, tmp_path / "capabilities").exists()
        assert not cleaned.exists()
        child.send_signal(signal.SIGTERM)
        assert child.wait(timeout=10) == -signal.SIGTERM
        # The proxy has no destructor: only the lifecycle's explicit release
        # call creates this marker, not kernel lock release or object collection.
        assert cleaned.exists()
        assert not record_path(port, tmp_path / "capabilities").exists()
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
