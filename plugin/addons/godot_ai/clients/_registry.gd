@tool
class_name McpClientRegistry
extends RefCounted

## Central enumeration of every supported MCP client. Adding a new client
## means: drop a file in clients/, then append one path below.
##
## Paths, not preloads (#736): a preload array pulled all client descriptor
## scripts into the boot-time compile closure of everything that preloads
## this registry (plugin.gd via client_configurator.gd and mcp_dock.gd),
## stalling "Initializing plugins" on every editor boot. Descriptors are
## only needed when the dock refreshes client statuses or a client_*
## command runs, so they load lazily on first registry access.

const _CLIENT_SCRIPT_PATHS := [
	"res://addons/godot_ai/clients/claude_code.gd",
	"res://addons/godot_ai/clients/claude_desktop.gd",
	"res://addons/godot_ai/clients/codex.gd",
	"res://addons/godot_ai/clients/grok.gd",
	"res://addons/godot_ai/clients/antigravity.gd",
	"res://addons/godot_ai/clients/cursor.gd",
	"res://addons/godot_ai/clients/windsurf.gd",
	"res://addons/godot_ai/clients/vscode.gd",
	"res://addons/godot_ai/clients/vscode_insiders.gd",
	"res://addons/godot_ai/clients/zed.gd",
	"res://addons/godot_ai/clients/gemini_cli.gd",
	"res://addons/godot_ai/clients/cline.gd",
	"res://addons/godot_ai/clients/kilo_code.gd",
	"res://addons/godot_ai/clients/roo_code.gd",
	"res://addons/godot_ai/clients/zoo_code.gd",
	"res://addons/godot_ai/clients/kiro.gd",
	"res://addons/godot_ai/clients/trae.gd",
	"res://addons/godot_ai/clients/cherry_studio.gd",
	"res://addons/godot_ai/clients/opencode.gd",
	"res://addons/godot_ai/clients/qwen_code.gd",
	"res://addons/godot_ai/clients/kimi_code.gd",
	"res://addons/godot_ai/clients/hermes.gd",
]

static var _instances: Array[McpClient] = []
static var _by_id: Dictionary = {}
## First registry access can come from the dock's client-status refresh
## worker thread while the main thread hits it via a client_* command —
## serialize the one-time load so a racing thread can never observe a
## half-built registry. load() itself is thread-safe via ResourceLoader.
static var _load_mutex := Mutex.new()


static func all() -> Array[McpClient]:
	_ensure_loaded()
	return _instances


static func get_by_id(id: String) -> McpClient:
	_ensure_loaded()
	return _by_id.get(id, null)


static func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for c in all():
		out.append(c.id)
	return out


static func has_id(id: String) -> bool:
	_ensure_loaded()
	return _by_id.has(id)


static func _ensure_loaded() -> void:
	if not _instances.is_empty():
		return
	_load_mutex.lock()
	if _instances.is_empty():
		_load()
	_load_mutex.unlock()


static func _load() -> void:
	## Build into locals and publish whole containers last, so the lock-free
	## fast path in _ensure_loaded can never see a partially-filled registry.
	var instances: Array[McpClient] = []
	var by_id: Dictionary = {}
	for path in _CLIENT_SCRIPT_PATHS:
		var script := load(path) as GDScript
		if script == null:
			push_warning("MCP | failed to load client descriptor %s" % path)
			continue
		var inst: McpClient = script.new()
		if inst.id.is_empty():
			push_warning("MCP | client descriptor %s has empty id" % path)
			continue
		if by_id.has(inst.id):
			push_warning("MCP | duplicate client id: %s" % inst.id)
			continue
		instances.append(inst)
		by_id[inst.id] = inst
	_by_id = by_id
	_instances = instances
