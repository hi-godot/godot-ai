"""MCP tools for curve point authoring."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import curve as curve_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_curve_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def curve_set_points(
        ctx: Context,
        points: list,
        path: str = "",
        property: str = "",
        resource_path: str = "",
        session_id: str = "",
    ) -> dict:
        """Replace all points on a Curve / Curve2D / Curve3D resource.

        Point list shape depends on the resource type:

        - Curve (scalar control curve): [{"offset": 0.0, "value": 1.0,
          "left_tangent": 0.0, "right_tangent": 0.0}, ...] — tangents optional.
        - Curve2D (2D path): [{"position": {"x": 0, "y": 0}, "in": {...},
          "out": {...}}, ...] — in/out default to zero (linear segments).
        - Curve3D (3D path): [{"position": {"x": 0, "y": 0, "z": 0}, "in": {...},
          "out": {...}, "tilt": 0.0}, ...] — all optional except position.

        Either pass path+property (a curve slot on a node, e.g. Path3D.curve,
        Line2D-like curves) or resource_path (a .tres file). Inline edits are
        undoable as a single action; .tres edits are persistent.

        If the node's curve slot is empty, a fresh Curve/Curve2D/Curve3D is
        auto-created (inferred from the property's class hint — Path3D.curve
        → Curve3D, Path2D.curve → Curve2D, etc.) and bundled into the same
        undo action. The response sets `curve_created: true` when this
        happens.

        Dedicated tool rather than set_property because Curve2D/Curve3D.add_point
        is a method call, not a property — resource_create's properties dict
        can't reach it.

        Args:
            points: Ordered list of point dicts (schema depends on curve type).
            path: Scene path of a node holding the curve.
            property: Property name on that node (e.g. "curve").
            resource_path: res:// path of a standalone curve .tres file.
            session_id: Optional Godot session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await curve_handlers.curve_set_points(
            runtime,
            points=points,
            path=path,
            property=property,
            resource_path=resource_path,
        )
