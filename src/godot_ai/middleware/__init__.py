"""FastMCP middleware for the Godot AI server."""

from __future__ import annotations

from godot_ai.middleware.client_wrapper_kwargs import (
    CLIENT_WRAPPER_KWARGS,
    StripClientWrapperKwargs,
)
from godot_ai.middleware.parse_stringified_params import ParseStringifiedParams

__all__ = [
    "CLIENT_WRAPPER_KWARGS",
    "ParseStringifiedParams",
    "StripClientWrapperKwargs",
]
