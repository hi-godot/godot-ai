@tool
class_name McpClientRegistry
extends RefCounted

## Central enumeration of every supported MCP client. Adding a new client
## means: drop a file in clients/, then append one preload below.

const _CLIENT_SCRIPTS := [
	preload("res://addons/godot_ai/clients/claude_code.gd"),
	preload("res://addons/godot_ai/clients/claude_desktop.gd"),
	preload("res://addons/godot_ai/clients/codex.gd"),
	preload("res://addons/godot_ai/clients/antigravity.gd"),
	preload("res://addons/godot_ai/clients/cursor.gd"),
	preload("res://addons/godot_ai/clients/windsurf.gd"),
	preload("res://addons/godot_ai/clients/vscode.gd"),
	preload("res://addons/godot_ai/clients/vscode_insiders.gd"),
	preload("res://addons/godot_ai/clients/zed.gd"),
	preload("res://addons/godot_ai/clients/gemini_cli.gd"),
	preload("res://addons/godot_ai/clients/cline.gd"),
	preload("res://addons/godot_ai/clients/kilo_code.gd"),
	preload("res://addons/godot_ai/clients/roo_code.gd"),
	preload("res://addons/godot_ai/clients/kiro.gd"),
	preload("res://addons/godot_ai/clients/trae.gd"),
	preload("res://addons/godot_ai/clients/cherry_studio.gd"),
	preload("res://addons/godot_ai/clients/opencode.gd"),
	preload("res://addons/godot_ai/clients/qwen_code.gd"),
	preload("res://addons/godot_ai/clients/kimi_code.gd"),
]

static var _instances: Array[McpClient] = []
static var _by_id: Dictionary = {}


static func all() -> Array[McpClient]:
	if _instances.is_empty():
		_load()
	return _instances


static func get_by_id(id: String) -> McpClient:
	if _instances.is_empty():
		_load()
	return _by_id.get(id, null)


static func ids() -> PackedStringArray:
	var out := PackedStringArray()
	for c in all():
		out.append(c.id)
	return out


static func has_id(id: String) -> bool:
	if _instances.is_empty():
		_load()
	return _by_id.has(id)


static func _load() -> void:
	_instances.clear()
	_by_id.clear()
	for script in _CLIENT_SCRIPTS:
		var inst: McpClient = script.new()
		if inst.id.is_empty():
			push_warning("MCP | client descriptor %s has empty id" % script.resource_path)
			continue
		if _by_id.has(inst.id):
			push_warning("MCP | duplicate client id: %s" % inst.id)
			continue
		_instances.append(inst)
		_by_id[inst.id] = inst
