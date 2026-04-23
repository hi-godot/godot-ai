@tool
class_name McpToolCatalog
extends RefCounted

## Mirror of src/godot_ai/tools/domains.py — drives the dock's Tools tab
## so the UI can render checkboxes, tool counts, and tooltips without
## round-tripping to a running server.
##
## DO NOT EDIT by hand. tests/unit/test_tool_catalog_parity.py verifies
## this file against actual tool registration and fails CI when they drift;
## the failure message prints the up-to-date catalog body for paste-over.
##
## The five core tools are always registered and cannot be excluded — they
## render as a single grayed-out "Core" row in the UI.

const CORE_TOOLS := [
	"editor_state",
	"node_get_properties",
	"scene_get_hierarchy",
	"session_activate",
	"session_list",
]

## Ordered list of user-toggleable domains. Each entry:
##   id:    matches the name passed to `--exclude-domains`
##   label: human-friendly display (same as id for now, kept separate so
##          a future renaming doesn't break the setting)
##   count: number of NON-CORE tools in this domain
##   tools: flat list of tool names registered by this domain (non-core only)
const DOMAINS := [
	{"id": "animation", "label": "animation", "count": 16, "tools": ["animation_add_method_track", "animation_add_property_track", "animation_create", "animation_create_simple", "animation_delete", "animation_get", "animation_list", "animation_play", "animation_player_create", "animation_preset_fade", "animation_preset_pulse", "animation_preset_shake", "animation_preset_slide", "animation_set_autoplay", "animation_stop", "animation_validate"]},
	{"id": "audio", "label": "audio", "count": 6, "tools": ["audio_list", "audio_play", "audio_player_create", "audio_player_set_playback", "audio_player_set_stream", "audio_stop"]},
	{"id": "autoload", "label": "autoload", "count": 3, "tools": ["autoload_add", "autoload_list", "autoload_remove"]},
	{"id": "batch", "label": "batch", "count": 1, "tools": ["batch_execute"]},
	{"id": "camera", "label": "camera", "count": 8, "tools": ["camera_apply_preset", "camera_configure", "camera_create", "camera_follow_2d", "camera_get", "camera_list", "camera_set_damping_2d", "camera_set_limits_2d"]},
	{"id": "client", "label": "client", "count": 3, "tools": ["client_configure", "client_remove", "client_status"]},
	{"id": "control", "label": "control", "count": 1, "tools": ["control_draw_recipe"]},
	{"id": "curve", "label": "curve", "count": 1, "tools": ["curve_set_points"]},
	{"id": "editor", "label": "editor", "count": 8, "tools": ["editor_quit", "editor_reload_plugin", "editor_screenshot", "editor_selection_get", "editor_selection_set", "logs_clear", "logs_read", "performance_monitors_get"]},
	{"id": "environment", "label": "environment", "count": 1, "tools": ["environment_create"]},
	{"id": "filesystem", "label": "filesystem", "count": 4, "tools": ["filesystem_read_text", "filesystem_reimport", "filesystem_search", "filesystem_write_text"]},
	{"id": "input_map", "label": "input_map", "count": 4, "tools": ["input_map_add_action", "input_map_bind_event", "input_map_list", "input_map_remove_action"]},
	{"id": "material", "label": "material", "count": 8, "tools": ["material_apply_preset", "material_apply_to_node", "material_assign", "material_create", "material_get", "material_list", "material_set_param", "material_set_shader_param"]},
	{"id": "node", "label": "node", "count": 12, "tools": ["node_add_to_group", "node_create", "node_delete", "node_duplicate", "node_find", "node_get_children", "node_get_groups", "node_move", "node_remove_from_group", "node_rename", "node_reparent", "node_set_property"]},
	{"id": "particle", "label": "particle", "count": 7, "tools": ["particle_apply_preset", "particle_create", "particle_get", "particle_restart", "particle_set_draw_pass", "particle_set_main", "particle_set_process"]},
	{"id": "physics_shape", "label": "physics_shape", "count": 1, "tools": ["physics_shape_autofit"]},
	{"id": "project", "label": "project", "count": 4, "tools": ["project_run", "project_settings_get", "project_settings_set", "project_stop"]},
	{"id": "resource", "label": "resource", "count": 5, "tools": ["resource_assign", "resource_create", "resource_get_info", "resource_load", "resource_search"]},
	{"id": "scene", "label": "scene", "count": 5, "tools": ["scene_create", "scene_get_roots", "scene_open", "scene_save", "scene_save_as"]},
	{"id": "script", "label": "script", "count": 6, "tools": ["script_attach", "script_create", "script_detach", "script_find_symbols", "script_patch", "script_read"]},
	{"id": "signal", "label": "signal", "count": 3, "tools": ["signal_connect", "signal_disconnect", "signal_list"]},
	{"id": "testing", "label": "testing", "count": 2, "tools": ["test_results_get", "test_run"]},
	{"id": "texture", "label": "texture", "count": 2, "tools": ["gradient_texture_create", "noise_texture_create"]},
	{"id": "theme", "label": "theme", "count": 6, "tools": ["theme_apply", "theme_create", "theme_set_color", "theme_set_constant", "theme_set_font_size", "theme_set_stylebox_flat"]},
	{"id": "ui", "label": "ui", "count": 3, "tools": ["ui_build_layout", "ui_set_anchor_preset", "ui_set_text"]},
]


## Total tool count when no domains are excluded. Used for the "Enabled: N / M"
## readout in the Tools tab without looping the catalog on every repaint.
static func total_tool_count() -> int:
	var n := CORE_TOOLS.size()
	for d in DOMAINS:
		n += int(d["count"])
	return n


## Tool count remaining after excluding the given set of domain ids.
static func enabled_tool_count(excluded: PackedStringArray) -> int:
	var n := CORE_TOOLS.size()
	for d in DOMAINS:
		if excluded.find(d["id"]) == -1:
			n += int(d["count"])
	return n


## Canonical comma-separated string for a set of domain ids — sorted and
## deduplicated so two equivalent settings (entered in different orders)
## hash to the same EditorSetting value. Matches `excluded_domains()` in
## client_configurator.gd.
static func canonical(excluded: PackedStringArray) -> String:
	var seen := PackedStringArray()
	for e in excluded:
		var t := e.strip_edges()
		if not t.is_empty() and seen.find(t) == -1:
			seen.append(t)
	seen.sort()
	return ",".join(seen)
