@tool
extends VBoxContainer

## Dock subpanel — port-change escape hatch surfaced inside the spawn-failure
## crash panel when a port is contested or an incompatible server cannot be reclaimed.
##
## It moves BOTH ports. A godot-ai server binds its HTTP and WebSocket ports
## together, so moving only the HTTP port onto a free number lands the next
## launch on a WebSocket port the previous server still holds, and the server
## dies at preflight ("WebSocket port 19630 is already in use"). Emits
## `port_apply_requested(new_http_port, new_ws_port)` after range-validation;
## the dock writes the EditorSettings and reloads the plugin.
##
## Extracted from mcp_dock.gd as part of audit-v2 #360 — see the comment at
## the top of mcp_dock.gd for the broader extraction story.

const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")

signal port_apply_requested(new_http_port: int, new_ws_port: int)

var _spinbox: SpinBox
var _ws_spinbox: SpinBox
## Bind probe used when seeding; tests substitute a deterministic one.
var port_in_use_probe: Callable = Callable(PortResolver, "is_port_in_use")


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

	_spinbox = _port_spinbox(ClientConfigurator.http_port(), "Effective HTTP port")
	picker_row.add_child(_spinbox)
	_ws_spinbox = _port_spinbox(ClientConfigurator.ws_port(), "Effective WebSocket port")
	picker_row.add_child(_ws_spinbox)

	var apply_btn := Button.new()
	apply_btn.text = "Apply + Reload"
	apply_btn.tooltip_text = (
		"Saves the effective HTTP and WebSocket ports to Editor Settings and reloads"
		+ " the plugin so the server spawns on the new ports. Reconfigure your AI"
		+ " clients afterwards so their bridges use the new ports."
	)
	apply_btn.pressed.connect(_on_apply_pressed)
	picker_row.add_child(apply_btn)

	add_child(picker_row)


static func _port_spinbox(value: int, tooltip: String) -> SpinBox:
	var spinbox := SpinBox.new()
	spinbox.min_value = ClientConfigurator.MIN_PORT
	spinbox.max_value = ClientConfigurator.MAX_PORT
	spinbox.step = 1
	spinbox.value = value
	spinbox.tooltip_text = tooltip
	spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spinbox


## Seed both boxes every time the panel surfaces, so a stale value from a
## previous spawn-failure round cannot carry over. The diagnosed
## `conflict_port` and any port that is simply in use get a fresh free
## suggestion; a port that is free keeps its value, so clients whose entries
## carry it keep working. Note that this OVERWRITES unsaved user input — fine
## in practice because the dock only calls this on `server_status`
## transitions (`if server_status == _last_server_status: return`).
func seed_suggested_ports(conflict_port := 0) -> void:
	if _spinbox == null:
		return
	var http := ClientConfigurator.http_port()
	var ws := ClientConfigurator.ws_port()
	if conflict_port == http or bool(port_in_use_probe.call(http)):
		http = ClientConfigurator.suggest_free_port(http + 1)
	if conflict_port == ws or ws == http or bool(port_in_use_probe.call(ws)):
		ws = ClientConfigurator.suggest_free_port(ws + 1)
		if ws == http:
			ws = ClientConfigurator.suggest_free_port(ws + 1)
	_spinbox.value = http
	_ws_spinbox.value = ws


func _on_apply_pressed() -> void:
	var new_http: int = int(_spinbox.value)
	var new_ws: int = int(_ws_spinbox.value)
	for port in [new_http, new_ws]:
		if port < ClientConfigurator.MIN_PORT or port > ClientConfigurator.MAX_PORT:
			return
	if new_http == new_ws:
		return
	port_apply_requested.emit(new_http, new_ws)
