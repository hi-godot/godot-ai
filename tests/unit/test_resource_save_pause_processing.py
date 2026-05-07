"""Regression test for #288 — re-entrant ResourceSaver.save crash.

`ResourceSaver.save()` can pump `Main::iteration()` while it scans for
script-class changes. If `McpConnection._process()` runs during that pump,
the dispatcher re-enters and may dispatch another command that also calls
`save_to_disk` -> tries to add the same `update_scripts_classes` editor
task -> "Task already exists" -> null deref -> SIGSEGV. Same family as
godotengine/godot#118545.

Mitigation mirrors the pattern `SceneHandler` / `ProjectHandler` already
use around `EditorInterface.save_scene*` and `play_*scene*`: flip
`McpConnection.pause_processing = true` while the editor pumps, so the
WebSocket pump short-circuits in `_process` (`connection.gd:55-57`).

The structural assertions below lock the wrap into place. If a future
refactor drops `pause_target` from `save_to_disk` or stops threading
`_connection` through any of the four resource-saving handlers, the test
fails with a pointer to this file.
"""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def test_save_to_disk_takes_pause_target() -> None:
    source = (PLUGIN_ROOT / "utils" / "resource_io.gd").read_text(encoding="utf-8")
    block = get_func_block(source, "static func save_to_disk(")
    assert "pause_target: McpConnection" in block, (
        "save_to_disk must accept a McpConnection so the WebSocket pump "
        "can be paused while ResourceSaver.save() runs. Without this, a "
        "queued command landing during the editor's progress-UI pump "
        "re-enters the dispatcher and crashes Godot. See #288."
    )
    assert "pause_target.pause_processing = true" in block, (
        "Before the ResourceSaver.save() call, save_to_disk must flip "
        "pause_processing on. Otherwise the re-entrancy mitigation isn't "
        "in effect."
    )
    assert "pause_target.pause_processing = false" in block, (
        "After the ResourceSaver.save() call, save_to_disk must flip "
        "pause_processing back off, otherwise the dispatcher stays silent "
        "for the rest of the session."
    )

    # Order: pause -> save -> unpause. A naive refactor that re-orders
    # these would silently neuter the guard.
    pause_idx = block.index("pause_target.pause_processing = true")
    save_idx = block.index("ResourceSaver.save(res, resource_path)")
    unpause_idx = block.index("pause_target.pause_processing = false")
    assert pause_idx < save_idx < unpause_idx, (
        f"Order must be pause -> save -> unpause, got "
        f"pause={pause_idx}, save={save_idx}, unpause={unpause_idx}"
    )


def test_resource_handler_threads_connection_to_save() -> None:
    source = (PLUGIN_ROOT / "handlers" / "resource_handler.gd").read_text(encoding="utf-8")
    assert "var _connection: McpConnection" in source, (
        "ResourceHandler must hold a McpConnection ref to thread into save_to_disk. See #288."
    )
    assert "_init(undo_redo: EditorUndoRedoManager, connection: McpConnection" in source, (
        "ResourceHandler._init must accept a McpConnection — the existing "
        "pattern from SceneHandler / ProjectHandler. plugin.gd passes it."
    )
    save_block = get_func_block(source, "func _save_created_resource")
    assert "_connection)" in save_block or "_connection," in save_block, (
        "_save_created_resource must pass _connection to "
        "McpResourceIO.save_to_disk. Otherwise the pause guard is a no-op "
        "for create_resource calls."
    )


def test_curve_handler_threads_connection_to_save() -> None:
    source = (PLUGIN_ROOT / "handlers" / "curve_handler.gd").read_text(encoding="utf-8")
    assert "var _connection: McpConnection" in source
    assert "_init(undo_redo: EditorUndoRedoManager, connection: McpConnection" in source
    set_points_block = get_func_block(source, "func set_points")
    assert "save_to_disk(" in set_points_block
    # Slice from save_to_disk( through the next return / line break out of
    # the call. _connection must appear in that range.
    after_save = set_points_block.split("save_to_disk(", 1)[1].split("\n\n", 1)[0]
    assert "_connection" in after_save, (
        "curve_handler.set_points must pass _connection to save_to_disk "
        "for the pause guard to take effect. See #288."
    )


def test_environment_handler_threads_connection_to_save() -> None:
    source = (PLUGIN_ROOT / "handlers" / "environment_handler.gd").read_text(encoding="utf-8")
    assert "var _connection: McpConnection" in source
    assert "_init(undo_redo: EditorUndoRedoManager, connection: McpConnection" in source
    save_block = get_func_block(source, "func _save_environment")
    assert "_connection)" in save_block or "_connection," in save_block, (
        "_save_environment must thread _connection to save_to_disk. See #288."
    )


def test_texture_handler_threads_connection_to_save() -> None:
    source = (PLUGIN_ROOT / "handlers" / "texture_handler.gd").read_text(encoding="utf-8")
    assert "var _connection: McpConnection" in source
    assert "_init(undo_redo: EditorUndoRedoManager, connection: McpConnection" in source
    # The save call lives inside _save_or_assign_texture in this handler;
    # locate the save_to_disk call and assert _connection is in the args.
    save_idx = source.index("McpResourceIO.save_to_disk(tex,")
    save_call = source[save_idx : source.index(")", save_idx) + 1]
    assert "_connection" in save_call, (
        "texture_handler must pass _connection to save_to_disk. See #288."
    )


def test_plugin_passes_connection_to_resource_handlers() -> None:
    source = (PLUGIN_ROOT / "plugin.gd").read_text(encoding="utf-8")
    # All four resource-saving handlers must be constructed with _connection,
    # otherwise the pause guard inside save_to_disk silently no-ops.
    for handler in ("ResourceHandler", "EnvironmentHandler", "TextureHandler", "CurveHandler"):
        assert f"{handler}.new(get_undo_redo(), _connection)" in source, (
            f"plugin.gd must construct {handler} with _connection. Without "
            f"the connection ref, save_to_disk's pause guard can't fire and "
            f"the editor crashes under load. See #288."
        )


def test_scene_handler_pause_pattern_still_present_for_reference() -> None:
    """The SceneHandler pattern is the precedent for the resource-save fix.

    If this test ever fails, the resource-save fix is now an orphan
    pattern and the issue #288 fix should be re-evaluated.
    """
    source = (PLUGIN_ROOT / "handlers" / "scene_handler.gd").read_text(encoding="utf-8")
    assert "_connection.pause_processing = true" in source
    assert "_connection.pause_processing = false" in source
