"""Source-structure regression tests for the create_script -> attach_script
import-settle fix (issue #261).

Without this guard, an agent that calls `script_create` followed immediately
by `script_attach` for the same `.gd` file races the editor's filesystem
scan: `ResourceLoader.exists(path)` can return false while Godot is still
recognising the new resource. The fix is to defer the `script_create`
response until either the resource is visible or a bounded settle window
elapses, so a successful response means an immediate `script_attach` will
succeed.

These tests pin the structure so a future refactor can't silently regress
the guarantee.
"""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
SCRIPT_HANDLER = PLUGIN_ROOT / "handlers" / "script_handler.gd"
PLUGIN_GD = PLUGIN_ROOT / "plugin.gd"


def test_script_handler_holds_connection_for_deferred_replies() -> None:
    """ScriptHandler needs an McpConnection ref to push the deferred response."""
    source = SCRIPT_HANDLER.read_text()

    assert "var _connection: McpConnection" in source, (
        "ScriptHandler must hold an McpConnection so create_script can defer "
        "its reply until the editor's filesystem scan settles. Without this "
        "field a fresh script_create -> script_attach pair races the import "
        "pipeline (issue #261)."
    )
    # _init must accept the connection. Default null keeps batch_execute and
    # unit-test contexts working on the synchronous fallback path.
    expected_init = "func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null)"
    assert expected_init in source, (
        "ScriptHandler._init must accept the connection as an optional "
        "second parameter so test contexts can keep using the sync fallback."
    )


def test_create_script_defers_for_freshly_created_files() -> None:
    """The new-file path returns DEFERRED_RESPONSE; existing-file path replies sync."""
    source = SCRIPT_HANDLER.read_text()

    # The deferred handoff must be guarded by `not existed_before` so that
    # overwriting an already-known resource still returns immediately —
    # ResourceLoader already knows it, no scan to wait for.
    assert "not existed_before and _connection != null and not request_id.is_empty()" in source, (
        "create_script must only defer when the file was newly created AND a "
        "connection is available AND a request_id is present. Overwrites and "
        "batch_execute / unit-test contexts must keep the synchronous reply."
    )
    assert "return McpDispatcher.DEFERRED_RESPONSE" in source, (
        "create_script must return the DEFERRED_RESPONSE sentinel on the "
        "deferred path so the dispatcher skips auto-sending the reply."
    )


def test_finish_create_script_deferred_polls_resourceloader_with_bounded_loop() -> None:
    """The settle loop must be bounded and check ResourceLoader.exists each frame."""
    source = SCRIPT_HANDLER.read_text()

    # The bounded counter prevents an indefinite hang if the editor's
    # filesystem pipeline never reports the new resource.
    assert "_IMPORT_SETTLE_MAX_FRAMES" in source, (
        "The deferred loop must use a named bounded-frame constant so the "
        "wait can't run forever if the filesystem scan stalls."
    )
    assert "_IMPORT_SETTLE_MAX_MSEC := 4500" in source, (
        "The deferred loop must also be capped below the Python client's "
        "default 5s send timeout. A pure 300-frame cap can exceed 5s on a "
        "slow editor frame rate."
    )
    deferred_block = get_func_block(source, "func _finish_create_script_deferred")
    assert "var deadline_ms := Time.get_ticks_msec() + _IMPORT_SETTLE_MAX_MSEC" in deferred_block
    assert "Time.get_ticks_msec() < deadline_ms" in deferred_block
    assert "ResourceLoader.exists(path)" in deferred_block, (
        "The deferred loop must poll ResourceLoader.exists(path) — that's "
        "the precise check script_attach uses, so settling on it gives the "
        "guarantee #261 wants."
    )
    assert "await tree.process_frame" in deferred_block, (
        "The deferred loop must yield via process_frame between polls so the "
        "editor can actually run the import pipeline between checks."
    )
    # The reply must use send_deferred_response with a {"data": ...} payload.
    assert "_connection.send_deferred_response(request_id" in deferred_block, (
        "After settling, the handler must push the response over the "
        "connection's send_deferred_response — the dispatcher won't do it."
    )
    # Match the project_handler.stop_project pattern: drop the response if
    # the plugin tore down during the await.
    assert "is_instance_valid(_connection)" in deferred_block, (
        "If _exit_tree fires during the await the connection is freed; the "
        "deferred reply must check is_instance_valid and bail silently."
    )


def test_plugin_gd_passes_connection_to_script_handler() -> None:
    """plugin.gd must wire _connection into ScriptHandler — the field is null otherwise."""
    source = PLUGIN_GD.read_text()

    assert "ScriptHandler.new(get_undo_redo(), _connection)" in source, (
        "plugin.gd must construct ScriptHandler with the connection so the "
        "deferred-reply path is reachable in production. Without this, every "
        "create_script falls back to the synchronous reply and #261 returns."
    )
