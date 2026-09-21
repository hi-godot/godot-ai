"""Promote opt-in custom tools to first-class MCP tools.

``custom_manage(op="invoke")`` is a double indirection: the agent's MCP
client never sees a custom tool's own name or ``params_schema``, so it
cannot validate params or surface the tool natively. A spec that sets
``promoted = true`` opts into ALSO being registered as a real MCP tool —
``custom_<name>`` — whose advertised schema is the addon's own, using the
``tools/list_changed`` broadcast the catalog already emits.

Budget: the repo deliberately caps its tool surface (see
``docs/tool-surface.md``), so promotion is capped at
``MAX_PROMOTED_TOOLS``; overflow tools stay fully reachable through
``custom_manage`` and the cap is logged once per sync.

Sessions: registration is NAME-level across sessions (deterministic:
sorted names, first ``MAX_PROMOTED_TOOLS``). Dispatch is unchanged — a
promoted call routes through :func:`custom_invoke`, which resolves the
ACTIVE session's definition, so a name promoted by a disconnected or
inactive editor fails with the same clear error as ``custom_manage``.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from typing import TYPE_CHECKING, Any

from fastmcp.tools import Tool, ToolResult
from pydantic import PrivateAttr

if TYPE_CHECKING:
    from fastmcp import FastMCP

    from godot_ai.services.custom_tool_service import (
        CustomToolDefinition,
        CustomToolService,
    )

logger = logging.getLogger(__name__)

## "custom_" both namespaces away from built-ins (which never use the
## prefix) and tells the agent what it is at a glance.
PROMOTED_PREFIX = "custom_"
MAX_PROMOTED_TOOLS = 8

_EMPTY_SCHEMA: dict[str, Any] = {"type": "object", "properties": {}}


class PromotedCustomTool(Tool):
    """A first-class MCP tool backed by a plugin-registered custom tool."""

    _catalog_name: str = PrivateAttr()

    async def run(self, arguments: dict[str, Any]) -> ToolResult:
        ## Late imports: this runs inside a request; the module itself is
        ## imported during lifespan startup where handlers may not be.
        from fastmcp.server.dependencies import get_context

        from godot_ai.handlers.custom import custom_invoke
        from godot_ai.runtime.direct import DirectRuntime

        runtime = DirectRuntime.from_context(get_context())
        ## Same path as custom_manage(op="invoke"): active-session lookup,
        ## conditional writable gate, spec-derived timeout.
        result = await custom_invoke(runtime, self._catalog_name, arguments or {})
        return ToolResult(structured_content=result)


class PromotedToolRegistrar:
    """Keeps the FastMCP tool list in sync with promoted catalog entries.

    Attached to :class:`CustomToolService` via its ``on_catalog_changed``
    hook; every catalog mutation (WS push, disconnect) re-syncs. The
    subsequent ``tools/list_changed`` broadcast the service already
    schedules tells MCP clients to re-fetch. Disabled definitions remain
    callable for stale clients but are filtered from fresh discovery by
    :class:`GodotAIFastMCP`.
    """

    def __init__(
        self,
        mcp: FastMCP,
        service: CustomToolService,
        *,
        set_hidden_tools: Callable[[set[str]], None] | None = None,
    ) -> None:
        self._mcp = mcp
        self._service = service
        self._set_hidden_tools = set_hidden_tools or (lambda _names: None)
        self._registered: set[str] = set()
        self._capped_logged: frozenset[str] = frozenset()
        self._conflict_logged: frozenset[str] = frozenset()
        service.on_catalog_changed = self.sync

    def sync(self) -> None:
        ## Never let a promotion bug take down the WS receive loop that
        ## triggered the catalog change.
        try:
            self._sync()
        except Exception:
            logger.exception("Promoted custom-tool sync failed")

    def _sync(self) -> None:
        ## Merged (cross-session) view on purpose: registration is
        ## name-level; dispatch re-resolves per active session.
        promoted: dict[str, CustomToolDefinition] = {}
        for definition in self._service.get_tools():
            if definition.promoted:
                promoted.setdefault(definition.name, definition)

        ## Fail closed on cross-session schema conflicts: when two editors
        ## promote the SAME name with DIFFERENT params_schema, advertising
        ## either schema misleads the MCP client whenever the other session
        ## is active (dispatch resolves per active session). Such names stay
        ## reachable via custom_manage, which is always session-correct.
        ## Identical-schema duplicates promote normally.
        schemas_by_name: dict[str, list] = {}
        for _session_id, definition in self._service.iter_all_definitions():
            if definition.promoted and definition.enabled:
                schemas_by_name.setdefault(definition.name, []).append(
                    definition.params_schema
                )
        conflicted = frozenset(
            name
            for name, schemas in schemas_by_name.items()
            if any(schema != schemas[0] for schema in schemas[1:])
        )
        if conflicted and conflicted != self._conflict_logged:
            logger.warning(
                "Promoted name(s) with conflicting schemas across editor "
                "sessions excluded from first-class registration "
                "(use custom_manage): %s",
                ", ".join(sorted(conflicted)),
            )
        self._conflict_logged = conflicted
        for name in conflicted:
            promoted.pop(name, None)

        ## Disabled definitions are intentionally absent from get_tools(),
        ## but remain in get_all_tools(). Keep them registered as hidden
        ## tombstones so stale MCP clients get CUSTOM_TOOL_DISABLED instead
        ## of FastMCP's generic "Unknown tool" response.
        disabled: dict[str, CustomToolDefinition] = {}
        for definition in self._service.get_all_tools():
            if definition.promoted and not definition.enabled and definition.name not in promoted:
                disabled.setdefault(definition.name, definition)

        chosen = sorted(promoted)[:MAX_PROMOTED_TOOLS]
        capped = frozenset(sorted(promoted)[MAX_PROMOTED_TOOLS:])
        if capped and capped != self._capped_logged:
            logger.warning(
                "Promoted custom-tool cap (%d) reached; %s stay behind custom_manage",
                MAX_PROMOTED_TOOLS,
                ", ".join(sorted(capped)),
            )
        self._capped_logged = capped

        want = {PROMOTED_PREFIX + name: promoted[name] for name in chosen}
        hidden = {PROMOTED_PREFIX + name: definition for name, definition in disabled.items()}
        registered_want = want | hidden
        self._set_hidden_tools(set(hidden))

        for tool_name in self._registered - set(registered_want):
            self._mcp.local_provider.remove_tool(tool_name)
            self._registered.discard(tool_name)

        for tool_name, definition in registered_want.items():
            ## Re-add even when already present: a re-push may have changed
            ## the description or schema, and the addon's definition wins.
            if tool_name in self._registered:
                self._mcp.local_provider.remove_tool(tool_name)
            tool = PromotedCustomTool(
                name=tool_name,
                description=_describe(definition),
                parameters=definition.params_schema or _EMPTY_SCHEMA,
            )
            tool._catalog_name = definition.name
            self._mcp.add_tool(tool)
            self._registered.add(tool_name)


def _describe(definition: CustomToolDefinition) -> str:
    source = definition.source or "a project addon"
    return (
        f"{definition.description}\n\n"
        f"Custom tool registered by {source} (Godot editor). Active session only."
    )
