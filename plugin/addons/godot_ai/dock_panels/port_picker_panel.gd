@tool
extends VBoxContainer

## Dock subpanel — port-change escape hatch surfaced inside the spawn-failure
## crash panel when the HTTP port is contested (PORT_EXCLUDED, FOREIGN_PORT).
## Emits `port_apply_requested(new_port)` after range-validation; the dock
## handles writing the EditorSetting and reloading the plugin.
##
## Extracted from mcp_dock.gd as part of audit-v2 #360 — see the comment at
## the top of mcp_dock.gd for the broader extraction story.

const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")

signal port_apply_requested(new_port: int)

var _spinbox: SpinBox


## Build the UI synchronously here so callers (and detached-tree tests that
## instantiate the dock with `McpDockScript.new()` and never enter the tree)
## can interact with the panel's controls right after `setup()`. Mirrors the
## pre-extraction inline-build behavior that test_dock.gd relies on.
##
## Idempotent: `_spinbox == null` covers an unlikely double-`setup()` call
## without rebuilding (which would orphan the prior controls).
func setup() -> void:
	if _spinbox == null:
		_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 4)
	visible = false

	var picker_row := HBoxContainer.new()
	picker_row.add_theme_constant_override("separation", 6)

	_spinbox = SpinBox.new()
	_spinbox.min_value = ClientConfigurator.MIN_PORT
	_spinbox.max_value = ClientConfigurator.MAX_PORT
	_spinbox.step = 1
	_spinbox.value = ClientConfigurator.http_port()
	_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_row.add_child(_spinbox)

	var apply_btn := Button.new()
	apply_btn.text = "Apply + Reload"
	apply_btn.tooltip_text = (
		"Saves godot_ai/http_port to Editor Settings and reloads the plugin so"
		+ " the server spawns on the new port."
	)
	apply_btn.pressed.connect(_on_apply_pressed)
	picker_row.add_child(apply_btn)

	add_child(picker_row)


## Re-seed the spinbox with a fresh suggestion every time the panel surfaces,
## so a stale value from a previous spawn-failure round can't carry over. Note
## that this OVERWRITES any unsaved user input — fine in practice because the
## dock's `_update_crash_panel` only calls this on `server_status` transitions
## (`if server_status == _last_server_status: return` short-circuit), so a
## user typing into the spinbox between transitions keeps their value. If the
## state flips while the picker is visible (e.g. `PORT_EXCLUDED` → `FOREIGN_PORT`),
## the in-flight edit is clobbered — accept that, the suggestion is more current.
func seed_suggested_port() -> void:
	if _spinbox == null:
		return
	_spinbox.value = ClientConfigurator.suggest_free_port(
		ClientConfigurator.http_port() + 1
	)


func _on_apply_pressed() -> void:
	var new_port: int = int(_spinbox.value)
	if new_port < ClientConfigurator.MIN_PORT or new_port > ClientConfigurator.MAX_PORT:
		return
	port_apply_requested.emit(new_port)
