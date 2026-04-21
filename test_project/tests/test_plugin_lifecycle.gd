@tool
extends McpTestSuite

## Tests for the plugin's re-entrancy guard across disable/enable cycles.
## Regression coverage for the reload-plugin hang exposed by #159: once
## _stop_server became deterministic, the static _server_started_this_session
## flag persisted across disable/enable and made the re-enabled plugin's
## _start_server short-circuit with no server to adopt.

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")


func suite_name() -> String:
	return "plugin_lifecycle"


func setup() -> void:
	## The flag is a class-level static; leave it in a known state between
	## tests so ordering can't mask a regression.
	GodotAiPlugin._server_started_this_session = false


func teardown() -> void:
	GodotAiPlugin._server_started_this_session = false


func test_exit_tree_resets_spawn_guard() -> void:
	## The bug: after a successful spawn, the static flag stays true across
	## a plugin disable/enable cycle (same editor session). When the new
	## plugin instance's _enter_tree calls _start_server, the guard fires
	## and no respawn happens — the dock sits in "reconnecting…" forever.
	## Fix: _exit_tree must reset the flag so the next enable starts clean.
	GodotAiPlugin._server_started_this_session = true
	var plugin := GodotAiPlugin.new()
	## _stop_server early-returns on the default _server_pid (-1), and every
	## teardown branch in _exit_tree is null-guarded — so calling it on a
	## freshly constructed (never-entered-tree) instance is safe and does
	## not touch the editor or spawn processes.
	plugin._exit_tree()
	plugin.free()
	assert_true(
		not GodotAiPlugin._server_started_this_session,
		"_exit_tree must clear the re-entrancy guard so the re-enabled plugin respawns"
	)


func test_prepare_for_update_reload_resets_spawn_guard() -> void:
	## Companion path used by the dock's Update button flow. Kept distinct
	## from _exit_tree because the update sequence calls this *before* the
	## disable/enable toggle, whereas _exit_tree runs *during* teardown.
	GodotAiPlugin._server_started_this_session = true
	var plugin := GodotAiPlugin.new()
	plugin.prepare_for_update_reload()
	plugin.free()
	assert_true(
		not GodotAiPlugin._server_started_this_session,
		"prepare_for_update_reload must clear the re-entrancy guard before the toggle"
	)


func test_exit_tree_is_idempotent_when_guard_already_false() -> void:
	## If the plugin is disabled twice in a row (or disabled without ever
	## having spawned), the second _exit_tree must still leave the flag
	## false. Guards against accidental inversion of the reset.
	GodotAiPlugin._server_started_this_session = false
	var plugin := GodotAiPlugin.new()
	plugin._exit_tree()
	plugin.free()
	assert_true(
		not GodotAiPlugin._server_started_this_session,
		"_exit_tree must not flip the guard back to true"
	)
