"""V4 source contracts for explicit, capability-bound server replacement."""

from __future__ import annotations

import os
import runpy
import stat
import tempfile
from pathlib import Path

import pytest

from godot_ai.transport.capability import record_path
from tests.unit._gdscript_text import get_func_block

ROOT = Path(__file__).resolve().parents[2]
PLUGIN = ROOT / "plugin" / "addons" / "godot_ai"
LIFECYCLE = PLUGIN / "utils" / "server_lifecycle.gd"
PORT_RESOLVER = PLUGIN / "utils" / "port_resolver.gd"
STALE_SERVER_SMOKE = ROOT / "script" / "ci-stale-server-smoke"


def _lifecycle() -> str:
    return LIFECYCLE.read_text(encoding="utf-8")


@pytest.mark.skipif(os.name == "nt", reason="POSIX temporary-root contract")
def test_stale_server_smoke_uses_a_capability_safe_temp_root() -> None:
    module = runpy.run_path(str(STALE_SERVER_SMOKE))
    parent = module["secure_capability_temp_parent"]()
    info = parent.lstat()

    assert parent in {Path("/private/tmp"), Path("/tmp"), Path("/var/tmp")}
    assert stat.S_ISDIR(info.st_mode)
    assert not stat.S_ISLNK(info.st_mode)
    assert info.st_uid == 0
    assert stat.S_IMODE(info.st_mode) & stat.S_ISVTX
    with tempfile.TemporaryDirectory(prefix="godot-ai-capability-test-", dir=parent) as raw:
        assert record_path(18128, Path(raw)).parent == Path(raw)


def test_stale_server_smoke_accepts_setup_godot_launcher_env(monkeypatch, tmp_path) -> None:
    launcher = tmp_path / "godot"
    launcher.touch()
    for name in ("GODOT_BIN", "GODOT4_BIN", "GODOT4"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setenv("GODOT", str(launcher))

    module = runpy.run_path(str(STALE_SERVER_SMOKE))

    assert module["find_godot"]() == str(launcher)


@pytest.mark.skipif(os.name == "nt", reason="POSIX override contract")
def test_stale_server_smoke_passes_the_exact_capability_override(monkeypatch, tmp_path) -> None:
    module = runpy.run_path(str(STALE_SERVER_SMOKE))
    monkeypatch.setenv("GODOT_AI_CAPABILITY_DIR", str(tmp_path))
    assert module["capability_directory"]() == tmp_path
    assert module["editor_environment"](tmp_path)["GODOT_AI_CAPABILITY_DIR"] == str(tmp_path)


def test_stale_server_smoke_proves_its_fixture_bound_before_starting_godot() -> None:
    source = STALE_SERVER_SMOKE.read_text(encoding="utf-8")
    run = source[
        source.index("def run_occupant_mode(") : source.index("async def reload_and_probe(")
    ]

    assert run.index("wait_for_log(occupant_log, OCCUPANT_READY_MARKER") < run.index(
        "start_editor("
    )


def test_stale_server_requires_a_fresh_explicit_replacement_action() -> None:
    source = _lifecycle()
    start = get_func_block(source, "func start_server() -> void:")
    request = get_func_block(source, "func request_replacement() -> bool:")

    assert "request_replacement" not in start
    assert "authorize_replacement(now) and replace_authorized(now)" in request
    for deleted_loop_state in (
        "_stale_recovery_budget",
        "_refresh_retried",
        "authorize_stale_recovery",
        "readopt",
    ):
        assert deleted_loop_state not in source


def test_lifecycle_worker_uses_the_main_thread_capability_path_snapshot() -> None:
    plugin = (PLUGIN / "plugin.gd").read_text(encoding="utf-8")
    lifecycle = _lifecycle()
    capture = get_func_block(plugin, "func _capture_lifecycle_plan() -> Dictionary:")
    read = get_func_block(lifecycle, "func _read_capability(port: int) -> Dictionary:")

    assert '"capability_path": str(policy.get("capability_path", ""))' in capture
    assert '_endpoint_policy["capability_path"] = TransportCapability.path_for_http_port(' in plugin
    assert 'str(_endpoint_policy.get("capability_path", ""))' in plugin
    assert 'str(_plan.get("capability_path", ""))' in read
    assert lifecycle.count("var capability := _read_capability(port)") == 4
    assert "var final_capability := _read_capability(port)" in lifecycle


def test_owned_launch_waits_boundedly_for_a_stable_branded_process_grant() -> None:
    source = _lifecycle()
    launch = get_func_block(source, "func _effect_launch(payload: Dictionary) -> Dictionary:")

    assert "const LAUNCH_FINGERPRINT_TIMEOUT_MS := 15_000" in source
    assert "Time.get_ticks_msec() + LAUNCH_FINGERPRINT_TIMEOUT_MS" in launch
    assert "capture_process_kill_grant(pid, true)" in launch
    assert (
        "while exact_grant.is_empty() and Time.get_ticks_msec() < fingerprint_deadline:"
        in launch
    )
    assert '"reason": "launch_unproven" if fingerprint.is_empty() else ""' in launch
    assert "kill_exact_processes" not in launch


def test_windows_fingerprint_has_a_reuse_resistant_non_cim_fallback() -> None:
    source = (PLUGIN / "utils" / "port_resolver.gd").read_text(encoding="utf-8")
    block = get_func_block(source, "static func process_fingerprint(pid: int) -> String:")

    assert "Get-CimInstance Win32_Process" in block
    assert "Get-Process -Id %d -ErrorAction Stop" in block
    assert ".StartTime.ToFileTimeUtc()" in block
    assert '(str(pid) + "|" + identity)' in block


def test_replacement_is_bound_to_status_instance_and_exact_process() -> None:
    source = _lifecycle()
    block = get_func_block(source, "func _effect_replace(payload: Dictionary) -> Dictionary:")

    assert block.count("_replacement_target_matches") >= 2
    assert "candidates.size() != 1" in block
    assert "process_fingerprint(pid)" in block
    assert "PortResolver.process_fingerprint(pid) != fingerprint" in block
    assert '"pid": pid, "fingerprint": fingerprint' in block
    assert "kill_exact_processes(" in block


def test_status_probe_is_authenticated_and_instance_pinned() -> None:
    source = _lifecycle()
    probe = get_func_block(
        source,
        "static func _probe_with_capability("
        "port: int, capability: Dictionary, timeout_ms: int) -> Dictionary:",
    )
    match = get_func_block(
        source,
        "static func _authenticated_status_matches_record("
        "live: Dictionary, capability: Dictionary) -> bool:",
    )

    assert '"Authorization: Bearer %s" % http_capability' in probe
    assert "MAX_STATUS_BODY_BYTES" in probe
    assert 'result.error = "response_too_large"' in probe
    assert 'live.get("instance_id", "")' in match
    assert 'capability.get("instance_nonce", "")' in match


def test_owned_launch_mints_transport_only_from_the_final_compatible_probe() -> None:
    source = _lifecycle()
    prove = get_func_block(source, "func _effect_prove(payload: Dictionary) -> Dictionary:")

    assert 'var final_version := str(final_live.get("version", ""))' in prove
    assert 'var final_ws_port := int(final_live.get("ws_port", 0))' in prove
    assert '"version": final_version' in prove
    assert "_transport_from(port, final_ws_port, final_live, final_capability)" in prove
    assert '"reason": "listener_pid"' in prove
    assert '"reason": "final_capture_window"' in prove


def test_lifecycle_has_one_episode_and_no_generic_host_edge() -> None:
    source = _lifecycle()
    assert "var _episode: Dictionary" in source
    assert "_host." not in source
    assert "var _host" not in source
    assert "effect_requested(episode_id" in source


def test_lifecycle_logs_only_proven_owned_start_stop_or_explicit_adoption() -> None:
    source = _lifecycle()
    stopped = get_func_block(source, "func _finish_stop() -> void:")
    ready = get_func_block(
        source,
        "func _ready(kind: String, transport, version: String) -> void:",
    )

    assert 'print("MCP | stopped server (PID %d)" % stopped_pid)' in stopped
    assert stopped.index("_episode = _dormant_episode") < stopped.index(
        'print("MCP | stopped server'
    )
    assert 'if kind == "owned":' in ready
    assert 'print("MCP | started server (PID %d)" % get_server_pid())' in ready
    assert 'elif kind == "adopted":' in ready
    assert 'print("MCP | adopted external server")' in ready


def test_root_starts_only_after_lifecycle_configuration() -> None:
    plugin = (PLUGIN / "plugin.gd").read_text(encoding="utf-8")
    compose = get_func_block(
        plugin,
        "func _continue_enter_tree_after_update_barrier() -> void:",
    )
    release = get_func_block(plugin, "func _release_normal_startup() -> void:")
    assert "_lifecycle.configure(_capture_lifecycle_plan())" in compose
    assert "_begin_startup_release()" in compose
    assert compose.index("_lifecycle.configure") < compose.index("_begin_startup_release()")
    assert "_start_server()" not in compose
    assert "_start_server()" in release


def test_export_plugin_is_constructed_after_post_restart_verification() -> None:
    """A swapped tree proves itself in `_enter_tree` before any plugin object is built."""

    plugin = (PLUGIN / "plugin.gd").read_text(encoding="utf-8")
    enter = get_func_block(plugin, "func _enter_tree() -> void:")
    compose = get_func_block(
        plugin,
        "func _continue_enter_tree_after_update_barrier() -> void:",
    )

    assert "ExportPlugin.new()" not in enter
    assert "_continue_enter_tree_after_update_barrier()" in enter
    assert enter.index("UpdateInstaller.verify_after_restart(") < enter.index(
        "_continue_enter_tree_after_update_barrier()"
    )
    assert compose.index("ExportPlugin.new()") < compose.index(
        "_mcp_disabled_for_headless_launch()"
    )


def test_developer_restart_uses_only_lifecycle_process_authority() -> None:
    plugin = (PLUGIN / "plugin.gd").read_text(encoding="utf-8")
    restart = get_func_block(
        plugin,
        "func restart_or_start_managed_server() -> bool:",
    )

    assert "if has_managed_server():" in restart
    assert "_lifecycle.force_restart_server()" in restart
    assert "PortResolver.is_port_in_use(port)" in restart
    assert "refusing to restart the unowned server" in restart
    assert "_lifecycle.start_server()" in restart
    assert "kill_exact_processes" not in restart


def test_process_kill_boundary_revalidates_exact_identity_without_child_heuristics() -> None:
    source = PORT_RESOLVER.read_text(encoding="utf-8")
    kill = get_func_block(
        source,
        "static func kill_exact_processes(",
    )

    assert "process_fingerprint(pid) != fingerprint" in kill
    assert "require_brand and not pid_cmdline_is_godot_ai(pid)" in kill
    assert 'taskkill", ["/PID", str(pid), "/T", "/F"]' in kill
    assert "not require_tree_proof and not pid_alive(pid)" in kill
    assert "find_windows_spawn_children" not in source
