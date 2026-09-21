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

Stylebox numeric fields (border widths, corner radii, margins, shadow) must be
finite numbers and stylebox flags (anti_aliasing, draw_center) must be real
booleans; a non-numeric or non-finite value is refused with a structured error
before anything is applied, so a refused call leaves the theme and undo history
untouched.

Slot changes are persisted immediately: if the theme file cannot be written the
call fails with an error, the previous slot is restored, and no undo entry is
committed.

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
  • set_stylebox_texture(theme_path, class_name, name, texture_path,
                          region?, margins?, axis_stretch_horizontal?,
                          axis_stretch_vertical?, modulate_color?, draw_center?)
        Compose a 9-slice StyleBoxTexture from an imported image — pixel-art
        buttons and artwork-backed panels. region is {position, size} or
        [x,y,w,h]; margins are {all|left|top|right|bottom}; axis stretch modes
        are "stretch" | "tile" | "tile_fit".
  • set_font(theme_path, class_name, name, font_path)
        Assign a Font resource (FontFile .ttf/.otf, FontVariation) to a font
        slot. Loads the imported resource from res://.
  • set_icon(theme_path, class_name, name, texture_path)
        Assign a Texture2D to an icon slot (checkbox marks, dropdown arrows).
  • stylebox_override(path, slot, patch)
        Per-node stylebox override: duplicate the stylebox the Control
        resolves for `slot`, apply a StyleBoxFlat patch (same keys as
        set_stylebox_flat; unknown top-level keys are refused), and attach it
        via add_theme_stylebox_override. The action lands in the scene's undo
        history, so the editor's scene undo restores the previous override or
        removes it. The zero-border angular-frame / flash-the-bar-bg pattern
        without mutating the theme.
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
            "set_stylebox_texture": theme_handlers.theme_set_stylebox_texture,
            "set_font": theme_handlers.theme_set_font,
            "set_icon": theme_handlers.theme_set_icon,
            "stylebox_override": theme_handlers.theme_stylebox_override,
            "apply": theme_handlers.theme_apply,
        },
    )
