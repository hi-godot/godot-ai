@tool
extends EditorPlugin

## Registers the top-down shooter tools with Godot AI's custom tool
## registry. Godot AI may load before or after this addon, and it creates a
## fresh registry instance whenever it reloads, so the registration is
## re-checked every frame (one static call and a pointer compare) instead
## of depending on plugin load order.

const ToolSpecs := preload("res://addons/topdown_shooter_tools/tool_specs.gd")

var _registered_with: McpToolRegistry = null
var _warned := false


func _enter_tree() -> void:
	set_process(true)
	_sync_registration()


func _exit_tree() -> void:
	set_process(false)
	var registry := McpToolRegistry.get_instance()
	if registry != null and registry == _registered_with:
		registry.unregister_source(ToolSpecs.SOURCE_PATH)
	_registered_with = null


func _process(_delta: float) -> void:
	_sync_registration()


func _sync_registration() -> void:
	var registry := McpToolRegistry.get_instance()
	if registry == null or registry == _registered_with:
		return
	if registry.batch_register(ToolSpecs.build()):
		_registered_with = registry
		_warned = false
	elif not _warned:
		_warned = true
		push_warning("Top-down Shooter Tools: Godot AI rejected the tool specs (see the errors above).")
