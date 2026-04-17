"""MCP tools for physics shape authoring."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import physics_shape as physics_shape_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_physics_shape_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def physics_shape_autofit(
        ctx: Context,
        path: str,
        source_path: str = "",
        shape_type: str = "",
        session_id: str = "",
    ) -> dict:
        """Size a CollisionShape2D/CollisionShape3D to match a visual sibling's bounds.

        Auto-creates the concrete shape subclass (BoxShape3D / SphereShape3D /
        CapsuleShape3D / CylinderShape3D for 3D; RectangleShape2D /
        CircleShape2D / CapsuleShape2D for 2D) if the shape slot is empty or
        holds a shape of a different type. Creation + sizing bundle into one
        undoable action.

        The visual source defaults to a sibling VisualInstance3D
        (MeshInstance3D, CSGShape3D, etc.) for 3D or a sibling Sprite2D /
        TextureRect for 2D. Pass source_path explicitly for anything more
        complex.

        Args:
            path: Scene path of the CollisionShape2D or CollisionShape3D.
            source_path: Optional scene path of the visual node to measure.
                Auto-detected from siblings when empty.
            shape_type: Desired shape kind. For 3D: "box" (default), "sphere",
                "capsule", "cylinder". For 2D: "rectangle" (default),
                "circle", "capsule".
            session_id: Optional Godot session to target. Empty = active.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await physics_shape_handlers.physics_shape_autofit(
            runtime,
            path=path,
            source_path=source_path,
            shape_type=shape_type,
        )
