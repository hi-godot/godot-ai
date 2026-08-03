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
## True when even a fresh rebuild yields instances missing base-schema
## fields — the deep stale-script state after an in-session self-update
## (#850; docs/releasing.md release-shape rules). Only an editor restart
## heals it; callers surface RESTART_TO_FINISH_UPDATE instead of erroring
## per client. Never reset within a session: rebuilding again cannot help,
## it would only repeat the load work and warning on every dock sweep.
static var _stale_session := false

const RESTART_TO_FINISH_UPDATE := (
	"Godot AI was updated in this editor session. Restart the editor to finish the update."
)


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


## True when this editor session is running a self-update whose script
## reloads left descriptor state unusable. Client operations short-circuit
## with RESTART_TO_FINISH_UPDATE rather than spamming per-field errors.
static func stale_session_detected() -> bool:
	_ensure_loaded()
	return _stale_session


## An instance is coherent when fields added to the CURRENT McpClient schema
## read back with their declared types. After an in-session self-update,
## hot-patched or pre-update instances answer Nil for vars the update added
## (#850: `config_path_candidates` and
## `config_file_env` read as Nil, crashing platform_key / String()). The
## reflected `get()` avoids typed-access errors on such instances.
static func _instance_is_coherent(inst: Object) -> bool:
	if inst == null:
		return false
	return (
		inst.get("config_path_candidates") is Dictionary
		and inst.get("config_file_env") is String
		and inst.get("path_template") is Dictionary
	)


static func _cache_is_coherent() -> bool:
	return not _instances.is_empty() and _instance_is_coherent(_instances[0])


static func _ensure_loaded() -> void:
	if _stale_session:
		return
	if _cache_is_coherent():
		return
	_load_mutex.lock()
	## Re-check under the lock: another thread may have rebuilt (or concluded
	## staleness) while this one waited.
	if not _stale_session and not _cache_is_coherent():
		## Covers both the first load and the post-self-update rebuild: this
		## registry file can survive an update unchanged, so its statics keep
		## serving pre-update instances to freshly reloaded callers. A rebuild
		## instantiates from the reloaded descriptor scripts, which repairs
		## every case except a stale base Script object itself.
		_load()
		if not _instances.is_empty() and not _cache_is_coherent():
			_stale_session = true
			push_warning("MCP | %s" % RESTART_TO_FINISH_UPDATE)
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
