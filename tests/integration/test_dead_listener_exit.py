"""A backend whose HTTP listener dies must exit and free the WebSocket port."""

from __future__ import annotations

import asyncio
import http.client
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

import pytest

from godot_ai.server import watch_http_listener
from godot_ai.transport.capability import read_capabilities

needs_proactor = pytest.mark.skipif(
    os.name != "nt", reason="proactor accept failure is Windows-only"
)
ROOT = Path(__file__).resolve().parents[2]
## The exit is bounded by the shutdown path (SIGINT into uvicorn's graceful
## close); a longer hang means a bug this test must surface, not a slow boot.
CHILD_EXIT_TIMEOUT_S = 30  # shutdown budget: see exit_on_dead_listener in src/godot_ai/server.py
KILL_WAIT_TIMEOUT_S = 5  # force-kill wait: see subprocess.Popen.kill in the Python stdlib docs

## Child: every accept completed after the marker exists fails the way AcceptEx
## does when a client resets mid-handshake (ERROR_NETNAME_DELETED). CPython's
## proactor then closes the listener for good and only logs it.
CHILD = """
import asyncio, sys
from asyncio import windows_events
from pathlib import Path
from godot_ai import main

marker = Path(sys.argv[1])
real_accept = windows_events.IocpProactor.accept

def accept(self, listener):
    inner = real_accept(self, listener)
    outer = self._loop.create_future()
    def finish(done):
        if outer.done():
            return
        if done.cancelled():
            outer.cancel()
        elif marker.exists():
            outer.set_exception(OSError(None, "network name deleted", None, 64))
        elif done.exception() is not None:
            outer.set_exception(done.exception())
        else:
            outer.set_result(done.result())
    inner.add_done_callback(finish)
    outer.add_done_callback(lambda f: f.cancelled() and inner.cancel())
    return outer

windows_events.IocpProactor.accept = accept
main(sys.argv[2:])
"""


@needs_proactor
def test_dead_http_listener_exits_and_releases_websocket_port(tmp_path):
    with socket.socket() as http_socket, socket.socket() as ws_socket:
        http_socket.bind(("127.0.0.1", 0))
        ws_socket.bind(("127.0.0.1", 0))
        port, ws_port = http_socket.getsockname()[1], ws_socket.getsockname()[1]
    env = dict(os.environ, PYTHONPATH=str(ROOT / "src"), GODOT_AI_DISABLE_TELEMETRY="true")
    for name in ("GODOT_AI_HTTP_CAPABILITY", "GODOT_AI_WS_TOKEN", "GODOT_AI_OWNER_PID"):
        env.pop(name, None)
    script, marker = tmp_path / "child.py", tmp_path / "fail-accept"
    script.write_text(CHILD, encoding="utf-8")
    with (tmp_path / "backend.log").open("wb") as log:
        child = subprocess.Popen(
            [
                sys.executable,
                str(script),
                str(marker),
                "--transport",
                "streamable-http",
                "--port",
                str(port),
                "--ws-port",
                str(ws_port),
            ],
            env=env,
            stdout=log,
            stderr=subprocess.STDOUT,
        )
    try:
        deadline = time.monotonic() + 45
        while read_capabilities(port) is None:
            assert child.poll() is None, "backend exited early; inspect backend.log"
            assert time.monotonic() < deadline, "backend never published capabilities"
            time.sleep(0.05)
        marker.touch()
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
        try:
            connection.request("GET", "/godot-ai/status")
            connection.getresponse()
        except (OSError, http.client.HTTPException):
            pass
        finally:
            connection.close()
        child.wait(timeout=CHILD_EXIT_TIMEOUT_S)
    finally:
        if child.poll() is None:
            child.kill()
            child.wait(timeout=KILL_WAIT_TIMEOUT_S)
            pytest.fail("backend kept running without an HTTP listener")
    assert read_capabilities(port) is None, "shutdown must unwind the capability record"
    with socket.socket() as released:
        released.bind(("127.0.0.1", ws_port))


async def test_http_listener_probe_exits_only_after_first_success():
    calls: list[bool] = []
    server_sock = socket.socket()
    task: asyncio.Task | None = None
    try:
        ## Bound but not listening: probes fail as on a slow boot, and a
        ## failure before the first success must not trigger the exit.
        server_sock.bind(("127.0.0.1", 0))
        port = server_sock.getsockname()[1]
        task = asyncio.create_task(
            watch_http_listener(
                port,
                poll_seconds=0.02,
                probe_timeout=0.05,
                shutdown=lambda: calls.append(True),
            )
        )
        await asyncio.sleep(0.1)
        assert calls == [], "a failure before the first success must not exit"

        server_sock.listen(5)
        await asyncio.sleep(0.1)  ## first success arms the guard

        server_sock.close()
        await asyncio.sleep(0.025)
        assert calls == [], "one failure below the threshold must not exit"
        await asyncio.wait_for(task, timeout=2.0)
        assert calls == [True], "consecutive failures past the threshold must exit"
    finally:
        server_sock.close()
        if task is not None:
            task.cancel()
            try:
                await task
            except asyncio.CancelledError:
                pass
