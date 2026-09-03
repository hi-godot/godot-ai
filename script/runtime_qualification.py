"""Exercise an immutable signed A-to-B release pair in a real Godot editor.

The harness owns only an external disposable project, TLS adapter and driver.
It never patches either candidate add-on, rebuilds an artifact, or substitutes
development Python code for the candidate server/update actor.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from godot_ai.update_transaction import (  # noqa: E402
    TransactionPaths,
    hash_tree,
    install_id,
    load_intent,
    validate_migration_complete,
    validate_terminal,
)
from script import release_qualification as qualification  # noqa: E402
from script import release_support as support  # noqa: E402
from script.qualification_https import ORIGIN, private_release_origin  # noqa: E402
from script.qualification_index import retained_index  # noqa: E402

HTTP_PORT = 8000
WS_PORT = 9500
TIMEOUT_SECONDS = 360


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


def _wait_for_ports_free(*ports: int, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if all(_free_port(port) for port in ports):
            return
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
            "GODOT_AI_CAPABILITY_DIR": str(capabilities),
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
        _DRIVER.replace("@VERSION_A@", version_a).replace("@VERSION_B@", version_b),
        encoding="utf-8",
    )


_DRIVER = """@tool
extends Node

const VERSION_A := "@VERSION_A@"
const VERSION_B := "@VERSION_B@"
const DEADLINE_MS := 300000
var deadline := 0
var started := false
var old_instance := ""

func _ready() -> void:
    if not Engine.is_editor_hint():
        queue_free()
        return
    if OS.get_environment("GODOT_AI_RUNTIME_QUALIFICATION_PARSE_ONLY") == "1":
        get_tree().quit(0)
        return
    deadline = Time.get_ticks_msec() + DEADLINE_MS
    set_process(true)

func _process(_delta: float) -> void:
    if Time.get_ticks_msec() >= deadline:
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
        started = true
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
    _finish(0, {
        "status": "passed", "from_version": VERSION_A, "to_version": VERSION_B,
        "old_instance": old_instance, "new_instance": instance,
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


def _verify_transaction(project: Path, candidate_a: Path, candidate_b: Path) -> dict[str, Any]:
    live = project / "addons/godot_ai"
    root = project.parent / ".godot-ai-recovery" / install_id(project.resolve(), live.resolve())
    support.require(root.is_dir(), "runtime update did not create its bound recovery root")
    support.require(not (root / "activation.lock").exists(), "runtime update retained its lock")
    backup = root / "retained-backup"
    support.require(
        support.inventory(backup) == _manifest_tree(candidate_a),
        "runtime backup is not exact A",
    )
    transactions = root / "transactions"
    entries = [path for path in transactions.iterdir() if path.is_dir()]
    support.require(len(entries) == 1, "runtime update did not retain exactly one transaction")
    paths = TransactionPaths.for_transaction(root, entries[0].name)
    intent = load_intent(paths)
    claim = validate_terminal(paths.claim, intent)
    completion = validate_migration_complete(paths, intent)
    support.require(claim["outcome"] == "success", "runtime transaction did not succeed")
    support.require(
        hash_tree(backup) == intent.old_tree and hash_tree(live) == intent.new_tree,
        "runtime transaction identities differ from A/B",
    )
    return {
        "transaction": intent.transaction,
        "claim": support.fingerprint(paths.claim),
        "migration_complete": support.fingerprint(paths.migration_complete),
        "backup_tree": support.inventory(backup),
        "migration_editor": completion["editor"],
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
    actual_godot_version = _validate_godot_version(str(executable), godot_version)
    support.require(_free_port(HTTP_PORT) and _free_port(WS_PORT), "qualification ports are busy")
    output.mkdir(parents=True)
    with tempfile.TemporaryDirectory(prefix="godot-ai-exact-runtime-") as temporary:
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
                "--recovery-root",
                str(work / "initial-install-recovery"),
                "--editors-closed",
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
                completed = subprocess.run(
                    [str(executable), "--headless", "--editor", "--path", str(project)],
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
                support.require(
                    release.downloads
                    == [
                        "godot-ai-v4-plugin.zip",
                        "godot-ai-v4-plugin.manifest.json",
                        "godot-ai-v4-plugin.manifest.sig",
                    ],
                    "update did not download exactly B's canonical signed triple",
                )
            _wait_for_ports_free(HTTP_PORT, WS_PORT)
        result = support.read_json(project / "runtime-result.json")
        support.require(result.get("status") == "passed", "runtime driver did not pass")
        live = project / "addons/godot_ai"
        support.require(
            support.inventory(live) == _manifest_tree(candidates / "b"), "live tree is not exact B"
        )
        config = Path(environment["CODEX_HOME"]) / "config.toml"
        text = config.read_text(encoding="utf-8")
        support.require(
            records["b"]["version"] in text and index not in text, "client pin is not clean B"
        )
        support.require(
            not any(secret in json.dumps(result) for secret in (release.token, index)),
            "qualification capability leaked into result",
        )
        transaction = _verify_transaction(project, candidates / "a", candidates / "b")
        private_values = (release.token, index, _private_index_capability(index), ORIGIN)
        _require_values_absent(project, private_values)
        _require_values_absent(project.parent / ".godot-ai-recovery", private_values)
        _require_values_absent(output, private_values)
        return {
            **result,
            "id": "exact-a-to-b-hot-update",
            "godot": {
                "path": str(Path(executable).resolve()),
                "sha256": hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                "version": actual_godot_version,
            },
            "index_artifacts_requested": sorted(set(index_requests)),
            "live_tree": support.inventory(live),
            "backend_stopped": True,
            **transaction,
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
    python_version = current_python_version()
    support.require(python_version in {"3.11", "3.14"}, "unsupported runtime Python row")
    support.require(godot_version in qualification.GODOT_BUILDS, "unsupported runtime Godot row")
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
    parser.add_argument("--godot-version", choices=qualification.GODOT_BUILDS, required=True)
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
