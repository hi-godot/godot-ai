"""MCP tools for Theme authoring — Godot's equivalent of USS stylesheets.

A Theme resource holds (class, name) -> value entries (colors, constants,
font sizes, styleboxes, icons) that cascade down a Control subtree when
assigned at any ancestor. Authoring a theme replaces dozens of per-node
property sets with one reusable stylesheet-like document.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastmcp import Context, FastMCP

from godot_ai.handlers import theme as theme_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_theme_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def theme_create(
        ctx: Context,
        path: str,
        overwrite: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create a new empty Theme resource (.tres) at a res:// path.

        A Theme is Godot's stylesheet-like resource. After creating one,
        use theme_set_color, theme_set_constant, theme_set_font_size, and
        theme_set_stylebox_flat to populate its slots, then theme_apply
        to assign it to a Control subtree.

        Args:
            path: Destination res:// path ending in .tres (e.g.
                "res://ui/themes/cyberpunk.tres").
            overwrite: If true, overwrite any existing theme at that path.
                Default false (errors if the file already exists).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await theme_handlers.theme_create(runtime, path=path, overwrite=overwrite)

    @mcp.tool(meta=DEFER_META)
    async def theme_set_color(
        ctx: Context,
        theme_path: str,
        class_name: str,
        name: str,
        value: Any,
        session_id: str = "",
    ) -> dict:
        """Set a color slot on a Theme (e.g. Label.font_color, Button.font_hover_color).

        Args:
            theme_path: res:// path to the Theme .tres file.
            class_name: Theme type (usually a Control subclass name like
                "Label", "Button", "Panel", "LineEdit").
            name: Color slot name (e.g. "font_color", "font_hover_color",
                "font_disabled_color", "caret_color").
            value: Color as "#rrggbb", "#rrggbbaa", named ("red", "cyan"),
                or {"r": 0.1, "g": 0.1, "b": 0.2, "a": 1.0}.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await theme_handlers.theme_set_color(
            runtime, theme_path=theme_path, class_name=class_name, name=name, value=value
        )

    @mcp.tool(meta=DEFER_META)
    async def theme_set_constant(
        ctx: Context,
        theme_path: str,
        class_name: str,
        name: str,
        value: int,
        session_id: str = "",
    ) -> dict:
        """Set an integer constant on a Theme (spacing, margins, padding).

        Use for layout constants like VBoxContainer.separation,
        MarginContainer.margin_left, GridContainer.h_separation.

        Args:
            theme_path: res:// path to the Theme .tres file.
            class_name: Theme type (e.g. "VBoxContainer", "HBoxContainer",
                "MarginContainer", "GridContainer").
            name: Constant slot name (e.g. "separation", "margin_left",
                "h_separation", "v_separation").
            value: Integer value (pixels).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await theme_handlers.theme_set_constant(
            runtime, theme_path=theme_path, class_name=class_name, name=name, value=value
        )

    @mcp.tool(meta=DEFER_META)
    async def theme_set_font_size(
        ctx: Context,
        theme_path: str,
        class_name: str,
        name: str,
        value: int,
        session_id: str = "",
    ) -> dict:
        """Set a font size slot on a Theme (text size per control class).

        Args:
            theme_path: res:// path to the Theme .tres file.
            class_name: Theme type (e.g. "Label", "Button", "LineEdit",
                "RichTextLabel").
            name: Font size slot name (usually "font_size").
            value: Size in pixels.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await theme_handlers.theme_set_font_size(
            runtime, theme_path=theme_path, class_name=class_name, name=name, value=value
        )

    @mcp.tool(meta=DEFER_META)
    async def theme_set_stylebox_flat(
        ctx: Context,
        theme_path: str,
        class_name: str,
        name: str,
        bg_color: Any = None,
        border_color: Any = None,
        border: Annotated[dict[str, Any] | None, JsonCoerced] = None,
        corners: Annotated[dict[str, Any] | None, JsonCoerced] = None,
        margins: Annotated[dict[str, Any] | None, JsonCoerced] = None,
        shadow: Annotated[dict[str, Any] | None, JsonCoerced] = None,
        anti_aliasing: bool | None = None,
        session_id: str = "",
    ) -> dict:
        """Compose a StyleBoxFlat and assign it to a theme slot.

        StyleBoxFlat is the workhorse styled-rectangle for panels, buttons,
        line edits, etc. One call sets background color, border, rounded
        corners, drop shadow, and content padding — all in a single
        reusable stylebox that the theme applies everywhere the named slot
        is used.

        Common slot names: "normal" (base Button/Panel background), "hover",
        "pressed", "focus", "disabled", "panel" (for Panel / PanelContainer).

        The border/corners/margins/shadow dicts each accept an ``all`` key
        that applies to every side and side-specific keys that override it.
        Omit a dict entirely to leave those StyleBox defaults untouched.

        Args:
            theme_path: res:// path to the Theme .tres file.
            class_name: Theme type (e.g. "Button", "Panel", "PanelContainer",
                "LineEdit").
            name: StyleBox slot name (e.g. "normal", "hover", "pressed",
                "focus", "panel").
            bg_color: Background fill color (hex string, named, or r/g/b/a dict).
            border_color: Border color.
            border: Border widths in pixels. Keys: ``all``, ``top``, ``bottom``,
                ``left``, ``right``. Side-specific keys override ``all``.
                Example: ``{"all": 1, "top": 2}`` → top=2, others=1.
            corners: Corner radii in pixels. Keys: ``all``, ``top_left``,
                ``top_right``, ``bottom_left``, ``bottom_right``.
            margins: Inner content padding in pixels. Keys: ``all``, ``top``,
                ``bottom``, ``left``, ``right``.
            shadow: Drop shadow. Keys: ``color``, ``size`` (blur, px),
                ``offset_x``, ``offset_y``.
            anti_aliasing: Whether to anti-alias borders and corners.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await theme_handlers.theme_set_stylebox_flat(
            runtime,
            theme_path=theme_path,
            class_name=class_name,
            name=name,
            bg_color=bg_color,
            border_color=border_color,
            border=border,
            corners=corners,
            margins=margins,
            shadow=shadow,
            anti_aliasing=anti_aliasing,
        )

    @mcp.tool(meta=DEFER_META)
    async def theme_apply(
        ctx: Context,
        node_path: str,
        theme_path: str = "",
        session_id: str = "",
    ) -> dict:
        """Assign a Theme resource to a Control (cascades to descendants).

        Setting the theme at the top of a UI subtree is the usual pattern:
        one theme applied at /Main/HUD styles every button, label, panel,
        and container inside it. To clear a theme, pass an empty theme_path.

        Args:
            node_path: Scene path to a Control or Window node.
            theme_path: res:// path to the Theme .tres file. Empty string
                clears the theme.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await theme_handlers.theme_apply(runtime, node_path=node_path, theme_path=theme_path)
