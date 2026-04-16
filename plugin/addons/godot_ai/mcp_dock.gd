@tool
class_name McpDock
extends VBoxContainer

## Editor dock panel showing MCP connection status, client config, and command log.

const DEV_MODE_SETTING := "godot_ai/dev_mode"
static var COLOR_MUTED := Color(0.7, 0.7, 0.7)
static var COLOR_HEADER := Color(0.95, 0.95, 0.95)

var _connection: Connection
var _log_buffer: McpLogBuffer
var _plugin: EditorPlugin

# Always visible
var _redock_btn: Button
var _status_icon: ColorRect
var _status_label: Label
var _client_dropdown: OptionButton
var _client_status_label: Label
var _client_configure_btn: Button
var _client_manual_panel: VBoxContainer
var _client_manual_text: TextEdit
var _dev_mode_toggle: CheckButton

# Dev-mode only
var _dev_section: VBoxContainer
var _server_label: Label
var _reconnect_btn: Button
var _reload_btn: Button
var _setup_section: VBoxContainer
var _setup_container: VBoxContainer
var _dev_server_btn: Button
var _log_section: VBoxContainer
var _log_display: RichTextLabel
var _log_toggle: CheckButton

var _last_log_count := 0
var _last_connected := false
var _client_keys: Array[String] = []

# Update check
var _update_banner: VBoxContainer
var _http_request: HTTPRequest
var _download_request: HTTPRequest
var _update_label: Label
var _update_btn: Button
var _latest_download_url := ""
const RELEASES_URL := "https://api.github.com/repos/hi-godot/godot-ai/releases/latest"
const RELEASES_PAGE := "https://github.com/hi-godot/godot-ai/releases/latest"
const UPDATE_TEMP_DIR := "user://godot_ai_update/"
const UPDATE_TEMP_ZIP := "user://godot_ai_update/update.zip"


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
	if _log_section.visible:
		_update_log()


func _notification(what: int) -> void:
	# Detect dock/undock by watching for reparenting events.
	if what == NOTIFICATION_PARENTED or what == NOTIFICATION_UNPARENTED:
		_update_redock_visibility.call_deferred()


func _is_floating() -> bool:
	var p := get_parent()
	while p != null:
		if p is Window:
			return p != get_tree().root
		p = p.get_parent()
	return false


func _update_redock_visibility() -> void:
	if _redock_btn == null:
		return
	var floating := _is_floating()
	if _redock_btn.visible != floating:
		_redock_btn.visible = floating


func _on_redock() -> void:
	# When floating, our Window is NOT the editor root. Closing it triggers
	# Godot's internal dock-return logic (same as clicking the window's X).
	var win := get_window()
	if win != null and win != get_tree().root:
		win.close_requested.emit()


func _build_ui() -> void:
	add_theme_constant_override("separation", 8)

	# --- Top row: status indicator + redock button (when floating) ---
	var status_row := HBoxContainer.new()
	status_row.add_theme_constant_override("separation", 8)

	_status_icon = ColorRect.new()
	_status_icon.custom_minimum_size = Vector2(14, 14)
	_status_icon.color = Color.RED
	var icon_center := CenterContainer.new()
	icon_center.add_child(_status_icon)
	status_row.add_child(icon_center)

	_status_label = Label.new()
	_status_label.text = "Disconnected"
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_row.add_child(_status_label)

	_redock_btn = Button.new()
	_redock_btn.text = "Dock"
	_redock_btn.tooltip_text = "Return this panel to the editor dock"
	_redock_btn.visible = false
	_redock_btn.pressed.connect(_on_redock)
	status_row.add_child(_redock_btn)

	add_child(status_row)

	# --- Update banner (top of dock, hidden until check finds a newer version) ---
	_update_banner = VBoxContainer.new()
	_update_banner.add_theme_constant_override("separation", 4)
	_update_banner.visible = false

	_update_label = Label.new()
	_update_label.add_theme_font_size_override("font_size", 15)
	_update_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	_update_banner.add_child(_update_label)

	var update_btn_row := HBoxContainer.new()
	update_btn_row.add_theme_constant_override("separation", 6)

	_update_btn = Button.new()
	_update_btn.text = "Update"
	_update_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_update_btn.pressed.connect(_on_update_pressed)
	update_btn_row.add_child(_update_btn)

	var release_link := Button.new()
	release_link.text = "Release notes"
	release_link.pressed.connect(func(): OS.shell_open(RELEASES_PAGE))
	update_btn_row.add_child(release_link)

	_update_banner.add_child(update_btn_row)
	_update_banner.add_child(HSeparator.new())

	add_child(_update_banner)

	_http_request = HTTPRequest.new()
	_http_request.request_completed.connect(_on_update_check_completed)
	add_child(_http_request)
	_check_for_updates.call_deferred()

	# --- Dev-only connection extras (server label + reconnect/reload buttons) ---
	_dev_section = VBoxContainer.new()
	_dev_section.add_theme_constant_override("separation", 6)
	add_child(_dev_section)

	_server_label = Label.new()
	_server_label.text = "WS: %d  HTTP: %d" % [McpClientConfigurator.SERVER_WS_PORT, McpClientConfigurator.SERVER_HTTP_PORT]
	_server_label.add_theme_color_override("font_color", COLOR_MUTED)
	_dev_section.add_child(_server_label)

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)

	_reconnect_btn = Button.new()
	_reconnect_btn.text = "Reconnect"
	_reconnect_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reconnect_btn.pressed.connect(_on_reconnect)
	btn_row.add_child(_reconnect_btn)

	_reload_btn = Button.new()
	_reload_btn.text = "Reload Plugin"
	_reload_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reload_btn.pressed.connect(_on_reload_plugin)
	btn_row.add_child(_reload_btn)

	_dev_section.add_child(btn_row)

	# --- Setup section (dev-only or when uv missing) ---
	_setup_section = VBoxContainer.new()
	_setup_section.add_theme_constant_override("separation", 6)
	add_child(_setup_section)

	_setup_section.add_child(HSeparator.new())
	_setup_section.add_child(_make_header("Setup"))
	_setup_container = VBoxContainer.new()
	_setup_container.add_theme_constant_override("separation", 6)
	_setup_section.add_child(_setup_container)

	add_child(HSeparator.new())

	# --- Client config (dropdown, no separate header needed) ---
	var client_row := HBoxContainer.new()
	client_row.add_theme_constant_override("separation", 6)

	_client_dropdown = OptionButton.new()
	_client_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for client_name in McpClientConfigurator.CLIENT_TYPE_MAP:
		_client_dropdown.add_item(_pretty_client_name(client_name))
		_client_keys.append(client_name)
	_client_dropdown.item_selected.connect(_on_client_selected)
	client_row.add_child(_client_dropdown)

	_client_configure_btn = Button.new()
	_client_configure_btn.text = "Configure"
	_client_configure_btn.pressed.connect(_on_configure_selected_client)
	client_row.add_child(_client_configure_btn)

	add_child(client_row)

	_client_status_label = Label.new()
	_client_status_label.text = "..."
	_client_status_label.add_theme_color_override("font_color", COLOR_MUTED)
	add_child(_client_status_label)

	# Manual-command fallback panel (hidden until auto-configure fails)
	_client_manual_panel = VBoxContainer.new()
	_client_manual_panel.add_theme_constant_override("separation", 4)
	_client_manual_panel.visible = false

	var manual_hint := Label.new()
	manual_hint.text = "Run this manually:"
	manual_hint.add_theme_color_override("font_color", COLOR_MUTED)
	_client_manual_panel.add_child(manual_hint)

	_client_manual_text = TextEdit.new()
	_client_manual_text.editable = false
	_client_manual_text.custom_minimum_size = Vector2(0, 60)
	_client_manual_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_client_manual_panel.add_child(_client_manual_text)

	var copy_btn := Button.new()
	copy_btn.text = "Copy"
	copy_btn.pressed.connect(_on_copy_manual_command)
	_client_manual_panel.add_child(copy_btn)

	add_child(_client_manual_panel)

	add_child(HSeparator.new())

	# --- Dev mode toggle (always visible) ---
	var dev_toggle_row := HBoxContainer.new()
	var dev_toggle_label := Label.new()
	dev_toggle_label.text = "Developer mode"
	dev_toggle_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dev_toggle_row.add_child(dev_toggle_label)

	_dev_mode_toggle = CheckButton.new()
	_dev_mode_toggle.button_pressed = _load_dev_mode()
	_dev_mode_toggle.toggled.connect(_on_dev_mode_toggled)
	dev_toggle_row.add_child(_dev_mode_toggle)
	add_child(dev_toggle_row)

	# --- Log section (dev-only) ---
	_log_section = VBoxContainer.new()
	_log_section.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_log_section)

	_log_section.add_child(HSeparator.new())

	var log_header_row := HBoxContainer.new()
	var log_header := _make_header("MCP Log")
	log_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	log_header_row.add_child(log_header)

	_log_toggle = CheckButton.new()
	_log_toggle.text = "Log"
	_log_toggle.button_pressed = true
	_log_toggle.toggled.connect(_on_log_toggled)
	log_header_row.add_child(_log_toggle)

	_log_section.add_child(log_header_row)

	_log_display = RichTextLabel.new()
	_log_display.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_display.custom_minimum_size = Vector2(0, 120)
	_log_display.scroll_following = true
	_log_display.bbcode_enabled = false
	_log_display.selection_enabled = true
	_log_section.add_child(_log_display)

	# Apply initial dev-mode visibility
	_apply_dev_mode_visibility()
	_refresh_setup_status.call_deferred()
	_refresh_client_status.call_deferred()


func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_color", COLOR_HEADER)
	return label


func _pretty_client_name(client_name: String) -> String:
	return client_name.capitalize()


func _selected_client_key() -> String:
	var idx := _client_dropdown.selected
	if idx < 0 or idx >= _client_keys.size():
		return ""
	return _client_keys[idx]


# --- Status updates ---

func _update_status() -> void:
	var connected := _connection.is_connected
	if connected == _last_connected:
		return
	_last_connected = connected

	if connected:
		_status_icon.color = Color.GREEN
		_status_label.text = "Connected"
	else:
		_status_icon.color = Color.RED
		_status_label.text = "Disconnected"

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


# --- Dev mode persistence ---

func _load_dev_mode() -> bool:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return McpClientConfigurator.is_dev_checkout()
	if not es.has_setting(DEV_MODE_SETTING):
		# Default: on for dev checkouts, off for end-users
		var default := McpClientConfigurator.is_dev_checkout()
		es.set_setting(DEV_MODE_SETTING, default)
		return default
	return bool(es.get_setting(DEV_MODE_SETTING))


func _on_dev_mode_toggled(enabled: bool) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(DEV_MODE_SETTING, enabled)
	_apply_dev_mode_visibility()
	_refresh_setup_status()


func _apply_dev_mode_visibility() -> void:
	var dev := _dev_mode_toggle.button_pressed
	_dev_section.visible = dev
	_log_section.visible = dev

	# Setup section: visible in dev mode, OR in user mode when uv is missing
	# (so users can install uv from the dock).
	var is_dev := McpClientConfigurator.is_dev_checkout()
	var uv_missing := not is_dev and McpClientConfigurator.check_uv_version().is_empty()
	_setup_section.visible = dev or uv_missing


# --- Button handlers ---

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


# --- Setup section ---

func _refresh_setup_status() -> void:
	if _setup_container == null:
		return
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
	label.add_theme_color_override("font_color", COLOR_MUTED)
	label.custom_minimum_size.x = 60
	row.add_child(label)

	var value := Label.new()
	value.text = value_text
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
	_update_dev_server_btn.call_deferred()


func _on_install_uv() -> void:
	match OS.get_name():
		"Windows":
			OS.execute("powershell", ["-ExecutionPolicy", "ByPass", "-c", "irm https://astral.sh/uv/install.ps1 | iex"], [], false)
		_:
			OS.execute("bash", ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"], [], false)
	_refresh_setup_status.call_deferred()


# --- Client section ---

func _on_client_selected(_index: int) -> void:
	_client_manual_panel.visible = false
	_refresh_client_status()


func _on_configure_selected_client() -> void:
	var key := _selected_client_key()
	if key.is_empty():
		return
	var client_type: int = McpClientConfigurator.client_type_from_string(key)
	if client_type < 0:
		return
	var ct := client_type as McpClientConfigurator.ClientType
	var result := McpClientConfigurator.configure(ct)
	if result.get("status") == "ok":
		_set_client_status_label("configured", Color.GREEN)
		_client_configure_btn.text = "Reconfigure"
		_client_manual_panel.visible = false
	else:
		var msg := str(result.get("message", "failed"))
		_set_client_status_label("error: %s" % msg, Color.RED)
		_show_manual_command(ct)


func _show_manual_command(client_type: McpClientConfigurator.ClientType) -> void:
	var cmd := McpClientConfigurator.manual_command(client_type)
	if cmd.is_empty():
		_client_manual_panel.visible = false
		return
	_client_manual_text.text = cmd
	_client_manual_panel.visible = true


func _on_copy_manual_command() -> void:
	DisplayServer.clipboard_set(_client_manual_text.text)


func _refresh_client_status() -> void:
	var key := _selected_client_key()
	if key.is_empty():
		return
	var client_type: McpClientConfigurator.ClientType = McpClientConfigurator.CLIENT_TYPE_MAP[key]
	var status := McpClientConfigurator.check_status(client_type)
	match status:
		McpClientConfigurator.ConfigStatus.CONFIGURED:
			_set_client_status_label("configured", Color.GREEN)
			_client_configure_btn.text = "Reconfigure"
		McpClientConfigurator.ConfigStatus.NOT_CONFIGURED:
			_set_client_status_label("not configured", COLOR_MUTED)
			_client_configure_btn.text = "Configure"
		_:
			_set_client_status_label("error", Color.RED)
			_client_configure_btn.text = "Configure"


func _set_client_status_label(text: String, color: Color) -> void:
	_client_status_label.text = text
	_client_status_label.add_theme_color_override("font_color", color)


# --- Update check & self-update ---

func _check_for_updates() -> void:
	_http_request.request(RELEASES_URL, ["Accept: application/vnd.github+json"])


func _on_update_check_completed(result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		return
	var json := JSON.parse_string(body.get_string_from_utf8())
	if json == null or not json is Dictionary:
		return
	var tag: String = json.get("tag_name", "")
	if tag.is_empty():
		return
	var remote_version := tag.trim_prefix("v")
	var local_version := McpClientConfigurator.get_plugin_version()
	if not _is_newer(remote_version, local_version):
		return

	# Find the plugin ZIP asset URL
	var assets: Array = json.get("assets", [])
	for asset in assets:
		var name: String = asset.get("name", "")
		if name == "godot-ai-plugin.zip":
			_latest_download_url = asset.get("browser_download_url", "")
			break

	_update_label.text = "Update available: v%s" % remote_version
	_update_banner.visible = true


func _on_update_pressed() -> void:
	if _latest_download_url.is_empty():
		OS.shell_open(RELEASES_PAGE)
		return

	var btn := _update_btn
	btn.text = "Downloading..."
	btn.disabled = true

	# Create a separate HTTPRequest for the ZIP download
	if _download_request != null:
		_download_request.queue_free()
	_download_request = HTTPRequest.new()
	var global_zip := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	var global_dir := ProjectSettings.globalize_path(UPDATE_TEMP_DIR)
	DirAccess.make_dir_recursive_absolute(global_dir)
	_download_request.download_file = global_zip
	_download_request.max_redirects = 10
	_download_request.request_completed.connect(_on_download_completed)
	add_child(_download_request)
	var err := _download_request.request(_latest_download_url)
	if err != OK:
		btn.text = "Request failed"
		btn.disabled = false


func _on_download_completed(result: int, response_code: int, _headers: PackedStringArray, _body: PackedByteArray) -> void:
	if _download_request != null:
		_download_request.queue_free()
		_download_request = null

	var btn := _update_btn
	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		print("MCP | update download failed: result=%d code=%d" % [result, response_code])
		btn.text = "Download failed (%d)" % response_code
		btn.disabled = false
		return

	btn.text = "Installing..."
	# Extract and install on next frame to avoid mid-callback issues
	_install_update.call_deferred()


func _install_update() -> void:
	var zip_path := ProjectSettings.globalize_path(UPDATE_TEMP_ZIP)
	var install_base := ProjectSettings.globalize_path("res://")

	var reader := ZIPReader.new()
	if reader.open(zip_path) != OK:
		_update_btn.text = "Extract failed"
		_update_btn.disabled = false
		return

	var files := reader.get_files()
	for file_path in files:
		if not file_path.begins_with("addons/godot_ai/"):
			continue
		if file_path.ends_with("/"):
			DirAccess.make_dir_recursive_absolute(install_base.path_join(file_path))
		else:
			var dir := file_path.get_base_dir()
			DirAccess.make_dir_recursive_absolute(install_base.path_join(dir))
			var content := reader.read_file(file_path)
			var f := FileAccess.open(install_base.path_join(file_path), FileAccess.WRITE)
			if f != null:
				f.store_buffer(content)
				f.close()

	reader.close()

	# Clean up temp files
	DirAccess.remove_absolute(zip_path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(UPDATE_TEMP_DIR))

	# Godot 4.4+ handles plugin reload safely. On 4.3 and older, toggling
	# the plugin off/on can cause re-entrant server spawns, so we ask the
	# user to restart the editor instead.
	var version := Engine.get_version_info()
	if version.get("minor", 0) >= 4:
		_update_btn.text = "Reloading..."
		_reload_after_update.call_deferred()
	else:
		_update_btn.text = "Restart editor to apply"
		_update_btn.disabled = true
		_update_label.text = "Updated! Restart the editor."
		_update_label.add_theme_color_override("font_color", Color.GREEN)


func _reload_after_update() -> void:
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


static func _is_newer(remote: String, local: String) -> bool:
	var r := remote.split(".")
	var l := local.split(".")
	for i in range(max(r.size(), l.size())):
		var rv := int(r[i]) if i < r.size() else 0
		var lv := int(l[i]) if i < l.size() else 0
		if rv > lv:
			return true
		if rv < lv:
			return false
	return false
