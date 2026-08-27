"""Exclusion-aware MCP capability advertising (#772).

Domain exclusion has always been honored by registration, but the
``instructions`` string was a static literal finalized before the exclude
set was computed — an excluded tool read as a discovery failure instead of
a configuration. These tests pin:

  - byte-identity of the no-exclusion output against a frozen snapshot of
    the current intentional capability guidance;
  - omission of excluded domains' named verbs and rollup lines, plus the
    trailing "Excluded domains" section;
  - the named-verb count in the header against live registration, for
    several exclusion sets, so the two can't drift apart again;
  - the ``exclude_domains`` metadata on ``session_manage(op="list")``.
"""

from __future__ import annotations

import asyncio
import re

import pytest

from godot_ai.server import build_instructions, create_server
from godot_ai.tools._meta_tool import MANAGE_TOOL_HANDLERS

## Frozen copy of the intentional no-exclusion instructions. Update this only
## when capability guidance changes deliberately; accidental drift must fail
## loudly.
_FROZEN_NO_EXCLUSION_TEXT = (
    "Production-grade Godot MCP server with persistent editor integration.\n\n"
    "Tool surface — 19 named verbs + per-domain `<domain>_manage` rollups:\n\n"
    "Core named verbs (always loaded — common reads + high-traffic writes):\n"
    "  editor_state                      — readiness, version, current scene\n"
    "  scene_get_hierarchy               — paginated scene tree walk\n"
    "  node_get_properties               — full property snapshot\n"
    "  session_activate                  — pin commands to one editor\n"
    "  node_create / node_set_property / node_find\n"
    "  scene_open / scene_save\n"
    "  script_create / script_attach / script_patch\n"
    "  project_run, test_run, batch_execute, logs_read\n"
    "  editor_screenshot, editor_reload_plugin, animation_create\n\n"
    "Domain rollups (one tool per domain; pass `op=` + a `params` dict):\n"
    "  scene_manage     create, save_as, get_roots\n"
    "  node_manage      get_children, get_groups, delete, duplicate, rename,\n"
    "                   move, reparent, add_to_group, remove_from_group\n"
    "  script_manage    read, detach, find_symbols\n"
    "  project_manage   stop, settings_get, settings_set\n"
    "  editor_manage    state, selection_get/set, monitors_get, quit, logs_clear,\n"
    "                   game_eval\n"
    "  session_manage   list\n"
    "  test_manage      results_get\n"
    "  animation_manage player_create, delete, validate, add_property_track,\n"
    "                   add_method_track, set_autoplay, play, stop, list, get,\n"
    "                   create_simple, preset_fade/slide/shake/pulse\n"
    "  material_manage  create, set_param, set_shader_param, get, list, assign,\n"
    "                   apply_to_node, apply_preset\n"
    "  audio_manage     player_create, player_set_stream, player_set_playback,\n"
    "                   play, stop, list\n"
    "  particle_manage  create, set_main, set_process, set_draw_pass, restart,\n"
    "                   get, apply_preset\n"
    "  camera_manage    create, configure, set_limits_2d, set_damping_2d,\n"
    "                   follow_2d, get, list, apply_preset\n"
    "  signal_manage    list, connect, disconnect\n"
    "  input_map_manage list, add_action, ensure_action, remove_action,\n"
    "                   bind_event, ensure_binding\n"
    "  game_manage      get_scene_tree, get_node_info, get_ui_elements,\n"
    "                   input_key, input_mouse, input_gamepad, input_action,\n"
    "                   input_state\n"
    "  autoload_manage  list, add, remove\n"
    "  filesystem_manage read_text, write_text, reimport, scan, search\n"
    "  theme_manage     create, set_color, set_constant, set_font_size,\n"
    "                   set_stylebox_flat, apply\n"
    "  ui_manage        set_anchor_preset, set_text, build_layout, draw_recipe\n"
    "  resource_manage  search, load, assign, get_info, create,\n"
    "                   curve_set_points, environment_create,\n"
    "                   physics_shape_autofit, physics_shape_generate,\n"
    "                   gradient_texture_create,\n"
    "                   noise_texture_create\n"
    "  api_manage       get_class\n"
    "  client_manage    status, configure, remove\n\n"
    "  tilemap_manage   tilemap_set_cell, tilemap_set_cells_rect,\n"
    "                   tilemap_clear, tilemap_get_cells\n"
    "  tileset_manage   tileset_get_atlas_tiles, tileset_get_atlas_image\n"
    "  gridmap_manage   gridmap_set_item, gridmap_fill, gridmap_clear,\n"
    "                   gridmap_get_used_cells, gridmap_list_library_items\n"
    "  csg_manage       csg_create, csg_set_operation\n"
    "  custom_manage    list, invoke\n\n"
    "Resources (read-only URIs, no tool-count cost — prefer for active-session "
    "reads when the client surfaces them):\n"
    "  godot://sessions, godot://editor/state, godot://selection/current,\n"
    "  godot://logs/recent, godot://scene/current, godot://scene/hierarchy,\n"
    "  godot://node/{path}/properties|children|groups,\n"
    "  godot://class/{class_name},\n"
    "  godot://script/{path}, godot://project/info, godot://project/settings,\n"
    "  godot://materials, godot://input_map, godot://performance,\n"
    "  godot://test/results, godot://custom-tools\n\n"
    "Code-mode adapters keep server and member names separate: "
    "call('godot-ai', 'editor_state', {}) and "
    "readResource('godot-ai', 'godot://scene/current'). Never prefix the "
    "second argument with 'godot-ai/' and do not invent legacy names such as "
    "get_editor_state or get_current_scene.\n\n"
    "Always connect to an editor session first (session_activate or "
    'session_manage(op="list")). Write operations require session readiness; '
    "check editor_state if a call is rejected as 'not writable'. After driving a "
    "running game, check logs_read(source='editor' or 'game', include_details=true) "
    "before declaring a feature verified."
)


def _registered_tools(exclude: set[str] | None = None) -> set[str]:
    """Return tool names registered for the requested domain exclusions."""
    server = create_server(exclude_domains=exclude)
    return {t.name for t in asyncio.run(server.list_tools())}


def _registered_tool(name: str):
    """Return one registered tool definition by name."""
    server = create_server()
    return next(tool for tool in asyncio.run(server.list_tools()) if tool.name == name)


def test_editor_state_description_teaches_code_mode_call_signature():
    """The editor-state description should teach the Pi call signature."""
    description = _registered_tool("editor_state").description

    assert "call('godot-ai', 'editor_state', {})" in description
    assert "readResource('godot-ai', 'godot://scene/current')" in description
    assert "godot-ai/get_editor_state" in description


def test_scene_and_node_descriptions_explain_persistence_and_subresources():
    """Scene and node descriptions should explain persistence semantics."""
    scene_description = _registered_tool("scene_manage").description
    node_description = _registered_tool("node_set_property").description

    assert "later node_create/node_set_property mutations remain" in scene_description
    assert "until scene_save or save_as is called" in scene_description
    assert "[sub_resource]" in node_description
    assert '"resource_path": "res://meshes/box.tres"' in node_description


# --- byte-identity with no exclusions ---


def test_no_exclusions_is_byte_identical_to_frozen_text():
    text = build_instructions(set())
    assert text == _FROZEN_NO_EXCLUSION_TEXT
    assert "Excluded domains" not in text


def test_create_server_wires_builder_into_instructions():
    assert create_server().instructions == build_instructions(set())
    assert create_server(exclude_domains={"audio"}).instructions == build_instructions({"audio"})


# --- exclusion-aware output ---


def test_excluded_domain_dropped_and_named_in_trailing_section():
    text = build_instructions({"audio"})
    assert "audio_manage" not in text
    assert "Excluded domains (not registered on this server): audio." in text
    assert "Core tools for core-bearing domains remain available." in text


def test_multiple_exclusions_listed_sorted():
    text = build_instructions({"theme", "audio"})
    assert "audio_manage" not in text
    assert "theme_manage" not in text
    assert "Excluded domains (not registered on this server): audio, theme." in text


def test_core_bearing_exclusion_names_surviving_core_tools():
    text = build_instructions({"node"})
    ## Non-core node surface gone from the advertised map...
    assert "node_manage" not in text
    assert "node_create" not in text
    ## ...but the core verb line stays, and the caveat names the survivor.
    assert "node_get_properties               — full property snapshot" in text
    assert (
        "Excluded domains (not registered on this server): node. "
        "Core tools for core-bearing domains remain available: node_get_properties." in text
    )


# --- named-verb count and tool mentions track live registration ---


@pytest.mark.parametrize(
    "exclude",
    [
        (),
        ("audio",),
        ("editor",),
        ("script", "animation"),
        ("node", "editor", "scene"),
        ("project", "testing", "batch"),
    ],
    ids=lambda e: ",".join(e) or "none",
)
def test_advertised_surface_matches_live_registration(exclude: tuple[str, ...]):
    """The header count and tool mentions must track what actually registered.

    Instructions count comes from the display tables in server.py;
    registration comes from create_server's gating — comparing them here is
    what prevents the two from drifting apart again (the original #772 bug
    was exactly such a drift, hardcoded as "19 named verbs").
    """
    exclude_set = set(exclude)
    server = create_server(exclude_domains=exclude_set)
    tools = {t.name for t in asyncio.run(server.list_tools())}
    named = {t for t in tools if not t.endswith("_manage")}
    text = server.instructions

    header = re.search(r"Tool surface — (\d+) named verbs", text)
    assert header, "named-verb count header missing from instructions"
    assert int(header.group(1)) == len(named)

    ## Every registered tool (named verb or rollup) is advertised.
    for tool in tools:
        assert tool in text, f"registered tool {tool} missing from instructions"

    ## Every tool dropped by the exclusion is absent from the capability
    ## sections (the static closing guidance may reference optional tools
    ## like logs_read, so only the surface above "Resources (" is checked).
    capability_sections = text.split("Resources (")[0]
    for tool in _registered_tools() - tools:
        assert tool not in capability_sections, (
            f"excluded tool {tool} still advertised in instructions"
        )


# --- session_manage(op="list") metadata ---


class _FakeRuntime:
    active_session_id = None

    def list_sessions(self):
        return []


def test_session_list_carries_exclusion_list():
    create_server(exclude_domains={"audio"})
    handler = MANAGE_TOOL_HANDLERS["session_manage"]["list"]
    result = handler(_FakeRuntime())
    assert result["exclude_domains"] == ["audio"]
    assert result["count"] == 0


def test_session_list_exclusion_list_empty_by_default():
    create_server()
    handler = MANAGE_TOOL_HANDLERS["session_manage"]["list"]
    result = handler(_FakeRuntime())
    assert result["exclude_domains"] == []
