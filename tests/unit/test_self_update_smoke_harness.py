"""Tests for the local interactive self-update smoke harness."""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import ModuleType
from typing import Any

import pytest

from godot_ai.transport.capability import CAPABILITY_DIR_ENV, write_capabilities
from tests.conftest import isolate_capability_directory

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script" / "local-self-update-smoke"
HTTP_CAPABILITY = "self-update-http-capability-0123456789abcdef"
WS_CAPABILITY = "0123456789abcdef" * 4
INSTANCE_NONCE = "1234567890abcdef1234567890abcdef"


def load_smoke_script() -> ModuleType:
    loader = SourceFileLoader("local_self_update_smoke", str(SCRIPT))
    module = ModuleType(loader.name)
    module.__file__ = str(SCRIPT)
    loader.exec_module(module)
    return module


def _static_func_block(text: str, signature: str) -> str:
    """Return one top-level GDScript function, stopping at the next top-level func."""
    start = text.index(signature)
    end = re.compile(r"^(?:static )?func ", re.MULTILINE).search(text, start + len(signature))
    return text[start : end.start() if end else len(text)]


def test_self_update_smoke_harness_prepares_fixture(tmp_path: Path) -> None:
    smoke = load_smoke_script()
    project = tmp_path / "self-update-smoke"

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--no-launch",
            "--project-dir",
            str(project),
            "--base-version",
            "4.0.0",
            "--next-version",
            "4.0.1",
        ],
        cwd=ROOT,
        check=True,
        text=True,
        capture_output=True,
    )

    assert "Self-update smoke fixture ready" in result.stdout
    assert "click Update" in result.stdout
    assert "a new Godot*.ips" in result.stdout
    assert "/godot-ai/status" in result.stdout
    assert "--log-file" in result.stdout
    assert ".godot-ai-self-update-smoke" in result.stdout
    assert "godot-editor.log" in result.stdout

    base_cfg = (project / "addons" / "godot_ai" / "plugin.cfg").read_text(encoding="utf-8")
    assert 'version="4.0.0"' in base_cfg
    base_plugin = (project / "addons" / "godot_ai" / "plugin.gd").read_text(encoding="utf-8")
    assert '"expected_version": "4.0.0"' in base_plugin

    # The smoke patches land on the manager file; the dock keeps only
    # the visible banner UI.
    base_manager = (project / "addons" / "godot_ai" / "utils" / "update_manager.gd").read_text(
        encoding="utf-8"
    )
    assert (
        'const SELF_UPDATE_SMOKE_ARCHIVE := "res://self_update_smoke/godot-ai-v4-plugin.zip"'
        in base_manager
    )
    assert (
        "const SELF_UPDATE_SMOKE_MANIFEST := "
        '"res://self_update_smoke/godot-ai-v4-plugin.manifest.json"' in base_manager
    )
    assert (
        "const SELF_UPDATE_SMOKE_SIGNATURE := "
        '"res://self_update_smoke/godot-ai-v4-plugin.manifest.sig"' in base_manager
    )
    assert "activation_requested.emit" in base_manager
    assert 'preflight.get("download_root", "")' in base_manager
    assert "_download_root = directory" in base_manager
    assert '"download_root": directory' in base_manager
    production_manager = (ROOT / "plugin/addons/godot_ai/utils/update_manager.gd").read_text(
        encoding="utf-8"
    )

    def function_block(source: str, signature: str) -> str:
        return source[source.index(signature) :].split("\n\nfunc ", 1)[0]

    for signature in (
        "func start_install(preflight: Dictionary) -> void:",
        "func _on_check_completed(",
        "func _on_asset_completed(",
        "func _finish_downloads() -> void:",
    ):
        assert function_block(base_manager, signature) == function_block(
            production_manager, signature
        )
    assert "for name in _RELEASE_ASSET_LIMITS:" in base_manager
    assert "_on_check_completed(HTTPRequest.RESULT_SUCCESS" in base_manager
    assert "_smoke_downloads != [ASSET_NAME, MANIFEST_NAME, SIGNATURE_NAME]" in base_manager

    base_configurator = (project / "addons" / "godot_ai" / "client_configurator.gd").read_text(
        encoding="utf-8"
    )
    assert "const DEFAULT_HTTP_PORT := 18000" in base_configurator
    assert "const DEFAULT_WS_PORT := 19500" in base_configurator
    assert ".godot-ai-self-update-smoke" in base_configurator
    assert "server-selector.py" in base_configurator
    assert '"-I"' in base_configurator
    assert "godot-ai==" not in _static_func_block(
        base_configurator, "static func get_server_command() -> Array[String]:"
    )
    assert "return default_port" in base_configurator
    assert "static func ensure_settings_registered() -> void:" in base_configurator
    assert "static func _register_port_setting(" in base_configurator
    assert 'return PackedStringArray(["codex"])' in base_configurator
    assert '"reason": "frozen self-update fixture runtime"' in base_configurator
    launch_block = base_configurator[
        base_configurator.index("static func resolve_attach_launch(") : base_configurator.index(
            "static func _resolve_attach_launch_uncached("
        )
    ]
    assert '"tier": "self_update_smoke"' in launch_block
    assert "find_uvx" not in launch_block
    prewarm_block = base_configurator[
        base_configurator.index(
            "static func prewarm_server_package_blocking("
        ) : base_configurator.index("static func prewarm_attach_plan(")
    ]
    assert "find_uvx" not in prewarm_block
    assert "McpCliExec.run" not in prewarm_block
    marker = project / ".godot-ai-self-update-smoke"
    assert not (marker / "smoke-release-key.pem").exists()
    for name, version in (("server-a", "4.0.0"), ("server-b", "4.0.1")):
        launcher = marker / name / "godot-ai-server.py"
        assert launcher.is_file()
        assert (marker / name / "src/godot_ai/server.py").is_file()
        reported = subprocess.run(
            [str(smoke.smoke_python()), "-I", str(launcher), "--version"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        assert reported == f"godot-ai {version}"
    selector = marker / "server-selector.py"
    assert selector.is_file()
    selector_text = selector.read_text(encoding="utf-8")
    assert "runpy.run_path(command[2]" in selector_text
    assert "refused unknown or ambiguous plugin version" in selector_text
    assert "refused invalid frozen server command" in selector_text
    assert "shell" not in selector_text
    selected = subprocess.run(
        [str(smoke.smoke_python()), "-I", str(selector), "--version"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    assert selected == "godot-ai 4.0.0"

    fixture_paths = smoke.fixture_environment_paths(project)
    client_config = fixture_paths["codex_home"] / "config.toml"
    config_text = client_config.read_text(encoding="utf-8")
    assert f"command = {json.dumps(str(fixture_paths['client_command']))}" in config_text
    assert "godot-ai==4.0.0" in config_text
    assert "godot-ai==4.0.1" not in config_text
    if os.name != "nt":
        assert fixture_paths["client_command"].stat().st_mode & 0o111 == 0
        assert client_config.stat().st_mode & 0o077 == 0

    base_settings = (project / "addons" / "godot_ai" / "utils" / "settings.gd").read_text(
        encoding="utf-8"
    )
    assert "godot_ai_self_update_smoke/excluded_domains" in base_settings

    zip_path = project / "self_update_smoke" / "godot-ai-v4-plugin.zip"
    assert zip_path.exists()
    assert (zip_path.parent / "godot-ai-v4-plugin.manifest.json").is_file()
    assert (zip_path.parent / "godot-ai-v4-plugin.manifest.sig").stat().st_size == 512
    with zipfile.ZipFile(zip_path) as zf:
        names = set(zf.namelist())
        assert "addons/godot_ai/plugin.cfg" in names
        assert "addons/godot_ai/mcp_dock.gd" in names
        assert "addons/godot_ai/utils/update_manager.gd" in names
        assert "addons/godot_ai/utils/self_update_smoke_base.gd" in names
        assert "addons/godot_ai/utils/self_update_smoke_base.gd.uid" in names
        assert "addons/godot_ai/utils/self_update_smoke_child.gd" in names
        assert "addons/godot_ai/utils/self_update_smoke_child.gd.uid" in names
        vnext_cfg = zf.read("addons/godot_ai/plugin.cfg").decode()
        vnext_plugin = zf.read("addons/godot_ai/plugin.gd").decode()
        vnext_dock = zf.read("addons/godot_ai/mcp_dock.gd").decode()
        vnext_manager = zf.read("addons/godot_ai/utils/update_manager.gd").decode()
        vnext_configurator = (
            zf.read("addons/godot_ai/client_configurator.gd").decode().replace("\r\n", "\n")
        )
        vnext_settings = zf.read("addons/godot_ai/utils/settings.gd").decode()
        vnext_base = zf.read("addons/godot_ai/utils/self_update_smoke_base.gd").decode()
        vnext_child = zf.read("addons/godot_ai/utils/self_update_smoke_child.gd").decode()
        vnext_base_uid = zf.read("addons/godot_ai/utils/self_update_smoke_base.gd.uid").decode()
        vnext_child_uid = zf.read("addons/godot_ai/utils/self_update_smoke_child.gd.uid").decode()

    assert 'version="4.0.1"' in vnext_cfg
    assert '"expected_version": "4.0.1"' in vnext_plugin
    # The smoke download URL is no longer in the dock (it lives on the
    # manager); the dock should not contain it either.
    assert "smoke://local-prestaged" not in vnext_dock
    assert "smoke://local-prestaged" not in vnext_manager
    assert "activation_requested.emit" in vnext_manager
    assert 'var _self_update_smoke_trigger: Dictionary = {"armed": true}' in vnext_dock
    assert 'var _self_update_smoke_array_trigger: Array[String] = ["armed"]' in vnext_dock
    assert "MCP | [self-update-smoke vnext _exit_tree]" in vnext_dock
    assert "SelfUpdateSmokeChild" in vnext_dock
    assert "class_name McpSelfUpdateSmokeBase" in vnext_base
    assert "class_name McpSelfUpdateSmokeChild" in vnext_child
    assert "extends McpSelfUpdateSmokeBase" in vnext_child
    assert vnext_base_uid.strip() == "uid://m5waxbfff4ud"
    assert vnext_child_uid.strip() == "uid://bm2056w0qvj7x"
    assert "const DEFAULT_HTTP_PORT := 18000" in vnext_configurator
    assert "server-selector.py" in vnext_configurator

    server_signature = "static func get_server_command() -> Array[String]:"
    assert _static_func_block(base_configurator, server_signature) == _static_func_block(
        vnext_configurator, server_signature
    )
    assert "return default_port" in vnext_configurator
    assert "static func ensure_settings_registered() -> void:" in vnext_configurator
    assert "static func _register_port_setting(" in vnext_configurator
    assert 'return PackedStringArray(["codex"])' in vnext_configurator
    assert '"reason": "frozen self-update fixture runtime"' in vnext_configurator
    vnext_launch = vnext_configurator[
        vnext_configurator.index("static func resolve_attach_launch(") : vnext_configurator.index(
            "static func _resolve_attach_launch_uncached("
        )
    ]
    assert '"tier": "self_update_smoke"' in vnext_launch
    assert "find_uvx" not in vnext_launch
    assert "godot_ai_self_update_smoke/excluded_domains" in vnext_settings


def test_replace_function_keeps_top_level_functions_separate() -> None:
    smoke = load_smoke_script()
    source = "static func first() -> Array:\n\treturn []\nstatic func second() -> void:\n\tpass\n"

    patched = smoke.replace_function(
        source,
        "static func first() -> Array:",
        "static func first() -> Array:\n\treturn [1]",
    )

    assert "return [1]\n\nstatic func second()" in patched


def test_cli_preparation_never_uses_parent_client_or_capability_paths(tmp_path: Path) -> None:
    smoke = load_smoke_script()
    project = tmp_path / "self-update-smoke"
    parent_home = tmp_path / "parent-home"
    parent_codex = tmp_path / "parent-codex"
    parent_capabilities = tmp_path / "parent-capabilities"
    parent_codex.mkdir()
    parent_config = parent_codex / "config.toml"
    original = '[mcp_servers."godot-ai"]\ncommand = "user-owned"\n'
    parent_config.write_text(original, encoding="utf-8")
    environment = os.environ.copy()
    environment.update(
        {
            "HOME": str(parent_home),
            "USERPROFILE": str(parent_home),
            "CODEX_HOME": str(parent_codex),
            CAPABILITY_DIR_ENV: str(parent_capabilities),
        }
    )

    subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--no-launch",
            "--project-dir",
            str(project),
            "--base-version",
            "4.0.0",
            "--next-version",
            "4.0.1",
        ],
        cwd=ROOT,
        env=environment,
        check=True,
        text=True,
        capture_output=True,
    )

    assert parent_config.read_text(encoding="utf-8") == original
    assert not parent_capabilities.exists()
    fixture = smoke.fixture_environment_paths(project)
    assert (fixture["codex_home"] / "config.toml").is_file()
    assert fixture["capability_dir"].is_dir()


def test_launch_passes_isolation_only_to_godot_child(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    smoke = load_smoke_script()
    project = tmp_path / "self-update-smoke"
    godot = tmp_path / "Godot"
    godot.write_text("not executed\n", encoding="utf-8")
    parent_home = tmp_path / "parent-home"
    parent_codex = tmp_path / "parent-codex"
    parent_capabilities = tmp_path / "parent-capabilities"
    monkeypatch.setenv("HOME", str(parent_home))
    monkeypatch.setenv("USERPROFILE", str(parent_home))
    monkeypatch.setenv("CODEX_HOME", str(parent_codex))
    monkeypatch.setenv(CAPABILITY_DIR_ENV, str(parent_capabilities))
    fixture = smoke.fixture_environment_paths(project)
    captured: dict[str, Any] = {}

    class FakeGodot:
        stdout = iter(
            [
                f"{smoke.SMOKE_STAGED_LOG}\n",
                "MCP | stopped server (PID [123])\n",
                "MCP | update to 4.0.1 swapped in; restarting the editor\n",
            ]
        )

        @staticmethod
        def wait() -> int:
            return 0

    def fake_popen(command: list[str], **kwargs: Any) -> FakeGodot:
        captured["command"] = command
        captured["environment"] = kwargs["env"]
        return FakeGodot()

    def fake_wait(
        http_port: int,
        expected_version: str,
        *,
        capability_dir: Path | None = None,
        **_kwargs: Any,
    ) -> dict[str, str]:
        captured["status"] = (http_port, expected_version, capability_dir)
        return {"name": "godot-ai", "server_version": expected_version}

    monkeypatch.setattr(smoke.subprocess, "Popen", fake_popen)
    monkeypatch.setattr(smoke, "wait_for_live_status", fake_wait)
    monkeypatch.setattr(
        smoke,
        "wait_for_restarted_editor",
        lambda *_args, **_kwargs: [smoke.SMOKE_MIGRATED_LOG, "MCP | plugin loaded"],
    )
    monkeypatch.setattr(smoke, "verify_post_run", lambda *_args, **_kwargs: True)

    assert (
        smoke.launch_and_verify(
            project,
            str(godot),
            "4.0.1",
            set(),
            http_port=18000,
            next_server_version="4.0.1",
        )
        == 0
    )

    assert os.environ["HOME"] == str(parent_home)
    assert os.environ["CODEX_HOME"] == str(parent_codex)
    assert os.environ[CAPABILITY_DIR_ENV] == str(parent_capabilities)
    child = captured["environment"]
    assert child["HOME"] == str(fixture["home"])
    assert child["USERPROFILE"] == str(fixture["home"])
    assert child["CODEX_HOME"] == str(fixture["codex_home"])
    assert child["GODOT_AI_DISABLE_TELEMETRY"] == "true"
    if os.name == "nt":
        assert CAPABILITY_DIR_ENV not in child
        assert child["LOCALAPPDATA"] == str(fixture["local_app_data"])
    else:
        assert child[CAPABILITY_DIR_ENV] == str(fixture["capability_dir"])
    assert captured["status"] == (18000, "4.0.1", fixture["capability_dir"])


def test_server_selector_refuses_unknown_or_ambiguous_installed_version(
    tmp_path: Path,
) -> None:
    smoke = load_smoke_script()
    marker = tmp_path / "marker"
    marker.mkdir()
    plugin_cfg = tmp_path / "plugin.cfg"
    commands = {
        "4.0.0": [str(smoke.smoke_python()), "-I", str(tmp_path / "a.py")],
        "4.0.1": [str(smoke.smoke_python()), "-I", str(tmp_path / "b.py")],
    }
    command = smoke.prepare_server_selector(marker, plugin_cfg, commands)

    for contents in (
        '[plugin]\nversion="9.9.9"\n',
        '[plugin]\nversion="4.0.0"\nversion="4.0.1"\n',
        '[plugin]\nversion = "4.0.0"\n',
    ):
        plugin_cfg.write_text(contents, encoding="utf-8")
        refused = subprocess.run(command, text=True, capture_output=True)
        assert refused.returncode != 0
        assert "refused unknown or ambiguous plugin version" in refused.stderr


def test_lean_update_state_requires_success_marker_backup_and_clean_state(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    smoke = load_smoke_script()
    project = tmp_path / "project"
    live = project / "addons" / "godot_ai"
    live.mkdir(parents=True)
    (live / "plugin.cfg").write_text('version="4.0.1"\n', encoding="utf-8")
    state = project / "addons" / ".godot_ai_update"
    backup = state / "backup" / "4.0.0"
    backup.mkdir(parents=True)
    marker_path = state / "pending.json"
    marker = {
        "status": "success",
        "from_version": "4.0.0",
        "to_version": "4.0.1",
        "expected_tree_sha256": "tree-live",
        "backup_root": "res://addons/.godot_ai_update/backup/4.0.0",
        "clients_migrated": True,
    }
    monkeypatch.setattr(
        smoke.release_verify,
        "hash_tree",
        lambda root: {
            "files": {},
            "tree_sha256": "tree-live" if root == live.resolve() else "tree-other",
        },
        raising=False,
    )

    def write(**changes: object) -> None:
        marker_path.write_text(json.dumps({**marker, **changes}), encoding="utf-8")

    with pytest.raises(smoke.HarnessError, match="marker is missing"):
        smoke.verify_lean_update_state(project, "4.0.1")
    write()
    assert smoke.verify_lean_update_state(project, "4.0.1") == (marker, backup.resolve())

    write(status="rolled_back")
    with pytest.raises(smoke.HarnessError, match="does not record success"):
        smoke.verify_lean_update_state(project, "4.0.1")
    write(clients_migrated=False)
    with pytest.raises(smoke.HarnessError, match="does not record client migration"):
        smoke.verify_lean_update_state(project, "4.0.1")
    write(to_version="4.0.2")
    with pytest.raises(smoke.HarnessError, match="ends at"):
        smoke.verify_lean_update_state(project, "4.0.1")
    write(expected_tree_sha256="tree-other")
    with pytest.raises(smoke.HarnessError, match="differs from the hash"):
        smoke.verify_lean_update_state(project, "4.0.1")
    write()
    (state / "lock.json").write_text("{}", encoding="utf-8")
    with pytest.raises(smoke.HarnessError, match="left lock.json behind"):
        smoke.verify_lean_update_state(project, "4.0.1")
    (state / "lock.json").unlink()
    shutil.rmtree(backup)
    with pytest.raises(smoke.HarnessError, match="retained backup"):
        smoke.verify_lean_update_state(project, "4.0.1")


def test_v3_floor_refusal_verifier_requires_restored_final_v3_and_clean_tree(
    tmp_path: Path,
) -> None:
    smoke = load_smoke_script()
    project = tmp_path / "project"
    live = project / "addons" / "godot_ai"
    live.mkdir(parents=True)
    final_v3 = smoke.release_tag_to_version(smoke.FINAL_V3_REF)
    (live / "plugin.cfg").write_text(f'[plugin]\nversion="{final_v3}"\n', encoding="utf-8")
    (project / "project.godot").write_text(
        '[editor_plugins]\n\nenabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")\n',
        encoding="utf-8",
    )
    lines = [
        smoke.V3_CLICK_LOG,
        "MCP | self-update release signature verified",
        "MCP | update runner disabling old plugin",
        smoke.V3_FLOOR_REFUSAL_LOG + "; bridge remains inactive.",
        f"{smoke.V3_RESTORED_LOG}{final_v3}; update again on Godot 4.7 or newer",
        "MCP | plugin loaded",
    ]
    # A far-future start keeps unrelated crash reports on this machine out of the check.
    started = time.time() + 3600

    def verify(log: list[str]) -> bool:
        return smoke.verify_v3_floor_refusal(project, "3.2.4", set(), started, log)

    assert verify(lines)
    assert not verify(lines[:-2]), "restore and reload must be logged"
    assert not verify([lines[0], *lines[2:], lines[1]]), "order matters"
    assert not verify([*lines, smoke.V3_BRIDGE_RESTART_LOG]), "the bridge must stop at the refusal"
    assert not verify([*lines, "SCRIPT ERROR: bad"])
    assert not smoke._restored_final_v3_loaded(lines[:-1])
    assert smoke._restored_final_v3_loaded(lines)

    (live / "migration_payload").mkdir()
    assert not verify(lines), "capsule-only entries must be gone"
    (live / "migration_payload").rmdir()
    stage = project / "addons" / ".godot_ai_update" / "stage"
    stage.mkdir(parents=True)
    assert not verify(lines), "no v4 update state may remain"
    shutil.rmtree(stage.parent)
    (project / "project.godot").write_text("[editor_plugins]\n", encoding="utf-8")
    assert not verify(lines), "the restored plugin must stay enabled"
    (project / "project.godot").write_text(
        'enabled=PackedStringArray("res://addons/godot_ai/plugin.cfg")\n', encoding="utf-8"
    )
    (live / "plugin.cfg").write_text('[plugin]\nversion="4.0.0"\n', encoding="utf-8")
    assert not verify(lines), "the live tree must be final v3"


def test_self_update_smoke_log_verifier_rejects_external_adoption() -> None:
    smoke = load_smoke_script()
    lines = [
        "MCP | foreign server already running on port 18000, using existing",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | stopped server (PID [123])",
        "MCP | update to 4.0.1 swapped in; restarting the editor",
    ]

    assert smoke.smoke_adopted_existing_server_before_update(lines)
    assert not smoke.smoke_started_own_server_before_update(lines)
    assert smoke.smoke_stopped_server_during_update(lines)


def test_self_update_smoke_log_verifier_requires_managed_stop_after_staging() -> None:
    smoke = load_smoke_script()
    lines = [
        "MCP | started server (PID 123, v2.2.1): godot-ai",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | update to 4.0.1 swapped in; restarting the editor",
    ]

    assert smoke.smoke_started_own_server_before_update(lines)
    assert not smoke.smoke_adopted_existing_server_before_update(lines)
    assert not smoke.smoke_stopped_server_during_update(lines)


def test_self_update_smoke_log_verifier_rejects_version_mismatch() -> None:
    smoke = load_smoke_script()
    lines = [
        "MCP | started server (PID 123, v2.2.0): godot-ai",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | stopped server (PID [123])",
        "MCP | update to 4.0.1 swapped in; restarting the editor",
        "MCP | plugin loaded",
        (
            "MCP | Port 18000 is occupied by godot-ai server v2.2.0; "
            "plugin expects v2.2.1. Stop the old server or change both HTTP and WS ports."
        ),
    ]

    assert smoke.smoke_reported_server_version_mismatch(lines)


def test_self_update_smoke_log_verifier_accepts_matching_versions() -> None:
    smoke = load_smoke_script()
    lines = [
        "MCP | started server (PID 123, v2.2.0): godot-ai",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | stopped server (PID [123])",
        "MCP | update to 4.0.1 swapped in; restarting the editor",
        "MCP | started server (PID 456, v2.2.0): godot-ai",
        "MCP | plugin loaded",
    ]

    assert not smoke.smoke_reported_server_version_mismatch(lines)


def test_self_update_smoke_harness_refuses_unmarked_existing_dir(tmp_path: Path) -> None:
    project = tmp_path / "existing-project"
    project.mkdir()
    (project / "project.godot").write_text("not generated by the harness\n")

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--no-launch",
            "--project-dir",
            str(project),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "not marked as a smoke fixture" in result.stderr


def _make_addon_with(tmp_path: Path, *, present: tuple[str, ...]) -> Path:
    addon = tmp_path / "addon"
    (addon / "utils").mkdir(parents=True)
    for rel in present:
        (addon / rel).write_text("# fixture stub\n", encoding="utf-8")
    return addon


def test_v4_shape_passes_when_both_files_present(tmp_path: Path) -> None:
    smoke = load_smoke_script()
    addon = _make_addon_with(
        tmp_path,
        present=("utils/server_lifecycle.gd", "utils/update_manager.gd"),
    )
    # Validator returns None on success and raises HarnessError otherwise; the
    # assertion both documents intent and trips the runner's zero-assertion guard.
    assert smoke._require_v4_addon_shape(addon, "4.0.0") is None


@pytest.mark.parametrize(
    ("present", "expected_missing"),
    [
        (("utils/update_manager.gd",), "utils/server_lifecycle.gd"),
        (("utils/server_lifecycle.gd",), "utils/update_manager.gd"),
    ],
)
def test_v4_shape_refuses_single_missing_file(
    tmp_path: Path, present: tuple[str, ...], expected_missing: str
) -> None:
    smoke = load_smoke_script()
    addon = _make_addon_with(tmp_path, present=present)
    with pytest.raises(smoke.HarnessError) as exc_info:
        smoke._require_v4_addon_shape(addon, "3.2.4")
    message = str(exc_info.value)
    assert expected_missing in message, message
    assert "3.2.4" in message, message
    assert "clean migration" in message, message


def test_v4_shape_lists_all_missing_files_when_both_absent(tmp_path: Path) -> None:
    smoke = load_smoke_script()
    addon = _make_addon_with(tmp_path, present=())
    with pytest.raises(smoke.HarnessError) as exc_info:
        smoke._require_v4_addon_shape(addon, "3.2.4")
    message = str(exc_info.value)
    assert "utils/server_lifecycle.gd" in message, message
    assert "utils/update_manager.gd" in message, message


def test_self_update_smoke_harness_refuses_suspicious_marker(tmp_path: Path) -> None:
    project = tmp_path / "existing-project"
    (project / ".godot-ai-self-update-smoke").mkdir(parents=True)
    (project / ".godot-ai-self-update-smoke" / "marker.txt").write_text("marker\n")
    (project / "project.godot").write_text("not generated by the harness\n")

    result = subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--no-launch",
            "--project-dir",
            str(project),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )

    assert result.returncode != 0
    assert "has a smoke marker but does not look generated" in result.stderr


def test_smoke_restart_requested_needs_the_swap_line() -> None:
    smoke = load_smoke_script()
    before_swap = [
        "MCP | started server (PID 123, v4.0.0): godot-ai",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | stopped server (PID [123])",
    ]
    assert not smoke.smoke_restart_requested(before_swap)
    swapped = before_swap + ["MCP | update to 4.0.1 swapped in; restarting the editor"]
    assert smoke.smoke_restart_requested(swapped)
    assert not smoke.vnext_exit_tree_during_update(swapped + [smoke.SMOKE_TRIGGER_LOG])
    assert smoke.vnext_exit_tree_during_update(before_swap + [smoke.SMOKE_TRIGGER_LOG])


def test_status_reports_live_version_requires_name_and_pin() -> None:
    smoke = load_smoke_script()
    assert not smoke.status_reports_live_version(None, "3.2.4")
    assert not smoke.status_reports_live_version(
        {"name": "other", "server_version": "3.2.4"}, "3.2.4"
    )
    assert not smoke.status_reports_live_version(
        {"name": "godot-ai", "server_version": "3.2.3"}, "3.2.4"
    )
    assert smoke.status_reports_live_version(
        {"name": "godot-ai", "server_version": "3.2.4"}, "3.2.4"
    )


class _StatusHandler(BaseHTTPRequestHandler):
    payload: dict[str, Any] = {
        "name": "godot-ai",
        "server_version": "3.2.4",
        "instance_id": INSTANCE_NONCE,
    }

    def do_GET(self) -> None:  # noqa: N802
        if self.path != "/godot-ai/status":
            self.send_error(404)
            return
        if self.headers.get("Authorization") != f"Bearer {HTTP_CAPABILITY}":
            self.send_error(401)
            return
        body = json.dumps(self.payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def test_fetch_and_wait_for_live_status(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    smoke = load_smoke_script()
    _StatusHandler.payload = {
        "name": "godot-ai",
        "server_version": "3.2.4",
        "instance_id": INSTANCE_NONCE,
    }
    server = HTTPServer(("127.0.0.1", 0), _StatusHandler)
    port = int(server.server_address[1])
    capability_dir = isolate_capability_directory(monkeypatch, tmp_path)
    write_capabilities(
        port,
        HTTP_CAPABILITY,
        WS_CAPABILITY,
        instance_nonce=INSTANCE_NONCE,
        directory=capability_dir,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        payload = smoke.fetch_status_payload(port, capability_dir=capability_dir)
        assert payload == _StatusHandler.payload
        live = smoke.wait_for_live_status(
            port, "3.2.4", capability_dir=capability_dir, timeout=2.0, poll=0.05
        )
        assert live == payload
        missing = smoke.wait_for_live_status(
            port, "9.9.9", capability_dir=capability_dir, timeout=0.2, poll=0.05
        )
        assert missing == payload
        assert not smoke.status_reports_live_version(missing, "9.9.9")
    finally:
        server.shutdown()
        server.server_close()


def test_fetch_status_payload_none_when_port_dark() -> None:
    smoke = load_smoke_script()
    assert smoke.fetch_status_payload(1, timeout=0.2) is None


class _TruncatedStatusHandler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:  # noqa: N802
        body = json.dumps(_StatusHandler.payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body) + 64))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, _format: str, *_args: object) -> None:
        return


def test_fetch_status_payload_none_on_truncated_body(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    smoke = load_smoke_script()
    server = HTTPServer(("127.0.0.1", 0), _TruncatedStatusHandler)
    port = int(server.server_address[1])
    capability_dir = isolate_capability_directory(monkeypatch, tmp_path)
    write_capabilities(
        port,
        HTTP_CAPABILITY,
        WS_CAPABILITY,
        instance_nonce=INSTANCE_NONCE,
        directory=capability_dir,
    )
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        assert smoke.fetch_status_payload(port, capability_dir=capability_dir, timeout=1.0) is None
    finally:
        server.shutdown()
        server.server_close()


def _minimal_smoke_project(tmp_path: Path, version: str) -> Path:
    project = tmp_path / "smoke"
    addon = project / "addons" / "godot_ai"
    addon.mkdir(parents=True)
    (addon / "plugin.cfg").write_text(f'version="{version}"\n', encoding="utf-8")
    return project


def test_verify_post_run_requires_live_status(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    smoke = load_smoke_script()
    project = _minimal_smoke_project(tmp_path, "4.0.1")
    monkeypatch.setattr(
        smoke,
        "verify_lean_update_state",
        lambda *_args: ({"from_version": "4.0.0", "to_version": "4.0.1"}, tmp_path / "backup"),
    )
    lines = [
        "MCP | started server (PID 123, v4.0.0): godot-ai",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | stopped server (PID [123])",
        "MCP | update to 4.0.1 swapped in; restarting the editor",
        "MCP | client migration completed",
        "MCP | plugin loaded",
    ]
    ok = smoke.verify_post_run(
        project,
        "4.0.1",
        set(),
        time.time(),
        lines,
        post_update_status=None,
        next_server_version="4.0.0",
    )
    captured = capsys.readouterr().out
    assert ok is False
    assert "post-update /godot-ai/status was not live" in captured


def test_verify_post_run_accepts_live_status(
    tmp_path: Path,
    capsys: pytest.CaptureFixture[str],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    smoke = load_smoke_script()
    project = _minimal_smoke_project(tmp_path, "4.0.1")
    monkeypatch.setattr(
        smoke,
        "verify_lean_update_state",
        lambda *_args: ({"from_version": "4.0.0", "to_version": "4.0.1"}, tmp_path / "backup"),
    )
    lines = [
        "MCP | started server (PID 123, v4.0.0): godot-ai",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | stopped server (PID [123])",
        "MCP | update to 4.0.1 swapped in; restarting the editor",
        "MCP | client migration completed",
        "MCP | plugin loaded",
    ]
    ok = smoke.verify_post_run(
        project,
        "4.0.1",
        set(),
        time.time(),
        lines,
        post_update_status={"name": "godot-ai", "server_version": "4.0.0"},
        next_server_version="4.0.0",
    )
    captured = capsys.readouterr().out
    assert ok is True
    assert "PASS: post-update /godot-ai/status live v4.0.0" in captured


def test_crash_report_filter_ignores_an_unrelated_godot_binary(tmp_path: Path) -> None:
    smoke = load_smoke_script()
    launched = tmp_path / "Godot-4.7"
    unrelated = tmp_path / "Godot-4.6"
    launched.touch()
    unrelated.touch()
    report = tmp_path / "Godot-test.ips"
    report.write_text(
        json.dumps({"app_name": "Godot"}) + "\n" + json.dumps({"procPath": str(unrelated)}),
        encoding="utf-8",
    )

    assert smoke._report_matches_executable(report, launched) is False
    assert smoke._report_matches_executable(report, unrelated) is True
