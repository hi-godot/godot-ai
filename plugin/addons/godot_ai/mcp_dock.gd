@tool
class_name McpDock
extends VBoxContainer

## Editor dock panel showing MCP connection status, client config, and command log.

var _connection: Connection
var _log_buffer: McpLogBuffer
var _plugin: EditorPlugin

var _status_icon: ColorRect
var _status_label: Label
var _session_label: Label
var _server_label: Label
var _log_display: RichTextLabel
var _log_toggle: CheckButton
var _reconnect_btn: Button
var _last_log_count := 0
var _last_connected := false

# Setup UI
var _setup_container: VBoxContainer
var _dev_server_btn: Button

# Client config UI
var _client_rows: Dictionary = {}  # client_name -> {status_label, button}


func setup(connection: Connection, log_buffer: McpLogBuffer, plugin: EditorPlugin) -> void:
	_connection = connection
	_log_buffer = log_buffer
	_plugin = plugin


func _ready() -> void:
	_build_ui()


func _process(_delta: float) -> void:
	if _connection == null:
		return
	_update_status()
	_update_log()


func _build_ui() -> void:
	# --- Status section ---
	var status_header := _make_header("Connection")
	add_child(status_header)

	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)

	_status_icon = ColorRect.new()
	_status_icon.custom_minimum_size = Vector2(12, 12)
	_status_icon.color = Color.RED
	var icon_center := CenterContainer.new()
	icon_center.add_child(_status_icon)
	status_row.add_child(icon_center)

	_status_label = Label.new()
	_status_label.text = "Disconnected"
	status_row.add_child(_status_label)

	add_child(status_row)

	_session_label = Label.new()
	_session_label.text = ""
	_session_label.add_theme_font_size_override("font_size", 11)
	_session_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_session_label)

	_server_label = Label.new()
	_server_label.text = "WS: %d  HTTP: %d" % [McpClientConfigurator.SERVER_WS_PORT, McpClientConfigurator.SERVER_HTTP_PORT]
	_server_label.add_theme_font_size_override("font_size", 11)
	_server_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	add_child(_server_label)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)

	_reconnect_btn = Button.new()
	_reconnect_btn.text = "Reconnect"
	_reconnect_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reconnect_btn.pressed.connect(_on_reconnect)
	btn_row.add_child(_reconnect_btn)

	var reload_btn := Button.new()
	reload_btn.text = "Reload Plugin"
	reload_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	reload_btn.pressed.connect(_on_reload_plugin)
	btn_row.add_child(reload_btn)

	add_child(btn_row)

	add_child(HSeparator.new())

	# --- Setup section ---
	var setup_header := _make_header("Setup")
	add_child(setup_header)

	_setup_container = VBoxContainer.new()
	add_child(_setup_container)
	_refresh_setup_status.call_deferred()

	add_child(HSeparator.new())

	# --- Client config section ---
	var client_header := _make_header("Clients")
	add_child(client_header)

	for client_name in McpClientConfigurator.CLIENT_TYPE_MAP:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)

		var name_label := Label.new()
		name_label.text = client_name.replace("_", " ").capitalize()
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(name_label)

		var status_lbl := Label.new()
		status_lbl.text = "..."
		status_lbl.add_theme_font_size_override("font_size", 11)
		row.add_child(status_lbl)

		var btn := Button.new()
		btn.text = "Configure"
		btn.pressed.connect(_on_configure_client.bind(client_name))
		row.add_child(btn)

		_client_rows[client_name] = {"status_label": status_lbl, "button": btn}
		add_child(row)

	_refresh_client_status.call_deferred()

	add_child(HSeparator.new())

	# --- Log section ---
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


func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	return label


func _update_status() -> void:
	var connected := _connection.is_connected
	if connected == _last_connected:
		return
	_last_connected = connected

	if connected:
		_status_icon.color = Color.GREEN
		_status_label.text = "Connected"
		_session_label.text = ""
	else:
		_status_icon.color = Color.RED
		_status_label.text = "Disconnected"
		_session_label.text = ""

	_update_dev_server_btn()


func _update_log() -> void:
	if _log_buffer == null:
		return
	var count := _log_buffer.total_count()
	if count == _last_log_count:
		return

	# Append only new lines
	var new_lines := _log_buffer.get_recent(count - _last_log_count)
	for line in new_lines:
		_log_display.add_text(line + "\n")
	_last_log_count = count


func _on_reload_plugin() -> void:
	# Toggle plugin off/on to reload all GDScript
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func _on_reconnect() -> void:
	if _connection:
		_connection.disconnect_from_server()
		_connection._attempt_reconnect()


func _on_log_toggled(enabled: bool) -> void:
	if _connection and _connection.dispatcher:
		_connection.dispatcher.mcp_logging = enabled
	_log_display.visible = enabled


func _refresh_setup_status() -> void:
	# Clear previous indicators
	for child in _setup_container.get_children():
		child.queue_free()
	_dev_server_btn = null

	var is_dev := McpClientConfigurator.is_dev_checkout()
	if is_dev:
		_setup_container.add_child(_make_status_row("Mode", "Dev (venv)", Color.CYAN))
		_dev_server_btn = Button.new()
		_dev_server_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_dev_server_btn.pressed.connect(_on_dev_server_pressed)
		_update_dev_server_btn()
		_setup_container.add_child(_dev_server_btn)
		return

	# User mode — check for uv
	var uv_version := McpClientConfigurator.check_uv_version()
	if not uv_version.is_empty():
		_setup_container.add_child(_make_status_row("uv", uv_version, Color.GREEN))
		var ver := McpClientConfigurator.get_plugin_version()
		_setup_container.add_child(_make_status_row("Server", "godot-ai ~= %s" % ver, Color.GREEN))
	else:
		_setup_container.add_child(_make_status_row("uv", "not found", Color.RED))
		var install_btn := Button.new()
		install_btn.text = "Install uv"
		install_btn.pressed.connect(_on_install_uv)
		_setup_container.add_child(install_btn)


func _make_status_row(label_text: String, value_text: String, value_color: Color) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)

	var label := Label.new()
	label.text = label_text
	label.add_theme_font_size_override("font_size", 11)
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	label.custom_minimum_size.x = 50
	row.add_child(label)

	var value := Label.new()
	value.text = value_text
	value.add_theme_font_size_override("font_size", 11)
	value.add_theme_color_override("font_color", value_color)
	row.add_child(value)

	return row


func _update_dev_server_btn() -> void:
	if _dev_server_btn == null:
		return
	if _plugin and _plugin.is_dev_server_running():
		_dev_server_btn.text = "Stop Dev Server"
	else:
		_dev_server_btn.text = "Start Dev Server"


func _on_dev_server_pressed() -> void:
	if _plugin == null:
		return
	if _plugin.is_dev_server_running():
		_plugin.stop_dev_server()
	else:
		_plugin.start_dev_server()
	# Defer UI update to let port state settle
	_update_dev_server_btn.call_deferred()


func _on_install_uv() -> void:
	match OS.get_name():
		"Windows":
			OS.execute("powershell", ["-ExecutionPolicy", "ByPass", "-c", "irm https://astral.sh/uv/install.ps1 | iex"], [], false)
		_:
			OS.execute("bash", ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"], [], false)
	_refresh_setup_status.call_deferred()


func _on_configure_client(client_name: String) -> void:
	var client_type: int = McpClientConfigurator.client_type_from_string(client_name)
	if client_type < 0:
		return
	var result := McpClientConfigurator.configure(client_type as McpClientConfigurator.ClientType)
	var row: Dictionary = _client_rows.get(client_name, {})
	if row.has("status_label"):
		if result.get("status") == "ok":
			row["status_label"].text = "configured"
			row["status_label"].add_theme_color_override("font_color", Color.GREEN)
		else:
			row["status_label"].text = "failed"
			row["status_label"].add_theme_color_override("font_color", Color.RED)


func _refresh_client_status() -> void:
	for client_name in McpClientConfigurator.CLIENT_TYPE_MAP:
		var client_type: McpClientConfigurator.ClientType = McpClientConfigurator.CLIENT_TYPE_MAP[client_name]
		var status := McpClientConfigurator.check_status(client_type)
		var row: Dictionary = _client_rows.get(client_name, {})
		if not row.has("status_label"):
			continue
		match status:
			McpClientConfigurator.ConfigStatus.CONFIGURED:
				row["status_label"].text = "configured"
				row["status_label"].add_theme_color_override("font_color", Color.GREEN)
				row["button"].text = "Reconfigure"
			McpClientConfigurator.ConfigStatus.NOT_CONFIGURED:
				row["status_label"].text = "not configured"
				row["status_label"].add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
				row["button"].text = "Configure"
