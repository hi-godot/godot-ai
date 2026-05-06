@tool
extends VBoxContainer

## Dock subpanel — renders the MCP request/response log buffer. Owns its own
## UI subtree and the line-count cursor; the dock provides the buffer +
## connection at setup() time and calls tick() each frame the panel is visible.
##
## Extracted from mcp_dock.gd as part of audit-v2 #360 — see the comment at
## the top of mcp_dock.gd for the broader extraction story.

const COLOR_HEADER := Color(0.95, 0.95, 0.95)

var _log_buffer
var _connection
var _log_display: RichTextLabel
var _log_toggle: CheckButton
var _last_log_count := 0


func setup(log_buffer, connection) -> void:
	_log_buffer = log_buffer
	_connection = connection


func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(HSeparator.new())

	var log_header_row := HBoxContainer.new()
	var log_header := _make_header("MCP Log")
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
	var count: int = _log_buffer.total_count()
	if count == _last_log_count:
		return
	var new_lines: Array[String] = _log_buffer.get_recent(count - _last_log_count)
	for line in new_lines:
		_log_display.add_text(line + "\n")
	_last_log_count = count


func _on_log_toggled(enabled: bool) -> void:
	if _connection and _connection.dispatcher:
		_connection.dispatcher.mcp_logging = enabled
	_log_display.visible = enabled


static func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_HEADER)
	return label
