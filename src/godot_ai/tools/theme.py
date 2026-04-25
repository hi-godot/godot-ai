"""MCP tool for Theme authoring — Godot's equivalent of USS stylesheets.

A Theme resource holds (class, name) -> value entries (colors, constants,
font sizes, styleboxes, icons) that cascade down a Control subtree when
assigned at any ancestor. Authoring a theme replaces dozens of per-node
property sets with one reusable stylesheet-like document.

Exposed as a single rolled-up tool ``theme_manage`` with ops; see the
tool description for the per-op signatures.
"""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import theme as theme_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Theme authoring (Godot's stylesheet-like resource for Controls). Cascades
down a Control subtree when assigned via theme_apply.

Ops (pass via op="..." plus a params dict):
  • create(path, overwrite=False)
        Create a new empty Theme .tres at a res:// path.
  • set_color(theme_path, class_name, name, value)
        Set a color slot. value: "#rrggbb"/"#rrggbbaa", named, or
        {"r","g","b","a"}.
  • set_constant(theme_path, class_name, name, value)
        Set an integer constant (separation, margin, padding).
  • set_font_size(theme_path, class_name, name, value)
        Set a font_size slot in pixels.
  • set_stylebox_flat(theme_path, class_name, name, bg_color?, border_color?,
                       border?, corners?, margins?, shadow?, anti_aliasing?)
        Compose a StyleBoxFlat (panels, button states, line edits).
        border/corners/margins/shadow each accept "all" + per-side keys.
  • apply(node_path, theme_path="")
        Assign the theme to a Control (cascades to descendants). Empty
        theme_path clears.

All ops accept `session_id` on the wrapper to target a specific editor.
"""


def register_theme_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="theme_manage",
        description=_DESCRIPTION,
        ops={
            "create": theme_handlers.theme_create,
            "set_color": theme_handlers.theme_set_color,
            "set_constant": theme_handlers.theme_set_constant,
            "set_font_size": theme_handlers.theme_set_font_size,
            "set_stylebox_flat": theme_handlers.theme_set_stylebox_flat,
            "apply": theme_handlers.theme_apply,
        },
    )
