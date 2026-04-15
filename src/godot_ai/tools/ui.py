"""MCP tools for UI (Control) authoring — HUD, pause menu, upgrade screens, etc."""

from __future__ import annotations

from typing import Annotated, Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import ui as ui_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


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

    @mcp.tool(meta=DEFER_META)
    async def ui_build_layout(
        ctx: Context,
        tree: Annotated[dict[str, Any], JsonCoerced],
        parent_path: str = "",
        session_id: str = "",
    ) -> dict:
        """Build a UI subtree atomically from a declarative nested spec.

        One call turns a nested description into a fully-constructed,
        configured, themed, anchored Control tree under a parent. Faster
        and more reliable than a sequence of node_create + node_set_property
        + ui_set_anchor_preset + theme_apply calls; everything commits (or
        fails and rolls back) as one undo action. This is the closest thing
        to writing UXML and getting UI back.

        Tree spec (per node):
            type           - Godot class name (required, e.g. "VBoxContainer",
                             "Panel", "Label", "Button", "HBoxContainer",
                             "MarginContainer", "TextureRect").
            name           - Node name (optional).
            properties     - Dict of property -> value (optional). Color values
                             accept hex strings; Vector2 accepts {"x": ,"y": }
                             or [x, y]; strings go to text/icon paths; ints to
                             size_flags_*, separation, etc.
            anchor_preset  - Optional preset name (full_rect, center, top_left,
                             top_wide, right_wide, ...). Applied after properties.
            anchor_margin  - Optional margin in pixels for the anchor preset.
            theme          - Optional res:// path to a Theme; applies to this
                             subtree. Use theme_create + theme_set_* first.
            children       - Optional array of nested child specs.

        Example — a pause menu:
            {
              "type": "Panel", "name": "PauseMenu", "anchor_preset": "full_rect",
              "theme": "res://ui/themes/game.tres",
              "children": [{
                "type": "VBoxContainer", "anchor_preset": "center",
                "properties": {"separation": 16},
                "children": [
                  {"type": "Label", "properties": {"text": "Paused"}},
                  {"type": "Button", "name": "Resume",
                   "properties": {"text": "Resume"}},
                  {"type": "Button", "name": "Quit",
                   "properties": {"text": "Quit"}}
                ]
              }]
            }

        All nodes are validated (types exist, properties exist, res:// paths
        resolve) before any scene mutation. If anything is invalid, no node
        is created. Ctrl+Z in Godot undoes the entire build in one step.

        Args:
            tree: Root node spec (see above). Nested structure supported.
            parent_path: Scene path to attach under. Empty or "/" = scene root.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await ui_handlers.ui_build_layout(
            runtime, tree=tree, parent_path=parent_path
        )
