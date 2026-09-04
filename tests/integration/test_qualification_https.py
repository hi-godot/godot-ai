"""Real Godot HTTPS through a harness-only per-request proxy/TLS adapter."""

import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from script import release_support as support
from script.qualification_https import private_release_origin
from tests._qualification_https_fixture import make_tls_material
from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    load_smoke_script,
    read_plugin_version,
)

DRIVER = """extends SceneTree

var certificate := X509Certificate.new()

func _initialize() -> void:
    assert(certificate.load(OS.get_environment("PRIVATE_HTTPS_CERTIFICATE")) == OK)
    node_added.connect(_configure_request)
    _run.call_deferred()

func _configure_request(node: Node) -> void:
    if node is HTTPRequest:
        node.set_https_proxy("127.0.0.1", int(OS.get_environment("PRIVATE_HTTPS_PORT")))
        node.set_tls_options(TLSOptions.client(certificate))

func _fetch(url: String) -> Dictionary:
    var request := HTTPRequest.new()
    request.timeout = 5.0
    request.max_redirects = 0
    request.body_size_limit = 1024 * 1024
    root.add_child(request)
    var headers := PackedStringArray([
        "Authorization: Bearer " + OS.get_environment("GODOT_AI_QUALIFICATION_TOKEN")])
    assert(request.request(url, headers) == OK)
    var completed: Array = await request.request_completed
    request.queue_free()
    var body: PackedByteArray = completed[3]
    var digest := HashingContext.new()
    digest.start(HashingContext.HASH_SHA256)
    digest.update(body)
    return {"result": completed[0], "status": completed[1],
        "sha256": digest.finish().hex_encode(), "body": body.get_string_from_utf8()}

func _run() -> void:
    var metadata: Dictionary = await _fetch(
        OS.get_environment("GODOT_AI_QUALIFICATION_RELEASE_URL"))
    var report := {"metadata": metadata.duplicate()}
    report.metadata.erase("body")
    if metadata.result == HTTPRequest.RESULT_SUCCESS and metadata.status == 200:
        var release: Dictionary = JSON.parse_string(metadata.body)
        assert(release.tag_name == "v4.0.1")
        for asset in release.assets:
            if asset.name == "godot-ai-v4-plugin.zip":
                var fetched: Dictionary = await _fetch(asset.browser_download_url)
                fetched.erase("body")
                report["asset"] = fetched
    var output := FileAccess.open("res://result.json", FileAccess.WRITE)
    assert(output != null)
    output.store_string(JSON.stringify(report))
    output.close()
    quit(0)
"""

MANAGER_DRIVER = """extends SceneTree

const Manager := preload("res://addons/godot_ai/utils/update_manager.gd")
var manager: Node
var certificate := X509Certificate.new()
var report := {"candidate": false, "requests": 0, "package": {}, "hashes": {}}

func _initialize() -> void:
    assert(certificate.load(OS.get_environment("PRIVATE_HTTPS_CERTIFICATE")) == OK)
    manager = Manager.new()
    node_added.connect(_configure_request)
    root.add_child(manager)
    manager.activation_requested.connect(_prepared)
    _run.call_deferred()

func _configure_request(node: Node) -> void:
    # Scope transport injection to this actual manager's requests only.
    if node is HTTPRequest and node.get_parent() == manager:
        report.requests += 1
        node.set_https_proxy("127.0.0.1", int(OS.get_environment("PRIVATE_HTTPS_PORT")))
        node.set_tls_options(TLSOptions.client(certificate))

func _prepared(package: Dictionary) -> void:
    # Observe the real handoff boundary; do not activate or bypass verification.
    report.package = package.duplicate()
    for key in ["archive", "manifest", "signature"]:
        report.hashes[key] = FileAccess.get_sha256(package[key])

func _run() -> void:
    manager.check_for_updates()
    while manager._check_request != null:
        await process_frame
    report.candidate = manager.has_install_candidate()
    if report.candidate:
        manager.start_install({
            "ok": true, "download_root": OS.get_environment("PRIVATE_DOWNLOAD_ROOT")})
        while report.package.is_empty() and manager.is_install_in_flight():
            await process_frame
    manager.cancel_install()
    assert(not manager.is_install_in_flight())
    manager.queue_free()
    await process_frame
    var output := FileAccess.open("res://result.json", FileAccess.WRITE)
    assert(output != null)
    output.store_string(JSON.stringify(report))
    output.close()
    quit(0)
"""


@pytest.mark.parametrize(
    "mode", ["authorized", "wrong-token", "wrong-certificate", "wrong-hostname"]
)
def test_real_godot_uses_verified_default_port_https_without_system_changes(tmp_path, mode):
    godot = godot_bin_or_skip()
    tls_options = {"host": "wrong.qualification.invalid"} if mode == "wrong-hostname" else {}
    certificate, key = make_tls_material(tmp_path / "tls", **tls_options)
    assets = tmp_path / "assets"
    assets.mkdir()
    for name in support.RELEASE_NAMES:
        (assets / name).write_bytes(b"x" * 512 if name.endswith(".sig") else name.encode())
    inventory = support.inventory(assets)
    project = tmp_path / "native-http-project"
    project.mkdir()
    (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    driver = project / "driver.gd"
    driver.write_text(DRIVER, encoding="utf-8")
    trusted = certificate
    if mode == "wrong-certificate":
        trusted, _ = make_tls_material(tmp_path / "wrong-tls")
    with private_release_origin(
        assets, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        environment = {
            **os.environ,
            **endpoint.environment(),
            "GODOT_AI_DISABLE_TELEMETRY": "true",
            "PRIVATE_HTTPS_PORT": str(endpoint.proxy_port),
            "PRIVATE_HTTPS_CERTIFICATE": str(trusted),
        }
        if mode == "wrong-token":
            environment["GODOT_AI_QUALIFICATION_TOKEN"] = "wrong"
        completed = subprocess.run(
            [godot, "--headless", "--path", str(project), "--script", str(driver)],
            env=environment,
            capture_output=True,
            timeout=30,
        )
        assert completed.returncode == 0, completed.stdout + completed.stderr
        assert endpoint.token.encode() not in completed.stdout + completed.stderr
        report = json.loads((project / "result.json").read_text(encoding="utf-8"))
        assert endpoint.token not in json.dumps(report)
        if mode == "authorized":
            assert report["metadata"]["result"] == 0
            assert report["metadata"]["status"] == 200
            assert report["asset"] == {
                "result": 0,
                "status": 200,
                "sha256": hashlib.sha256(b"godot-ai-v4-plugin.zip").hexdigest(),
            }
            assert endpoint.downloads == ["godot-ai-v4-plugin.zip"]
        elif mode == "wrong-token":
            assert report["metadata"]["result"] == 0
            assert report["metadata"]["status"] == 401
            assert "asset" not in report and endpoint.downloads == []
        else:
            assert report["metadata"]["result"] == 5  # RESULT_TLS_HANDSHAKE_ERROR
            assert report["metadata"]["status"] == 0
            assert "asset" not in report and endpoint.downloads == []


@pytest.mark.parametrize("authorized", [True, False])
def test_unchanged_update_manager_discovers_and_downloads_over_private_https(tmp_path, authorized):
    """Development fixture: the real manager alone, with no signature approval or A/B claim."""
    godot = godot_bin_or_skip()
    major, minor, patch = support.version_tuple(read_plugin_version(PLUGIN_ROOT / "plugin.cfg"))
    version = f"{major}.{minor}.{patch + 1}"
    certificate, key = make_tls_material(tmp_path / "tls")
    assets = tmp_path / "assets"
    assets.mkdir()
    for name in support.RELEASE_NAMES:
        (assets / name).write_bytes(b"x" * 512 if name.endswith(".sig") else name.encode())
    (assets / "godot-ai-v4-plugin.manifest.json").write_bytes(
        support.canonical({"source_commit": "a" * 40})
    )
    inventory = support.inventory(assets)
    project = tmp_path / "real-manager-project"
    addon = project / "addons" / "godot_ai"
    shutil.copytree(PLUGIN_ROOT, addon, ignore=load_smoke_script().copy_ignore)
    code = {
        path.relative_to(PLUGIN_ROOT): path.read_bytes()
        for path in PLUGIN_ROOT.rglob("*")
        if path.is_file() and path.suffix in {".gd", ".cfg"}
    }
    (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    driver = project / "driver.gd"
    driver.write_text(MANAGER_DRIVER, encoding="utf-8")
    downloads = tmp_path / "private-downloads"
    downloads.mkdir()
    with private_release_origin(
        assets, inventory, version=version, certificate=certificate, private_key=key
    ) as endpoint:
        environment = {
            **os.environ,
            **endpoint.environment(),
            "GODOT_AI_MODE": "user",
            "GODOT_AI_DISABLE_TELEMETRY": "true",
            "PRIVATE_HTTPS_PORT": str(endpoint.proxy_port),
            "PRIVATE_HTTPS_CERTIFICATE": str(certificate),
            "PRIVATE_DOWNLOAD_ROOT": str(downloads),
        }
        if not authorized:
            environment["GODOT_AI_QUALIFICATION_TOKEN"] = "0" * 64
        imported = subprocess.run(
            [godot, "--headless", "--editor", "--path", str(project), "--import"],
            env=environment,
            capture_output=True,
            timeout=60,
        )
        assert imported.returncode == 0, imported.stdout + imported.stderr
        completed = subprocess.run(
            [godot, "--headless", "--path", str(project), "--script", str(driver)],
            env=environment,
            capture_output=True,
            timeout=30,
        )
        output = imported.stdout + imported.stderr + completed.stdout + completed.stderr
        assert completed.returncode == 0, output
        assert b"SCRIPT ERROR" not in output and b"ERROR:" not in output, output
        assert endpoint.token.encode() not in output
        report = json.loads((project / "result.json").read_text(encoding="utf-8"))
        assert endpoint.token not in json.dumps(report)
        assert report["candidate"] is authorized
        if authorized:
            expected_paths = {
                "archive": "godot-ai-v4-plugin.zip",
                "manifest": "godot-ai-v4-plugin.manifest.json",
                "signature": "godot-ai-v4-plugin.manifest.sig",
            }
            assert report["requests"] == 4
            assert endpoint.downloads == list(expected_paths.values())
            assert report["hashes"] == {
                field: inventory[name]["sha256"] for field, name in expected_paths.items()
            }
            package = report["package"].copy()
            for field, name in expected_paths.items():
                assert Path(package.pop(field)) == downloads / name
            assert Path(package.pop("download_root")) == downloads
            assert package == {
                "repository": "hi-godot/godot-ai",
                "channel": "stable",
                "tag": f"v{version}",
                "version": version,
                "source": "a" * 40,
            }
            assert not downloads.exists()
        else:
            assert report["requests"] == 1 and endpoint.downloads == []
            assert report["package"] == {} and report["hashes"] == {}
            assert downloads.is_dir() and list(downloads.iterdir()) == []
    assert all((addon / path).read_bytes() == contents for path, contents in code.items())
