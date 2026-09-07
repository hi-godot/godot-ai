"""Real-editor scenarios for the lean self-updater (docs/self-update.md).

Each scenario drives the production entry points inside a real editor and
proves the state one update leaves behind: a signed v4-to-v4 update restarts
into a working server, the final-v3 capsule crosses into v4, a tampered live
tree after a swap is rolled back, and the closed-editor installer's first
start completes client migration.
"""

from __future__ import annotations

import asyncio
import contextlib
import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
from pathlib import Path

import pytest
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

from godot_ai.transport.capability import CAPABILITY_DIR_ENV, read_capabilities
from tests._qualification_https_fixture import signed_smoke_https_delivery
from tests.conftest import allocate_free_ports
from tests.integration._self_update_fixture import (
    CLEAN_MAJOR_MARKER_RELATIVE,
    CLEAN_MAJOR_STATUS_FILE,
    CLEAN_MAJOR_TOOL_PROBE_FILE,
    LIVE_HTTP_PORT,
    LIVE_WS_PORT,
    PLUGIN_ROOT,
    POST_UPDATE_COMPLETE_FILE,
    POST_UPDATE_STATUS_FILE,
    POST_UPDATE_TOOL_PROBE_FILE,
    PRE_INSTANCE_ID_FILE,
    RESTARTED_EDITOR_LOG,
    UPDATE_STATE_RELATIVE,
    AttachedAgent,
    _write_fake_uvx_shim,
    append_driver_autoload,
    assert_no_update_parse_errors,
    godot_bin_or_skip,
    load_smoke_script,
    patch_restart_diagnostics,
    prepare_clean_major_migration_project,
    prepare_signed_update_project,
    read_editor_receipts,
    read_plugin_version,
    remove_configure_client_driver,
    run_godot_editor,
    write_clean_major_driver,
    write_configure_client_driver,
    write_driver_support,
    write_install_update_driver,
    write_post_restart_driver,
)


def _tree_bytes(root: Path) -> dict[str, bytes]:
    return {
        path.relative_to(root).as_posix(): path.read_bytes()
        for path in root.rglob("*")
        if path.is_file()
    }


def _assert_ordered(log: str, markers: list[str] | tuple[str, ...]) -> None:
    position = -1
    for marker in markers:
        next_position = log.find(marker, position + 1)
        assert next_position > position, f"missing/out-of-order marker {marker!r}:\n{log}"
        position = next_position


def _isolated_environment(isolated: Path) -> tuple[dict[str, str], Path]:
    """A user-mode editor environment whose client configs live under tmp."""
    home = isolated / "home"
    home.mkdir(parents=True, exist_ok=True)
    environment = {
        "CODEX_HOME": str(isolated / "codex"),
        "GODOT_AI_MODE": "user",
        "HOME": str(home),
        "USERPROFILE": str(home),
    }
    if os.name == "nt":
        local_app_data = isolated / "local-app-data"
        local_app_data.mkdir(exist_ok=True)
        environment["LOCALAPPDATA"] = str(local_app_data)
        capability_dir = local_app_data / "godot-ai" / "capabilities"
    else:
        capability_dir = isolated / "capabilities"
        environment[CAPABILITY_DIR_ENV] = str(capability_dir)
    return environment, capability_dir


def test_clean_major_driver_waits_for_automatic_migration(tmp_path: Path) -> None:
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
    assert 'plugin.get("_normal_start_released")' in text
    assert "update marker does not record success" in text
    assert "migration completed automatically" in text
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
    fresh: bool = False,
) -> tuple[Path, Path]:
    """Run the closed-editor installer over a synthetic pre-v4 project.

    ``fresh`` installs into a project without an add-on: the marker then
    names no previous version and retains no backup.
    """
    from_version = "3.2.4"
    project = tmp_path / "clean-major-migration"
    isolated = tmp_path / "clean-major-environment"
    argv, verifier_root = prepare_clean_major_migration_project(
        project,
        codex_home=isolated / "codex",
        from_version=from_version,
        target_version=target_version,
        http_port=http_port,
        ws_port=ws_port,
        fresh=fresh,
    )
    write_clean_major_driver(
        project,
        http_port=http_port,
        from_version=from_version,
        target_version=target_version,
    )
    old_addon = project / "addons" / "godot_ai"
    old_tree = {} if fresh else _tree_bytes(old_addon)
    install_environment = os.environ.copy()
    install_environment["PATH"] = (
        str(project / ".clean-major-smoke" / "fake-bin")
        + os.pathsep
        + install_environment.get("PATH", "")
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
    assert installed.stdout.startswith("OK: installed exact v4 tree"), installed.stdout
    assert argv[-2:] == ["--project-root", str(project)]
    assert read_plugin_version(old_addon / "plugin.cfg") == target_version
    assert not (old_addon / "old_only.gd").exists()
    state = project / UPDATE_STATE_RELATIVE
    marker = json.loads((project / CLEAN_MAJOR_MARKER_RELATIVE).read_text(encoding="utf-8"))
    assert marker["status"] == "success", marker
    if fresh:
        assert not (state / "backup").exists()
        assert marker["from_version"] == ""
        assert marker["backup_root"] == ""
    else:
        assert _tree_bytes(state / "backup" / from_version) == old_tree
        assert marker["from_version"] == from_version
    assert marker["to_version"] == target_version
    assert marker["replace_owned_mismatches"] is True
    assert not (state / "lock.json").exists()
    assert not (state / "stage").exists()
    return project, isolated


def test_clean_major_installer_cli_retains_exact_pre_v4_tree(tmp_path: Path) -> None:
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    project, _isolated = _install_clean_major_fixture(tmp_path, target_version)

    assert (project / CLEAN_MAJOR_MARKER_RELATIVE).is_file()
    assert (project / UPDATE_STATE_RELATIVE / "backup" / "3.2.4" / "old_only.gd").is_file()


def test_closed_editor_install_then_first_start_completes_migration(tmp_path: Path) -> None:
    """The first editor start after a closed install repins clients, then serves."""
    project, marker = _first_start_after_closed_install(tmp_path)
    assert (project / UPDATE_STATE_RELATIVE / "backup" / "3.2.4" / "old_only.gd").is_file()
    assert marker["from_version"] == "3.2.4"


def test_closed_editor_install_into_fresh_project_then_first_start_serves(
    tmp_path: Path,
) -> None:
    """No add-on before the install: the marker names no previous version.

    This is how the release qualification's runtime row installs candidate A;
    the first start must still repin the stale owned entry and serve.
    """
    project, marker = _first_start_after_closed_install(tmp_path, fresh=True)
    assert not (project / UPDATE_STATE_RELATIVE / "backup").exists()
    assert marker["from_version"] == ""


def _first_start_after_closed_install(tmp_path: Path, *, fresh: bool = False) -> tuple[Path, dict]:
    godot_bin = godot_bin_or_skip()
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    http_port, ws_port = allocate_free_ports(2)
    project, isolated = _install_clean_major_fixture(
        tmp_path, target_version, http_port, ws_port, fresh=fresh
    )
    environment, capability_dir = _isolated_environment(isolated)
    environment["PATH"] = (
        str(project / ".clean-major-smoke" / "fake-bin") + os.pathsep + os.environ.get("PATH", "")
    )

    log = run_godot_editor(
        project,
        godot_bin,
        allow_headless=True,
        timeout=240,
        environment=environment,
        live_probe=lambda: _authenticated_tool_probe(
            http_port,
            capability_dir,
            resource_path="res://_test_clean_major_probe.txt",
            content="clean major authenticated write\n",
        ),
        probe_ready_file=CLEAN_MAJOR_STATUS_FILE,
        probe_done_file=CLEAN_MAJOR_TOOL_PROBE_FILE,
    )

    assert_no_update_parse_errors(log)
    _assert_ordered(
        log,
        (
            "MCP | client migration completed",
            "CLEAN_MAJOR_TEST | migration completed automatically",
            f"CLEAN_MAJOR_TEST | repinned owned Codex command pin={target_version}",
            "CLEAN_MAJOR_TEST | authenticated read/write tool probe completed",
        ),
    )
    config_text = (isolated / "codex" / "config.toml").read_text(encoding="utf-8")
    assert f"godot-ai=={target_version}" in config_text
    assert "godot-ai==3.2.4" not in config_text
    marker = json.loads((project / CLEAN_MAJOR_MARKER_RELATIVE).read_text(encoding="utf-8"))
    assert marker["status"] == "success", marker
    assert marker["clients_migrated"] is True, marker
    assert not (project / UPDATE_STATE_RELATIVE / "lock.json").exists()
    assert (project / "_test_clean_major_probe.txt").read_text(encoding="utf-8") == (
        "clean major authenticated write\n"
    )
    return project, marker


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
                sessions = await client.call_tool("session_manage", {"op": "list", "params": {}})
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


@pytest.fixture(
    params=(
        pytest.param(
            "local-files",
            marks=pytest.mark.skipif(
                os.name == "nt",
                reason=(
                    "same signed-update-and-restart scenario as private-https "
                    "through a different delivery transport; a Windows real-editor "
                    "run costs ~105 s, Linux and macOS keep both variants"
                ),
            ),
        ),
        "private-https",
    )
)
def signed_update_delivery(request):
    with contextlib.ExitStack() as stack:

        def configure(project, version, environment):
            if request.param == "local-files":
                return None
            endpoint, transport_environment = stack.enter_context(
                signed_smoke_https_delivery(project, version)
            )
            environment.update(transport_environment)
            return endpoint

        yield configure


def test_signed_update_restarts_into_matching_live_server(
    tmp_path: Path,
    signed_update_delivery,
) -> None:
    """Click Update on A; the editor swaps, restarts, repins, and serves B."""
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
        agent_gate=True,
    )
    base_addon = project / "addons" / "godot_ai"
    patch_restart_diagnostics(base_addon, project / RESTARTED_EDITOR_LOG)
    isolated = project / ".self-update-integration"
    environment, capability_dir = _isolated_environment(isolated)
    codex_home = Path(environment["CODEX_HOME"])
    write_configure_client_driver(
        project,
        http_port=http_port,
        version=base_version,
        reload_before_quit=True,
    )

    delivery = signed_update_delivery(project, next_version, environment)
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
    assert (
        "SELF_UPDATE_TEST | ordinary reload restored backend and persisted enablement" in prep_log
    )
    assert f"godot-ai=={base_version}" in (codex_home / "config.toml").read_text(encoding="utf-8")
    remove_configure_client_driver(project)

    # An agent stays attached through the whole update, exactly as a user's
    # AI client would be. Its bridge loses server A, spawns a backend of the
    # old version into the restart window, and the restarted editor must
    # replace that backend on its own rather than ask the user to.
    with AttachedAgent(project, http_port, ws_port, capability_dir=capability_dir) as agent:
        try:
            log = run_godot_editor(
                project,
                godot_bin,
                allow_headless=True,
                timeout=240,
                environment=environment,
                live_probe=lambda: _authenticated_tool_probe(http_port, capability_dir),
                restart_completion_file=POST_UPDATE_COMPLETE_FILE,
            )
        except AssertionError as exc:
            raise AssertionError(
                f"agent ok={agent.ok} fault={agent.fault!r} errors={agent.errors[:3]}\n{exc}"
            ) from exc
    assert not agent.fault, agent.fault
    assert agent.ok >= 1, agent.errors
    # What the old bridge reports afterwards varies with timing (a refused
    # incompatible backend, a lost lease, a backend without an editor); the
    # contract is only that the editor came back live on its own, above.
    print(f"attached agent: ok={agent.ok} errors={len(agent.errors)} last={agent.errors[-1:]}")
    # Whether the bridge's spawned backend takes the port before the editor's
    # probe, between its probe and its launch, or not at all is a race; the
    # editor recovers from each on its own (the ordered markers and the live
    # probe below are the contract). Say which path this run took.
    replaced_line = (
        f"MCP | replacing the v{base_version} server left on port {http_port} by the update"
    )
    restarted_log = log[log.index("SELF_UPDATE_HARNESS | replacement editor log:") :]
    started_at = restarted_log.index("MCP | started server (PID ")
    blocks_before_start = [
        line.split("MCP | server start blocked: ", 1)[1]
        for line in restarted_log[:started_at].splitlines()
        if "MCP | server start blocked: " in line
    ]
    initial_log = log[: log.index("SELF_UPDATE_HARNESS | replacement editor log:")]
    print(f"server A: {'stopped' if 'MCP | stopped server' in initial_log else 'detached (lease)'}")
    print(f"replacement: {'needed' if replaced_line in restarted_log else 'not needed'}")
    print(f"blocks before the start: {blocks_before_start}")
    assert f"MCP | AI clients attached before the update must restart to use v{next_version}" in log

    initial_editor, restarted_editor = read_editor_receipts(project)
    assert initial_editor["pid"] != restarted_editor["pid"], (initial_editor, restarted_editor)
    assert initial_editor["display"] == restarted_editor["display"] == "headless"
    assert_no_update_parse_errors(log)
    _assert_ordered(
        log,
        [
            "SELF_UPDATE_TEST | pre-update instance_id=",
            f"SELF_UPDATE_TEST | configured Codex command pin={base_version}",
            "SELF_UPDATE_TEST | requesting canonical signed install",
            # The local bundle is staged before the swap; the HTTPS observer is
            # connected after the plugin's activation listener, which runs the
            # whole swap synchronously, so its line lands after the restart
            # announcement. Whether A is stopped or merely detached before the
            # swap depends on the attached agent holding a lease at that
            # instant; the restarted editor replaces either occupant.
            *(
                [
                    f"MCP | update to {next_version} swapped in; restarting the editor",
                    "SELF_UPDATE_TEST | HTTPS canonical triple downloaded",
                ]
                if delivery is not None
                else [
                    smoke.SMOKE_STAGED_LOG,
                    f"MCP | update to {next_version} swapped in; restarting the editor",
                ]
            ),
            # Everything below runs in the restarted editor process. The driver
            # sees the new server answer /godot-ai/status before the plugin
            # logs the handshake that follows the spawn.
            "MCP | client migration completed",
            "MCP | plugin loaded",
            f"SELF_UPDATE_TEST | repinned Codex command pin={next_version}",
            "SELF_UPDATE_TEST | signed topology files installed",
            f"SELF_UPDATE_TEST | status name=godot-ai server_version={next_version}",
            "MCP | started server (PID ",
            "SELF_UPDATE_TEST | authenticated read/write tool probe completed",
        ],
    )
    assert read_plugin_version(base_addon / "plugin.cfg") == next_version
    assert (base_addon / "utils" / "self_update_smoke_child.gd").is_file()
    assert (base_addon / "utils" / "self_update_smoke_child.gd.uid").is_file()
    client_config = (codex_home / "config.toml").read_text(encoding="utf-8")
    assert f"godot-ai=={next_version}" in client_config
    assert f"godot-ai=={base_version}" not in client_config
    assert (project / "_test_authenticated_tool_probe.txt").read_text(encoding="utf-8") == (
        "signed self-update authenticated write\n"
    )
    marker, backup = smoke.verify_lean_update_state(project, next_version)
    assert marker["from_version"] == base_version
    assert marker["replace_owned_mismatches"] is False
    assert read_plugin_version(backup / "plugin.cfg") == base_version

    payload = json.loads((project / POST_UPDATE_STATUS_FILE).read_text(encoding="utf-8"))
    assert payload.get("name") == "godot-ai"
    assert payload.get("server_version") == next_version
    post_id = payload.get("instance_id")
    pre_id = (project / PRE_INSTANCE_ID_FILE).read_text(encoding="utf-8").strip()
    assert isinstance(post_id, str) and post_id and pre_id
    assert post_id != pre_id
    if delivery is not None:
        assert delivery.downloads == [
            smoke.SMOKE_ARCHIVE_NAME,
            smoke.SMOKE_MANIFEST_NAME,
            smoke.SMOKE_SIGNATURE_NAME,
        ]
        # B is the canonical tree; A (the backup) carried the fixture signing key.
        canonical_manager = (PLUGIN_ROOT / "utils/update_manager.gd").read_bytes()
        assert (base_addon / "utils/update_manager.gd").read_bytes() == canonical_manager
        assert (backup / "utils/update_manager.gd").read_bytes() != canonical_manager
        for retained in (
            prep_log,
            log,
            client_config,
            json.dumps(marker),
            (project / "project.godot").read_text(encoding="utf-8"),
        ):
            assert delivery.token not in retained
            assert "https://release.qualification.invalid" not in retained


# The v3 versions the installed fleet runs (telemetry, 30 days to 2026-09-04,
# every version above ~100 installs). Each crosses into v4 through its own
# updater and the capsule. Every pull request proves the two newest; the
# whole fleet runs nightly and wherever GODOT_AI_FLEET_CROSSINGS=1 is set.
V3_FLEET_VERSIONS = (
    "3.0.7",
    "3.1.1",
    "3.1.2",
    "3.1.3",
    "3.1.4",
    "3.1.5",
    "3.2.0",
    "3.2.1",
    "3.2.2",
    "3.2.3",
    "3.2.4",
    "3.2.5",
)
V3_NEWEST_VERSIONS = V3_FLEET_VERSIONS[-2:]
FLEET_CROSSINGS_ENABLED = os.environ.get("GODOT_AI_FLEET_CROSSINGS", "") == "1"


@pytest.mark.parametrize(
    "from_version",
    [
        pytest.param(
            version,
            marks=pytest.mark.skipif(
                not FLEET_CROSSINGS_ENABLED and version not in V3_NEWEST_VERSIONS,
                reason="older fleet crossings run nightly (GODOT_AI_FLEET_CROSSINGS=1)",
            ),
        )
        for version in V3_FLEET_VERSIONS
    ],
)
def test_final_v3_capsule_automatically_replaces_tree_repins_and_starts(
    tmp_path: Path,
    from_version: str,
) -> None:
    """Click Update in an exact fleet v3 and prove the rest is automatic."""
    godot_bin = godot_bin_or_skip()
    smoke = load_smoke_script()
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    http_port, ws_port = allocate_free_ports(2)
    project = tmp_path / "v3-bridge-update"
    prepared = smoke.prepare_v3_crossing_project(
        project,
        from_version=from_version,
        target_version=target_version,
        http_port=http_port,
        ws_port=ws_port,
        restart_log=project / RESTARTED_EDITOR_LOG,
    )
    append_driver_autoload(project / "project.godot")
    live = prepared["live"]
    v3_source = prepared["v3_source"]

    write_driver_support(project)
    (project / "_test_runner_driver.gd").write_text(
        f'''@tool
extends Node

const TARGET_VERSION := "{target_version}"
const HTTP_PORT := {http_port}
const STATUS_PATH := "res://{POST_UPDATE_STATUS_FILE}"
const PROBE_DONE_PATH := "res://{POST_UPDATE_TOOL_PROBE_FILE}"
const COMPLETE_PATH := "res://{POST_UPDATE_COMPLETE_FILE}"
const INITIAL_RECEIPT := "res://_test_initial_editor.json"
const RESTARTED_RECEIPT := "res://_test_restarted_editor.json"
const DriverSupport := preload("res://_test_self_update_driver_support.gd")
const DEADLINE_MSEC := 180000

var _deadline := 0
var _migration_ready := false
var _clicked := false


func _ready() -> void:
\tif not Engine.is_editor_hint():
\t\tqueue_free()
\t\treturn
\tvar restarted := FileAccess.file_exists(INITIAL_RECEIPT)
\tvar receipt_path := RESTARTED_RECEIPT if restarted else INITIAL_RECEIPT
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
    log = run_godot_editor(
        project,
        godot_bin,
        allow_headless=True,
        timeout=360 if os.name == "nt" else 240,
        environment=environment,
        live_probe=lambda: _authenticated_tool_probe(
            http_port,
            capability_dir,
            resource_path="res://_test_v3_bridge_probe.txt",
            content="v3 bridge authenticated write\n",
        ),
        restart_completion_file=POST_UPDATE_COMPLETE_FILE,
    )

    initial_editor, restarted_editor = read_editor_receipts(project)
    assert initial_editor["pid"] != restarted_editor["pid"], (initial_editor, restarted_editor)
    assert initial_editor["display"] == restarted_editor["display"] == "headless", (
        initial_editor,
        restarted_editor,
    )
    assert "Failed to create an autoload" not in log, log
    disable = log.find("MCP | v3 bridge disabling transition plugin")
    assert disable >= 0, log
    for pattern in (
        "SCRIPT ERROR: Parse Error",
        "ERROR: Failed to load script",
        "Could not resolve script",
    ):
        assert pattern not in log[disable:], log[disable:]
    _assert_ordered(
        log,
        (
            "V3_BRIDGE_TEST | clicked final-v3 Update button",
            "MCP | self-update release signature verified",
            "MCP | update runner disabling old plugin",
            "MCP | v3 bridge verifying and staging the signed v4 tree",
            "MCP | v3 bridge activating canonical v4 tree",
            "MCP | v3 bridge disabling transition plugin",
            "MCP | v3 bridge swapping in the verified canonical v4 tree",
            "MCP | v3 bridge restarting editor into canonical v4 tree",
            # Everything below runs in the restarted editor on the v4 tree.
            "MCP | client migration completed",
            "V3_BRIDGE_TEST | v4 server and client pin ready",
            "V3_BRIDGE_TEST | authenticated tool probe completed",
        ),
    )
    assert read_plugin_version(live / "plugin.cfg") == target_version
    assert not (live / "migration_payload").exists()
    assert not (live / "update_reload_runner.gd").exists()
    assert not (live / "migration_bridge.gd").exists()
    codex_home = smoke.fixture_environment_paths(project)["codex_home"]
    config_text = (codex_home / "config.toml").read_text(encoding="utf-8")
    assert f"godot-ai=={target_version}" in config_text
    assert f"godot-ai=={from_version}" not in config_text
    marker, backup = smoke.verify_lean_update_state(project, target_version)
    assert marker["from_version"] == from_version
    assert marker["replace_owned_mismatches"] is True
    assert backup == project / UPDATE_STATE_RELATIVE / "backup" / from_version
    assert (backup / "migration_payload" / smoke.SMOKE_ARCHIVE_NAME).is_file()
    assert (backup / "update_reload_runner.gd").is_file()
    # The supported v3 updater overlays the capsule; it retains the old
    # autoload until the canonical tree replaces it. The capsule is not a
    # standalone add-on and must not grow a second game-helper implementation.
    assert (backup / "runtime/game_helper.gd").read_bytes() == (
        v3_source / "runtime/game_helper.gd"
    ).read_bytes()
    # The v4 plugin registers its own game-helper autoload on start; what #946
    # removed was v3's entry dangling through the migration window. After the
    # crossing the entry must point at a file the live tree actually has.
    project_settings = (project / "project.godot").read_text(encoding="utf-8")
    autoload = re.search(r'_mcp_game_helper="\*?(res://[^"]+)"', project_settings)
    assert autoload is not None, project_settings
    assert autoload.group(1) == "res://addons/godot_ai/runtime/game_helper.gd"
    assert (live / "runtime" / "game_helper.gd").is_file()


def test_final_v3_capsule_restores_final_v3_when_godot_is_too_old(tmp_path: Path) -> None:
    """Below v4's Godot floor the capsule puts the final v3 add-on back, working."""
    godot_bin = godot_bin_or_skip()
    smoke = load_smoke_script()
    target_version = read_plugin_version(PLUGIN_ROOT / "plugin.cfg")
    from_version = "3.2.4"
    http_port, ws_port = allocate_free_ports(2)
    project = tmp_path / "v3-floor-refusal"
    prepared = smoke.prepare_v3_crossing_project(
        project,
        from_version=from_version,
        target_version=target_version,
        http_port=http_port,
        ws_port=ws_port,
    )
    append_driver_autoload(project / "project.godot")
    live = prepared["live"]
    write_driver_support(project)
    (project / "_test_runner_driver.gd").write_text(
        f'''@tool
extends Node

const DriverSupport := preload("res://_test_self_update_driver_support.gd")
const DEADLINE_MSEC := 180000

var _deadline := 0
var _clicked := false


func _ready() -> void:
\tif not Engine.is_editor_hint():
\t\tqueue_free()
\t\treturn
\t_deadline = Time.get_ticks_msec() + DEADLINE_MSEC
\tset_process(true)


func _process(_delta: float) -> void:
\tif Time.get_ticks_msec() >= _deadline:
\t\tpush_error("V3_FALLBACK_TEST | restore timed out")
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
\tif FileAccess.file_exists("res://addons/godot_ai/migration_bridge.gd"):
\t\treturn
\tvar config := ConfigFile.new()
\tif config.load("res://addons/godot_ai/plugin.cfg") != OK:
\t\treturn
\tif str(config.get_value("plugin", "version", "")) != "{smoke.FINAL_V3_REF.lstrip("v")}":
\t\treturn
\tif DriverSupport.find_godot_ai_plugin() == null:
\t\treturn
\tprint("V3_FALLBACK_TEST | final v3 restored and enabled")
\tget_tree().quit(0)
''',
        encoding="utf-8",
    )
    environment = smoke.godot_child_environment(project)
    # The restored final v3 is pristine: keep its server launch off the network.
    shim_root = project / ".floor-smoke"
    shim_root.mkdir()
    fake_bin = _write_fake_uvx_shim(shim_root, smoke.smoke_python()).parent
    environment["PATH"] = str(fake_bin) + os.pathsep + os.environ.get("PATH", "")
    environment["GODOT_AI_TEST_GODOT_FLOOR"] = "unmet"

    log = run_godot_editor(
        project, godot_bin, allow_headless=True, timeout=240, environment=environment
    )

    _assert_ordered(
        log,
        (
            "V3_BRIDGE_TEST | clicked final-v3 Update button",
            "MCP | update runner disabling old plugin",
            "Godot AI v4 migration requires Godot 4.7 or newer; bridge remains inactive.",
            "MCP | v3 bridge restored Godot AI v3.2.5; update again on Godot 4.7 or newer",
            "V3_FALLBACK_TEST | final v3 restored and enabled",
        ),
    )
    restored_at = log.index("MCP | v3 bridge restored Godot AI v3.2.5")
    for pattern in (
        "SCRIPT ERROR: Parse Error",
        "ERROR: Failed to load script",
        "Could not resolve script",
    ):
        assert pattern not in log[restored_at:], log[restored_at:]
    assert read_plugin_version(live / "plugin.cfg") == "3.2.5"
    assert (live / "update_reload_runner.gd").is_file(), "final v3 keeps its own updater"
    for capsule_only in (
        "migration_bridge.gd",
        "migration_coordinator.gd",
        "migration_fallback.gd",
        "migration_payload",
        "utils/update_installer.gd",
        "utils/release_verifier.gd",
    ):
        assert not (live / capsule_only).exists(), capsule_only
    assert not (project / UPDATE_STATE_RELATIVE).exists(), "nothing was staged or swapped"


def test_tampered_tree_after_swap_is_rolled_back_and_restarted(tmp_path: Path) -> None:
    """A swap whose live tree does not hash as expected restores the backup."""
    godot_bin = godot_bin_or_skip()
    smoke = load_smoke_script()
    project = tmp_path / "rolled-back-update"
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
    write_post_restart_driver(project, http_port=http_port, expected_version=base_version)
    live = project / "addons" / "godot_ai"
    patch_restart_diagnostics(live, project / RESTARTED_EDITOR_LOG)
    environment, capability_dir = _isolated_environment(project / ".self-update-integration")

    # Simulate the instant after step 7 of docs/self-update.md: the previous
    # tree is retained as the backup and the marker says a swap happened, but
    # the tree now live does not hash to what the manifest promised.
    state = project / UPDATE_STATE_RELATIVE
    backup = state / "backup" / base_version
    shutil.copytree(live, backup)
    (state / ".gdignore").write_text("", encoding="utf-8")
    (state / ".gitignore").write_text("*\n", encoding="utf-8")
    (live / "plugin.gd").write_text(
        (live / "plugin.gd").read_text(encoding="utf-8") + "\n# tampered after the swap\n",
        encoding="utf-8",
    )
    marker = {
        "status": "swapped",
        "from_version": base_version,
        "to_version": next_version,
        "manifest_sha256": hashlib.sha256(b"fixture manifest").hexdigest(),
        "expected_tree_sha256": hashlib.sha256(b"not the tree that is live").hexdigest(),
        "editor_nonce": secrets.token_hex(16),
        "replace_owned_mismatches": False,
        "backup_root": f"res://addons/.godot_ai_update/backup/{base_version}",
        "live_root": "res://addons/godot_ai",
        "swapped_unix": 0,
    }
    (state / "pending.json").write_text(json.dumps(marker, indent=2) + "\n", encoding="utf-8")

    log = run_godot_editor(
        project,
        godot_bin,
        allow_headless=True,
        timeout=240,
        environment=environment,
        live_probe=lambda: _authenticated_tool_probe(
            http_port,
            capability_dir,
            resource_path="res://_test_rollback_probe.txt",
            content="rolled back authenticated write\n",
        ),
        restart_completion_file=POST_UPDATE_COMPLETE_FILE,
    )

    initial_editor, restarted_editor = read_editor_receipts(project)
    assert initial_editor["pid"] != restarted_editor["pid"], (initial_editor, restarted_editor)
    _assert_ordered(
        log,
        (
            f"MCP | update to {next_version} failed and the previous version was restored",
            # The restarted editor runs the restored tree and reports the outcome.
            f"MCP | update to {next_version} failed; the previous version is live",
            "MCP | plugin loaded",
            f"POST_RESTART_TEST | live server ready at version {base_version}",
            "POST_RESTART_TEST | authenticated tool probe completed",
        ),
    )
    assert read_plugin_version(live / "plugin.cfg") == base_version
    assert "# tampered after the swap" not in (live / "plugin.gd").read_text(encoding="utf-8")
    quarantine = state / "quarantine" / next_version
    assert "# tampered after the swap" in (quarantine / "plugin.gd").read_text(encoding="utf-8")
    assert not backup.exists()
    assert not (state / "pending.json").exists()
    assert not (state / "lock.json").exists()
    payload = json.loads((project / POST_UPDATE_STATUS_FILE).read_text(encoding="utf-8"))
    assert payload.get("server_version") == base_version
    assert (project / "_test_rollback_probe.txt").read_text(encoding="utf-8") == (
        "rolled back authenticated write\n"
    )
