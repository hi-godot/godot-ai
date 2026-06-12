"""MCP tool for version-correct Godot API introspection."""

from __future__ import annotations

from fastmcp import FastMCP

from godot_ai.handlers import api as api_handlers
from godot_ai.tools._meta_tool import register_manage_tool

_DESCRIPTION = """\
Inspect Godot API documentation-shaped metadata from the connected editor's
ClassDB: "what properties does X have", method signatures, signals, enums,
constants, defaults, and property hint strings.

Resource form (prefer for active-session reads):
  godot://class/{class_name}

Ops:
  - get_class(class_name, sections=None, include_inherited=False,
              include_inheritors=False, offset=0, limit=100)
        Return selected class-reference sections without creating a scene
        instance. sections may be a comma-separated string or list containing
        properties, methods, signals, enums, constants, inheritors.
        For pagination, request one section at a time so offset/limit apply
        only to the list you are paging.
"""


def register_api_tools(mcp: FastMCP) -> None:
    register_manage_tool(
        mcp,
        tool_name="api_manage",
        description=_DESCRIPTION,
        ops={"get_class": api_handlers.api_get_class},
        read_resource_forms={"get_class": "godot://class/{class_name}"},
    )
