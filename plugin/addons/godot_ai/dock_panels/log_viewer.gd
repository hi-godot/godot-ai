@tool
extends VBoxContainer

## Dock subpanel — renders the MCP request/response log buffer. Owns its own
## UI subtree, the line-count cursor, and the display-visibility toggle. Emits
## `logging_enabled_changed` so the dock can route the flag onto the
## connection dispatcher without the panel knowing the routing exists.
##
## Extracted from mcp_dock.gd as part of audit-v2 #360 — see the comment at
## the top of mcp_dock.gd for the broader extraction story.

signal logging_enabled_changed(enabled: bool)

const Dock := preload("res://addons/godot_ai/mcp_dock.gd")

## Untyped: a `: McpLogBuffer` annotation hits the class_name registry at
## script-load and trips the self-update parse hazard (#398). The type fence
## stays on the `setup(log_buffer: McpLogBuffer)` parameter.
var _log_buffer
var _log_display: RichTextLabel
var _log_toggle: CheckButton
## Last `McpLogBuffer.total_logged()` value painted into the display. Tracking
## the buffer's monotonic sequence (rather than its bounded `total_count()`)
## keeps the viewer painting once the ring fills — a size-based cursor would
## freeze at MAX_LINES on every subsequent append. See PR #392 for the bug.
var _last_log_seq := 0


## Build the UI synchronously here so callers (and detached-tree tests that
## instantiate the dock with `McpDockScript.new()` and never enter the tree)
## can interact with the panel's controls right after `setup()`. Mirrors the
## pre-extraction inline-build behavior that test_dock.gd relies on.
##
## Idempotent: `_log_display == null` covers an unlikely double-`setup()` call
## without rebuilding (which would orphan the prior controls).
func setup(log_buffer: McpLogBuffer) -> void:
	_log_buffer = log_buffer
	if _log_display == null:
		_build_ui()


func _build_ui() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(HSeparator.new())

	var log_header_row := HBoxContainer.new()
	var log_header := Dock._make_header("MCP Log")
	log_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_header_row.add_child(log_header)

	_log_toggle = CheckButton.new()
	_log_toggle.text = "Log"
	_log_toggle.button_pressed = true
	_log_toggle.toggled.connect(_on_log_toggled)
	log_header_row.add_child(_log_toggle)

	add_child(log_header_row)

	_log_display = RichTextLabel.new()
	_log_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_display.custom_minimum_size = Vector2(0, 120)
	_log_display.scroll_following = true
	_log_display.bbcode_enabled = false
	_log_display.selection_enabled = true
	add_child(_log_display)


## Called from McpDock._process when the panel is visible. Appends any new
## log lines since the last tick.
func tick() -> void:
	if _log_buffer == null or _log_display == null:
		return
	var seq: int = _log_buffer.total_logged()
	if seq == _last_log_seq:
		return
	if seq < _last_log_seq:
		## Buffer cleared via `McpLogBuffer.clear()` (the `clear_logs` MCP
		## tool / `logs_clear` handler). The buffer resets `_total_logged`
		## to 0, flipping the sequence backward. Without this branch the
		## display would keep showing pre-clear lines forever — the viewer
		## drifts permanently out of sync with the buffer. Reset display +
		## cursor so the next append paints over a clean slate.
		_log_display.clear()
		_last_log_seq = 0
		if seq == 0:
			return
	var new_lines: Array[String] = _log_buffer.get_recent(seq - _last_log_seq)
	for line in new_lines:
		_log_display.add_text(line + "\n")
	_last_log_seq = seq


func _on_log_toggled(enabled: bool) -> void:
	_log_display.visible = enabled
	logging_enabled_changed.emit(enabled)
