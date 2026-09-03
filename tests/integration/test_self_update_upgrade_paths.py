from __future__ import annotations

import asyncio
import hashlib
import json
import os
import shutil
import subprocess
import zipfile
from pathlib import Path

import pytest
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

from godot_ai.transport.capability import CAPABILITY_DIR_ENV, read_capabilities
from tests.conftest import allocate_free_ports
from tests.integration._self_update_fixture import (
    CLEAN_MAJOR_MARKER_RELATIVE,
    CLEAN_MAJOR_STATUS_FILE,
    CLEAN_MAJOR_TOOL_PROBE_FILE,
    COORDINATOR_DISABLE_MARKER,
    LIVE_HTTP_PORT,
    LIVE_WS_PORT,
    PLUGIN_ROOT,
    POST_UPDATE_STATUS_FILE,
    POST_UPDATE_TOOL_PROBE_FILE,
    append_driver_autoload,
    assert_no_update_parse_errors,
    clean_major_install_argv,
    godot_bin_or_skip,
    load_smoke_script,
    prepare_clean_major_migration_project,
    prepare_signed_update_project,
    read_plugin_version,
    remove_configure_client_driver,
    run_godot_editor,
    write_clean_major_driver,
    write_configure_client_driver,
    write_driver_support,
    write_install_update_driver,
)

PRODUCTION_UVX_RESOLUTION_ARGS = [
    "--isolated",
    "--no-config",
    "--no-env-file",
    "--no-sources",
    "--no-build",
    "--index-strategy",
    "first-index",
    "--keyring-provider",
    "disabled",
    "--index",
    "https://pypi.org/simple",
    "--default-index",
    "https://pypi.org/simple",
    "--find-links",
    "https://pypi.org/simple/godot-ai/",
]


def test_parse_error_window_uses_current_coordinator_boundary() -> None:
    clean = f"{COORDINATOR_DISABLE_MARKER}\nMCP | plugin loaded\n"
    assert_no_update_parse_errors(clean)
    with pytest.raises(AssertionError, match="Parse Error"):
        assert_no_update_parse_errors(
            f"{COORDINATOR_DISABLE_MARKER}\nSCRIPT ERROR: Parse Error\nMCP | plugin loaded\n"
        )


def test_install_update_driver_uses_canonical_root_handoff(tmp_path: Path) -> None:
    project = tmp_path / "driver-only"
    project.mkdir()
    write_install_update_driver(
        project,
        http_port=LIVE_HTTP_PORT,
        base_version="4.0.0",
        next_version="4.0.1",
    )
    text = (project / "_test_runner_driver.gd").read_text(encoding="utf-8")
    support = (project / "_test_self_update_driver_support.gd").read_text(encoding="utf-8")
    assert 'plugin.call("_on_dock_update_requested")' in text
    assert "plugin.install_downloaded_update" not in text
    assert "ZIP_PATH, TEMP_DIR, null" not in text
    assert f"const HTTP_PORT := {LIVE_HTTP_PORT}" in text
    assert "/godot-ai/status" in support
    assert "res://addons/godot_ai" not in support
    assert "SELF_UPDATE_TEST | requesting canonical signed install" in text
    assert "SELF_UPDATE_TEST | pre-update instance_id=" in text
    assert "ClientConfigurator" not in text
    assert "DriverSupport.client_config_has_pin(BASE_VERSION)" in text
    assert 'plugin.call("_on_dock_post_update_action_requested", "continue")' not in text
    assert "_observe_automatic_repin()" in text
    assert "authenticated read/write tool probe completed" in text
    assert "post_id == _pre_instance_id" in text
    assert "deadline = Time.get_ticks_msec() + 2000" in support


def test_clean_major_install_argv_matches_documented_closure_contract(tmp_path: Path) -> None:
    argv = clean_major_install_argv(
        Path("python3"),
        bundle=tmp_path / "release",
        project_root=tmp_path / "project",
        recovery_root=tmp_path / "recovery",
        target_version="4.0.0",
        source_commit="a" * 40,
    )

    assert argv[:3] == ["python3", "script/v4-release", "install"]
    assert argv[-2:] == ["--editors-closed", "--clients-and-backend-stopped"]
    assert argv[argv.index("--expected-tag") + 1] == "v4.0.0"
    assert argv[argv.index("--expected-version") + 1] == "4.0.0"
    assert argv[argv.index("--expected-source") + 1] == "a" * 40


def test_clean_major_driver_waits_for_automatic_marker_migration(tmp_path: Path) -> None:
    project = tmp_path / "clean-major-driver"
    project.mkdir()
    write_clean_major_driver(
        project,
        http_port=LIVE_HTTP_PORT,
        from_version="3.2.4",
        target_version="4.0.0",
    )
    text = (project / "_test_runner_driver.gd").read_text(encoding="utf-8")

    assert CLEAN_MAJOR_MARKER_RELATIVE.as_posix() in text
    assert "migration marker removed automatically" in text
    assert "repinned owned Codex command pin=" in text
    assert 'lifecycle.get("episode_state", "")) != "READY"' in text
    assert 'lifecycle.get("ready_kind", "")) != "owned"' in text
    assert 'plugin.call("_on_dock_post_update_action_requested", "continue")' not in text
    assert "authenticated read/write tool probe completed" in text


def test_client_configuration_prep_is_removed_before_signed_swap(tmp_path: Path) -> None:
    project = tmp_path / "client-prep"
    project.mkdir()
    (project / "project.godot").write_text(
        '[autoload]\n_SelfUpdateRunnerDriver="*res://_test_runner_driver.gd"\n',
        encoding="utf-8",
    )

    write_configure_client_driver(project, http_port=LIVE_HTTP_PORT, version="4.0.0")
    prep = (project / "_test_configure_client.gd").read_text(encoding="utf-8")
    assert "ClientConfigurator.configure" in prep
    assert "production-configured Codex command pin=" in prep
    assert "_SelfUpdateClientPrep" in (project / "project.godot").read_text(encoding="utf-8")

    remove_configure_client_driver(project)
    assert "_SelfUpdateClientPrep" not in (project / "project.godot").read_text(encoding="utf-8")
    assert not (project / "_test_configure_client.gd").exists()


def _install_clean_major_fixture(
    tmp_path: Path,
    target_version: str,
    http_port: int = LIVE_HTTP_PORT,
    ws_port: int = LIVE_WS_PORT,
) -> tuple[Path, Path, Path, Path]:
    from_version = "3.2.4"
    project = tmp_path / "clean-major-migration"
    recovery = tmp_path / "retained-clean-major-recovery"
    isolated = tmp_path / "clean-major-environment"
    isolated_home = isolated / "home"
    codex_home = isolated / "codex"
    isolated_home.mkdir(parents=True)
    argv, verifier_root = prepare_clean_major_migration_project(
        project,
        recovery_root=recovery,
        codex_home=codex_home,
        from_version=from_version,
        target_version=target_version,
        http_port=http_port,
        ws_port=ws_port,
    )
    write_clean_major_driver(
        project,
        http_port=http_port,
        from_version=from_version,
        target_version=target_version,
    )
    old_addon = project / "addons" / "godot_ai"
    old_tree = {
        path.relative_to(old_addon).as_posix(): path.read_bytes()
        for path in old_addon.rglob("*")
        if path.is_file()
    }
    prewarm_log = project / ".clean-major-smoke" / "prewarm.jsonl"
    install_environment = os.environ.copy()
    install_environment.update(
        {
            "CLEAN_MAJOR_INSTALL_CLAIM": str(project / "addons/.godot-ai-v4-installing"),
            "CLEAN_MAJOR_OLD_SENTINEL": str(old_addon / "old_only.gd"),
            "CLEAN_MAJOR_PREWARM_LOG": str(prewarm_log),
            "PATH": (
                str(project / ".clean-major-smoke" / "fake-bin")
                + os.pathsep
                + install_environment.get("PATH", "")
            ),
        }
    )
    installed = subprocess.run(
        argv,
        cwd=verifier_root,
        env=install_environment,
        check=True,
        text=True,
        capture_output=True,
        timeout=60,
    )
    assert installed.stdout.startswith("OK: installed exact v4 tree")
    assert "retained pre-v4 backup at" in installed.stdout
    assert argv[-2:] == ["--editors-closed", "--clients-and-backend-stopped"]
    prewarm_records = [
        json.loads(line) for line in prewarm_log.read_text(encoding="utf-8").splitlines()
    ]
    assert prewarm_records == [
        {
            "argv": [
                *PRODUCTION_UVX_RESOLUTION_ARGS,
                "--from",
                f"godot-ai=={target_version}",
                "godot-ai-update-transaction",
                "identity",
            ],
            "install_claim_present": False,
            "kind": "install_identity",
            "old_tree_present": True,
            "uv_no_progress": "1",
        }
    ]
    assert read_plugin_version(project / "addons" / "godot_ai" / "plugin.cfg") == target_version
    assert not (project / "addons" / "godot_ai" / "old_only.gd").exists()
    backup = recovery / "retained-pre-v4-addon"
    retained_tree = {
        path.relative_to(backup).as_posix(): path.read_bytes()
        for path in backup.rglob("*")
        if path.is_file()
    }
    assert retained_tree == old_tree
    return project, recovery, isolated_home, codex_home


def test_clean_major_installer_cli_retains_exact_pre_v4_tree(tmp_path: Path) -> None:
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    project, recovery, _home, _codex_home = _install_clean_major_fixture(tmp_path, target_version)

    assert (project / CLEAN_MAJOR_MARKER_RELATIVE).is_file()
    assert (recovery / "retained-pre-v4-addon").is_dir()


def test_clean_major_installer_missing_uvx_fails_before_mutation(tmp_path: Path) -> None:
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    project = tmp_path / "missing-actor-project"
    recovery = tmp_path / "missing-actor-recovery"
    codex_home = tmp_path / "missing-actor-codex"
    argv, verifier_root = prepare_clean_major_migration_project(
        project,
        recovery_root=recovery,
        codex_home=codex_home,
        from_version="3.2.4",
        target_version=target_version,
        http_port=LIVE_HTTP_PORT,
        ws_port=LIVE_WS_PORT,
    )
    old_addon = project / "addons" / "godot_ai"
    before = {
        path.relative_to(old_addon).as_posix(): path.read_bytes()
        for path in old_addon.rglob("*")
        if path.is_file()
    }
    openssl = shutil.which("openssl")
    assert openssl is not None
    actorless_bin = tmp_path / "actorless-bin"
    actorless_bin.mkdir()
    if os.name == "nt":
        (actorless_bin / "openssl.cmd").write_text(
            f'@echo off\r\n"{openssl}" %*\r\n', encoding="utf-8"
        )
    else:
        (actorless_bin / "openssl").symlink_to(openssl)
    environment = os.environ.copy()
    environment["PATH"] = str(actorless_bin)

    refused = subprocess.run(
        argv,
        cwd=verifier_root,
        env=environment,
        text=True,
        capture_output=True,
        timeout=60,
    )

    assert refused.returncode == 1
    assert "uvx is required" in refused.stderr
    after = {
        path.relative_to(old_addon).as_posix(): path.read_bytes()
        for path in old_addon.rglob("*")
        if path.is_file()
    }
    assert after == before
    assert not (project / CLEAN_MAJOR_MARKER_RELATIVE).exists()
    assert not (project / "addons/.godot-ai-v4-installing").exists()
    assert not recovery.exists()


def _authenticated_tool_probe(
    http_port: int,
    capability_dir: Path,
    *,
    resource_path: str = "res://_test_authenticated_tool_probe.txt",
    content: str = "signed self-update authenticated write\n",
) -> None:
    async def run() -> None:
        record = read_capabilities(http_port, capability_dir)
        assert record is not None
        transport = StreamableHttpTransport(
            f"http://127.0.0.1:{http_port}/mcp",
            headers={"Authorization": f"Bearer {record.http}"},
        )
        async with Client(transport, timeout=10, init_timeout=10) as client:
            deadline = asyncio.get_running_loop().time() + 90
            while True:
                sessions = await client.call_tool(
                    "session_manage", {"op": "list", "params": {}}
                )
                if int(sessions.data.get("count", 0)) > 0:
                    break
                if asyncio.get_running_loop().time() >= deadline:
                    raise AssertionError("editor session stayed unavailable")
                # Do not monopolize the server's event loop while the editor's
                # WebSocket reconnect and authenticated handshake are pending.
                await asyncio.sleep(0.2)
            while True:
                state = await client.call_tool("editor_state", {}, raise_on_error=False)
                if not state.is_error:
                    break
                if asyncio.get_running_loop().time() >= deadline:
                    raise AssertionError(f"editor_state stayed unavailable: {state}")
                await asyncio.sleep(0.1)
            written = await client.call_tool(
                "filesystem_manage",
                {
                    "op": "write_text",
                    "params": {
                        "path": resource_path,
                        "content": content,
                    },
                },
            )
            assert written.data["path"] == resource_path
            reread = await client.call_tool(
                "filesystem_manage",
                {
                    "op": "read_text",
                    "params": {"path": resource_path},
                },
            )
            assert reread.data["content"] == content

    asyncio.run(run())


def test_signed_update_restarts_matching_live_server_without_parse_errors(
    tmp_path: Path,
) -> None:
    """Drive signed verification, actor activation, reload, and server B."""
    godot_bin = godot_bin_or_skip()
    smoke = load_smoke_script()
    project = tmp_path / "signed-self-update"
    http_port, ws_port = allocate_free_ports(2)
    base_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    next_version = smoke.bump_patch_version(base_version)
    prepare_signed_update_project(
        project,
        base_version=base_version,
        next_version=next_version,
        base_server_version=base_version,
        next_server_version=next_version,
        http_port=http_port,
        ws_port=ws_port,
    )
    write_install_update_driver(
        project,
        http_port=http_port,
        base_version=base_version,
        next_version=next_version,
    )
    base_addon = project / "addons" / "godot_ai"
    isolated = project / ".self-update-integration"
    isolated_home = isolated / "home"
    codex_home = isolated / "codex"
    isolated_home.mkdir(parents=True)
    write_configure_client_driver(
        project,
        http_port=http_port,
        version=base_version,
    )
    environment = {
        "CODEX_HOME": str(codex_home),
        "GODOT_AI_MODE": "user",
        "HOME": str(isolated_home),
        "USERPROFILE": str(isolated_home),
    }
    if os.name == "nt":
        local_app_data = isolated / "local-app-data"
        local_app_data.mkdir()
        environment["LOCALAPPDATA"] = str(local_app_data)
        capability_dir = local_app_data / "godot-ai" / "capabilities"
    else:
        capability_dir = isolated / "capabilities"
        environment[CAPABILITY_DIR_ENV] = str(capability_dir)

    prep_environment = dict(environment)
    prep_environment.update(
        {
            "_SELF_UPDATE_CONFIGURE_CLIENT": "1",
            "_SELF_UPDATE_DRIVER_SKIP": "1",
        }
    )
    prep_log = run_godot_editor(
        project,
        godot_bin,
        allow_headless=True,
        timeout=180,
        environment=prep_environment,
        phase="configure",
    )
    assert f"SELF_UPDATE_TEST | production-configured Codex command pin={base_version}" in prep_log
    assert f"godot-ai=={base_version}" in (codex_home / "config.toml").read_text(encoding="utf-8")
    remove_configure_client_driver(project)

    log = run_godot_editor(
        project,
        godot_bin,
        allow_headless=True,
        timeout=180,
        environment=environment,
        live_probe=lambda: _authenticated_tool_probe(http_port, capability_dir),
    )

    assert_no_update_parse_errors(log)
    assert "SELF_UPDATE_TEST | requesting canonical signed install" in log
    assert "SELF_UPDATE_TEST | signed topology files installed" in log
    assert "SELF_UPDATE_TEST | authenticated read/write tool probe completed" in log
    assert f"SELF_UPDATE_TEST | status name=godot-ai server_version={next_version}" in log
    assert "SELF_UPDATE_TEST | pre-update instance_id=" in log
    assert read_plugin_version(base_addon / "plugin.cfg") == next_version
    assert (base_addon / "utils" / "self_update_smoke_child.gd").is_file()
    assert (base_addon / "utils" / "self_update_smoke_child.gd.uid").is_file()
    client_config = (codex_home / "config.toml").read_text(encoding="utf-8")
    assert f"godot-ai=={next_version}" in client_config
    assert f"godot-ai=={base_version}" not in client_config
    assert (project / "_test_authenticated_tool_probe.txt").read_text(encoding="utf-8") == (
        "signed self-update authenticated write\n"
    )
    transaction, backup = smoke.verify_transaction_recovery(project, next_version)
    assert backup.is_dir()
    paths = smoke.TransactionPaths.for_transaction(backup.parent, transaction)
    intent = smoke.load_intent(paths)
    claim = smoke.validate_terminal(paths.claim, intent)
    completion = smoke.validate_migration_complete(paths, intent)

    def record_sha256(record: dict[str, object]) -> str:
        canonical = (
            json.dumps(
                record,
                allow_nan=False,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode()
        return hashlib.sha256(canonical).hexdigest()

    assert paths.migration_complete.is_file()
    assert claim["outcome"] == "success"
    assert completion["transaction"] == transaction
    assert completion["claim_sha256"] == record_sha256(claim)
    assert completion["intent_sha256"] == record_sha256(intent.record())
    assert completion["live_tree"] == intent.new_tree.record()
    assert smoke.hash_tree(base_addon) == intent.new_tree
    downloads = backup.parent / "downloads"
    assert not downloads.exists() or not any(downloads.iterdir())

    ordered_markers = [
        f"SELF_UPDATE_TEST | configured Codex command pin={base_version}",
        "SELF_UPDATE_TEST | requesting canonical signed install",
        "MCP | self-update smoke: staged signed local bundle",
        "MCP | stopped server",
        COORDINATOR_DISABLE_MARKER,
        "MCP | update coordinator enabling verified plugin",
        f"SELF_UPDATE_TEST | repinned Codex command pin={next_version}",
        "MCP | client migration durably completed",
        "MCP | plugin loaded",
        "SELF_UPDATE_TEST | signed topology files installed",
        "SELF_UPDATE_TEST | status name=godot-ai",
        "MCP | started server (PID ",
        "SELF_UPDATE_TEST | authenticated read/write tool probe completed",
    ]
    position = -1
    for marker in ordered_markers:
        next_position = log.find(marker, position + 1)
        assert next_position > position, f"missing/out-of-order marker {marker!r}:\n{log}"
        position = next_position

    status_path = project / POST_UPDATE_STATUS_FILE
    assert status_path.is_file(), log
    payload = json.loads(status_path.read_text(encoding="utf-8"))
    assert payload.get("name") == "godot-ai"
    assert payload.get("server_version") == next_version
    post_id = payload.get("instance_id")
    assert isinstance(post_id, str) and post_id
    pre_line = next(
        line
        for line in log.splitlines()
        if line.startswith("SELF_UPDATE_TEST | pre-update instance_id=")
    )
    pre_id = pre_line.split("=", 1)[1]
    assert post_id != pre_id


def test_final_v3_capsule_automatically_replaces_tree_repins_and_starts(
    tmp_path: Path,
) -> None:
    """Click Update in exact final v3 and prove the rest is automatic."""
    godot_bin = godot_bin_or_skip()
    smoke = load_smoke_script()
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    from_version = "3.2.4"
    http_port, ws_port = allocate_free_ports(2)
    project = tmp_path / "v3-bridge-update"
    project.mkdir()
    smoke.write_project_files(project)
    append_driver_autoload(project / "project.godot")
    work = project / ".godot-ai-self-update-smoke"
    work.mkdir()
    (work / "marker.txt").write_text("v3 bridge integration fixture\n", encoding="utf-8")

    server_command, runtime_source = smoke.prepare_local_server_runtime(
        work, "bridge-server", target_version
    )
    actor_command, private_key, public_key = smoke.prepare_smoke_actor(work, runtime_source)
    client_command = smoke.prepare_isolated_client_environment(
        project,
        base_version=from_version,
        http_port=http_port,
        ws_port=ws_port,
    )
    release_tree = work / "release-tree"
    shutil.copytree(PLUGIN_ROOT, release_tree, ignore=smoke.copy_ignore)
    smoke.patch_fixture_plugin(
        release_tree,
        version=target_version,
        server_version=target_version,
        http_port=http_port,
        ws_port=ws_port,
        force_local_update=False,
        next_version=target_version,
        server_command=server_command,
        actor_command=actor_command,
        isolate_client_migration=True,
        client_launch_command=client_command,
    )
    bundle = work / "release"
    bundle.mkdir()
    smoke.create_signed_v4_bundle(
        release_tree, bundle, target_version, private_key, public_key
    )

    capsule_tree = work / "capsule-tree" / "addons" / "godot_ai"
    shutil.copytree(PLUGIN_ROOT.parents[2] / "migration_bridge", capsule_tree)
    capsule_config = capsule_tree / "plugin.cfg"
    capsule_config.write_text(
        capsule_config.read_text(encoding="utf-8").replace("@VERSION@", target_version),
        encoding="utf-8",
    )
    # Godot does not forward --log-file on restart; Windows also disconnects
    # the replacement process's stdout. Redirect only its diagnostics, without
    # changing the restart, activation or startup-barrier implementation.
    coordinator = capsule_tree / "migration_coordinator.gd"
    restart_log = json.dumps(str(project / "_test_restarted_editor.log"))
    coordinator.write_text(
        smoke.replace_once(
            coordinator,
            coordinator.read_text(encoding="utf-8"),
            "\tEditorInterface.restart_editor(true)",
            "\tEditorInterface.restart_editor(true)\n"
            "\tvar diagnostics_args := OS.get_restart_on_exit_arguments()\n"
            '\tdiagnostics_args.append("--log-file")\n'
            f"\tdiagnostics_args.append({restart_log})\n"
            "\tOS.set_restart_on_exit(true, diagnostics_args)",
            "retain replacement-editor diagnostics",
        ),
        encoding="utf-8",
    )
    payload = capsule_tree / "migration_payload"
    payload.mkdir()
    for name in (
        smoke.SMOKE_ARCHIVE_NAME,
        smoke.SMOKE_MANIFEST_NAME,
        smoke.SMOKE_SIGNATURE_NAME,
    ):
        shutil.copy2(bundle / name, payload / name)
    bridge_exec = capsule_tree / "bridge_exec.gd"
    bridge_exec.write_text(
        smoke.replace_function(
            bridge_exec.read_text(encoding="utf-8"),
            "static func actor_command(version: String) -> Array[String]:",
            "static func actor_command(_version: String) -> Array[String]:\n"
            f"\treturn {json.dumps(actor_command)}",
        ),
        encoding="utf-8",
    )
    bridge = capsule_tree / "migration_bridge.gd"
    bridge.write_text(
        smoke.replace_function(
            bridge.read_text(encoding="utf-8"),
            "static func _previous_version() -> String:",
            "static func _previous_version() -> String:\n"
            f"\treturn {json.dumps(from_version)}",
        ),
        encoding="utf-8",
    )
    capsule = work / "godot-ai-plugin.zip"
    with zipfile.ZipFile(capsule, "w", compression=zipfile.ZIP_STORED) as package:
        for path in sorted(capsule_tree.rglob("*")):
            if path.is_file():
                package.write(path, path.relative_to(capsule_tree.parents[1]).as_posix())
    checksum = work / "godot-ai-plugin.zip.sha256"
    checksum.write_text(
        f"{hashlib.sha256(capsule.read_bytes()).hexdigest()}  {capsule.name}\n",
        encoding="ascii",
    )
    signature = work / "godot-ai-plugin.zip.sha256.sig"
    subprocess.run(
        [
            "openssl",
            "dgst",
            "-sha256",
            "-sign",
            str(private_key),
            "-out",
            str(signature),
            str(checksum),
        ],
        check=True,
        capture_output=True,
    )
    private_key.unlink()

    archived = work / "v3.2.4.zip"
    archived.write_bytes(
        subprocess.run(
            ["git", "archive", "--format=zip", "v3.2.4", "plugin/addons/godot_ai"],
            cwd=PLUGIN_ROOT.parents[2],
            check=True,
            capture_output=True,
        ).stdout
    )
    extracted = work / "v3-source"
    with zipfile.ZipFile(archived) as package:
        assert all(
            not Path(info.filename).is_absolute() and ".." not in Path(info.filename).parts
            for info in package.infolist()
        )
        assert all(
            info.is_dir() or info.filename.startswith("plugin/addons/godot_ai/")
            for info in package.infolist()
        )
        package.extractall(extracted)
    live = project / "addons" / "godot_ai"
    shutil.copytree(extracted / "plugin/addons/godot_ai", live)
    old_plugin = live / "plugin.gd"
    old_plugin.write_text(
        smoke.replace_function(
            old_plugin.read_text(encoding="utf-8"),
            "func _start_server() -> void:",
            "func _start_server() -> void:\n\tpass",
        ),
        encoding="utf-8",
    )
    old_manager = live / "utils" / "update_manager.gd"
    manager_text = old_manager.read_text(encoding="utf-8")
    manager_text = smoke.subn_once(
        old_manager,
        manager_text,
        r'const RELEASE_SIGNING_PUBLIC_KEY_PEM := """[\s\S]*?"""',
        (
            'const RELEASE_SIGNING_PUBLIC_KEY_PEM := """'
            + public_key.strip()
            + '"""'
        ),
        "v3 fixture signing key",
    )
    manager_text = smoke.replace_once(
        old_manager,
        manager_text,
        'const UPDATE_TEMP_ZIP := "user://godot_ai_update/update.zip"\n',
        (
            'const UPDATE_TEMP_ZIP := "user://godot_ai_update/update.zip"\n'
            f'const CLICK_FIXTURE_ARCHIVE := {json.dumps(str(capsule))}\n'
            f'const CLICK_FIXTURE_CHECKSUM := {json.dumps(str(checksum))}\n'
            f'const CLICK_FIXTURE_SIGNATURE := {json.dumps(str(signature))}\n'
            f'const CLICK_FIXTURE_VERSION := {json.dumps(target_version)}\n'
        ),
        "v3 click fixture assets",
    )
    manager_text = smoke.replace_function(
        manager_text,
        "func check_for_updates() -> void:",
        """func check_for_updates() -> void:
\t_latest_download_url = (
\t\t"https://github.com/hi-godot/godot-ai/releases/download/v%s/" % CLICK_FIXTURE_VERSION
\t\t+ "godot-ai-plugin.zip"
\t)
\t_latest_checksum_url = _latest_download_url + ".sha256"
\t_latest_signature_url = _latest_checksum_url + ".sig"
\t_latest_remote_version = CLICK_FIXTURE_VERSION
\tupdate_check_completed.emit({
\t\t"has_update": true,
\t\t"version": CLICK_FIXTURE_VERSION,
\t\t"label_text": "Update available: v%s" % CLICK_FIXTURE_VERSION,
\t})""",
    )
    manager_text = smoke.replace_function(
        manager_text,
        "func start_install() -> void:",
        """func start_install() -> void:
\tprint("V3_BRIDGE_TEST | clicked final-v3 Update button")
\tvar global_zip := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
\tDirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))
\tif DirAccess.copy_absolute(CLICK_FIXTURE_ARCHIVE, global_zip) != OK:
\t\t_fail_verification("fixture archive copy failed")
\t\treturn
\tvar sidecar := FileAccess.get_file_as_bytes(CLICK_FIXTURE_CHECKSUM)
\tvar signature := FileAccess.get_file_as_bytes(CLICK_FIXTURE_SIGNATURE)
\tif not _verify_sidecar_signature(RELEASE_SIGNING_PUBLIC_KEY_PEM, sidecar, signature):
\t\t_fail_verification("fixture signature failed")
\t\treturn
\tprint("MCP | self-update release signature verified")
\tvar expected := _parse_sha256_digest(sidecar.get_string_from_utf8())
\t_finish_digest_check_and_install(expected)""",
    )
    old_manager.write_text(manager_text, encoding="utf-8")

    write_driver_support(project)
    (project / "_test_runner_driver.gd").write_text(
        f'''@tool
extends Node

const TARGET_VERSION := "{target_version}"
const HTTP_PORT := {http_port}
const STATUS_PATH := "res://{POST_UPDATE_STATUS_FILE}"
const PROBE_DONE_PATH := "res://{POST_UPDATE_TOOL_PROBE_FILE}"
const COMPLETE_PATH := "res://_test_v3_bridge_complete.done"
const DriverSupport := preload("res://_test_self_update_driver_support.gd")
const DEADLINE_MSEC := 180000

var _deadline := 0
var _migration_ready := false
var _clicked := false


func _ready() -> void:
\tif not Engine.is_editor_hint():
\t\tqueue_free()
\t\treturn
\tvar initial := "res://_test_v3_initial_editor.json"
\tvar receipt_path := (
\t\t"res://_test_v3_restarted_editor.json" if FileAccess.file_exists(initial) else initial
\t)
\tvar receipt := FileAccess.open(receipt_path, FileAccess.WRITE)
\tif receipt == null:
\t\tget_tree().quit(43)
\t\treturn
\treceipt.store_string(JSON.stringify({{
\t\t"pid": OS.get_process_id(), "display": DisplayServer.get_name(),
\t}}))
\treceipt.close()
\t_deadline = Time.get_ticks_msec() + DEADLINE_MSEC
\tset_process(true)


func _process(_delta: float) -> void:
\tif Time.get_ticks_msec() >= _deadline:
\t\tpush_error("V3_BRIDGE_TEST | automatic migration timed out")
\t\tget_tree().quit(41)
\t\treturn
\tif not _clicked:
\t\tvar old_plugin := DriverSupport.find_godot_ai_plugin()
\t\tif old_plugin == null:
\t\t\treturn
\t\tvar dock: Variant = old_plugin.get("_dock")
\t\tif dock == null or not dock.has_method("_on_update_pressed"):
\t\t\treturn
\t\tdock.call("_on_update_pressed")
\t\t_clicked = true
\t\treturn
\tif _migration_ready:
\t\tif FileAccess.file_exists(PROBE_DONE_PATH):
\t\t\tprint("V3_BRIDGE_TEST | authenticated tool probe completed")
\t\t\tvar complete := FileAccess.open(COMPLETE_PATH, FileAccess.WRITE)
\t\t\tif complete != null:
\t\t\t\tcomplete.store_string("complete\\n")
\t\t\t\tcomplete.close()
\t\t\tget_tree().quit(0)
\t\treturn
\tvar plugin := DriverSupport.find_godot_ai_plugin()
\tif plugin == null or not bool(plugin.call("has_managed_server")):
\t\treturn
\tif not DriverSupport.client_config_has_pin(TARGET_VERSION):
\t\treturn
\tvar status := DriverSupport.fetch_status(HTTP_PORT)
\tif str(status.get("server_version", "")) != TARGET_VERSION:
\t\treturn
\tvar file := FileAccess.open(STATUS_PATH, FileAccess.WRITE)
\tif file == null:
\t\tget_tree().quit(42)
\t\treturn
\tfile.store_string(JSON.stringify(status))
\tfile.close()
\tprint("V3_BRIDGE_TEST | v4 server and client pin ready")
\t_migration_ready = true
''',
        encoding="utf-8",
    )

    environment = smoke.godot_child_environment(project)
    capability_dir = smoke.fixture_environment_paths(project)["capability_dir"]
    # Preserve the existing outer budget while #957 is investigated; a longer
    # timeout did not cure its restart failure. The fixture now preserves the
    # headless drivers and the receipts below prove a real headless restart.
    editor_start_timeout = 360 if os.name == "nt" else 240
    log = run_godot_editor(
        project,
        godot_bin,
        allow_headless=True,
        timeout=editor_start_timeout,
        environment=environment,
        live_probe=lambda: _authenticated_tool_probe(
            http_port,
            capability_dir,
            resource_path="res://_test_v3_bridge_probe.txt",
            content="v3 bridge authenticated write\n",
        ),
        restart_completion_file="_test_v3_bridge_complete.done",
    )

    initial_editor = json.loads(
        (project / "_test_v3_initial_editor.json").read_text(encoding="utf-8")
    )
    restarted_editor = json.loads(
        (project / "_test_v3_restarted_editor.json").read_text(encoding="utf-8")
    )
    assert initial_editor["pid"] != restarted_editor["pid"], (initial_editor, restarted_editor)
    assert initial_editor["display"] == restarted_editor["display"] == "headless", (
        initial_editor, restarted_editor
    )

    disable = log.find("MCP | v3 bridge disabling transition plugin")
    assert disable >= 0, log
    assert "Failed to create an autoload" not in log, log
    transition_window = log[disable:]
    parse_errors = (
        "SCRIPT ERROR: Parse Error",
        "ERROR: Failed to load script",
        "Could not resolve script",
    )
    for pattern in parse_errors:
        assert pattern not in transition_window, transition_window
    ordered_markers = (
        "V3_BRIDGE_TEST | clicked final-v3 Update button",
        "MCP | self-update release signature verified",
        "MCP | update runner disabling old plugin",
        "MCP | v3 bridge preparing signed v4 tree",
        "MCP | v3 bridge activating canonical v4 tree",
        "MCP | v3 bridge disabling transition plugin",
        "MCP | v3 bridge restarting editor into canonical v4 tree",
    )
    position = -1
    for marker in ordered_markers:
        position = log.find(marker, position + 1)
        assert position >= 0, f"missing/out-of-order {marker!r}:\n{log}"
    assert read_plugin_version(live / "plugin.cfg") == target_version
    assert not (live / "migration_payload").exists()
    assert not (live / "update_reload_runner.gd").exists()
    codex_home = smoke.fixture_environment_paths(project)["codex_home"]
    config_text = (codex_home / "config.toml").read_text(encoding="utf-8")
    assert f"godot-ai=={target_version}" in config_text
    assert f"godot-ai=={from_version}" not in config_text
    transaction, backup = smoke.verify_transaction_recovery(project, target_version)
    intent = smoke.load_intent(
        smoke.TransactionPaths.for_transaction(backup.parent, transaction)
    )
    assert intent.from_version == from_version
    assert (backup / "migration_payload" / smoke.SMOKE_ARCHIVE_NAME).is_file()
    assert (backup / "update_reload_runner.gd").is_file()
    # The supported v3 updater overlays the capsule; it retains the old
    # autoload until the canonical tree replaces it. The capsule is not a
    # standalone add-on and must not grow a second game-helper implementation.
    assert (backup / "runtime/game_helper.gd").read_bytes() == (
        extracted / "plugin/addons/godot_ai/runtime/game_helper.gd"
    ).read_bytes()


@pytest.mark.parametrize("prewarm_mode", ["cold", "offline", "wedged"])
def test_clean_major_installer_holds_first_start_until_client_confirmation(
    tmp_path: Path, prewarm_mode: str
) -> None:
    """Exercise the documented synthetic pre-v4 -> v4 clean migration lane."""
    godot_bin = godot_bin_or_skip()
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    from_version = "3.2.4"
    http_port, ws_port = allocate_free_ports(2)
    project, _recovery, isolated_home, codex_home = _install_clean_major_fixture(
        tmp_path, target_version, http_port, ws_port
    )
    marker = project / CLEAN_MAJOR_MARKER_RELATIVE
    assert marker.is_file()
    isolated = isolated_home.parent
    prewarm_log = project / ".clean-major-smoke" / "prewarm.jsonl"
    wedge_started = project / ".clean-major-smoke" / "wedge-started.txt"
    environment = {
        "CLEAN_MAJOR_FAKE_UVX_MODE": prewarm_mode,
        "CLEAN_MAJOR_PREWARM_LOG": str(prewarm_log),
        "CLEAN_MAJOR_WEDGE_STARTED": str(wedge_started),
        "CODEX_HOME": str(codex_home),
        "GODOT_AI_MODE": "user",
        "HOME": str(isolated_home),
        "PATH": (
            str(project / ".clean-major-smoke" / "fake-bin")
            + os.pathsep
            + os.environ.get("PATH", "")
        ),
        "USERPROFILE": str(isolated_home),
    }
    if os.name == "nt":
        local_app_data = isolated / "local-app-data"
        local_app_data.mkdir()
        environment["LOCALAPPDATA"] = str(local_app_data)
        capability_dir = local_app_data / "godot-ai" / "capabilities"
    else:
        capability_dir = isolated / "capabilities"
        environment[CAPABILITY_DIR_ENV] = str(capability_dir)
    probe_resource = "res://_test_clean_major_authenticated_probe.txt"
    probe_content = "clean-major authenticated write\n"
    wedged = prewarm_mode == "wedged"
    # Windows owns and terminates the entire cmd.exe process tree, so a
    # timed-out prewarm may safely continue once that exact tree is proven
    # dead. POSIX can kill only the captured launcher PID and must retain the
    # migration barrier because possible descendants remain unproven.
    requires_retry = wedged and os.name != "nt"
    log = run_godot_editor(
        project,
        godot_bin,
        allow_headless=True,
        timeout=240,
        environment=environment,
        live_probe=(
            None
            if requires_retry
            else lambda: _authenticated_tool_probe(
                http_port,
                capability_dir,
                resource_path=probe_resource,
                content=probe_content,
            )
        ),
        probe_ready_file=CLEAN_MAJOR_STATUS_FILE,
        probe_done_file=CLEAN_MAJOR_TOOL_PROBE_FILE,
        expected_exit_code=23 if requires_retry else 0,
    )

    client_config = (codex_home / "config.toml").read_text(encoding="utf-8")
    prewarm_records = [
        json.loads(line) for line in prewarm_log.read_text(encoding="utf-8").splitlines()
    ]
    assert prewarm_records[-1] == {
        "argv": [
            *PRODUCTION_UVX_RESOLUTION_ARGS,
            "--from",
            f"godot-ai=={target_version}",
            "godot-ai",
            "--version",
        ],
        "kind": "startup_prewarm",
        "mode": prewarm_mode,
    }
    assert len(prewarm_records) == 2
    if wedged:
        assert "CLEAN_MAJOR_TEST | editor remained responsive during wedged prewarm" in log
    if requires_retry:
        assert "Post-update package pre-warm could not be proven stopped" in log
        assert "CLEAN_MAJOR_TEST | client migration requested retry" in log
        assert "MCP | client migration durably completed" not in log
        assert "MCP | started server (PID " not in log
        assert marker.is_file()
        assert not (project / CLEAN_MAJOR_STATUS_FILE).exists()
        assert not (project / probe_resource.removeprefix("res://")).exists()
        assert f"godot-ai=={from_version}" in client_config
        assert f"godot-ai=={target_version}" not in client_config
        return

    assert not marker.exists()
    assert (project / probe_resource.removeprefix("res://")).read_text(
        encoding="utf-8"
    ) == probe_content
    assert f"godot-ai=={target_version}" in client_config
    assert f"godot-ai=={from_version}" not in client_config
    ordered_markers = [
        "CLEAN_MAJOR_TEST | migration marker removed automatically",
        f"CLEAN_MAJOR_TEST | repinned owned Codex command pin={target_version}",
        "MCP | client migration durably completed",
        "MCP | plugin loaded",
        "MCP | started server (PID ",
        f"CLEAN_MAJOR_TEST | status name=godot-ai server_version={target_version}",
        "CLEAN_MAJOR_TEST | authenticated read/write tool probe completed",
    ]
    position = -1
    for expected in ordered_markers:
        next_position = log.find(expected, position + 1)
        assert next_position > position, f"missing/out-of-order marker {expected!r}:\n{log}"
        position = next_position
    status = json.loads((project / CLEAN_MAJOR_STATUS_FILE).read_text(encoding="utf-8"))
    assert status.get("name") == "godot-ai"
    assert status.get("server_version") == target_version
