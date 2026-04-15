"""MCP tools for UI (Control) authoring — HUD, pause menu, upgrade screens, etc."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import ui as ui_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_ui_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def ui_set_anchor_preset(
        ctx: Context,
        path: str,
        preset: str,
        resize_mode: str = "minsize",
        margin: int = 0,
        session_id: str = "",
    ) -> dict:
        """Apply a Control layout preset (anchors and offsets) to a UI node.

        Wraps Godot's Control.set_anchors_and_offsets_preset — the fast way to
        pin a HUD element, panel, pause menu, upgrade draft screen, or game-over
        overlay to an edge, corner, or the full viewport. Much simpler than
        setting anchor_left / anchor_top / anchor_right / anchor_bottom and the
        four offset_* properties one at a time.

        The target node must be a Control (or subclass — Panel, Label, Button,
        Container, VBoxContainer, HBoxContainer, MarginContainer, etc.). Change
        is undoable.

        Args:
            path: Scene path to a Control node (e.g. "/Main/HUD/HealthBar").
            preset: Layout preset name. One of:
                top_left, top_right, bottom_left, bottom_right,
                center_left, center_top, center_right, center_bottom, center,
                left_wide, top_wide, right_wide, bottom_wide,
                vcenter_wide, hcenter_wide, full_rect.
            resize_mode: How the existing size is handled when applying the
                preset. One of: minsize (default — resize to minimum),
                keep_width, keep_height, keep_size.
            margin: Margin in pixels from the anchor edges. Default 0.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await ui_handlers.ui_set_anchor_preset(
            runtime,
            path=path,
            preset=preset,
            resize_mode=resize_mode,
            margin=margin,
        )
