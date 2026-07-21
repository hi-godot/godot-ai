"""Source-structure regression tests for the create_script -> attach_script
import-settle fix (issue #261), extended to write_file's fresh-`.gd` path
(#714).

Without this guard, an agent that calls `script_create` (or `write_file` on a
`.gd` path) followed immediately by `script_attach` for the same file races
the editor's filesystem scan: `ResourceLoader.exists(path)` can return false
while Godot is still recognising the new resource. The fix is to defer the
response until either the resource is visible or a bounded settle window
elapses, so a successful response means an immediate `script_attach` will
succeed. The shared machinery lives on McpResourceIO
(`utils/resource_io.gd::finish_text_write_deferred`) so the two handlers
can't drift apart.

These tests pin the structure so a future refactor can't silently regress
the guarantee.
"""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
SCRIPT_HANDLER = PLUGIN_ROOT / "handlers" / "script_handler.gd"
FILESYSTEM_HANDLER = PLUGIN_ROOT / "handlers" / "filesystem_handler.gd"
RESOURCE_IO = PLUGIN_ROOT / "utils" / "resource_io.gd"
PLUGIN_GD = PLUGIN_ROOT / "plugin.gd"


def test_handlers_hold_connection_for_deferred_replies() -> None:
    """Both handlers need an McpConnection ref to push the deferred response."""
    script_source = SCRIPT_HANDLER.read_text(encoding="utf-8")
    fs_source = FILESYSTEM_HANDLER.read_text(encoding="utf-8")

    assert "var _connection: McpConnection" in script_source, (
        "ScriptHandler must hold an McpConnection so create_script can defer "
        "its reply until the editor's filesystem scan settles. Without this "
        "field a fresh script_create -> script_attach pair races the import "
        "pipeline (issue #261)."
    )
    # _init must accept the connection. Default null keeps batch_execute and
    # unit-test contexts working on the synchronous fallback path.
    expected_init = "func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null)"
    assert expected_init in script_source, (
        "ScriptHandler._init must accept the connection as an optional "
        "second parameter so test contexts can keep using the sync fallback."
    )
    assert "var _connection: McpConnection" in fs_source, (
        "FilesystemHandler must hold an McpConnection so write_file's "
        "fresh-.gd path can defer its reply (#714)."
    )


def test_fresh_writes_defer_and_overwrites_reply_sync() -> None:
    """The new-file paths return DEFERRED_RESPONSE; existing-file paths reply sync."""
    script_source = SCRIPT_HANDLER.read_text(encoding="utf-8")
    fs_source = FILESYSTEM_HANDLER.read_text(encoding="utf-8")

    # The deferred handoff must be guarded by `not existed_before` so that
    # overwriting an already-known resource still returns immediately —
    # ResourceLoader already knows it, no scan to wait for.
    create_guard = "not existed_before and _connection != null and not request_id.is_empty()"
    assert create_guard in script_source, (
        "create_script must only defer when the file was newly created AND a "
        "connection is available AND a request_id is present. Overwrites and "
        "batch_execute / unit-test contexts must keep the synchronous reply."
    )
    assert "return McpDispatcher.DEFERRED_RESPONSE" in script_source, (
        "create_script must return the DEFERRED_RESPONSE sentinel on the "
        "deferred path so the dispatcher skips auto-sending the reply."
    )
    # write_file's deferral must additionally be scoped to .gd paths:
    # ResourceLoader never learns plain text files, so an unconditional wait
    # would burn the full settle window on every fresh .txt write (#714).
    assert (
        "is_gdscript and not existed_before and _connection != null and not request_id.is_empty()"
        in fs_source
    ), (
        "write_file must only defer for freshly-created .gd files with a "
        "connection and request_id present — plain text files and overwrites "
        "keep the synchronous reply (#714)."
    )
    assert "return McpDispatcher.DEFERRED_RESPONSE" in fs_source, (
        "write_file must return the DEFERRED_RESPONSE sentinel on the "
        "deferred fresh-.gd path (#714)."
    )


def test_handlers_share_one_write_and_one_settle_implementation() -> None:
    """#714: the write path and the settle coroutine must not be duplicated."""
    script_source = SCRIPT_HANDLER.read_text(encoding="utf-8")
    fs_source = FILESYSTEM_HANDLER.read_text(encoding="utf-8")

    for name, source in (("create_script", script_source), ("write_file", fs_source)):
        assert "McpResourceIO.write_text_to_disk(path, content)" in source, (
            f"{name} must write through the shared "
            "McpResourceIO.write_text_to_disk helper — a private copy is how "
            "the two paths drifted apart before #714."
        )
        defer_call = "McpResourceIO.finish_text_write_deferred(_connection, request_id, path, data)"
        assert defer_call in source, (
            f"{name} must defer through the shared "
            "McpResourceIO.finish_text_write_deferred coroutine, passing "
            "_connection explicitly (no instance-state capture)."
        )
        assert "FileAccess.open(path, FileAccess.WRITE)" not in source, (
            f"{name} must not keep a private text-write path alongside the "
            "shared helper (#714)."
        )


def test_finish_text_write_deferred_polls_resourceloader_with_bounded_loop() -> None:
    """The settle loop must be bounded and check ResourceLoader.exists each frame."""
    source = RESOURCE_IO.read_text(encoding="utf-8")

    # The bounded counter prevents an indefinite hang if the editor's
    # filesystem pipeline never reports the new resource.
    assert "IMPORT_SETTLE_MAX_FRAMES" in source, (
        "The deferred loop must use a named bounded-frame constant so the "
        "wait can't run forever if the filesystem scan stalls."
    )
    assert "IMPORT_SETTLE_MAX_MSEC := 3500" in source, (
        "The deferred loop must be capped well below the dispatcher's "
        "create_script/write_file deferred timeouts. If this window reaches "
        "the dispatcher timeout, a committed file can still surface to "
        "callers as DEFERRED_TIMEOUT."
    )
    deferred_block = get_func_block(source, "static func finish_text_write_deferred")
    assert "var deadline_ms := Time.get_ticks_msec() + IMPORT_SETTLE_MAX_MSEC" in deferred_block
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
    assert deferred_block.find(
        "var deadline_ms := Time.get_ticks_msec() + IMPORT_SETTLE_MAX_MSEC"
    ) < deferred_block.find("await tree.process_frame"), (
        "The deferred coroutine must start its deadline before the registration "
        "handoff await. Otherwise a slow first frame is outside the bounded "
        "window and a committed write can still hit the dispatcher timeout (#324)."
    )
    # The reply must use send_deferred_response with a {"data": ...} payload.
    assert "connection.send_deferred_response(request_id" in deferred_block, (
        "After settling, the handler must push the response over the "
        "connection's send_deferred_response — the dispatcher won't do it."
    )
    assert 'payload["import_settle"] = "settled" if settled else "timeout"' in deferred_block
    assert 'payload["import_pending"] = not settled' in deferred_block
    # Match the project_handler.stop_project pattern: drop the response if
    # the plugin tore down during the await. The static function takes
    # `connection` explicitly instead of relying on instance state.
    assert "is_instance_valid(connection)" in deferred_block, (
        "If _exit_tree fires during the await the connection is freed; the "
        "deferred reply must check is_instance_valid and bail silently."
    )


def test_writes_report_committed_status_even_when_import_wait_times_out() -> None:
    """A committed file must not be indistinguishable from a failed mutation."""
    script_source = SCRIPT_HANDLER.read_text(encoding="utf-8")
    fs_source = FILESYSTEM_HANDLER.read_text(encoding="utf-8")
    io_source = RESOURCE_IO.read_text(encoding="utf-8")

    assert '"committed": true' in script_source, (
        "create_script writes the file before waiting for ResourceLoader; the "
        "response must expose committed=true so callers know retrying is not a "
        "plain safe retry."
    )
    assert '"import_settle": "already_known" if existed_before else "not_waited"' in script_source
    # write_file mirrors the same fields for .gd paths (#714).
    assert 'data["committed"] = true' in fs_source
    fs_settle_marker = 'data["import_settle"] = "already_known" if existed_before else "not_waited"'
    assert fs_settle_marker in fs_source
    deferred_block = get_func_block(io_source, "static func finish_text_write_deferred")
    assert 'payload["import_settle"] = "settled" if settled else "timeout"' in deferred_block, (
        "Deferred completion must distinguish import success from import-settle "
        "timeout while still returning a success payload for the committed file."
    )
    assert 'payload["import_pending"] = not settled' in deferred_block, (
        "When import settling times out, callers need an explicit import_pending "
        "flag instead of interpreting a transport timeout as write failure."
    )


def test_finish_text_write_deferred_is_static() -> None:
    """Source-pin: the deferred completion must be a `static func`.

    Under concurrent script_create storms (e.g. /tmp/shitstorm2.py) combined
    with editor_reload_plugin firing during the burst, the handler RefCounted
    was being freed mid-await, producing "Resumed function ... after await,
    but class instance is gone" and dropping the deferred response. The fix
    is to declare the coroutine `static` so it captures no `self` reference,
    surviving handler GC. This source check prevents a silent revert.
    """
    source = RESOURCE_IO.read_text(encoding="utf-8")
    assert "static func finish_text_write_deferred(" in source, (
        "finish_text_write_deferred must be declared `static` so the "
        "deferred coroutine doesn't capture self. Without this, a handler "
        "freed mid-await produces 'class instance is gone' errors and drops "
        "the response."
    )
    # And the connection must be passed in explicitly, not pulled from self.
    assert "connection: McpConnection," in source, (
        "The static function must take the connection as an explicit "
        "parameter — referencing self._connection would re-introduce the "
        "implicit `self` capture the static refactor avoids."
    )


def test_dispatcher_grants_write_file_the_settle_timeout_headroom() -> None:
    """write_file's deferral needs the same dispatcher headroom as create_script."""
    dispatcher_source = (PLUGIN_ROOT / "dispatcher.gd").read_text(encoding="utf-8")
    assert '"write_file": 4500' in dispatcher_source, (
        "write_file defers through the 3500ms import-settle window (#714); "
        "without a matching dispatcher timeout entry the default deferred "
        "timeout applies and the headroom contract with "
        "IMPORT_SETTLE_MAX_MSEC is implicit instead of pinned."
    )


def test_plugin_gd_passes_connection_to_handlers() -> None:
    """plugin.gd must wire _connection into both handlers — the field is null otherwise."""
    source = PLUGIN_GD.read_text(encoding="utf-8")

    assert (
        'register_lazy_handler("script", HANDLERS_DIR + "script_handler.gd", '
        "[undo, _connection])"
    ) in source, (
        "plugin.gd must register the script handler with the connection in "
        "its lazy ctor args (#736) so the deferred-reply path is reachable "
        "in production. Without this, every create_script falls back to the "
        "synchronous reply and #261 returns."
    )
    assert (
        'register_lazy_handler("filesystem", '
        'HANDLERS_DIR + "filesystem_handler.gd", [_connection])'
    ) in source, (
        "plugin.gd must register the filesystem handler with the connection "
        "in its lazy ctor args (#736) so write_file's fresh-.gd deferral is "
        "reachable in production (#714)."
    )
