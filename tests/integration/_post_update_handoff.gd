@tool
extends Node

const Plugin := preload("res://addons/godot_ai/plugin.gd")
const Lifecycle := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const Dock := preload("res://addons/godot_ai/mcp_dock.gd")

class PresentationPlugin extends Plugin:
	func _enter_tree() -> void:
		pass
	func _exit_tree() -> void:
		pass

var results := {}

func _ready() -> void:
	if Engine.is_editor_hint():
		run.call_deferred()

func make_case() -> Dictionary:
	var plugin := PresentationPlugin.new()
	get_tree().root.add_child(plugin)
	var manager := Lifecycle.new()
	manager.configure({"automatic_effects": false})
	plugin._lifecycle = manager
	plugin._normal_start_released = true
	plugin._post_update_replaced_version = "4.0.4"
	plugin._post_update_reprobes_left = 1
	var dock := Dock.new()
	dock._build_ui()
	plugin._dock = dock
	manager.snapshot_changed.connect(plugin._on_lifecycle_snapshot_changed)
	manager.start_server()
	return {"plugin": plugin, "manager": manager, "dock": dock}

func block_handoff(fixture: Dictionary) -> void:
	fixture.manager._episode["proof_pending_reason"] = "capability_pair"
	fixture.manager._block("launch_gone", "HTTP port already claimed")
	fixture.dock._update_status()

func destroy_case(fixture: Dictionary) -> void:
	fixture.plugin._dock = null
	fixture.dock.free()
	fixture.plugin._lifecycle = null
	fixture.plugin.free()

func run() -> void:
	var fixture := make_case()
	block_handoff(fixture)
	var scheduled_episode := int(fixture.plugin._post_update_retry_episode)
	results["scheduled"] = {
		"episode": scheduled_episode,
		"remaining": fixture.plugin._post_update_reprobes_left,
		"amber": fixture.dock._status_icon.color == Dock.COLOR_AMBER,
		"transport": fixture.manager.authority_snapshot().transport,
		"blocked": fixture.manager.is_connection_blocked(),
	}
	await get_tree().create_timer(1.1).timeout
	results["consumed"] = {
		"episode": fixture.plugin._post_update_retry_episode,
		"phase": fixture.manager.get_status_dict().phase,
		"fresh_episode": int(fixture.manager.episode_snapshot().id) != scheduled_episode,
		"blocked": fixture.manager.is_connection_blocked(),
		"transport": fixture.manager.authority_snapshot().transport,
	}
	block_handoff(fixture)
	var exhausted: Dictionary = fixture.manager.episode_snapshot()
	results["exhausted"] = {
		"episode": fixture.plugin._post_update_retry_episode,
		"red": fixture.dock._status_icon.color == Color.RED,
		"state": fixture.manager.get_status_dict().episode_state,
	}
	await get_tree().create_timer(1.1).timeout
	results.exhausted["unchanged"] = fixture.manager.episode_snapshot() == exhausted
	destroy_case(fixture)

	fixture = make_case()
	block_handoff(fixture)
	results["stop_scheduled"] = int(fixture.plugin._post_update_retry_episode) > 0
	fixture.manager.stop_server()
	var stopped: Dictionary = fixture.manager.episode_snapshot()
	await get_tree().create_timer(1.1).timeout
	results["stopped"] = {
		"episode": fixture.plugin._post_update_retry_episode,
		"unchanged": fixture.manager.episode_snapshot() == stopped,
		"blocked": fixture.manager.is_connection_blocked(),
		"transport": fixture.manager.authority_snapshot().transport,
	}
	destroy_case(fixture)
	var file := FileAccess.open("res://result.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(results))
	file.close()
	get_tree().quit()
