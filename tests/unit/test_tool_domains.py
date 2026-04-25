"""Tests for the tool-domain catalog and `--exclude-domains` filtering."""

from __future__ import annotations

import asyncio
import re
from pathlib import Path

import pytest

from godot_ai.server import create_server
from godot_ai.tools.domains import (
    CORE_BEARING_DOMAINS,
    CORE_TOOLS,
    DOMAINS,
    EXCLUDABLE_DOMAINS,
    parse_exclude_list,
)

## Path to the GDScript catalog the dock UI reads. Parity test below parses
## it and verifies it matches live registration — if this file moves, update
## here and in the dock.
_CATALOG_GD = (
    Path(__file__).resolve().parent.parent.parent
    / "plugin"
    / "addons"
    / "godot_ai"
    / "tool_catalog.gd"
)


def _list_tools(server) -> list[str]:
    tools = asyncio.run(server.list_tools())
    return [t.name for t in tools]


# --- domains.parse_exclude_list ---


def test_parse_empty_returns_empty_set():
    assert parse_exclude_list(None) == set()
    assert parse_exclude_list("") == set()
    assert parse_exclude_list("   ") == set()


def test_parse_strips_whitespace_and_dedupes():
    assert parse_exclude_list("audio, particle ,theme,audio") == {"audio", "particle", "theme"}


def test_parse_accepts_iterable():
    assert parse_exclude_list(["audio", "theme"]) == {"audio", "theme"}


def test_parse_rejects_unknown_names():
    with pytest.raises(ValueError, match="Unknown or non-excludable"):
        parse_exclude_list("audio,bogus")


def test_parse_rejects_core_only_session_domain():
    ## `session` is all-core — excluding it is a no-op. Hard-fail so users
    ## don't assume they trimmed something they didn't.
    with pytest.raises(ValueError, match="session"):
        parse_exclude_list("session")


def test_parse_rejects_core_only_batch_domain():
    ## `batch` is all-core — same reasoning as session.
    with pytest.raises(ValueError, match="batch"):
        parse_exclude_list("batch")


def test_core_bearing_domains_are_all_known():
    assert CORE_BEARING_DOMAINS <= set(DOMAINS)


def test_excludable_domains_excludes_all_core_only_domains():
    ## session and batch have only core tools → never excludable. Every other
    ## registered domain must be excludable.
    assert EXCLUDABLE_DOMAINS == set(DOMAINS) - {"session", "batch"}


# --- create_server() filtering ---


def test_create_server_full_registration_matches_domain_count():
    ## Sanity: total tools equal core (5) + sum of non-core-per-domain.
    ## The exact number (125) will drift as tools are added; the relationship
    ## between exclusion and tool count is what we pin.
    full = set(_list_tools(create_server()))
    assert set(CORE_TOOLS) <= full


def test_create_server_drops_whole_non_core_domain():
    full = set(_list_tools(create_server()))
    trimmed = set(_list_tools(create_server(exclude_domains={"audio"})))
    dropped = full - trimmed
    ## Every dropped tool must be from the excluded domain; nothing else.
    assert dropped, "excluding 'audio' should drop at least one tool"
    assert all(t.startswith("audio_") for t in dropped)


def test_create_server_preserves_core_when_core_bearing_domain_excluded():
    ## Excluding `node` drops node_find, node_duplicate, … but keeps the
    ## node CRUD core tools (node_create, node_set_property, …) and
    ## node_get_properties. Same for editor/scene.
    trimmed = set(_list_tools(create_server(exclude_domains={"editor", "scene", "node"})))
    for core_name in CORE_TOOLS:
        assert core_name in trimmed, f"{core_name} should survive exclusion"
    ## And the non-core members really are gone.
    assert "node_find" not in trimmed
    assert "node_duplicate" not in trimmed
    assert "editor_selection_get" not in trimmed
    assert "scene_open" not in trimmed


def test_create_server_ignores_unknown_domain_names_via_set_input():
    ## `create_server` accepts any iterable; only the CLI parser enforces
    ## known names. This lets the plugin pass a set that may contain a
    ## stale domain id from a previous version without wedging the spawn.
    ## (Unknown names are a no-op here because no registration is gated
    ## on them.)
    trimmed = set(_list_tools(create_server(exclude_domains={"audio", "ghost_domain"})))
    assert not any(t.startswith("audio_") for t in trimmed)


# --- GDScript catalog parity ---


def _parse_gd_catalog() -> tuple[list[str], dict[str, list[str]]]:
    """Parse tool_catalog.gd into (core_tools, {domain_id: [tool_names]})."""
    text = _CATALOG_GD.read_text()

    core_match = re.search(r"const CORE_TOOLS := \[(.*?)\]", text, re.DOTALL)
    assert core_match, "CORE_TOOLS block not found in tool_catalog.gd"
    core_tools = re.findall(r'"([^"]+)"', core_match.group(1))

    domains_match = re.search(r"const DOMAINS := \[(.*?)^\]", text, re.DOTALL | re.MULTILINE)
    assert domains_match, "DOMAINS block not found in tool_catalog.gd"
    domain_entries = re.findall(
        r'\{"id": "([^"]+)",\s*"label":\s*"[^"]*",\s*"count":\s*(\d+),\s*"tools":\s*\[([^\]]*)\]\}',
        domains_match.group(1),
    )
    domains: dict[str, list[str]] = {}
    for dom_id, count_str, tools_str in domain_entries:
        tools = re.findall(r'"([^"]+)"', tools_str)
        assert int(count_str) == len(tools), (
            f"{dom_id}: declared count {count_str} != actual tool list length {len(tools)}"
        )
        domains[dom_id] = tools
    return core_tools, domains


def test_gdscript_catalog_matches_python_registration():
    """If this fails, tool_catalog.gd drifted from src/godot_ai/tools/*.

    The failure message lists what's missing/extra per domain so a developer
    can update the GDScript const. Regenerate with:

        python -c "from godot_ai.server import create_server; \\
                   from godot_ai.tools.domains import EXCLUDABLE_DOMAINS; \\
                   import asyncio; \\
                   full = {t.name for t in asyncio.run(create_server().list_tools())}; \\
                   for d in sorted(EXCLUDABLE_DOMAINS): \\
                       trimmed = {t.name for t in asyncio.run( \\
                           create_server(exclude_domains=[d]).list_tools())}; \\
                       print(d, sorted(full - trimmed))"
    """
    gd_core, gd_domains = _parse_gd_catalog()

    assert sorted(gd_core) == sorted(CORE_TOOLS), (
        f"CORE_TOOLS drift — GDScript has {sorted(gd_core)}, Python has {sorted(CORE_TOOLS)}"
    )

    assert set(gd_domains) == EXCLUDABLE_DOMAINS, (
        f"Domain set drift — GDScript has {sorted(gd_domains)}, "
        f"Python has {sorted(EXCLUDABLE_DOMAINS)}"
    )

    full = {t.name for t in asyncio.run(create_server().list_tools())}
    for domain in sorted(EXCLUDABLE_DOMAINS):
        trimmed = {
            t.name for t in asyncio.run(create_server(exclude_domains=[domain]).list_tools())
        }
        expected = sorted(full - trimmed)
        actual = sorted(gd_domains[domain])
        assert actual == expected, (
            f"Domain '{domain}' drift:\n"
            f"  GDScript lists: {actual}\n"
            f"  Actually registered: {expected}\n"
            f"  Fix: update tool_catalog.gd"
        )
