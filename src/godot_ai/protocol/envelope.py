"""Protocol envelope types for server <-> plugin communication."""

from __future__ import annotations

import math
from typing import Any
from uuid import uuid4

from pydantic import BaseModel, Field


def find_non_finite_float(value: Any, path: str = "params") -> str | None:
    """Return the key path of the first non-finite float in a params tree.

    NaN/Infinity are not representable in JSON: ``model_dump_json`` serializes
    them as ``null``, so a write-tool param that went NaN upstream (physics
    blowup, divide-by-zero position) would silently corrupt scene data while
    the tool reports success (#688). Callers reject the command instead.
    Returns ``None`` when every float in the tree is finite.
    """
    if isinstance(value, float) and not math.isfinite(value):
        return path
    if isinstance(value, dict):
        for key, item in value.items():
            found = find_non_finite_float(item, f"{path}.{key}")
            if found is not None:
                return found
    elif isinstance(value, (list, tuple)):
        for index, item in enumerate(value):
            found = find_non_finite_float(item, f"{path}[{index}]")
            if found is not None:
                return found
    return None


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
    ## Live readiness snapshot stamped by the plugin's dispatcher onto every
    ## response envelope. The server uses it to keep `Session.readiness` in
    ## lockstep with editor state, so a stale "playing" / "importing" cache
    ## (e.g. a `readiness_changed` event lost in transit, or a one-frame race
    ## around `pause_processing`) self-heals on the very next tool call —
    ## without the agent having to call `editor_state` first. Older plugins
    ## omit the field; the server falls through to the existing event-driven
    ## path. See connection.gd::get_readiness for the producer.
    readiness: str | None = None
    ## Optional monotonic-ish counters stamped by newer plugins after each
    ## command. Components may reset independently (game run rotation), so the
    ## server compares per key and treats decreases as a reset baseline.
    error_watermark: dict[str, int] | None = None


class ErrorDetail(BaseModel):
    """Structured error information from the plugin."""

    code: str
    message: str
    data: dict[str, Any] = Field(default_factory=dict)


class HandshakeMessage(BaseModel):
    """Initial handshake sent by the Godot plugin on connection."""

    type: str = "handshake"
    ## Bounded + charset-constrained: the plugin always produces "<slug>@<4hex>"
    ## (slug is [a-z0-9-]; see connection.gd::_make_session_id), so this only
    ## rejects a malformed or non-plugin peer. The value is used as a registry
    ## key, logged, and hashed into telemetry, so an unbounded/arbitrary string
    ## from an untrusted WS client shouldn't flow downstream unchecked (#527).
    session_id: str = Field(pattern=r"^[A-Za-z0-9._@-]{1,128}$")
    godot_version: str
    project_path: str
    plugin_version: str
    protocol_version: int = 1
    readiness: str = "ready"
    ## Optional because older plugins won't send it; server falls back to 0.
    editor_pid: int = 0
    ## Which launcher tier the plugin resolved for the Python server. Older
    ## plugins omit the field entirely, which lands as "unknown" on the
    ## server — distinguishable from a live detection that returned
    ## "unknown" only by plugin_version.
    server_launch_mode: str = "unknown"
    ## Per-launch WS auth token (#690). The spawning plugin generates it,
    ## passes it to the server via the GODOT_AI_WS_TOKEN spawn env, and
    ## echoes it here. None from older plugins and from editors adopting a
    ## server they didn't spawn — both accepted (compat gate); only a
    ## PRESENT-but-wrong token is rejected. Bounded like session_id so an
    ## untrusted peer can't stuff an unbounded string into the handshake.
    auth_token: str | None = Field(default=None, max_length=128)


## State events emitted by the plugin's _check_state_changes() poller. Each
## carries one typed string field. Validating them on receive prevents a
## malformed event (or a hijacked WS) from setting non-string values on the
## Session, which then ship to MCP clients verbatim via Session.to_dict().
## See audit-v2 finding #7 (issue #351).


class SceneChangedEvent(BaseModel):
    current_scene: str = ""


class PlayStateChangedEvent(BaseModel):
    play_state: str = "stopped"


class ReadinessChangedEvent(BaseModel):
    readiness: str = "ready"


## Plugin-emitted telemetry event. The plugin relays its own events
## (self-update outcome, plugin reload, dock startup) through this
## envelope so opt-out / endpoint / customer_uuid stay in one place
## (Python). The dispatcher in transport/websocket.py validates and
## forwards to ``telemetry.record_telemetry``.
class PluginTelemetryEvent(BaseModel):
    name: str = ""
    data: dict[str, Any] = Field(default_factory=dict)
