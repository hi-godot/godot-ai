"""Source-level contracts for Camera2D current-state flake guards."""

from __future__ import annotations

from pathlib import Path

from tests.unit._gdscript_text import get_func_block

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"
CAMERA_HANDLER_PATH = PLUGIN_ROOT / "handlers" / "camera_handler.gd"


def test_current_switch_undo_captures_logical_or_effective_current() -> None:
    """The undo action must restore the logical/viewport current camera.

    Headless editor CI has repeatedly observed Camera2D.is_current() and the
    viewport camera slot disagreeing for a short window. On current beta, the
    handler also keeps logical-current bookkeeping. If current-switch undo
    captures the previous camera using only is_current(), it can miss the real
    current camera and record "clear new camera" instead of "make old camera
    current", leaving the new camera active after undo.
    """

    source = CAMERA_HANDLER_PATH.read_text()
    switch_block = get_func_block(
        source,
        "func _add_make_current_to_action(node: Node, type_str: String, scene_root: Node) -> void:",
    )
    assert "_resolve_current(scene_root, cam)" in switch_block
    assert "if _is_current(cam):" not in switch_block


def test_configure_current_false_uses_authoritative_current_guard() -> None:
    source = CAMERA_HANDLER_PATH.read_text()
    configure_block = get_func_block(source, "func configure(params: Dictionary) -> Dictionary:")
    assert "var was_on: bool = _resolve_current(scene_root, node)" in configure_block


def test_camera_reads_still_route_through_logical_current_resolvers() -> None:
    source = CAMERA_HANDLER_PATH.read_text()
    get_block = get_func_block(source, "func get_camera(params: Dictionary) -> Dictionary:")
    list_block = get_func_block(source, "func list_cameras(_params: Dictionary) -> Dictionary:")
    assert "_resolve_current(scene_root, node)" in get_block
    assert "_resolve_current_with_logicals(cam, logical_2d, logical_3d)" in list_block
