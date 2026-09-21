"""End-to-end contracts for the main shell Godot test runner."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

from godot_ai.transport.capability import (
    CAPABILITY_DIR_ENV,
    HTTP_CAPABILITY_ENV,
    WS_CAPABILITY_ENV,
    write_capabilities,
)
from script import release_support

ROOT = Path(__file__).resolve().parents[2]


class _LoopbackServer(release_support.LoopbackBind, ThreadingHTTPServer):
    """No FQDN lookup of 127.0.0.1: that stalls ~35 s per process on macOS."""


RUNNER = ROOT / "script" / "ci-godot-tests"
HTTP_CAPABILITY = "ci-runner-http-capability-0123456789abcdef"
WS_CAPABILITY = "0123456789abcdef" * 4
INSTANCE_NONCE = "1234567890abcdef1234567890abcdef"


def _find_bash() -> str:
    if bash := shutil.which("bash"):
        return bash
    if os.name == "nt":
        candidates = [
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git/bin/bash.exe",
            Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "Git/usr/bin/bash.exe",
        ]
        if git := shutil.which("git"):
            git_root = Path(git).resolve().parent.parent
            candidates.extend((git_root / "bin/bash.exe", git_root / "usr/bin/bash.exe"))
        for candidate in candidates:
            if candidate.is_file():
                return str(candidate)
    pytest.skip("bash is required for the shell runner regression")


def _capability_environment(tmp_path: Path, port: int) -> dict[str, str]:
    environment = os.environ.copy()
    for name in (CAPABILITY_DIR_ENV, HTTP_CAPABILITY_ENV, WS_CAPABILITY_ENV):
        environment.pop(name, None)

    if os.name == "nt":
        capability_dir = tmp_path / "godot-ai" / "capabilities"
        environment["LOCALAPPDATA"] = str(tmp_path)
    else:
        capability_dir = tmp_path / "capabilities"
        environment[CAPABILITY_DIR_ENV] = str(capability_dir)

    write_capabilities(
        port,
        HTTP_CAPABILITY,
        WS_CAPABILITY,
        instance_nonce=INSTANCE_NONCE,
        directory=capability_dir,
    )
    return environment


class _RunnerState:
    def __init__(self) -> None:
        self.initialize_attempts = 0
        self.sessions_created = 0
        self.session_list_calls = 0
        self.deleted_sessions: list[str] = []
        self.lock = threading.Lock()


def _tool_result(request_id: Any, content: dict[str, Any]) -> dict[str, Any]:
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": {
            "content": [{"type": "text", "text": json.dumps(content)}],
            "structuredContent": content,
            "isError": False,
        },
    }


def _handler(
    state: _RunnerState,
    project_path: Path,
    response_shape: str,
    runner_name: str = "ci-godot-tests",
) -> type[BaseHTTPRequestHandler]:
    suite_names = sorted(
        path.stem.removeprefix("test_") for path in project_path.glob("tests/test_*.gd")
    )

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, _format: str, *_args: object) -> None:
            pass

        def _request(self) -> dict[str, Any]:
            length = int(self.headers.get("Content-Length", "0"))
            return json.loads(self.rfile.read(length) or b"{}")

        def _json(self, status: int, payload: dict[str, Any], **headers: str) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for name, value in headers.items():
                self.send_header(name, value)
            self.end_headers()
            self.wfile.write(body)

        def _tool_response(self, payload: dict[str, Any]) -> None:
            if response_shape == "json":
                self._json(200, payload)
                return
            body = f"data: {json.dumps(payload)}\n\n".encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self) -> None:  # noqa: N802
            request = self._request()
            method = request.get("method")
            if method == "initialize":
                with state.lock:
                    state.initialize_attempts += 1
                    if state.sessions_created >= 32:
                        self._json(
                            429,
                            {
                                "jsonrpc": "2.0",
                                "id": request.get("id"),
                                "error": {
                                    "code": "MCP_SESSION_LIMIT_REACHED",
                                    "message": "session limit reached",
                                },
                            },
                        )
                        return
                    state.sessions_created += 1
                    session_id = f"ci-session-{state.sessions_created}"
                self._json(
                    200,
                    {"jsonrpc": "2.0", "id": request.get("id"), "result": {}},
                    **{"Mcp-Session-Id": session_id},
                )
                return

            if method == "notifications/initialized":
                self._json(200, {})
                return

            if method != "tools/call":
                self._json(400, {"error": "unexpected request"})
                return

            tool = request.get("params", {}).get("name")
            if tool == "session_manage":
                with state.lock:
                    state.session_list_calls += 1
                    connected = state.session_list_calls >= 2
                content: dict[str, Any] = {
                    "count": 1 if connected else 0,
                    "sessions": (
                        [
                            {
                                "session_id": "test-project@0123456789abcdef",
                                "project_path": str(project_path),
                            }
                        ]
                        if connected
                        else []
                    ),
                }
            elif tool == "filesystem_manage":
                content = {"scanned": True}
            elif tool == "scene_open":
                content = {"path": "res://main.tscn"}
            elif tool == "test_run":
                content = {
                    "passed": 25 if runner_name == "ci-slow-suite-smoke" else 2200,
                    "failed": 0,
                    "skipped": 0,
                    "total": 25 if runner_name == "ci-slow-suite-smoke" else 2200,
                    "failures": [],
                    "load_errors": [],
                    "suite_count": len(suite_names),
                    "suites_run": suite_names,
                }
            else:
                self._json(400, {"error": f"unexpected tool: {tool}"})
                return
            self._tool_response(_tool_result(request.get("id"), content))

        def do_DELETE(self) -> None:  # noqa: N802
            with state.lock:
                state.deleted_sessions.append(self.headers.get("Mcp-Session-Id", ""))
            self.send_response(204)
            self.send_header("Content-Length", "0")
            self.end_headers()

    return Handler


@pytest.mark.parametrize("runner_name", ("ci-godot-tests", "ci-slow-suite-smoke"))
@pytest.mark.parametrize("response_shape", ("json", "sse"))
def test_runner_reuses_one_mcp_session_and_accepts_both_response_shapes(
    tmp_path: Path,
    response_shape: str,
    runner_name: str,
) -> None:
    state = _RunnerState()
    server = _LoopbackServer(
        ("127.0.0.1", 0),
        _handler(state, ROOT / "test_project", response_shape, runner_name),
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        port = server.server_address[1]
        environment = _capability_environment(tmp_path, port)
        environment["MCP_SERVER_URL"] = f"http://127.0.0.1:{port}/mcp"
        environment["GODOT_AI_MIN_TESTS"] = "2050"
        python_path = [str(ROOT / "src")]
        if inherited := environment.get("PYTHONPATH"):
            python_path.append(inherited)
        environment["PYTHONPATH"] = os.pathsep.join(python_path)

        result = subprocess.run(
            [
                _find_bash(),
                "-c",
                (
                    "sleep() { :; }; "
                    "python3() { echo 'unexpected python3 call' >&2; return 97; }; "
                    'export -f sleep python3; exec bash "$1" "$2"'
                ),
                "ci-godot-tests-regression",
                str(ROOT / "script" / runner_name),
                sys.executable,
            ],
            cwd=ROOT,
            env=environment,
            text=True,
            encoding="utf-8",
            errors="replace",
            capture_output=True,
            timeout=30,
            check=False,
        )
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)

    assert result.returncode == 0, f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
    assert state.initialize_attempts == 1
    assert state.sessions_created == 1
    assert state.session_list_calls == 3
    assert state.deleted_sessions == ["ci-session-1"]
    if runner_name == "ci-godot-tests":
        assert "Godot tests: 2200/2200 passed, 0 failed, 0 skipped" in result.stdout
    else:
        assert "PASS: slow suite completed" in result.stdout
        assert not (ROOT / "test_project/tests/test_mcp_slow_smoke.gd").exists()
