"""MCP tools for node creation and manipulation.

Top-level: ``node_get_properties`` (core), ``node_create``, ``node_set_property``,
``node_find``. Everything else (delete, duplicate, rename, move, reparent,
get_children, get_groups, add_to_group, remove_from_group) collapses into
``node_manage``.
"""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import node as node_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Node tree manipulation (delete, duplicate, rename, reorder, reparent,
groups, hierarchy reads).

Resource forms (prefer for active-session reads):
  godot://node/{path}/properties, godot://node/{path}/children,
  godot://node/{path}/groups

Ops:
  • get_children(path)
        Direct children of a node (name, type, path each).
  • get_groups(path)
        Group names the node belongs to.
  • delete(path, scene_file="")
        Remove the node. Cannot delete scene root. Undoable.
  • duplicate(path, name="", scene_file="")
        Deep-copy a node + children as a sibling. Cannot duplicate scene root.
  • rename(path, new_name, scene_file="")
        Rename a node. Sibling-name collision and "/" / ":" / "@" rules apply.
  • move(path, index, scene_file="")
        Reorder among siblings. Index 0 = first.
  • reparent(path, new_parent, scene_file="")
        Move under a new parent. Children preserved. Cannot move into descendants.
  • add_to_group(path, group, scene_file="")
        Add the node to a group.
  • remove_from_group(path, group, scene_file="")
        Remove the node from a group.

All write ops accept the optional ``scene_file`` guard — if non-empty, the
mutation fails with EDITED_SCENE_MISMATCH when the editor's current scene
doesn't match.
"""


def register_node_tools(mcp: FastMCP, *, include_non_core: bool = True) -> None:
    @mcp.tool()
    async def node_get_properties(ctx: Context, path: str, session_id: str = "") -> dict:
        """Get all properties of a node.

        Resource form: ``godot://node/{path}/properties`` — prefer for
        active-session reads.

        Args:
            path: Scene path of the node (e.g. "/Main/Camera3D").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_get_properties(runtime, path=path)

    if not include_non_core:
        return

    @mcp.tool(meta=DEFER_META)
    async def node_create(
        ctx: Context,
        type: str = "",
        name: str = "",
        parent_path: str = "",
        scene_path: str = "",
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Create (spawn) a new node in the scene tree.

        Creates a node of the given type and adds it to the parent, or
        instantiates a PackedScene from ``scene_path``. type and scene_path
        are mutually exclusive — when scene_path is given, type is ignored.

        Args:
            type: Godot node class (e.g. "Node3D", "MeshInstance3D").
            name: Optional name; Godot auto-names if empty.
            parent_path: Parent scene path (e.g. "/Main"). Empty = scene root.
            scene_path: Optional res:// path of a PackedScene to instantiate.
            scene_file: Optional editor-scene guard (EDITED_SCENE_MISMATCH).
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_create(
            runtime,
            type=type,
            name=name,
            parent_path=parent_path,
            scene_path=scene_path,
            scene_file=scene_file,
        )

    @mcp.tool(meta=DEFER_META)
    async def node_set_property(
        ctx: Context,
        path: str,
        property: str,
        value: str | int | float | bool | dict | list | None,
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Set a property on a node.

        Coerces ``value`` to the property's type:
        - Vector2/Vector3: dict with x/y/z keys.
        - Color: dict {r,g,b,a} or hex string ("#ff0000").
        - NodePath: string ("../Other/Node").
        - Resource: res:// path string (loads + assigns); null/"" clears.
          For a fresh built-in resource, pass ``{"__class__": "BoxMesh", ...}``.
          See ``resource_manage(op="create")`` for more control.
        - StringName: plain string. Array/Dictionary: JSON list/object.

        Args:
            path: Scene path of the node.
            property: Property name (e.g. "fov", "position", "mesh").
            value: New value. Pass null (or "" for resources) to clear.
            scene_file: Optional editor-scene guard.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_set_property(
            runtime,
            path=path,
            property=property,
            value=value,
            scene_file=scene_file,
        )

    @mcp.tool(meta=DEFER_META)
    async def node_find(
        ctx: Context,
        name: str = "",
        type: str = "",
        group: str = "",
        offset: int = 0,
        limit: int = 100,
        session_id: str = "",
    ) -> dict:
        """Find nodes in the scene tree by name, type, or group.

        At least one filter must be provided. Filters AND together. Paginated.

        Args:
            name: Substring match on node name (case-insensitive).
            type: Exact Godot class name (e.g. "MeshInstance3D").
            group: Group name the node must belong to.
            offset: Number of results to skip. Default 0.
            limit: Max number of results. Default 100.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_find(
            runtime,
            name=name,
            type=type,
            group=group,
            offset=offset,
            limit=limit,
        )

    register_manage_tool(
        mcp,
        tool_name="node_manage",
        description=_DESCRIPTION,
        ops={
            "get_children": node_handlers.node_get_children,
            "get_groups": node_handlers.node_get_groups,
            "delete": node_handlers.node_delete,
            "duplicate": node_handlers.node_duplicate,
            "rename": node_handlers.node_rename,
            "move": node_handlers.node_move,
            "reparent": node_handlers.node_reparent,
            "add_to_group": node_handlers.node_add_to_group,
            "remove_from_group": node_handlers.node_remove_from_group,
        },
    )
