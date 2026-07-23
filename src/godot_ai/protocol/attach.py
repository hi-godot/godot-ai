"""Shared protocol constants and helpers for the ``godot-ai attach`` bridge."""

from __future__ import annotations

import hashlib
import json
import os
import uuid
from collections.abc import Sequence
from typing import Any, Literal

from fastmcp import FastMCP

ATTACH_PROTOCOL_VERSION = 1
ATTACH_SPAWNED_ENV = "GODOT_AI_CLIENT_SPAWNED"
PLUGIN_SPAWNED_ENV = "GODOT_AI_PLUGIN_SPAWNED"
DEV_TRANSPORT_ENV = "GODOT_AI_DEV_TRANSPORT"

## One nonce per Python process. It deliberately changes on every backend
## restart and is compatibility information only — never process-kill proof.
SERVER_INSTANCE_ID = uuid.uuid4().hex

OwnerType = Literal["plugin", "attach", "external"]


def owner_type_from_env() -> OwnerType:
    """Describe how this process was launched without implying kill authority."""

    if _env_truthy(PLUGIN_SPAWNED_ENV):
        return "plugin"
    if _env_truthy(ATTACH_SPAWNED_ENV):
        return "attach"
    return "external"


def _env_truthy(name: str) -> bool:
    return os.environ.get(name, "").strip().lower() in {"1", "true", "yes", "on"}


async def tool_catalog_hash(server: FastMCP[Any]) -> str:
    """Return a stable SHA-256 of the effective MCP tool schemas.

    The hash is diagnostic-only in attach protocol v1. Adoption gates on the
    exact package version, attach protocol, ports, and excluded domains. That
    keeps the bridge from trusting a hash reported by the process it is
    validating while still making schema drift observable in diagnostics.
    """

    tools = await server.list_tools()
    schemas: Sequence[dict[str, Any]] = [
        tool.to_mcp_tool().model_dump(mode="json", by_alias=True, exclude_none=True)
        for tool in tools
    ]
    canonical = json.dumps(
        sorted(schemas, key=lambda item: str(item.get("name", ""))),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()
