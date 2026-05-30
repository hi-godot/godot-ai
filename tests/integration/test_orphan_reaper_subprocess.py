"""End-to-end orphan-reaper test against a REAL server subprocess.

Unlike the unit tests (which inject fakes), this spawns an actual
``python -m godot_ai`` HTTP server with ``--owner-pid`` pointed at a throwaway
owner process, kills the owner, and asserts the server self-terminates. It
exercises the genuine POSIX primitives — ``os.kill(pid, 0)`` liveness and the
``SIGTERM``-to-self → uvicorn graceful shutdown — on whatever OS CI runs it on
(notably the Linux runners, which the in-CI plugin path never arms the reaper
on). Skipped on Windows, where the reaper is intentionally disabled.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time

import pytest

pytestmark = pytest.mark.skipif(
    sys.platform.startswith("win"),
    reason="orphan reaper is disabled on Windows (see should_arm_reaper)",
)


def _free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _port_open(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(0.25)
        return s.connect_ex(("127.0.0.1", port)) == 0


def _wait_port_closed(port: int, timeout: float) -> bool:
    """Poll until nothing is listening on ``port`` (socket teardown isn't
    instant after a process exits — avoids a TIME_WAIT flake)."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if not _port_open(port):
            return True
        time.sleep(0.2)
    return not _port_open(port)


def _terminate(proc: subprocess.Popen | None) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.kill()
    try:
        proc.wait(timeout=5)
    except subprocess.TimeoutExpired:
        pass


def test_server_subprocess_reaps_when_owner_dies():
    http_port = _free_port()
    ws_port = _free_port()
    # Two independent _free_port() calls can hand back the same just-released
    # ephemeral port; the server can't bind both on one port. Force them apart.
    while ws_port == http_port:
        ws_port = _free_port()

    env = dict(os.environ)
    env["GODOT_AI_DISABLE_TELEMETRY"] = "true"
    env["GODOT_AI_REAPER_POLL_SECONDS"] = "0.3"  # fast reap for the test

    owner = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"])
    server = None
    try:
        server = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "godot_ai",
                "--transport",
                "streamable-http",
                "--port",
                str(http_port),
                "--ws-port",
                str(ws_port),
                "--owner-pid",
                str(owner.pid),
            ],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        # Wait for the HTTP listener to come up (server fully started).
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if server.poll() is not None:
                pytest.fail(f"server exited early with code {server.returncode}")
            if _port_open(http_port):
                break
            time.sleep(0.2)
        else:
            pytest.fail("server did not start listening within 20s")

        # Owner alive + no editor sessions → reaper must NOT fire yet.
        time.sleep(1.0)
        assert server.poll() is None, "server reaped while owner still alive"

        # Kill the owner → reaper should see it gone, 0 sessions, and shut down.
        owner.kill()
        owner.wait(timeout=5)

        try:
            rc = server.wait(timeout=15)
        except subprocess.TimeoutExpired:
            pytest.fail("server did NOT self-terminate after owner died (reaper failed)")
        assert rc is not None
        # Port released after the process exits (poll: teardown isn't instant).
        assert _wait_port_closed(http_port, timeout=5), "http port not released after reap"
    finally:
        _terminate(server)
        _terminate(owner)
