"""Exercise the update driver's HTTP status polling against real socket failures."""

from __future__ import annotations

import json
import os
import socket
import socketserver
import subprocess
import threading
import time

import pytest

from tests.integration._self_update_fixture import godot_bin_or_skip, write_driver_support

pytestmark = pytest.mark.editor


def test_status_driver_quietly_rejects_interrupted_and_invalid_responses(tmp_path):
    nonce = "fixture-status-instance"
    valid = json.dumps({"instance_id": nonce, "server_version": "4.0.5"}).encode()
    responses = [
        valid,
        b'{"broken":',
        valid,
        b"x" * (64 * 1024 + 1),
        json.dumps({"instance_id": "wrong"}).encode(),
        valid,
    ]
    observed = []

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            request = b""
            while b"\r\n\r\n" not in request:
                chunk = self.request.recv(4096)
                if not chunk:
                    return
                request += chunk
            index = len(observed)
            observed.append(b"Authorization: Bearer fixture-status-auth" in request)
            body = responses[index]
            size = len(body) + 10 if index == 2 else len(body)
            self.request.sendall(
                f"HTTP/1.1 200 OK\r\nContent-Length: {size}\r\nConnection: close\r\n\r\n".encode()
            )
            if index == 2:
                # Give Godot time to enter STATUS_BODY before the connection drops.
                time.sleep(0.05)
            self.request.sendall(body)
            if index == 2:
                time.sleep(0.05)
                self.request.shutdown(socket.SHUT_RDWR)

    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
        port = server.server_address[1]
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            (tmp_path / "project.godot").write_text("config_version=5\n", encoding="utf-8")
            write_driver_support(tmp_path)
            capabilities = tmp_path / "local/godot-ai/capabilities"
            capabilities.mkdir(parents=True)
            (capabilities / f"http-{port}.json").write_text(
                json.dumps({"http": "fixture-status-auth", "instance_nonce": nonce}),
                encoding="utf-8",
            )
            driver = tmp_path / "driver.gd"
            driver.write_text(
                'extends SceneTree\nconst Support = preload("res://_test_self_update_driver_support.gd")\n'
                "func _initialize() -> void:\n"
                f"\tvar first := Support.fetch_status({port})\n"
                '\tassert(first.get("server_version") == "4.0.5")\n'
                "\tfor _index in range(4):\n"
                f"\t\tassert(Support.fetch_status({port}).is_empty())\n"
                f'\tassert(Support.fetch_status({port}).get("instance_id") == "{nonce}")\n'
                '\tprint("STATUS_DRIVER_SOCKET_CASES_PASSED")\n\tquit()\n',
                encoding="utf-8",
            )
            env = {
                **os.environ,
                "LOCALAPPDATA": str(tmp_path / "local"),
                "GODOT_AI_CAPABILITY_DIR": str(capabilities),
                "GODOT_AI_DISABLE_TELEMETRY": "true",
            }
            result = subprocess.run(
                [
                    godot_bin_or_skip(),
                    "--headless",
                    "--path",
                    str(tmp_path),
                    "--script",
                    str(driver),
                ],
                capture_output=True,
                text=True,
                timeout=30,
                env=env,
            )
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            assert "ERROR" not in output, output
            assert "STATUS_DRIVER_SOCKET_CASES_PASSED" in output
            assert observed == [True] * len(responses)
        finally:
            server.shutdown()
            thread.join(timeout=5)


@pytest.mark.parametrize("framing", ["chunked", "malformed-chunk", "missing-terminal", "close"])
def test_status_driver_requires_complete_explicit_framing(tmp_path, framing):
    body = b'{"instance_id":"framing-instance","server_version":"4.0.5"}'
    chunk = f"{len(body):x}\r\n".encode() + body + b"\r\n"
    response = (b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" + chunk
                + {"chunked": b"0\r\n\r\n", "malformed-chunk": b"Z\r\n",
                   "missing-terminal": b"", "close": b""}[framing])
    if framing == "close":
        response = b"HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n" + body
    observed = []

    class Handler(socketserver.BaseRequestHandler):
        def handle(self):
            request = b""
            while b"\r\n\r\n" not in request:
                part = self.request.recv(4096)
                if not part:
                    return
                request += part
            observed.append(b"Authorization: Bearer framing-auth" in request)
            self.request.sendall(response)
            time.sleep(0.05)

    with socketserver.TCPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            port = server.server_address[1]
            (tmp_path / "project.godot").write_text("config_version=5\n", encoding="utf-8")
            write_driver_support(tmp_path)
            capabilities = tmp_path / "local/godot-ai/capabilities"
            capabilities.mkdir(parents=True)
            (capabilities / f"http-{port}.json").write_text(json.dumps({
                "http": "framing-auth", "instance_nonce": "framing-instance",
            }), encoding="utf-8")
            driver = tmp_path / "driver.gd"
            driver.write_text(
                'extends SceneTree\nconst Support = preload("res://_test_self_update_driver_support.gd")\n'
                'func _initialize():\n'
                f'\tvar value = Support.fetch_status({port})\n'
                '\tvar file = FileAccess.open("res://result.json", FileAccess.WRITE)\n'
                '\tfile.store_string(JSON.stringify(value))\n\tfile.close()\n\tquit()\n',
                encoding="utf-8",
            )
            result = subprocess.run([
                godot_bin_or_skip(), "--headless", "--path", str(tmp_path), "--script", str(driver),
            ], capture_output=True, text=True, timeout=15, env={
                **os.environ, "LOCALAPPDATA": str(tmp_path / "local"),
                "GODOT_AI_CAPABILITY_DIR": str(capabilities), "GODOT_AI_DISABLE_TELEMETRY": "true",
            })
            output = result.stdout + result.stderr
            assert result.returncode == 0, output
            actual = json.loads((tmp_path / "result.json").read_text(encoding="utf-8"))
            assert actual == (json.loads(body) if framing == "chunked" else {}), output
            if framing == "malformed-chunk":
                # This malformed chunk deliberately triggers the native parser error below.
                errors = [line for line in output.splitlines() if "ERROR:" in line]
                assert errors == ["ERROR: HTTP Chunk len not in hex!!"], output
            else:
                assert "ERROR" not in output, output
            assert observed == [True]
        finally:
            server.shutdown()
            thread.join(timeout=5)


@pytest.mark.parametrize("publish_gate", [False, True])
def test_generated_agent_gate_budget_starts_on_first_entry(tmp_path, publish_gate):
    from tests.integration._self_update_fixture import write_install_update_driver

    write_install_update_driver(tmp_path, http_port=18000, base_version="4.0.4",
                                next_version="4.0.5", agent_gate=True)
    generated = (tmp_path / "_test_runner_driver.gd").read_text(encoding="utf-8")
    start = generated.index("\t\tif AGENT_GATE and not FileAccess.file_exists(AGENT_GATE_PATH):")
    end = generated.index("\t\tif not _update_candidate_ready():", start)
    branch = "\n".join(line[1:] for line in generated[start:end].splitlines())
    declarations = "\n".join(line for line in generated.splitlines()
                             if line.startswith("var _agent_gate_started_ms"))
    driver = tmp_path / "gate.gd"
    driver.write_text(
        'extends SceneTree\nconst AGENT_GATE = true\nconst STATUS_WAIT_MS = 100\n'
        'const AGENT_GATE_PATH = "res://gate"\n' + declarations + '\n'
        'var failed = false\nvar continued = false\n'
        'func _fail(_code, _message):\n\tfailed = true\n'
        'func step():\n' + branch + '\n\tcontinued = true\n'
        'func _initialize():\n\tOS.delay_msec(200)\n\tstep()\n'
        '\tvar early_failed = failed\n\tvar early_continued = continued\n'
        + ('\tvar gate = FileAccess.open(AGENT_GATE_PATH, FileAccess.WRITE)\n'
           '\tgate.store_string("ready")\n\tgate.close()\n' if publish_gate else
           '\tOS.delay_msec(150)\n')
        + '\tstep()\n\tvar file = FileAccess.open("res://gate-result.json", FileAccess.WRITE)\n'
        '\tfile.store_string(JSON.stringify({"early_failed":early_failed, '
        '"early_continued":early_continued,"failed":failed,"continued":continued}))\n'
        '\tfile.close()\n\tquit()\n', encoding="utf-8",
    )
    (tmp_path / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    result = subprocess.run([
        godot_bin_or_skip(), "--headless", "--path", str(tmp_path), "--script", str(driver),
    ], capture_output=True, text=True, timeout=15,
        env={**os.environ, "GODOT_AI_DISABLE_TELEMETRY": "true"})
    output = result.stdout + result.stderr
    assert result.returncode == 0 and "ERROR" not in output, output
    receipt = json.loads((tmp_path / "gate-result.json").read_text(encoding="utf-8"))
    assert receipt == {"early_failed": False, "early_continued": False,
                       "failed": not publish_gate, "continued": publish_gate}
