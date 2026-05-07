"""Source-structure regression tests for self-update orphan recovery."""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_GD = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai" / "plugin.gd"


def test_recover_incompatible_success_unblocks_existing_connection() -> None:
    """Recovery click must respawn the server AND clear the connection block.

    PR 6 (#297) moved the recovery body into McpServerLifecycleManager —
    the plugin shim delegates to `_lifecycle.recover_incompatible_server()`
    (which itself calls `start_server()`), then runs the connection-resume
    here on the plugin side because the resume touches the live
    `McpConnection` instance.
    """

    source = PLUGIN_GD.read_text(encoding="utf-8")
    recover_block = get_func_block(source, "func recover_incompatible_server() -> bool:")
    resume_block = get_func_block(source, "func _resume_connection_after_recovery() -> void:")
    lifecycle_source = (
        Path(__file__).resolve().parents[2]
        / "plugin"
        / "addons"
        / "godot_ai"
        / "utils"
        / "server_lifecycle.gd"
    ).read_text(encoding="utf-8")
    lifecycle_recover_block = get_func_block(
        lifecycle_source, "func recover_incompatible_server() -> bool:"
    )

    assert "_lifecycle.recover_incompatible_server()" in recover_block
    assert "_resume_connection_after_recovery()" in recover_block
    assert recover_block.index("_lifecycle.recover_incompatible_server()") < recover_block.index(
        "_resume_connection_after_recovery()"
    )

    # Manager-side: respawn happens here, after the kill drains.
    assert "start_server()" in lifecycle_recover_block

    assert "state != ServerStateScript.SPAWNING" in resume_block
    assert "state != ServerStateScript.READY" in resume_block
    assert "_lifecycle.is_connection_blocked()" in resume_block
    assert "_connection.connect_blocked = false" in resume_block
    assert '_connection.connect_block_reason = ""' in resume_block
    assert '_connection.server_version = ""' in resume_block
    assert "_connection.set_process(true)" in resume_block
    assert "_arm_server_version_check()" in resume_block


def test_status_probe_reads_response_body_only_after_headers() -> None:
    source = PLUGIN_GD.read_text(encoding="utf-8")
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
