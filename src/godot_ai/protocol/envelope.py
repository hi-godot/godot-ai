"""Protocol envelope types for server <-> plugin communication."""

from __future__ import annotations

from typing import Any
from uuid import uuid4

from pydantic import BaseModel, Field


class CommandRequest(BaseModel):
    """A command sent from the Python server to the Godot plugin."""

    request_id: str = Field(default_factory=lambda: uuid4().hex)
    command: str
    params: dict[str, Any] = Field(default_factory=dict)


class CommandResponse(BaseModel):
    """A response sent from the Godot plugin back to the Python server."""

    request_id: str
    status: str  # "ok" or "error"
    data: dict[str, Any] = Field(default_factory=dict)
    error: ErrorDetail | None = None


class ErrorDetail(BaseModel):
    """Structured error information from the plugin."""

    code: str
    message: str


class HandshakeMessage(BaseModel):
    """Initial handshake sent by the Godot plugin on connection."""

    type: str = "handshake"
    session_id: str
    godot_version: str
    project_path: str
    plugin_version: str
    protocol_version: int = 1
    readiness: str = "ready"
