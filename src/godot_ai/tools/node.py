"""MCP tools for node creation and manipulation."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import node as node_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_node_tools(mcp: FastMCP) -> None:
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
        """Create (spawn / add) a new node (game object / entity) in the scene tree.

        Creates a node of the given type and adds it as a child of the
        specified parent. If no parent is given, adds to the scene root.
        If no name is given, Godot assigns one based on the type.

        Args:
            type: The Godot node class (e.g. "Node3D", "MeshInstance3D", "Camera3D").
            name: Optional name for the node.
            parent_path: Node path of the parent (e.g. "/Main"). Empty = scene root.
            scene_path: File path of a PackedScene to instantiate (e.g.
                "res://prefabs/enemy.tscn"). When provided, the scene is loaded
                and instantiated instead of creating by type. Mutually exclusive
                with type — if scene_path is given, type is ignored.
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
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

        At least one filter must be provided. Filters are combined with AND
        logic — a node must match all specified filters. Results are paginated.

        Args:
            name: Substring match on node name (case-insensitive).
            type: Exact Godot class name (e.g. "MeshInstance3D").
            group: Group name the node must belong to.
            offset: Number of results to skip. Default 0.
            limit: Maximum number of results to return. Default 100.
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

    @mcp.tool()
    async def node_get_properties(ctx: Context, path: str, session_id: str = "") -> dict:
        """Get all properties of a node.

        Returns the property list with current values for the node at
        the given scene path.

        Args:
            path: Scene path of the node (e.g. "/Main/Camera3D").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_get_properties(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def node_get_children(ctx: Context, path: str, session_id: str = "") -> dict:
        """Get the direct children of a node.

        Returns name, type, and path for each immediate child of the
        specified node.

        Args:
            path: Scene path of the parent node (e.g. "/Main").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_get_children(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def node_get_groups(ctx: Context, path: str, session_id: str = "") -> dict:
        """Get the groups a node belongs to.

        Returns the list of group names for the node at the given path.

        Args:
            path: Scene path of the node (e.g. "/Main/Player").
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_get_groups(runtime, path=path)

    @mcp.tool(meta=DEFER_META)
    async def node_delete(
        ctx: Context, path: str, scene_file: str = "", session_id: str = ""
    ) -> dict:
        """Delete a node from the scene tree.

        Removes the node at the given path. This operation is undoable
        via Ctrl+Z in the Godot editor. Cannot delete the scene root.

        Args:
            path: Scene path of the node to delete (e.g. "/Main/Enemy").
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_delete(runtime, path=path, scene_file=scene_file)

    @mcp.tool(meta=DEFER_META)
    async def node_reparent(
        ctx: Context,
        path: str,
        new_parent: str,
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Move a node to a new parent in the scene tree.

        Reparents the node, preserving its children. Cannot reparent the
        scene root or move a node to one of its own descendants.

        Args:
            path: Scene path of the node to move (e.g. "/Main/Player").
            new_parent: Scene path of the new parent (e.g. "/Main/World").
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_reparent(
            runtime, path=path, new_parent=new_parent, scene_file=scene_file
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

        Coerces `value` to match the property's declared type:

        - Vector2/Vector3: dict with x/y/z keys
        - Color: dict with r/g/b/a keys, or hex string ("#ff0000")
        - NodePath: string ("../Other/Node")
        - Resource: res:// path string (loads and assigns); pass null or "" to clear.
          For a fresh built-in Resource instance, pass a dict with a "__class__"
          key — e.g. value={"__class__": "BoxMesh", "size": {"x": 2, "y": 2, "z": 2}}
          instantiates a BoxMesh with that size and assigns it. See resource_create
          for more control (save to .tres, validation errors).
        - StringName: plain string
        - Array/Dictionary: pass a JSON list/object
        - bool/int/float: JSON primitives

        Args:
            path: Scene path of the node (e.g. "/Main/Camera3D").
            property: Property name (e.g. "fov", "position", "visible", "mesh", "remote_path").
            value: New value for the property. Pass null (or "" for Resource properties) to clear.
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
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
    async def node_rename(
        ctx: Context,
        path: str,
        new_name: str,
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Rename a node in the scene tree.

        Changes the node's `name`. Fails if a sibling already has that name,
        or if the name contains `/`, `:`, or `@`. Cannot rename the scene root.

        Note: `NodePath` properties on OTHER nodes that pointed at this node
        (e.g. a camera's `remote_path`) will not be auto-updated. Scripts that
        reference this node by name (`$OldName`, `get_node("OldName")`) also
        need manual fixes. Children of the renamed node keep working because
        their paths are relative.

        Args:
            path: Scene path of the node to rename (e.g. "/Main/Player").
            new_name: New name for the node (e.g. "Hero").
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_rename(
            runtime, path=path, new_name=new_name, scene_file=scene_file
        )

    @mcp.tool(meta=DEFER_META)
    async def node_duplicate(
        ctx: Context,
        path: str,
        name: str = "",
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Duplicate (clone / copy) a node and all its children.

        Creates a deep copy of the node and adds it as a sibling.
        Cannot duplicate the scene root.

        Args:
            path: Scene path of the node to duplicate (e.g. "/Main/Enemy").
            name: Optional name for the duplicate. Godot auto-names if empty.
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_duplicate(
            runtime, path=path, name=name, scene_file=scene_file
        )

    @mcp.tool(meta=DEFER_META)
    async def node_move(
        ctx: Context,
        path: str,
        index: int,
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Reorder a node among its siblings.

        Changes the node's position in its parent's child list.
        Index 0 = first child.

        Args:
            path: Scene path of the node to move (e.g. "/Main/Player").
            index: New sibling index (0-based).
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_move(runtime, path=path, index=index, scene_file=scene_file)

    @mcp.tool(meta=DEFER_META)
    async def node_add_to_group(
        ctx: Context,
        path: str,
        group: str,
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Add a node to a group.

        Groups are Godot's lightweight tagging system. Nodes can belong
        to multiple groups.

        Args:
            path: Scene path of the node (e.g. "/Main/Enemy").
            group: Group name to add the node to (e.g. "enemies").
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_add_to_group(
            runtime, path=path, group=group, scene_file=scene_file
        )

    @mcp.tool(meta=DEFER_META)
    async def node_remove_from_group(
        ctx: Context,
        path: str,
        group: str,
        scene_file: str = "",
        session_id: str = "",
    ) -> dict:
        """Remove a node from a group.

        Args:
            path: Scene path of the node (e.g. "/Main/Enemy").
            group: Group name to remove the node from (e.g. "enemies").
            scene_file: Optional "res://..." path. When non-empty, the mutation
                fails with EDITED_SCENE_MISMATCH if the editor's current scene
                doesn't match — use it to guard multi-call sequences against
                silent scene-drift between calls.
            session_id: Optional Godot session to target. Empty = active session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await node_handlers.node_remove_from_group(
            runtime, path=path, group=group, scene_file=scene_file
        )
