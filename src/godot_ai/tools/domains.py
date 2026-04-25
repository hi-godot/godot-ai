"""Tool-domain catalog and exclude-list parsing.

Some MCP clients (notably Antigravity) reject connections whose total tool
count exceeds a hard limit (100 for Antigravity). `defer_loading` meta only
helps clients that speak Anthropic's tool-search — others still see every
registered tool at handshake time. To fit under such limits, the server
accepts `--exclude-domains` and drops whole domains' non-core tools before
registration.

This module is the single source of truth for:
  - the canonical ordered list of domains (`DOMAINS`)
  - which domains contain always-on core tools (`CORE_BEARING_DOMAINS`)
  - the core tools themselves (`CORE_TOOLS`) — shown as an "always on" row
    in the plugin's Tools UI
  - `parse_exclude_list(raw)` — CLI/plugin input parser
"""

from __future__ import annotations

from collections.abc import Iterable

## Registration order matches server.create_server(). Keep in sync.
##
## Single-verb / sub-domain entries (control, curve, environment,
## physics_shape, texture) were folded into adjacent ``*_manage`` rollups
## (``ui_manage`` and ``resource_manage``) and no longer appear as standalone
## domains.
DOMAINS: tuple[str, ...] = (
    "session",
    "editor",
    "scene",
    "node",
    "project",
    "script",
    "resource",
    "filesystem",
    "client",
    "signal",
    "autoload",
    "input_map",
    "testing",
    "batch",
    "ui",
    "theme",
    "animation",
    "material",
    "particle",
    "camera",
    "audio",
)

## Domains that contain at least one core (always-loaded) tool. When the
## user excludes one of these, only its non-core tools are dropped; the
## core tool is still registered.
CORE_BEARING_DOMAINS: frozenset[str] = frozenset({"session", "editor", "scene", "node"})

## The 4 core tools that survive any exclusion. Displayed as a disabled
## "Core" row in the plugin UI. ``session_list`` moved to ``godot://sessions``
## resource + ``session_manage(op="list")``; ``session_activate`` is the only
## session core tool left.
CORE_TOOLS: tuple[str, ...] = (
    "session_activate",
    "editor_state",
    "scene_get_hierarchy",
    "node_get_properties",
)

## Domains the user can toggle off. `session` has no non-core tools, so
## excluding it would be a no-op; we reject it up front so an accidental
## `--exclude-domains session` doesn't silently do nothing.
EXCLUDABLE_DOMAINS: frozenset[str] = frozenset(DOMAINS) - {"session"}


def parse_exclude_list(raw: str | Iterable[str] | None) -> set[str]:
    """Parse a comma-separated string (or iterable) of domain names.

    Whitespace and empty entries are ignored. Unknown names raise
    ValueError with the offending names listed — callers decide whether
    to surface the error (CLI: hard-fail) or degrade (plugin: warn).
    """
    if raw is None:
        return set()
    if isinstance(raw, str):
        parts = [p.strip() for p in raw.split(",")]
    else:
        parts = [str(p).strip() for p in raw]
    names = {p for p in parts if p}
    unknown = names - EXCLUDABLE_DOMAINS
    if unknown:
        raise ValueError(
            "Unknown or non-excludable domain(s): "
            + ", ".join(sorted(unknown))
            + f". Valid: {', '.join(sorted(EXCLUDABLE_DOMAINS))}."
        )
    return names
