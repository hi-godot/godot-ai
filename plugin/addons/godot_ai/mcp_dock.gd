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
var _client_grid: VBoxContainer
var _client_configure_all_btn: Button
var _clients_summary_label: Label
var _clients_window: Window
var _dev_mode_toggle: CheckButton

## Per-client UI handles, keyed by client id. Each entry holds the row's
## status dot, configure button, remove button, manual-command panel + text.
var _client_rows: Dictionary = {}

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
var _last_status_text := ""
var _startup_grace_until_msec: int = 0

# First-run grace: uvx installs 60+ Python packages on first run (can take
# 10-30s on a slow connection). Don't scare users with "Disconnected" during
# that window — show "Starting server…" instead. After this expires, fall
# back to the normal disconnect UI.
const STARTUP_GRACE_MSEC := 60 * 1000

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
	_startup_grace_until_msec = Time.get_ticks_msec() + STARTUP_GRACE_MSEC


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
	# Amber on first paint — matches the "Starting server…" label text and
	# distinguishes from a real disconnect (red).
	_status_icon.color = Color(1.0, 0.75, 0.25)
	var icon_center := CenterContainer.new()
	icon_center.add_child(_status_icon)
	status_row.add_child(icon_center)

	_status_label = Label.new()
	# Start in grace state — _update_status will take over on the next frame
	# once the connection is available. Never show bare "Disconnected" on
	# first paint because that's misleading while the server is still
	# spinning up.
	_status_label.text = "Starting server…"
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

	# --- Clients ---
	var clients_row := HBoxContainer.new()
	clients_row.add_theme_constant_override("separation", 8)

	var clients_header := _make_header("Clients")
	clients_row.add_child(clients_header)

	_clients_summary_label = Label.new()
	_clients_summary_label.add_theme_color_override("font_color", COLOR_MUTED)
	_clients_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clients_row.add_child(_clients_summary_label)

	var clients_open_btn := Button.new()
	clients_open_btn.text = "Configure Clients"
	clients_open_btn.pressed.connect(_on_open_clients_window)
	clients_row.add_child(clients_open_btn)

	add_child(clients_row)

	_clients_window = Window.new()
	_clients_window.title = "Configure MCP Clients"
	_clients_window.min_size = Vector2i(560, 400)
	_clients_window.visible = false
	_clients_window.close_requested.connect(_on_clients_window_close_requested)
	add_child(_clients_window)

	var window_margin := MarginContainer.new()
	window_margin.anchor_right = 1.0
	window_margin.anchor_bottom = 1.0
	window_margin.add_theme_constant_override("margin_left", 12)
	window_margin.add_theme_constant_override("margin_right", 12)
	window_margin.add_theme_constant_override("margin_top", 12)
	window_margin.add_theme_constant_override("margin_bottom", 12)
	_clients_window.add_child(window_margin)

	var window_body := VBoxContainer.new()
	window_body.add_theme_constant_override("separation", 8)
	window_margin.add_child(window_body)

	_client_configure_all_btn = Button.new()
	_client_configure_all_btn.text = "Configure all"
	_client_configure_all_btn.tooltip_text = "Configure every client that isn't already pointing at this server"
	_client_configure_all_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	_client_configure_all_btn.pressed.connect(_on_configure_all_clients)
	window_body.add_child(_client_configure_all_btn)

	var clients_scroll := ScrollContainer.new()
	clients_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clients_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	clients_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	window_body.add_child(clients_scroll)

	_client_grid = VBoxContainer.new()
	_client_grid.add_theme_constant_override("separation", 4)
	_client_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clients_scroll.add_child(_client_grid)

	for client_id in McpClientConfigurator.client_ids():
		_build_client_row(client_id)

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
	_refresh_all_client_statuses.call_deferred()


func _make_header(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", COLOR_HEADER)
	return label


func _build_client_row(client_id: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(10, 10)
	dot.color = COLOR_MUTED
	var dot_center := CenterContainer.new()
	dot_center.add_child(dot)
	row.add_child(dot_center)

	var name_label := Label.new()
	name_label.text = McpClientConfigurator.client_display_name(client_id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var configure_btn := Button.new()
	configure_btn.text = "Configure"
	configure_btn.pressed.connect(_on_configure_client.bind(client_id))
	row.add_child(configure_btn)

	var remove_btn := Button.new()
	remove_btn.text = "Remove"
	remove_btn.visible = false
	remove_btn.pressed.connect(_on_remove_client.bind(client_id))
	row.add_child(remove_btn)

	_client_grid.add_child(row)

	var manual_panel := VBoxContainer.new()
	manual_panel.add_theme_constant_override("separation", 4)
	manual_panel.visible = false

	var manual_hint := Label.new()
	manual_hint.text = "Run this manually:"
	manual_hint.add_theme_color_override("font_color", COLOR_MUTED)
	manual_panel.add_child(manual_hint)

	var manual_text := TextEdit.new()
	manual_text.editable = false
	manual_text.custom_minimum_size = Vector2(0, 60)
	manual_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	manual_panel.add_child(manual_text)

	var copy_btn := Button.new()
	copy_btn.text = "Copy"
	copy_btn.pressed.connect(_on_copy_manual_command.bind(client_id))
	manual_panel.add_child(copy_btn)

	_client_grid.add_child(manual_panel)

	_client_rows[client_id] = {
		"dot": dot,
		"name_label": name_label,
		"configure_btn": configure_btn,
		"remove_btn": remove_btn,
		"manual_panel": manual_panel,
		"manual_text": manual_text,
	}


# --- Status updates ---

func _update_status() -> void:
	var connected := _connection.is_connected
	var status_text: String
	var status_color: Color

	if connected:
		status_text = "Connected"
		status_color = Color.GREEN
	elif Time.get_ticks_msec() < _startup_grace_until_msec:
		# Inside startup grace — distinguish from real disconnect so first-run
		# users don't assume it's broken while uvx is downloading packages.
		status_text = "Starting server…"
		status_color = Color(1.0, 0.75, 0.25)  # amber
	else:
		status_text = "Disconnected"
		status_color = Color.RED

	var changed := connected != _last_connected or status_text != _last_status_text
	if not changed:
		return
	_last_connected = connected
	_last_status_text = status_text
	_status_icon.color = status_color
	_status_label.text = status_text

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
	# Default OFF for every install (including dev checkouts). Contributors
	# who want the extra diagnostic UI (Reload Plugin, Reconnect, MCP log
	# panel, Start/Stop Dev Server) can flip the toggle once — editor
	# settings persist across sessions.
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return false
	if not es.has_setting(DEV_MODE_SETTING):
		es.set_setting(DEV_MODE_SETTING, false)
		return false
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

func _on_configure_client(client_id: String) -> void:
	var result := McpClientConfigurator.configure(client_id)
	if result.get("status") == "ok":
		_apply_row_status(client_id, McpClient.Status.CONFIGURED)
		_client_rows[client_id]["manual_panel"].visible = false
	else:
		_apply_row_status(client_id, McpClient.Status.ERROR, str(result.get("message", "failed")))
		_show_manual_command_for(client_id)
	_refresh_clients_summary()


func _on_remove_client(client_id: String) -> void:
	var result := McpClientConfigurator.remove(client_id)
	if result.get("status") == "ok":
		_apply_row_status(client_id, McpClient.Status.NOT_CONFIGURED)
		_client_rows[client_id]["manual_panel"].visible = false
	else:
		_apply_row_status(client_id, McpClient.Status.ERROR, str(result.get("message", "failed")))
	_refresh_clients_summary()


func _on_configure_all_clients() -> void:
	for client_id in McpClientConfigurator.client_ids():
		if McpClientConfigurator.check_status(client_id) == McpClient.Status.CONFIGURED:
			continue
		_on_configure_client(client_id)
	_refresh_clients_summary()


func _on_open_clients_window() -> void:
	if _clients_window == null:
		return
	# popup_centered() with a minsize forces the window to that size and
	# centers on the parent viewport. Setting .size on a hidden Window
	# doesn't always take effect, so we force it at popup time here.
	_clients_window.popup_centered(Vector2i(640, 600))


func _on_clients_window_close_requested() -> void:
	if _clients_window != null:
		_clients_window.hide()


func _refresh_clients_summary() -> void:
	# Count from row dot colors — `_apply_row_status` is the single source of
	# truth, and reading colors avoids re-running filesystem-hitting status
	# checks on every refresh.
	if _clients_summary_label == null:
		return
	var configured := 0
	for row in _client_rows.values():
		if (row["dot"] as ColorRect).color == Color.GREEN:
			configured += 1
	_clients_summary_label.text = "%d / %d configured" % [configured, _client_rows.size()]


func _show_manual_command_for(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	var cmd := McpClientConfigurator.manual_command(client_id)
	if cmd.is_empty():
		row["manual_panel"].visible = false
		return
	row["manual_text"].text = cmd
	row["manual_panel"].visible = true


func _on_copy_manual_command(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	DisplayServer.clipboard_set(row["manual_text"].text)


func _refresh_all_client_statuses() -> void:
	for client_id in _client_rows:
		var status := McpClientConfigurator.check_status(client_id)
		_apply_row_status(client_id, status)
	_refresh_clients_summary()


func _apply_row_status(client_id: String, status: McpClient.Status, error_msg: String = "") -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	var dot: ColorRect = row["dot"]
	var configure_btn: Button = row["configure_btn"]
	var remove_btn: Button = row["remove_btn"]
	var name_label: Label = row["name_label"]
	var base_name := McpClientConfigurator.client_display_name(client_id)
	match status:
		McpClient.Status.CONFIGURED:
			dot.color = Color.GREEN
			configure_btn.text = "Reconfigure"
			remove_btn.visible = true
			name_label.text = base_name
		McpClient.Status.NOT_CONFIGURED:
			dot.color = COLOR_MUTED
			configure_btn.text = "Configure"
			remove_btn.visible = false
			var installed := McpClientConfigurator.is_installed(client_id)
			name_label.text = base_name if installed else "%s  (not detected)" % base_name
		_:
			dot.color = Color.RED
			configure_btn.text = "Retry"
			remove_btn.visible = false
			name_label.text = "%s — %s" % [base_name, error_msg] if not error_msg.is_empty() else base_name


# --- Update check & self-update ---

func _check_for_updates() -> void:
	## In a dev checkout `addons/godot_ai/` is a symlink into the canonical
	## `plugin/` tree, so `FileAccess.open(..., WRITE)` during self-update
	## follows the symlink and overwrites the user's source files in place.
	## Devs update via `git pull`, not the dock — skip the GitHub check
	## entirely to avoid even offering the destructive path. See #116.
	if McpClientConfigurator.is_dev_checkout():
		return
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
	## Belt-and-suspenders check. The banner is already gated on
	## is_dev_checkout() in _check_for_updates, but a stale cached
	## _latest_download_url or a code-path change that bypasses the banner
	## gate would still reach here. In a dev checkout `addons/godot_ai/`
	## is a symlink; writing into it clobbers the canonical source tree.
	## Bail before touching disk. See #116.
	if McpClientConfigurator.is_dev_checkout():
		_update_btn.text = "Dev checkout — update via git"
		_update_btn.disabled = true
		_update_banner.visible = false
		return

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

	## Kill the old server before the reload so the re-enabled plugin spawns
	## a fresh one against the new plugin version. Without this, the running
	## Python process on port 8000 outlives the reload, `_start_server`
	## short-circuits on "port already in use," and session_list reports
	## `plugin_version != server_version` until the user restarts the
	## editor. See issue #132.
	if _plugin != null and _plugin.has_method("prepare_for_update_reload"):
		_plugin.prepare_for_update_reload()

	# Godot 4.4+ handles plugin reload safely. On 4.3 and older, toggling
	# the plugin off/on can cause re-entrant server spawns, so we ask the
	# user to restart the editor instead.
	var version := Engine.get_version_info()
	if version.get("minor", 0) >= 4:
		_update_btn.text = "Scanning..."
		## Before reloading the plugin we MUST wait for Godot's filesystem
		## scanner to see the newly-extracted files. Otherwise plugin.gd
		## re-parses and its `class_name` references (GameLogBuffer,
		## McpDebuggerPlugin, …) resolve against a ClassDB that hasn't
		## picked up the new files yet — parse errors, dock tears down,
		## plugin reports "enabled" with no UI. See issue #127.
		var fs := EditorInterface.get_resource_filesystem()
		if fs != null:
			fs.filesystem_changed.connect(_on_filesystem_scanned_for_update, CONNECT_ONE_SHOT)
			fs.scan()
		else:
			## Fallback: no filesystem accessor — defer and hope (matches
			## the pre-#127 behaviour).
			_reload_after_update.call_deferred()
	else:
		_update_btn.text = "Restart editor to apply"
		_update_btn.disabled = true
		_update_label.text = "Updated! Restart the editor."
		_update_label.add_theme_color_override("font_color", Color.GREEN)


func _on_filesystem_scanned_for_update() -> void:
	_update_btn.text = "Reloading..."
	_reload_after_update.call_deferred()


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
