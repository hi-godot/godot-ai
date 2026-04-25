@tool
class_name McpToolCatalog
extends RefCounted

## Mirror of src/godot_ai/tools/domains.py — drives the dock's Tools tab
## so the UI can render checkboxes, tool counts, and tooltips without
## round-tripping to a running server.
##
## DO NOT EDIT by hand. tests/unit/test_tool_domains.py verifies this file
## against actual tool registration and fails CI when they drift; the
## failure message prints the up-to-date catalog body for paste-over.
##
## The four core tools are always registered and cannot be excluded — they
## render as a single grayed-out "Core" row in the UI. Each non-core domain
## now exposes one or two named verbs plus a single rolled-up
## `<domain>_manage` tool.

const CORE_TOOLS := [
	"editor_state",
	"node_get_properties",
	"scene_get_hierarchy",
	"session_activate",
]

## Ordered list of user-toggleable domains. Each entry:
##   id:    matches the name passed to `--exclude-domains`
##   label: human-friendly display (same as id for now, kept separate so
##          a future renaming doesn't break the setting)
##   count: number of NON-CORE tools in this domain
##   tools: flat list of tool names registered by this domain (non-core only)
const DOMAINS := [
	{"id": "animation", "label": "animation", "count": 2, "tools": ["animation_create", "animation_manage"]},
	{"id": "audio", "label": "audio", "count": 1, "tools": ["audio_manage"]},
	{"id": "autoload", "label": "autoload", "count": 1, "tools": ["autoload_manage"]},
	{"id": "batch", "label": "batch", "count": 1, "tools": ["batch_execute"]},
	{"id": "camera", "label": "camera", "count": 1, "tools": ["camera_manage"]},
	{"id": "client", "label": "client", "count": 1, "tools": ["client_manage"]},
	{"id": "editor", "label": "editor", "count": 4, "tools": ["editor_manage", "editor_reload_plugin", "editor_screenshot", "logs_read"]},
	{"id": "filesystem", "label": "filesystem", "count": 1, "tools": ["filesystem_manage"]},
	{"id": "input_map", "label": "input_map", "count": 1, "tools": ["input_map_manage"]},
	{"id": "material", "label": "material", "count": 1, "tools": ["material_manage"]},
	{"id": "node", "label": "node", "count": 4, "tools": ["node_create", "node_find", "node_manage", "node_set_property"]},
	{"id": "particle", "label": "particle", "count": 1, "tools": ["particle_manage"]},
	{"id": "project", "label": "project", "count": 2, "tools": ["project_manage", "project_run"]},
	{"id": "resource", "label": "resource", "count": 1, "tools": ["resource_manage"]},
	{"id": "scene", "label": "scene", "count": 3, "tools": ["scene_manage", "scene_open", "scene_save"]},
	{"id": "script", "label": "script", "count": 4, "tools": ["script_attach", "script_create", "script_manage", "script_patch"]},
	{"id": "signal", "label": "signal", "count": 1, "tools": ["signal_manage"]},
	{"id": "testing", "label": "testing", "count": 2, "tools": ["test_manage", "test_run"]},
	{"id": "theme", "label": "theme", "count": 1, "tools": ["theme_manage"]},
	{"id": "ui", "label": "ui", "count": 1, "tools": ["ui_manage"]},
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
