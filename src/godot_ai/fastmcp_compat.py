"""Small import bridge across Godot AI's supported FastMCP 3.x range."""

from __future__ import annotations

try:
    # FastMCP 3.1+ split the tool base models into this module.
    from fastmcp.tools.base import ToolResult
except ImportError:  # pragma: no cover - exercised by the FastMCP-floor CI job
    # FastMCP 3.0 keeps the same public model in tools.tool.
    from fastmcp.tools.tool import ToolResult

from fastmcp.utilities.types import Image

__all__ = ["Image", "ToolResult"]
