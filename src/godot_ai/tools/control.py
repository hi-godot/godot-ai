"""MCP tools for Control-node vector decoration.

Use control_draw_recipe when you need a Control to display vector graphics
that go beyond what anchors, nested Controls, or textures produce — radar
sweeps, gauge arcs, corner bracket frames, crosshairs, tick marks, waveform
traces, HUD overlays built out of lines and polygons. One MCP call attaches
a shared DrawRecipe script to the target Control and stores an ordered
list of draw operations in node metadata; the script dispatches each op
inside _draw() every repaint. No disk file is written, no per-node GDScript
is generated, and re-invoking the tool idempotently replaces the op list.

Keywords: vector, draw, gauge, radar, scanline, bracket, crosshair, tick,
waveform, hud, overlay, shape, canvas, line, rect, arc, circle, polyline,
polygon.
"""

from __future__ import annotations

from typing import Annotated

from fastmcp import Context, FastMCP

from godot_ai.handlers import control as control_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META, JsonCoerced


def register_control_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def control_draw_recipe(
        ctx: Context,
        path: str,
        ops: Annotated[list[dict], JsonCoerced],
        clear_existing: bool = True,
        session_id: str = "",
    ) -> dict:
        """Attach a declarative list of vector _draw() ops to a Control node.

        One call produces a vector-decorated widget — radar sweep, gauge,
        corner-bracket frame, crosshair, tick marks, HUD border — without
        authoring or attaching a custom GDScript. Ops persist as node
        metadata ("_ops"); the shared DrawRecipe script at
        res://addons/godot_ai/runtime/draw_recipe.gd replays them in _draw().
        Idempotent: a second call replaces the op list. Single Ctrl+Z
        reverts both the script attach and the metadata in one undo step.

        Coordinates are relative to the Control's local (0,0) — its top-left.

        Supported ops (each a dict with "draw" key plus op-specific fields):

            line       - {"draw": "line", "from": [x,y], "to": [x,y],
                          "color": ..., "width": 1.0, "antialiased": false}
            rect       - {"draw": "rect", "rect": [x,y,w,h] or {x,y,w,h} or
                          {position, size}, "color": ..., "filled": true,
                          "width": 1.0}
            arc        - {"draw": "arc", "center": [x,y], "radius": 40,
                          "start_angle": 0.0, "end_angle": 1.57, "color": ...,
                          "point_count": 32, "width": 2.0,
                          "antialiased": false}
            circle     - {"draw": "circle", "center": [x,y], "radius": 5,
                          "color": ...}
            polyline   - {"draw": "polyline", "points": [[x,y], ...],
                          "color": ..., "width": 1.0, "antialiased": false}
            polygon    - {"draw": "polygon", "points": [[x,y], ...],
                          "color": ... OR "colors": [color, ...]}
            string     - {"draw": "string", "position": [x,y], "text": "...",
                          "color": ..., "font_size": 16, "align": 0,
                          "max_width": -1.0}

        Value coercion:
            Colors accept "#rrggbb", "#rrggbbaa", named strings ("red",
                "magenta", "transparent"), or {"r","g","b","a"?}.
            Points accept {"x","y"} or [x, y].
            Angles are radians.

        Example — draw an L-shaped corner bracket (two lines) on a Panel:
            control_draw_recipe(
                path="/Main/HUD/VitalsPanel",
                ops=[
                    {"draw": "line", "from": [0,0], "to": [18,0],
                     "color": "#00eaff", "width": 2},
                    {"draw": "line", "from": [0,0], "to": [0,18],
                     "color": "#00eaff", "width": 2},
                ],
            )

        Args:
            path: Scene path to a Control node (Panel, ColorRect, Label, …).
            ops: Ordered list of draw op dicts.
            clear_existing: If true (default), replace any existing script on
                the node (except the DrawRecipe script itself, which is always
                replaceable). If false and the node already has a user script,
                the call errors so user-authored code isn't silently lost.
            session_id: Optional Godot session to target. Empty = active.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await control_handlers.control_draw_recipe(
            runtime, path=path, ops=ops, clear_existing=clear_existing
        )
