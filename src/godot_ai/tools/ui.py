"""MCP tool for UI (Control) authoring.

Absorbs ``control_draw_recipe`` (vector decoration on Controls) as
``draw_recipe`` op since it operates on Control nodes.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import control as control_handlers
from godot_ai.handlers import ui as ui_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
UI / Control authoring (HUD, menus, layouts, vector decoration).

Ops:
  • set_anchor_preset(path, preset, resize_mode="minsize", margin=0)
        Apply a Control layout preset. preset: top_left | top_right |
        bottom_left | bottom_right | center_left | center_top | center_right |
        center_bottom | center | left_wide | top_wide | right_wide |
        bottom_wide | vcenter_wide | hcenter_wide | full_rect.
        resize_mode: minsize | keep_width | keep_height | keep_size.
        Target must be a Control. CanvasLayer is the canonical HUD parent
        but is not a Control — put a Control child under the CanvasLayer and
        apply the preset to that overlay.
  • set_text(path, text)
        Set text on a Label/Button/LineEdit/TextEdit/RichTextLabel.
  • build_layout(tree, parent_path="")
        Atomically build a UI subtree from a nested spec
        ({type, name?, properties?, anchor_preset?, anchor_margin?, theme?,
        children?}). Validates everything before mutating.
        `properties` is direct node properties only. Theme constants like
        container spacing live under `theme_override_constants/<name>` —
        e.g. `{"theme_override_constants/separation": 8}` on a
        VBoxContainer, not `{"separation": 8}` (which errors).
        `theme` and `anchor_preset` require a Control / Window — for a HUD,
        nest a Control under a CanvasLayer and apply them to the Control
        child, not the layer itself.
  • draw_recipe(path, ops, clear_existing=True)
        Attach a declarative list of vector _draw() ops to a Control —
        radar sweeps, gauges, corner brackets, crosshairs, waveforms.
        Op kinds: line | rect | arc | circle | polyline | polygon | string.
"""


def register_ui_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="ui_manage",
        description=_DESCRIPTION,
        ops={
            "set_anchor_preset": ui_handlers.ui_set_anchor_preset,
            "set_text": ui_handlers.ui_set_text,
            "build_layout": ui_handlers.ui_build_layout,
            "draw_recipe": control_handlers.control_draw_recipe,
        },
    )
