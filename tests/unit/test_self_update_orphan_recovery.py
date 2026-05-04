"""Source-structure regression tests for self-update orphan recovery."""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_GD = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai" / "plugin.gd"


def test_recover_incompatible_success_unblocks_existing_connection() -> None:
    source = PLUGIN_GD.read_text()
    recover_block = get_func_block(source, "func recover_incompatible_server() -> bool:")
    resume_block = get_func_block(source, "func _resume_connection_after_recovery() -> void:")

    assert "_start_server()" in recover_block
    assert "_resume_connection_after_recovery()" in recover_block
    assert recover_block.index("_start_server()") < recover_block.index(
        "_resume_connection_after_recovery()"
    )

    # `SpawnState` is the script-local preload alias for `McpSpawnState`
    # (self-update parse-hazard policy in `plugin.gd`; see #244 / #294).
    assert "_spawn_state != SpawnState.OK or _connection_blocked" in resume_block
    assert "_connection.connect_blocked = false" in resume_block
    assert '_connection.connect_block_reason = ""' in resume_block
    assert '_connection.server_version = ""' in resume_block
    assert "_connection.set_process(true)" in resume_block
    assert "_arm_server_version_check()" in resume_block


def test_status_probe_reads_response_body_only_after_headers() -> None:
    source = PLUGIN_GD.read_text()
    probe_block = get_func_block(
        source,
        "static func _probe_live_server_status(port: int, timeout_ms: int = "
        "SERVER_STATUS_PROBE_TIMEOUT_MS) -> Dictionary:",
    )
    response_loop = probe_block.split("while true:", 1)[1].split("var response_code", 1)[0]
    requesting_branch = response_loop.split("if status == HTTPClient.STATUS_REQUESTING:", 1)[
        1
    ].split("elif status == HTTPClient.STATUS_BODY:", 1)[0]
    body_branch = response_loop.split("elif status == HTTPClient.STATUS_BODY:", 1)[1].split(
        "elif status == HTTPClient.STATUS_CONNECTED:", 1
    )[0]

    assert "client.poll()" in requesting_branch
    assert "read_response_body_chunk" not in requesting_branch
    assert "read_response_body_chunk" in body_branch
