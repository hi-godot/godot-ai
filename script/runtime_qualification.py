"""Exercise an immutable signed A-to-B release pair in a real Godot editor.

The harness owns only an external disposable project, TLS adapter and driver.
It never patches either candidate add-on, rebuilds an artifact, or substitutes
development Python code for the candidate server.
"""

from __future__ import annotations

import argparse
import json
import os
import platform
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from godot_ai import release_verify  # noqa: E402
from script import qualification_engine as engine  # noqa: E402
from script import release_qualification as qualification  # noqa: E402
from script import release_support as support  # noqa: E402
from script.qualification_https import ORIGIN, private_release_origin  # noqa: E402
from script.qualification_index import retained_index  # noqa: E402

HTTP_PORT = 8000
WS_PORT = 9500
TIMEOUT_SECONDS = 360
MANIFEST_NAME = "release/godot-ai-v4-plugin.manifest.json"
# The lean updater keeps its marker, lock and retained backup beside the live
# tree; nothing of it lives outside the project (docs/self-update.md).
UPDATE_STATE = "addons/.godot_ai_update"
# EditorInterface.restart_editor forwards explicit display/audio driver options
# but not the --headless shorthand (Godot 4.7). The update restarts the editor,
# and the restarted editor must stay headless on a display-less runner.
HEADLESS_EDITOR_ARGUMENTS = ("--display-driver", "headless", "--audio-driver", "Dummy")
## Gate files the attached bridge writes into the project for the driver:
## the first after it has served candidate A, so Update is clicked with a
## client attached; the second after the same bridge process has listed the
## editor session served by candidate B and closed, so the driver may quit.
BRIDGE_ATTACHED_FILE = "_bridge_attached.done"
BRIDGE_SERVED_B_FILE = "_bridge_served_b.done"
BRIDGE_ATTACH_TIMEOUT_SECONDS = 180.0
BRIDGE_CALL_TIMEOUT_SECONDS = 60.0
## A stop must finish one 1 s poll slice plus the close's own process waits.
BRIDGE_STOP_TIMEOUT_SECONDS = 50.0


def current_python_version() -> str:
    return f"{sys.version_info.major}.{sys.version_info.minor}"


def _validate_godot_version(executable: str, expected: str) -> str:
    actual = subprocess.run(
        [executable, "--version"], capture_output=True, text=True, check=True, timeout=15
    ).stdout.strip()
    parts = expected.split(".")
    display = ".".join(parts[:2]) if parts[2] == "0" else expected
    support.require(
        actual.startswith(f"{display}.stable.official."),
        "Godot executable differs from the required official build",
    )
    return actual


def _free_port(port: int) -> bool:
    family = socket.AF_INET
    with socket.socket(family, socket.SOCK_STREAM) as listener:
        try:
            listener.bind(("127.0.0.1", port))
        except OSError:
            return False
    return True


def _editor_command(executable: str | Path, project: Path) -> list[str]:
    return [str(executable), *HEADLESS_EDITOR_ARGUMENTS, "--editor", "--path", str(project)]


def _read_runtime_result(project: Path) -> dict[str, Any]:
    """The driver writes its report with GDScript's JSON.stringify, not canonically."""
    result = support.read_json(project / "runtime-result.json", canonical_required=False)
    support.require(type(result) is dict, "runtime driver result is not an object")
    return result


def _wait_for_runtime_result(path: Path, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while not path.is_file():
        support.require(time.monotonic() < deadline, "the restarted editor did not report a result")
        time.sleep(0.5)


def _capability_directory(environment: dict[str, str]) -> Path:
    """Where the row's backend publishes capabilities (see _isolated_environment)."""
    override = environment.get("GODOT_AI_CAPABILITY_DIR", "")
    if override:
        return Path(override)
    return Path(environment["LOCALAPPDATA"]) / "godot-ai" / "capabilities"


def _wait_for_capability_release(directory: Path, timeout: float = 30.0) -> None:
    """A stopped backend releases its capability lock a moment after its ports.

    A lock still held past the deadline means a backend outlived the editor.
    """
    deadline = time.monotonic() + timeout
    for lock in sorted(directory.glob("*.lock")) if directory.is_dir() else []:
        while not _lock_released(lock):
            remaining = deadline - time.monotonic()
            support.require(
                remaining > 0, f"candidate backend still holds {lock.name} after editor exit"
            )
            time.sleep(min(0.5, remaining))


def _lock_released(lock: Path) -> bool:
    """Whether no process holds the backend's port-claim lock any more.

    Windows refuses to delete a file another process holds open, so a
    successful delete is the proof there. On POSIX the backend holds an
    advisory flock and deleting the file says nothing, so the proof is taking
    that lock ourselves; the file is removed once we hold it.
    """
    if os.name == "nt":
        try:
            lock.unlink()
        except FileNotFoundError:
            return True
        except OSError:
            return False
        return True
    import fcntl

    try:
        with lock.open("rb") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return False
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    except FileNotFoundError:
        return True
    lock.unlink(missing_ok=True)
    return True


def _scrub_private_material(*paths: Path) -> None:
    """Remove the row's private key and capability records before the
    best-effort temp cleanup, so a cleanup failure can never retain them."""
    for path in paths:
        try:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)
        except OSError as error:
            raise support.ReleaseError(f"could not remove private material {path}: {error}")
        support.require(not path.exists(), f"private material remains at {path}")


# The restarted editor writes its result, then quits; its teardown kills the
# backend tree, and on a loaded Windows runner the whole exit has taken longer
# than 15 s (qualification run 34079902982) while run 34077763471 cleared it.
# A backend that never lets go is still refused, just later.
EDITOR_EXIT_TIMEOUT_SECONDS = 120.0


def _wait_for_ports_free(*ports: int, timeout: float = 15.0) -> float:
    """Seconds until every port was free; refuses when the backend stays up."""
    started = time.monotonic()
    deadline = started + timeout
    while time.monotonic() < deadline:
        if all(_free_port(port) for port in ports):
            return time.monotonic() - started
        time.sleep(0.1)
    raise support.ReleaseError("candidate backend remained live after editor exit")


def _tls_material(root: Path) -> tuple[Path, Path]:
    """Create a one-run certificate for the fixed private HTTPS hostname."""

    from script.qualification_https import ORIGIN_HOST

    root.mkdir()
    certificate, key = root / "certificate.pem", root / "private-key.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-nodes",
            "-days",
            "1",
            "-subj",
            f"/CN={ORIGIN_HOST}",
            "-addext",
            f"subjectAltName=DNS:{ORIGIN_HOST}",
            "-keyout",
            str(key),
            "-out",
            str(certificate),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    return certificate, key


def _isolated_environment(root: Path, index: str) -> dict[str, str]:
    home = root / "home"
    codex = root / "codex"
    config = root / "xdg-config"
    data = root / "xdg-data"
    cache = root / "xdg-cache"
    local = root / "local-app-data"
    capabilities = local / "godot-ai" / "capabilities" if os.name == "nt" else root / "capabilities"
    for directory in (home, codex, config, data, cache, capabilities):
        directory.mkdir(mode=0o700, parents=True)
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("UV_", "PIP_", "PYTHON", "GODOT_AI_"))
    }
    environment.update(
        {
            "HOME": str(home),
            "USERPROFILE": str(home),
            "CODEX_HOME": str(codex),
            "XDG_CONFIG_HOME": str(config),
            "XDG_DATA_HOME": str(data),
            "XDG_CACHE_HOME": str(cache),
            # The server refuses this override on Windows; there the isolated
            # LOCALAPPDATA below already relocates the capability directory.
            **({} if os.name == "nt" else {"GODOT_AI_CAPABILITY_DIR": str(capabilities)}),
            "GODOT_AI_DISABLE_TELEMETRY": "true",
            "GODOT_AI_ALLOW_HEADLESS": "1",
            "GODOT_AI_MODE": "user",
            "GODOT_AI_QUALIFICATION_PYTHON_INDEX": "1",
            "UV_INDEX": index,
            "UV_DEFAULT_INDEX": index,
            "UV_PYTHON": sys.executable,
            "UV_PYTHON_DOWNLOADS": "never",
            "UV_CACHE_DIR": str(root / "uv-cache"),
            "UV_TOOL_DIR": str(root / "uv-tools"),
            "UV_NO_PROGRESS": "1",
            "PIP_CONFIG_FILE": os.devnull,
            "PYTHONNOUSERSITE": "1",
        }
    )
    if os.name == "nt":
        environment["LOCALAPPDATA"] = str(local)
    return environment


def _write_client_pin(codex: Path, uvx: str, version: str) -> None:
    args = [
        "--link-mode",
        "copy",
        "--from",
        f"godot-ai=={version}",
        "godot-ai",
        "attach",
        "--port",
        str(HTTP_PORT),
        "--ws-port",
        str(WS_PORT),
    ]
    encoded = ", ".join(json.dumps(value) for value in args)
    (codex / "config.toml").write_text(
        '[mcp_servers."godot-ai"]\n'
        f"command = {json.dumps(uvx)}\n"
        f"args = [{encoded}]\n"
        "enabled = true\nstartup_timeout_sec = 60\ntool_timeout_sec = 360\n",
        encoding="utf-8",
    )


def _write_project(
    project: Path,
    certificate: Path,
    version_a: str,
    version_b: str,
    *,
    enable_plugin: bool = True,
) -> None:
    enabled = (
        'enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")'
        if enable_plugin
        else "enabled=PackedStringArray()"
    )
    (project / "project.godot").write_text(
        f"""config_version=5

[application]
config/name="Godot AI Exact Runtime Qualification"
run/main_scene="res://empty.tscn"
config/features=PackedStringArray("4.7")

[editor_plugins]
{enabled}

[autoload]
_QualificationTransport="*res://_qualification_transport.gd"
_QualificationDriver="*res://_qualification_driver.gd"
""",
        encoding="utf-8",
    )
    (project / "empty.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Main" type="Node3D"]\n', encoding="utf-8"
    )
    (project / "_qualification_transport.gd").write_text(
        """@tool
extends Node

var certificate := X509Certificate.new()

func _enter_tree() -> void:
    assert(certificate.load(OS.get_environment("PRIVATE_HTTPS_CERTIFICATE")) == OK)
    get_tree().node_added.connect(_configure)

func _configure(node: Node) -> void:
    if not node is HTTPRequest:
        return
    var owner_node := node.get_parent()
    if owner_node == null or owner_node.get_script() == null:
        return
    if owner_node.get_script().resource_path != "res://addons/godot_ai/utils/update_manager.gd":
        return
    node.set_https_proxy("127.0.0.1", int(OS.get_environment("PRIVATE_HTTPS_PORT")))
    node.set_tls_options(TLSOptions.client(certificate))
""",
        encoding="utf-8",
    )
    (project / "_qualification_driver.gd").write_text(
        _DRIVER.replace("@VERSION_A@", version_a)
        .replace("@VERSION_B@", version_b)
        .replace("@BRIDGE_ATTACHED@", BRIDGE_ATTACHED_FILE)
        .replace("@BRIDGE_SERVED_B@", BRIDGE_SERVED_B_FILE),
        encoding="utf-8",
    )


_DRIVER = """@tool
extends Node

const VERSION_A := "@VERSION_A@"
const VERSION_B := "@VERSION_B@"
const DEADLINE_MS := 300000
## The update restarts the editor; the restarted driver resumes from here.
const PROGRESS_PATH := "res://runtime-progress.json"
var deadline := 0
var started := false
var b_live := false
var old_instance := ""

func _ready() -> void:
    if not Engine.is_editor_hint():
        queue_free()
        return
    if OS.get_environment("GODOT_AI_RUNTIME_QUALIFICATION_PARSE_ONLY") == "1":
        get_tree().quit(0)
        return
    if FileAccess.file_exists(PROGRESS_PATH):
        var progress: Variant = JSON.parse_string(FileAccess.get_file_as_string(PROGRESS_PATH))
        if progress is Dictionary:
            started = bool(progress.get("started", false))
            old_instance = str(progress.get("old_instance", ""))
    deadline = Time.get_ticks_msec() + DEADLINE_MS
    set_process(true)

func _process(_delta: float) -> void:
    if Time.get_ticks_msec() >= deadline:
        if b_live:
            _finish(44, {"error": "the attached bridge never served candidate B"})
        else:
            _finish(41, {"error": "runtime qualification timed out"})
        return
    var plugin := _find_plugin()
    if plugin == null:
        return
    if not started:
        var status := _status()
        old_instance = str(status.get("instance_id", ""))
        var manager: Variant = plugin.get("_update_manager")
        if old_instance.is_empty() or manager == null or not manager.has_install_candidate():
            return
        if not _client_pin(VERSION_A):
            _finish(42, {"error": "candidate A client pin missing"})
            return
        if not FileAccess.file_exists("res://@BRIDGE_ATTACHED@"):
            return
        started = true
        var progress := FileAccess.open(PROGRESS_PATH, FileAccess.WRITE)
        if progress == null:
            _finish(43, {"error": "cannot record qualification progress"})
            return
        progress.store_string(JSON.stringify({"started": true, "old_instance": old_instance}))
        progress.close()
        plugin.call("_on_dock_update_requested")
        return
    var config := ConfigFile.new()
    if config.load("res://addons/godot_ai/plugin.cfg") != OK:
        return
    if str(config.get_value("plugin", "version", "")) != VERSION_B:
        return
    var current := _status()
    var instance := str(current.get("instance_id", ""))
    if (
        str(current.get("server_version", "")) != VERSION_B
        or instance.is_empty()
        or instance == old_instance
        or not _client_pin(VERSION_B)
    ):
        return
    b_live = true
    if not FileAccess.file_exists("res://@BRIDGE_SERVED_B@"):
        return
    _finish(0, {
        "status": "passed", "from_version": VERSION_A, "to_version": VERSION_B,
        "old_instance": old_instance, "new_instance": instance,
        "attached_bridge_served_b": true,
    })

func _finish(code: int, report: Dictionary) -> void:
    set_process(false)
    var file := FileAccess.open("res://runtime-result.json", FileAccess.WRITE)
    if file != null:
        file.store_string(JSON.stringify(report))
        file.close()
    get_tree().quit(code)

func _client_pin(version: String) -> bool:
    var path := OS.get_environment("CODEX_HOME").path_join("config.toml")
    return FileAccess.file_exists(path) and FileAccess.get_file_as_string(path).contains(
        "godot-ai==%s" % version)

func _find_plugin() -> EditorPlugin:
    return _walk(get_tree().root)

func _walk(node: Node) -> EditorPlugin:
    if node is EditorPlugin and node.has_method("install_downloaded_update"):
        return node
    for child in node.get_children():
        var found := _walk(child)
        if found != null:
            return found
    return null

func _status() -> Dictionary:
    var capability := _capability()
    if capability.is_empty():
        return {}
    var client := HTTPClient.new()
    if client.connect_to_host("127.0.0.1", 8000) != OK:
        return {}
    var end := Time.get_ticks_msec() + 2000
    while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
        client.poll()
        if Time.get_ticks_msec() >= end:
            return {}
        OS.delay_msec(10)
    if client.get_status() != HTTPClient.STATUS_CONNECTED:
        return {}
    var headers := PackedStringArray([
        "Authorization: Bearer %s" % capability.http, "Accept-Encoding: identity"])
    if client.request(HTTPClient.METHOD_GET, "/godot-ai/status", headers) != OK:
        return {}
    while client.get_status() == HTTPClient.STATUS_REQUESTING:
        client.poll()
        if Time.get_ticks_msec() >= end:
            return {}
        OS.delay_msec(10)
    var body := PackedByteArray()
    while client.get_status() == HTTPClient.STATUS_BODY:
        client.poll()
        var chunk := client.read_response_body_chunk()
        if body.size() + chunk.size() > 65536:
            return {}
        body.append_array(chunk)
        if Time.get_ticks_msec() >= end:
            return {}
        if chunk.is_empty():
            OS.delay_msec(5)
    var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
    if not parsed is Dictionary or parsed.get("instance_id") != capability.instance_nonce:
        return {}
    return parsed

func _capability() -> Dictionary:
    var directory := OS.get_environment("GODOT_AI_CAPABILITY_DIR")
    if OS.get_name() == "Windows":
        directory = OS.get_environment("LOCALAPPDATA").path_join("godot-ai/capabilities")
    var path := directory.path_join("http-8000.json")
    if not FileAccess.file_exists(path):
        return {}
    var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
    return parsed if parsed is Dictionary else {}
"""


class AttachedBridge:
    """A real ``godot-ai attach`` bridge, attached through the whole update.

    The bridge is the published package pinned to candidate A, resolved from
    the retained index exactly as a client entry written for A would run it.
    It speaks MCP over stdio itself (newline-delimited JSON-RPC; the runner
    has no MCP client library), lists the editor session before the update
    so the driver may click Update with a client attached, keeps calling
    through the swap and the editor restart, and passes only when the same
    bridge process lists a session served by candidate B. That is the
    contract #1024 gives users: a plugin update within a major version needs
    no client relaunch.
    """

    def __init__(
        self,
        command: list[str],
        environment: dict[str, str],
        project: Path,
        capability_dir: Path,
        version_a: str,
        version_b: str,
        log_path: Path,
    ) -> None:
        self.command = command
        self.environment = environment
        self.project = project
        self.capability_dir = capability_dir
        self.version_a = version_a
        self.version_b = version_b
        self.log_path = log_path
        self.ok_before_update = 0
        self.served_b = False
        self.errors: list[str] = []
        self.fault = ""
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="attached-bridge", daemon=True)
        self._lines: queue.Queue[str | None] = queue.Queue()
        self._next_id = 0
        self._process: subprocess.Popen[bytes] | None = None

    def __enter__(self) -> AttachedBridge:
        self._thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        """Stop the bridge and prove it stopped: the row reads the bridge log,
        scans the project and waits for the ports right after this, so a
        thread that outlived its budget must not keep a process alive."""
        self._stop.set()
        self._thread.join(timeout=BRIDGE_STOP_TIMEOUT_SECONDS)
        if self._thread.is_alive():
            process = self._process
            if process is not None and process.poll() is None:
                process.kill()
            self._thread.join(timeout=15)
            self.fault = self.fault or "attached bridge did not stop within its budget"

    def report(self) -> dict[str, Any]:
        return {
            "pin": self.version_a,
            "ok_before_update": self.ok_before_update,
            "served_b": self.served_b,
            "errors": self.errors[-5:],
            "fault": self.fault,
        }

    def _run(self) -> None:
        try:
            self._attach_and_follow()
        except Exception as exc:  # surfaced by the row after the run
            self.fault = f"{type(exc).__name__}: {exc}"

    def _attach_and_follow(self) -> None:
        deadline = time.monotonic() + BRIDGE_ATTACH_TIMEOUT_SECONDS
        record = self.capability_dir / f"http-{HTTP_PORT}.json"
        while not record.is_file():
            if self._stop.is_set() or time.monotonic() > deadline:
                raise RuntimeError("candidate A never published its capability record")
            time.sleep(0.25)
        with self.log_path.open("ab") as log:
            process = subprocess.Popen(
                self.command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=log,
                env=self.environment,
                cwd=str(self.project.parent),
            )
            self._process = process
            reader = threading.Thread(target=self._read, args=(process,), daemon=True)
            reader.start()
            try:
                self._handshake(process)
                self._follow(process)
            finally:
                self._close(process)

    def _read(self, process: subprocess.Popen[bytes]) -> None:
        assert process.stdout is not None
        for raw in process.stdout:
            self._lines.put(raw.decode("utf-8", errors="replace"))
        self._lines.put(None)

    def _send(self, process: subprocess.Popen[bytes], message: dict[str, Any]) -> None:
        assert process.stdin is not None
        process.stdin.write((json.dumps(message) + "\n").encode("utf-8"))
        process.stdin.flush()

    def _request(
        self, process: subprocess.Popen[bytes], method: str, params: dict[str, Any]
    ) -> dict[str, Any]:
        self._next_id += 1
        request_id = self._next_id
        self._send(
            process, {"jsonrpc": "2.0", "id": request_id, "method": method, "params": params}
        )
        deadline = time.monotonic() + BRIDGE_CALL_TIMEOUT_SECONDS
        while True:
            ## Poll in short slices so a stop request ends a call promptly
            ## instead of waiting out the full call budget.
            support.require(not self._stop.is_set(), "attached bridge was stopped")
            remaining = deadline - time.monotonic()
            support.require(remaining > 0, f"attached bridge did not answer {method}")
            try:
                line = self._lines.get(timeout=min(1.0, remaining))
            except queue.Empty:
                continue
            support.require(line is not None, "attached bridge closed its output")
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("id") == request_id:
                return message

    def _handshake(self, process: subprocess.Popen[bytes]) -> None:
        response = self._request(
            process,
            "initialize",
            {
                "protocolVersion": "2024-11-05",
                "capabilities": {},
                "clientInfo": {"name": "godot-ai-qualification", "version": "1"},
            },
        )
        support.require("result" in response, f"attached bridge refused initialize: {response}")
        self._send(process, {"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _sessions(self, process: subprocess.Popen[bytes]) -> list[dict[str, Any]] | str:
        response = self._request(
            process, "tools/call", {"name": "session_manage", "arguments": {"op": "list"}}
        )
        if "error" in response:
            return json.dumps(response["error"])[:300]
        result = response.get("result", {})
        texts = [
            item.get("text", "") for item in result.get("content", []) if isinstance(item, dict)
        ]
        if result.get("isError"):
            return (" ".join(texts) or "tool error")[:300]
        payload: Any = result.get("structuredContent")
        if payload is None:
            try:
                payload = json.loads(texts[0]) if texts else None
            except json.JSONDecodeError:
                payload = None
        if not isinstance(payload, dict):
            return f"unexpected session_manage payload: {str(result)[:200]}"
        sessions = payload.get("sessions", [])
        return [session for session in sessions if isinstance(session, dict)]

    def _follow(self, process: subprocess.Popen[bytes]) -> None:
        attached = self.project / BRIDGE_ATTACHED_FILE
        while not self._stop.is_set():
            sessions = self._sessions(process)
            if isinstance(sessions, str):
                self.errors.append(sessions)
            else:
                versions = {
                    (str(s.get("plugin_version", "")), str(s.get("server_version", "")))
                    for s in sessions
                }
                if (self.version_a, self.version_a) in versions and not attached.exists():
                    attached.write_text("attached\n", encoding="utf-8")
                if attached.exists() and not self.served_b:
                    self.ok_before_update += 1
                if (self.version_b, self.version_b) in versions:
                    self.served_b = True
                    return
            time.sleep(0.5)

    def _close(self, process: subprocess.Popen[bytes]) -> None:
        """Close the client side first so the bridge releases its lease, then
        tell the driver the same bridge served B; the editor may quit now."""
        try:
            if process.stdin is not None:
                process.stdin.close()
        except OSError:
            pass
        try:
            process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
        if self.served_b:
            (self.project / BRIDGE_SERVED_B_FILE).write_text("served\n", encoding="utf-8")


def _bridge_command(uvx: str, version: str) -> list[str]:
    """The exact launch a client entry written for ``version`` performs."""
    return [
        uvx,
        "--link-mode",
        "copy",
        "--from",
        f"godot-ai=={version}",
        "godot-ai",
        "attach",
        "--port",
        str(HTTP_PORT),
        "--ws-port",
        str(WS_PORT),
        "--disable-telemetry",
    ]


def _manifest_tree(candidate: Path) -> dict[str, dict[str, Any]]:
    manifest = support.read_json(candidate / "release/godot-ai-v4-plugin.manifest.json")
    prefix = "addons/godot_ai/"
    support.require(
        all(row["path"].startswith(prefix) for row in manifest["inventory"]),
        "candidate inventory is outside the managed add-on",
    )
    return {
        row["path"][len(prefix) :]: {"size": row["size"], "sha256": row["sha256"]}
        for row in manifest["inventory"]
    }


def _write_secret_free_log(path: Path, output: bytes, secrets: tuple[str, ...]) -> None:
    """Retain diagnostics only when they contain no private capability value."""

    leaked = [secret for secret in secrets if secret.encode() in output]
    if leaked:
        path.write_text(
            "qualification output withheld: private capability leaked\n", encoding="utf-8"
        )
        raise support.ReleaseError("qualification process printed a private capability")
    path.write_bytes(output)


def _require_values_absent(root: Path, values: tuple[str, ...]) -> None:
    needles = tuple(value.encode() for value in values if value)
    for path in root.rglob("*"):
        if path.is_symlink() or not path.is_file():
            continue
        data = path.read_bytes()
        support.require(
            not any(needle in data for needle in needles),
            f"private qualification value persisted in {path.relative_to(root)}",
        )


def _private_index_capability(index: str) -> str:
    path = urlsplit(index).path.strip("/").split("/", 1)[0]
    support.require(path, "private index capability is missing")
    return path


def _execute_sensitive(
    command: list[str],
    log: Path,
    *,
    cwd: Path,
    environment: dict[str, str],
    secrets: tuple[str, ...],
) -> None:
    completed = subprocess.run(
        command,
        cwd=cwd,
        env=environment,
        capture_output=True,
        timeout=2400,
        check=False,
    )
    header = support.canonical({"command": command, "cwd": str(cwd)})
    _write_secret_free_log(log, header + completed.stdout + completed.stderr, secrets)
    support.require(completed.returncode == 0, f"qualification command failed; see {log}")


def _verify_lean_update(
    project: Path, candidates: Path, records: dict[str, dict[str, Any]]
) -> dict[str, Any]:
    """Prove the editor left exactly the lean updater's success state behind.

    The live tree must hash to B's signed inventory, the single retained backup
    to A's, the marker must record that success against B's manifest, and no
    lock, stage or quarantine may survive (docs/self-update.md, steps 6-10).
    """
    live = project / "addons/godot_ai"
    state = project / UPDATE_STATE
    marker_path = state / "pending.json"
    support.require(marker_path.is_file(), "runtime update did not record its marker")
    marker = support.read_json(marker_path, canonical_required=False)
    support.require(type(marker) is dict, "runtime update marker is not an object")
    version_a, version_b = records["a"]["version"], records["b"]["version"]
    manifests = {name: candidates / name / MANIFEST_NAME for name in ("a", "b")}
    expected = {
        name: release_verify.inventory_tree_hash(support.read_json(path))
        for name, path in manifests.items()
    }
    support.require(marker.get("status") == "success", "runtime update did not succeed")
    support.require(
        marker.get("clients_migrated") is True,
        "runtime update did not record its client migration",
    )
    support.require(
        marker.get("from_version") == version_a and marker.get("to_version") == version_b,
        "runtime update marker versions differ from A/B",
    )
    support.require(
        marker.get("manifest_sha256") == support.fingerprint(manifests["b"])["sha256"]
        and marker.get("expected_tree_sha256") == expected["b"],
        "runtime update marker is not bound to B's signed manifest",
    )
    support.require(
        release_verify.hash_tree(live)["tree_sha256"] == expected["b"],
        "live tree is not exact B",
    )
    backups = state / "backup"
    retained = sorted(path.name for path in backups.iterdir()) if backups.is_dir() else []
    support.require(retained == [version_a], "runtime update did not retain exactly A")
    backup = backups / version_a
    support.require(
        release_verify.hash_tree(backup)["tree_sha256"] == expected["a"],
        "runtime backup is not exact A",
    )
    backup_root = str(marker.get("backup_root", "")).replace("\\", "/").rstrip("/")
    support.require(
        backup_root.endswith(f"backup/{version_a}"),
        "runtime update marker does not name the retained backup",
    )
    for leftover in ("lock.json", "stage", "quarantine"):
        support.require(not (state / leftover).exists(), f"runtime update retained {leftover}")
    return {
        "update_marker": support.fingerprint(marker_path),
        "update_state": {
            key: marker.get(key)
            for key in (
                "status",
                "clients_migrated",
                "from_version",
                "to_version",
                "manifest_sha256",
                "expected_tree_sha256",
            )
        },
        "live_tree_sha256": expected["b"],
        "backup_tree": support.inventory(backup),
        "backup_tree_sha256": expected["a"],
    }


def exact_a_to_b(
    candidates: Path,
    packages: Path,
    dependencies: list[dict[str, Any]],
    godot: str,
    godot_version: str,
    output: Path,
) -> dict[str, Any]:
    records = {name: support.verify_candidate(candidates / name, name) for name in ("a", "b")}
    executable = shutil.which(godot) if not Path(godot).is_absolute() else godot
    support.require(
        executable is not None and Path(executable).is_file(), "Godot executable missing"
    )
    engine_identity = engine.verify_executable(Path(executable), godot_version)
    executable = engine_identity["path"]
    actual_godot_version = _validate_godot_version(str(executable), godot_version)
    support.require(_free_port(HTTP_PORT) and _free_port(WS_PORT), "qualification ports are busy")
    output.mkdir(parents=True)
    # A backend that has just been stopped can still hold its capability lock
    # for a moment; the row waits for that release and removes every private
    # file itself, so this best-effort cleanup can only ever leave public
    # scratch (retained wheels, the project) behind on a runner.
    with tempfile.TemporaryDirectory(
        prefix="godot-ai-exact-runtime-", ignore_cleanup_errors=True
    ) as temporary:
        work = Path(temporary).resolve()
        project = work / "project"
        project.mkdir()
        (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
        certificate, key = _tls_material(work / "tls")
        release_b = candidates / "b/release"
        with retained_index(packages, dependencies) as (index, index_requests):
            environment = _isolated_environment(work / "environment", index)
            uvx = shutil.which("uvx", path=environment.get("PATH"))
            support.require(uvx is not None, "uvx is required for runtime qualification")
            _write_client_pin(Path(environment["CODEX_HOME"]), uvx, records["a"]["version"])
            print("Installing signed candidate A in the disposable project", flush=True)
            command = [
                sys.executable,
                str(support.ROOT / "script/v4-release"),
                "install",
                "--archive",
                str(candidates / "a/release/godot-ai-v4-plugin.zip"),
                "--manifest",
                str(candidates / "a/release/godot-ai-v4-plugin.manifest.json"),
                "--signature",
                str(candidates / "a/release/godot-ai-v4-plugin.manifest.sig"),
                "--expected-repository",
                support.REPOSITORY,
                "--expected-channel",
                "stable",
                "--expected-tag",
                records["a"]["tag"],
                "--expected-version",
                records["a"]["version"],
                "--expected-source",
                records["a"]["source"],
                "--project-root",
                str(project),
            ]
            _execute_sensitive(
                command,
                output / "install-a.log",
                cwd=work,
                environment=environment,
                secrets=(index,),
            )
            _write_project(project, certificate, records["a"]["version"], records["b"]["version"])
            with private_release_origin(
                release_b,
                support.inventory(release_b),
                version=records["b"]["version"],
                certificate=certificate,
                private_key=key,
            ) as release:
                environment.update(release.environment())
                environment.update(
                    {
                        "PRIVATE_HTTPS_PORT": str(release.proxy_port),
                        "PRIVATE_HTTPS_CERTIFICATE": str(certificate),
                    }
                )
                print(f"Running the A-to-B update in Godot {godot_version}", flush=True)
                bridge_log = work / "attached-bridge.log"
                bridge = AttachedBridge(
                    _bridge_command(uvx, records["a"]["version"]),
                    environment,
                    project,
                    _capability_directory(environment),
                    records["a"]["version"],
                    records["b"]["version"],
                    bridge_log,
                )
                with bridge:
                    completed = subprocess.run(
                        _editor_command(executable, project),
                        cwd=work,
                        env=environment,
                        capture_output=True,
                        timeout=TIMEOUT_SECONDS,
                        check=False,
                    )
                    _write_secret_free_log(
                        output / "godot.log",
                        completed.stdout + completed.stderr,
                        (release.token, index),
                    )
                    support.require(completed.returncode == 0, "real Godot A-to-B update failed")
                    # The swap restarts the editor; the process above exits and
                    # the restarted editor finishes the case once the attached
                    # bridge has listed the session candidate B serves.
                    print("Waiting for the restarted editor to report candidate B", flush=True)
                    _wait_for_runtime_result(project / "runtime-result.json", TIMEOUT_SECONDS)
                _write_secret_free_log(
                    output / "attached-bridge.log",
                    bridge_log.read_bytes() if bridge_log.is_file() else b"",
                    (release.token, index),
                )
                support.require(not bridge.fault, f"attached bridge failed: {bridge.fault}")
                support.require(
                    bridge.ok_before_update >= 1,
                    "the attached bridge never served candidate A before the update",
                )
                support.require(
                    bridge.served_b,
                    f"the attached bridge never served candidate B: {bridge.errors[-3:]}",
                )
                support.require(
                    release.downloads
                    == [
                        "godot-ai-v4-plugin.zip",
                        "godot-ai-v4-plugin.manifest.json",
                        "godot-ai-v4-plugin.manifest.sig",
                    ],
                    "update did not download exactly B's canonical signed triple",
                )
            released = _wait_for_ports_free(HTTP_PORT, WS_PORT, timeout=EDITOR_EXIT_TIMEOUT_SECONDS)
            print(f"backend released its ports {released:.1f}s after the editor's result")
            capability_dir = _capability_directory(environment)
            _wait_for_capability_release(capability_dir)
            _scrub_private_material(key, capability_dir)
        print("Verifying update evidence and private-data cleanup", flush=True)
        result = _read_runtime_result(project)
        support.require(result.get("status") == "passed", "runtime driver did not pass")
        support.require(
            result.get("attached_bridge_served_b") is True,
            "runtime driver finished without the attached bridge serving B",
        )
        live = project / "addons/godot_ai"
        live_tree = support.inventory(live)
        support.require(live_tree == _manifest_tree(candidates / "b"), "live tree is not exact B")
        config = Path(environment["CODEX_HOME"]) / "config.toml"
        text = config.read_text(encoding="utf-8")
        support.require(
            records["b"]["version"] in text and index not in text, "client pin is not clean B"
        )
        support.require(
            not any(secret in json.dumps(result) for secret in (release.token, index)),
            "qualification capability leaked into result",
        )
        update = _verify_lean_update(project, candidates, records)
        private_values = (release.token, index, _private_index_capability(index), ORIGIN)
        _require_values_absent(project, private_values)
        _require_values_absent(output, private_values)
        return {
            **result,
            "id": "exact-a-to-b-hot-update",
            "godot": {
                **engine_identity,
                "version": actual_godot_version,
            },
            "index_artifacts_requested": sorted(set(index_requests)),
            "live_tree": live_tree,
            "backend_stopped": True,
            "attached_bridge": bridge.report(),
            **update,
        }


def runtime_row(
    candidates: Path,
    python_row: Path,
    godot: str,
    godot_version: str,
    output: Path,
    os_label: str,
) -> None:
    support.require(os_label in support.PLATFORMS, "unknown platform row")
    support.require(os_label == engine.host_row(), "runtime row differs from actual host")
    python_version = current_python_version()
    support.require(python_version in {"3.11", "3.14"}, "unsupported runtime Python row")
    support.require(
        godot_version in qualification.RUNTIME_GODOT_VERSIONS, "unsupported runtime Godot row"
    )
    support.require(not output.exists(), "qualification output already exists")
    records = {name: support.verify_candidate(candidates / name, name) for name in ("a", "b")}
    source_row = support.read_json(python_row / "row.json")
    bindings = {name: support.fingerprint(candidates / name / "evidence.json") for name in records}
    support.require(
        source_row.get("kind") == "python"
        and source_row.get("status") == "passed"
        and source_row.get("os") == os_label
        and source_row.get("python") == python_version
        and source_row.get("candidates") == bindings,
        "runtime dependency row is not the matching exact Python evidence",
    )
    dependencies = qualification.dependency_inventory(python_row / "packages")
    support.require(
        source_row.get("dependencies") == dependencies,
        "runtime packages changed after Python evidence",
    )
    output.mkdir(parents=True)
    report: dict[str, Any] = {
        "schema": 2,
        "kind": "runtime",
        "status": "failed",
        "required_skips": 0,
        "os": os_label,
        "python": python_version,
        "godot_version": godot_version,
        "python_build": sys.version,
        "machine": platform.machine(),
        "platform": platform.platform(),
        "candidates": bindings,
        "cases": [],
    }
    try:
        report["cases"].append(
            exact_a_to_b(
                candidates,
                python_row / "packages",
                dependencies,
                godot,
                godot_version,
                output / "exact-a-to-b",
            )
        )
        report["status"] = "passed"
    finally:
        report["files"] = support.inventory(output)
        (output / "row.json").write_bytes(support.canonical(report))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path, required=True)
    parser.add_argument("--python-row", type=Path, required=True)
    parser.add_argument("--godot", default=os.environ.get("GODOT_BIN", "godot"))
    parser.add_argument(
        "--godot-version", choices=qualification.RUNTIME_GODOT_VERSIONS, required=True
    )
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--os", choices=support.PLATFORMS, required=True)
    args = parser.parse_args(argv)
    try:
        runtime_row(
            args.candidates.resolve(),
            args.python_row.resolve(),
            args.godot,
            args.godot_version,
            args.output.resolve(),
            args.os,
        )
    except (support.ReleaseError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"runtime qualification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
