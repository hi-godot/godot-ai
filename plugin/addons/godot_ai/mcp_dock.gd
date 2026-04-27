@tool
class_name McpDock
extends VBoxContainer

## Editor dock panel showing MCP connection status, client config, and command log.

const DEV_MODE_SETTING := "godot_ai/dev_mode"
## Index ↔ persisted-value mapping for the mode-override dropdown. The array
## index is the OptionButton item id; the string is what's written to the
## EditorSetting and read by `McpClientConfigurator.mode_override()`.
const MODE_OVERRIDE_VALUES := ["", "user", "dev"]
const MODE_OVERRIDE_LABELS := ["Auto", "Force user", "Force dev"]
const CLIENT_STATUS_REFRESH_COOLDOWN_MSEC := 15 * 1000
const CLIENT_STATUS_REFRESH_TIMEOUT_MSEC := 30 * 1000
static var COLOR_MUTED := Color(0.7, 0.7, 0.7)
static var COLOR_HEADER := Color(0.95, 0.95, 0.95)
## Used for "in-progress" / "stale, action needed" UI: the startup-grace
## status icon, the spawn-failure suggested-port hint, the drift banner,
## and the per-row mismatch dot. One constant so a future palette tweak
## doesn't have to find every literal.
static var COLOR_AMBER := Color(1.0, 0.75, 0.25)

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
var _install_label: Label

# Tools tab (secondary window, Tab 2) — domain-exclusion UI for clients
# that cap total tool count (Antigravity: 100). Pending set is mutated by
# checkbox clicks; saved set reflects what the spawned server actually
# sees. `Apply & Restart Server` writes pending → setting and triggers a
# plugin reload so the new server comes up with the trimmed list.
var _tools_pending_excluded: PackedStringArray = PackedStringArray()
var _tools_saved_excluded: PackedStringArray = PackedStringArray()
var _tools_domain_checkboxes: Dictionary = {}
var _tools_count_label: Label
var _tools_apply_btn: Button
var _tools_reset_btn: Button
var _tools_dirty_warning: Label
var _tools_close_confirm: ConfirmationDialog

## Per-client UI handles, keyed by client id. Each entry holds the row's
## status dot, configure button, remove button, manual-command panel + text.
var _client_rows: Dictionary = {}

# Drift banner — surfaced near the Clients section when one or more clients
# have a stored entry whose URL no longer matches `http_url()` (typical after
# the user changes `godot_ai/http_port`). Refreshes are stale-while-refreshing:
# cached row dots/banner remain visible while a background worker performs the
# potentially blocking config/CLI probes, then the main thread applies results.
# Automatic focus-in refreshes use a short cooldown to avoid repeated sweeps
# during tab-away/tab-back churn. See #166 and #226.
var _drift_banner: VBoxContainer
var _drift_label: Label
## Handles for the Setup section's "Server" row. `_update_status` keeps
## the label text/color in sync with `Connection.server_version` so the
## dock reports the TRUE running server version, not the plugin's
## expected version. See #174 follow-up — a plugin upgrade via self-
## update can leave the plugin connected to an older adopted server
## (foreign-port branch never sets `_server_pid`, so `_stop_server`
## can't kill it); the line has to show the mismatch honestly.
var _setup_server_label: Label
## Last rendered server-version string. `_update_status` runs every
## frame; early-outs text repaint when nothing changed. Empty means
## "no line rendered yet" (dev-checkout branch doesn't render a
## user-mode Server line).
var _last_rendered_server_text: String = ""
## Restart-server button shown next to the Setup container when
## `Connection.server_version` drifts from the plugin version. Hidden
## in the match case so the UI stays calm.
var _version_restart_btn: Button
## Sorted snapshot of the most recent mismatched-client set. Powers two things:
## (a) the Reconfigure button reuses this list instead of re-running
## `check_status` per row (saves ~18 filesystem reads per click), and
## (b) `_refresh_drift_banner` early-returns when the set is unchanged so
## repeated explicit refreshes don't repaint identical text. Mirrors the
## `_last_server_status` pattern used by the crash panel.
var _last_mismatched_ids: Array[String] = []
var _client_status_refresh_thread: Thread
var _client_status_refresh_in_flight := false
var _client_status_refresh_pending := false
var _client_status_refresh_pending_force := false
var _last_client_status_refresh_completed_msec: int = 0
var _client_status_refresh_started_msec: int = 0
var _client_status_refresh_generation: int = 0
var _client_status_refresh_shutdown_requested := false
var _client_status_refresh_timed_out := false
static var _orphaned_client_status_refresh_threads: Array[Thread] = []

# Dev-mode only
var _dev_section: VBoxContainer
var _server_label: Label
var _reconnect_btn: Button
var _reload_btn: Button
var _mode_override_btn: OptionButton
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

# Spawn-failure panel — rendered when `get_server_status` reports a
# non-OK `state`. One panel, one body paragraph per state, no cascading
# booleans. See `_crash_body_for_state`.
var _crash_panel: VBoxContainer
var _crash_output: RichTextLabel
## Port-picker escape hatch — visible inside the panel when the root
## cause is port contention (PORT_EXCLUDED or FOREIGN_PORT). Applies a
## new `godot_ai/http_port` value and reloads the plugin so the spawn
## retries with the new port.
var _port_picker_section: VBoxContainer
var _port_picker_spinbox: SpinBox
## Last status Dict rendered into the panel — used to skip re-population
## when nothing changed, which would otherwise reset the user's scroll
## position on every frame. GDScript Dicts compare by value with `==`.
var _last_server_status: Dictionary = {}

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
	_prune_orphaned_client_status_refresh_threads()
	_check_client_status_refresh_timeout()
	_update_status()
	if _log_section.visible:
		_update_log()


func _exit_tree() -> void:
	## Block on any in-flight refresh worker before letting the dock leave the
	## tree. The plugin disable path (editor_reload_plugin, Project Settings
	## toggle) reloads the McpDock script class — which wipes the static
	## `_orphaned_client_status_refresh_threads`, GCs the Thread objects mid-
	## execution, and triggers `~Thread … destroyed without its completion
	## having been realized` plus GDScript VM corruption (Opcode: 0, IP-bounds
	## errors, intermittent SIGSEGV). Probes finish in well under a second
	## under normal conditions; if a CLI probe genuinely hung, the runtime
	## timeout path (`_abandon_client_status_refresh_thread`) has already
	## moved that thread into the orphan list, so we drain it here too.
	##
	## `wait_to_finish` is unbounded by design: GDScript's Thread API has no
	## timeout, and a polling/abandon fallback would just re-introduce the
	## GC-mid-execution crash this fix exists to prevent. Blocking the editor
	## briefly on plugin-reload is strictly better than the SIGSEGV.
	_client_status_refresh_shutdown_requested = true
	_client_status_refresh_generation += 1
	if _client_status_refresh_thread != null:
		_client_status_refresh_thread.wait_to_finish()
		_client_status_refresh_thread = null
	for thread in _orphaned_client_status_refresh_threads:
		if thread != null:
			thread.wait_to_finish()
	_orphaned_client_status_refresh_threads.clear()
	_client_status_refresh_in_flight = false
	_client_status_refresh_pending = false
	_client_status_refresh_pending_force = false


func _notification(what: int) -> void:
	# Detect dock/undock by watching for reparenting events.
	if what == NOTIFICATION_PARENTED or what == NOTIFICATION_UNPARENTED:
		_update_redock_visibility.call_deferred()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if _should_refresh_client_statuses_on_focus_in():
			_request_client_status_refresh(false)


func _should_refresh_client_statuses_on_focus_in() -> bool:
	## Focus-in is part of Godot/editor window activation. Keep automatic refresh,
	## but only through the async/cooldown-protected path; never run a blocking
	## client-status sweep directly from this notification.
	return true


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
	_status_icon.color = COLOR_AMBER
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

	# Install-mode line — so a git-clone user doesn't press the yellow Update
	# banner below and silently downgrade from main to the last release tag.
	# See #144.
	_install_label = Label.new()
	_install_label.add_theme_color_override("font_color", COLOR_MUTED)
	_install_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_install_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_install_label.text = _install_mode_text()
	_install_label.tooltip_text = _install_mode_tooltip()
	_install_label.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_install_label)

	# --- Spawn-failure panel (shown when `_start_server` reports a non-OK
	# state via `get_server_status`). One body paragraph + the matching
	# action; the top status label already carries the state headline.
	_crash_panel = VBoxContainer.new()
	_crash_panel.add_theme_constant_override("separation", 6)
	_crash_panel.visible = false

	_crash_output = RichTextLabel.new()
	_crash_output.custom_minimum_size = Vector2(0, 60)
	_crash_output.bbcode_enabled = false
	_crash_output.selection_enabled = true
	_crash_output.scroll_following = false
	_crash_output.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_crash_output.fit_content = true
	_crash_panel.add_child(_crash_output)

	_build_port_picker_section()

	var crash_retry := Button.new()
	crash_retry.text = "Reload Plugin"
	crash_retry.tooltip_text = "Re-run the spawn after fixing the underlying issue"
	crash_retry.pressed.connect(_on_reload_plugin)
	_crash_panel.add_child(crash_retry)

	_crash_panel.add_child(HSeparator.new())
	add_child(_crash_panel)

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
	_server_label.add_theme_color_override("font_color", COLOR_MUTED)
	_dev_section.add_child(_server_label)
	_refresh_server_label()

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

	# Dev-only override for testing the update-banner flow; persisted via EditorSettings.
	var mode_row := HBoxContainer.new()
	mode_row.add_theme_constant_override("separation", 6)
	var mode_label := Label.new()
	mode_label.text = "Mode override"
	mode_label.tooltip_text = "Force dev or user mode for testing the update flow. Normally leave on Auto. GODOT_AI_MODE env var is the fallback when this is Auto."
	mode_row.add_child(mode_label)
	_mode_override_btn = OptionButton.new()
	_mode_override_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in MODE_OVERRIDE_LABELS.size():
		_mode_override_btn.add_item(MODE_OVERRIDE_LABELS[i], i)
	_mode_override_btn.tooltip_text = mode_label.tooltip_text
	_mode_override_btn.select(_mode_override_index_from_setting())
	_mode_override_btn.item_selected.connect(_on_mode_override_selected)
	mode_row.add_child(_mode_override_btn)
	_dev_section.add_child(mode_row)

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

	var clients_refresh_btn := Button.new()
	clients_refresh_btn.text = "Refresh"
	clients_refresh_btn.tooltip_text = "Refresh client status in the background. Cached status stays visible while checks run."
	clients_refresh_btn.pressed.connect(_on_refresh_clients_pressed)
	clients_row.add_child(clients_refresh_btn)

	var clients_open_btn := Button.new()
	clients_open_btn.text = "Clients & Tools"
	clients_open_btn.tooltip_text = "Open the MCP settings window — configure AI clients or disable tool domains to fit under a client's hard tool-count cap (e.g. Antigravity's 100)."
	clients_open_btn.pressed.connect(_on_open_clients_window)
	clients_row.add_child(clients_open_btn)

	add_child(clients_row)

	# Drift banner — hidden until a sweep finds at least one mismatched client.
	_drift_banner = VBoxContainer.new()
	_drift_banner.add_theme_constant_override("separation", 4)
	_drift_banner.visible = false
	_drift_label = Label.new()
	_drift_label.add_theme_color_override("font_color", COLOR_AMBER)
	_drift_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_drift_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_drift_banner.add_child(_drift_label)
	var drift_btn := Button.new()
	drift_btn.text = "Reconfigure mismatched"
	drift_btn.tooltip_text = "Re-run Configure on every client whose stored URL doesn't match the current server URL."
	drift_btn.pressed.connect(_on_reconfigure_mismatched)
	_drift_banner.add_child(drift_btn)
	add_child(_drift_banner)

	_clients_window = Window.new()
	_clients_window.title = "MCP Clients & Tools"
	_clients_window.min_size = Vector2i(560, 460)
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

	## Two-tab secondary window: Clients (existing per-client rows) and Tools
	## (domain-exclusion checkboxes for clients that cap total tool count,
	## like Antigravity at 100). Adding a third tab is one more _build_*_tab
	## call and a set_tab_title line — no surgery on the rest of the window.
	var tabs := TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	window_margin.add_child(tabs)

	var clients_tab := VBoxContainer.new()
	clients_tab.name = "Clients"
	clients_tab.add_theme_constant_override("separation", 8)
	tabs.add_child(clients_tab)

	_client_configure_all_btn = Button.new()
	_client_configure_all_btn.text = "Configure all"
	_client_configure_all_btn.tooltip_text = "Configure every client that isn't already pointing at this server"
	_client_configure_all_btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	_client_configure_all_btn.pressed.connect(_on_configure_all_clients)
	clients_tab.add_child(_client_configure_all_btn)

	var clients_scroll := ScrollContainer.new()
	clients_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clients_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	clients_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	clients_tab.add_child(clients_scroll)

	_client_grid = VBoxContainer.new()
	_client_grid.add_theme_constant_override("separation", 4)
	_client_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clients_scroll.add_child(_client_grid)

	for client_id in McpClientConfigurator.client_ids():
		_build_client_row(client_id)

	_build_tools_tab(tabs)

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
	_request_client_status_refresh.call_deferred(true)


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
		"status": McpClient.Status.NOT_CONFIGURED,
		"name_label": name_label,
		"configure_btn": configure_btn,
		"remove_btn": remove_btn,
		"manual_panel": manual_panel,
		"manual_text": manual_text,
	}


# --- Status updates ---

func _update_status() -> void:
	var connected := _connection.is_connected
	## During plugin self-update there's a brief window where this dock
	## script is already the new version (Godot hot-reloads scripts on
	## file change) but `_plugin` is still the old `EditorPlugin` instance
	## (only `set_plugin_enabled(false, true)` re-instantiates that). When
	## the new dock calls a method the old plugin doesn't have, `_process`
	## errors every frame until the deferred `_reload_after_update` lands.
	## Guard every `_plugin.<new_method>()` call with `has_method` so that
	## window stays silent. See #168.
	var server_status: Dictionary = (
		_plugin.get_server_status()
		if _plugin != null and _plugin.has_method("get_server_status")
		else {}
	)
	var state: String = server_status.get("state", McpSpawnState.OK)

	## One `match`/`elif` chain, one source of truth. Adding a new
	## spawn outcome = one `McpSpawnState` constant + one arm here +
	## one body string in `_crash_body_for_state`.
	var status_text: String
	var status_color: Color
	if connected:
		status_text = "Connected"
		status_color = Color.GREEN
	elif state == McpSpawnState.CRASHED:
		var exit_ms: int = server_status.get("exit_ms", 0)
		status_text = "Server exited after %.1fs" % (exit_ms / 1000.0)
		status_color = Color.RED
	elif state == McpSpawnState.PORT_EXCLUDED:
		status_text = "Port %d reserved by Windows" % McpClientConfigurator.http_port()
		status_color = Color.RED
	elif state == McpSpawnState.FOREIGN_PORT:
		status_text = "Port %d held by another process" % McpClientConfigurator.http_port()
		status_color = Color.RED
	elif state == McpSpawnState.NO_COMMAND:
		status_text = "No server command found"
		status_color = Color.RED
	elif Time.get_ticks_msec() < _startup_grace_until_msec:
		## Inside startup grace — distinguish from real disconnect so
		## first-run users don't assume it's broken while uvx downloads.
		status_text = "Starting server…"
		status_color = COLOR_AMBER
	else:
		status_text = "Disconnected"
		status_color = Color.RED

	_update_crash_panel(server_status)
	_refresh_server_version_label()

	var changed := connected != _last_connected or status_text != _last_status_text
	if not changed:
		return
	_last_connected = connected
	_last_status_text = status_text
	_status_icon.color = status_color
	_status_label.text = status_text

	_update_dev_server_btn()


## Render the diagnostic panel body for a given spawn state. The top
## status label already names the problem; this answers "what do I do?".
## Panel shows for any non-OK state; picker shows when the root cause
## is port contention (same escape applies to PORT_EXCLUDED + FOREIGN_PORT).
func _update_crash_panel(server_status: Dictionary) -> void:
	var state: String = server_status.get("state", McpSpawnState.OK)
	if state == McpSpawnState.OK:
		if _crash_panel.visible:
			_crash_panel.visible = false
			_last_server_status = {}
		return
	if server_status == _last_server_status:
		return
	_last_server_status = server_status.duplicate()
	_crash_panel.visible = true
	_crash_output.clear()
	_crash_output.add_text(_crash_body_for_state(state))

	var port_picker_visible := state == McpSpawnState.PORT_EXCLUDED or state == McpSpawnState.FOREIGN_PORT
	_port_picker_section.visible = port_picker_visible
	if port_picker_visible:
		## Seed the SpinBox with a suggested non-reserved port each time
		## the panel surfaces. Idempotent when the user already has a
		## good candidate queued up.
		_port_picker_spinbox.value = McpClientConfigurator.suggest_free_port(
			McpClientConfigurator.http_port() + 1
		)


static func _crash_body_for_state(state: String) -> String:
	## Single sentence per state. The top status label already names the
	## problem; don't repeat it here. This copy answers "what do I do?".
	var port := McpClientConfigurator.http_port()
	match state:
		McpSpawnState.PORT_EXCLUDED:
			return "Windows (Hyper-V / WSL2 / Docker) reserved port %d. Pick a free port or try `net stop winnat; net start winnat` in an admin shell." % port
		McpSpawnState.FOREIGN_PORT:
			return "Another process is already bound to port %d. Pick a free port or stop the other process." % port
		McpSpawnState.CRASHED:
			## Both spawn attempts failed on the uvx tier — almost always
			## means PyPI hasn't propagated this version yet (~10 min after
			## publish). `_start_server` already tried `--refresh` once, so
			## the next realistic move is to wait and reload.
			if McpClientConfigurator.get_server_launch_mode() == "uvx":
				var version := McpClientConfigurator.get_plugin_version()
				return "The server exited before the WebSocket handshake, even after a `uvx --refresh` retry. If this is a brand-new release, PyPI's index may still be propagating (~10 min). Wait a moment and click Reload Plugin to retry, or check Godot's output log for Python's traceback. Target: godot-ai==%s." % version
			return "The server exited before the WebSocket handshake. Check Godot's output log (bottom panel) for Python's traceback."
		McpSpawnState.NO_COMMAND:
			return "No godot-ai server found. Install `uv` via the Setup panel above, or run `pip install godot-ai`."
		_:
			return ""


func _build_port_picker_section() -> void:
	_port_picker_section = VBoxContainer.new()
	_port_picker_section.add_theme_constant_override("separation", 4)
	_port_picker_section.visible = false

	var picker_row := HBoxContainer.new()
	picker_row.add_theme_constant_override("separation", 6)

	_port_picker_spinbox = SpinBox.new()
	_port_picker_spinbox.min_value = McpClientConfigurator.MIN_PORT
	_port_picker_spinbox.max_value = McpClientConfigurator.MAX_PORT
	_port_picker_spinbox.step = 1
	_port_picker_spinbox.value = McpClientConfigurator.http_port()
	_port_picker_spinbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker_row.add_child(_port_picker_spinbox)

	var apply_btn := Button.new()
	apply_btn.text = "Apply + Reload"
	apply_btn.tooltip_text = (
		"Saves godot_ai/http_port to Editor Settings and reloads the plugin so"
		+ " the server spawns on the new port."
	)
	apply_btn.pressed.connect(_on_apply_new_port)
	picker_row.add_child(apply_btn)

	_port_picker_section.add_child(picker_row)
	_crash_panel.add_child(_port_picker_section)


func _on_apply_new_port() -> void:
	var new_port: int = int(_port_picker_spinbox.value)
	if new_port < McpClientConfigurator.MIN_PORT or new_port > McpClientConfigurator.MAX_PORT:
		return
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(McpClientConfigurator.SETTING_HTTP_PORT, new_port)
	## Every saved client config now points at the old port. Re-sweep so the
	## drift banner appears in the same frame the user committed the change —
	## the plugin reload below will run a second sweep on its own first paint,
	## but we want the banner up immediately rather than after the reload
	## handshake races to completion. See #166.
	_refresh_all_client_statuses()
	## Reload after the setting is committed so `_start_server` reads the new
	## port on the re-enabled plugin instance.
	_on_reload_plugin()


func _refresh_server_label() -> void:
	if _server_label == null:
		return
	_server_label.text = "WS: %d  HTTP: %d" % [McpClientConfigurator.ws_port(), McpClientConfigurator.http_port()]


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


func _mode_override_index_from_setting() -> int:
	var es := EditorInterface.get_editor_settings()
	if es == null or not es.has_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING):
		return 0
	var v := str(es.get_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING)).strip_edges().to_lower()
	return maxi(MODE_OVERRIDE_VALUES.find(v), 0)


## Called whenever `is_dev_checkout()`'s answer could have changed — repaints
## the install label/tooltip, rebuilds the setup container (Mode row, Dev
## Server button vs uv status), and clears any stale update banner so a
## fresh `_check_for_updates()` paints over a clean slate. The Update
## button state is reset too: a prior install attempt may have left it
## disabled with text like "Dev checkout — update via git" or "Extract
## failed"; without this reset, flipping the dropdown and re-checking
## would re-open the banner with the stale button text.
func _refresh_install_mode_ui() -> void:
	_install_label.text = _install_mode_text()
	_install_label.tooltip_text = _install_mode_tooltip()
	_refresh_setup_status()
	_update_banner.visible = false
	_latest_download_url = ""
	if _update_btn != null:
		_update_btn.text = "Update"
		_update_btn.disabled = false


func _on_mode_override_selected(index: int) -> void:
	var value: String = MODE_OVERRIDE_VALUES[index] if index >= 0 and index < MODE_OVERRIDE_VALUES.size() else ""
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(McpClientConfigurator.MODE_OVERRIDE_SETTING, value)
	_refresh_install_mode_ui()
	## Cancel any in-flight startup check before firing a new one, otherwise
	## `_http_request.request()` can return ERR_BUSY and the dropdown flip
	## silently fails to re-check. `call_deferred` lets the cancel settle
	## before the new request goes out.
	if _http_request != null:
		_http_request.cancel_request()
	_check_for_updates.call_deferred()
	print("MCP | mode override -> %s" % (value if value else "auto"))


# --- Button handlers ---

func _on_reload_plugin() -> void:
	# Toggle plugin off/on to reload all GDScript
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func _on_reconnect() -> void:
	if _connection:
		_connection.disconnect_from_server()
		_connection._attempt_reconnect()


## Setup-section "Server" row: always report the TRUE running server
## version (from the handshake_ack) rather than the plugin's expected
## version, and highlight the mismatch so self-update drift is visible
## at a glance instead of silently masked by a green label.
##
## Three render states, keyed off `Connection.server_version`:
## - empty (pre-ack or older server): show plugin's expected version,
##   muted, no Restart button
## - matches plugin: show it green, no Restart button
## - diverges from plugin: show it amber, append "(plugin X)", show
##   Restart button so the user can kill the stale occupant and respawn
##   without restarting the editor
func _refresh_server_version_label() -> void:
	if _setup_server_label == null:
		return
	var plugin_ver := McpClientConfigurator.get_plugin_version()
	var server_ver := _connection.server_version if _connection != null else ""
	var text: String
	var color: Color
	var show_restart := false
	if server_ver.is_empty():
		text = "godot-ai == %s" % plugin_ver
		color = COLOR_MUTED
	elif server_ver == plugin_ver:
		text = "godot-ai == %s" % server_ver
		color = Color.GREEN
	else:
		text = "godot-ai == %s  (plugin %s)" % [server_ver, plugin_ver]
		color = COLOR_AMBER
		show_restart = true
	if text == _last_rendered_server_text:
		if _version_restart_btn != null and _version_restart_btn.visible != show_restart:
			_version_restart_btn.visible = show_restart
		return
	_last_rendered_server_text = text
	_setup_server_label.text = text
	_setup_server_label.add_theme_color_override("font_color", color)
	if _version_restart_btn != null:
		_version_restart_btn.visible = show_restart


func _on_restart_stale_server() -> void:
	if _plugin != null and _plugin.has_method("force_restart_server"):
		_plugin.force_restart_server()


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
		## Build the Server row with a placeholder label we can update every
		## frame. `_refresh_server_version_label` replaces the text + color
		## once `Connection.server_version` lands via `handshake_ack`, and
		## flips to amber + "(plugin X)" on drift. Pre-ack we show the
		## plugin's expected version so the row isn't blank.
		var server_row := HBoxContainer.new()
		server_row.add_theme_constant_override("separation", 8)
		var key_label := Label.new()
		key_label.text = "Server"
		key_label.add_theme_color_override("font_color", COLOR_MUTED)
		key_label.custom_minimum_size = Vector2(60, 0)
		server_row.add_child(key_label)
		_setup_server_label = Label.new()
		_setup_server_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		server_row.add_child(_setup_server_label)
		_version_restart_btn = Button.new()
		_version_restart_btn.text = "Restart"
		_version_restart_btn.tooltip_text = "Kill the server on port %d and respawn with the plugin's bundled version" % McpClientConfigurator.http_port()
		_version_restart_btn.pressed.connect(_on_restart_stale_server)
		_version_restart_btn.visible = false
		server_row.add_child(_version_restart_btn)
		_setup_container.add_child(server_row)
		_last_rendered_server_text = ""
		_refresh_server_version_label()
	else:
		_setup_container.add_child(_make_status_row("uv", "not found", Color.RED))
		var install_btn := Button.new()
		install_btn.text = "Install uv"
		install_btn.pressed.connect(_on_install_uv)
		_setup_container.add_child(install_btn)


func _install_mode_text() -> String:
	if McpClientConfigurator.is_dev_checkout():
		return "Install: dev checkout — update via git pull"
	return "Install: v%s" % McpClientConfigurator.get_plugin_version()


func _install_mode_tooltip() -> String:
	if not McpClientConfigurator.is_dev_checkout():
		return "Plugin installed from a release ZIP, Asset Library, or source copy. Update button in this dock downloads the latest GitHub release."
	var target := _resolve_plugin_symlink_target()
	if target.is_empty():
		return "Plugin source tree resolved via local .venv — press Reload Plugin after editing."
	return "Plugin source: %s\nPress Reload Plugin after editing." % target


func _resolve_plugin_symlink_target() -> String:
	var addons_path := ProjectSettings.globalize_path("res://addons/godot_ai")
	var dir := DirAccess.open(addons_path.get_base_dir())
	if dir == null or not dir.is_link(addons_path):
		return ""
	var target := dir.read_link(addons_path)
	if target.is_empty():
		return ""
	if target.is_relative_path():
		target = addons_path.get_base_dir().path_join(target).simplify_path()
	return target


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


## Pure helper — given the two independent server states, return the button
## label and tooltip. Factored out so tests can cover all three states without
## spinning up a real server or plugin.
static func _dev_server_btn_state(has_managed: bool, dev_running: bool) -> Dictionary:
	var port := McpClientConfigurator.http_port()
	if has_managed:
		return {
			"text": "Switch to dev mode (--reload)",
			"tooltip": "Stops the plugin's managed server and replaces it with a --reload dev server on port %d. The dev server auto-restarts when you edit Python sources." % port,
		}
	if dev_running:
		return {
			"text": "Exit dev mode",
			"tooltip": "Stops the external dev server on port %d so the plugin's managed server can take over on next reload." % port,
		}
	return {
		"text": "Start dev server",
		"tooltip": "Spawns a --reload dev server on port %d. Auto-restarts when you edit Python sources." % port,
	}


func _update_dev_server_btn() -> void:
	if _dev_server_btn == null:
		return
	if _plugin == null:
		return
	## Defensive guard against the self-update mixed-state window — see the
	## comment in `_update_status` for the full story. Same #168.
	if not (_plugin.has_method("has_managed_server") and _plugin.has_method("is_dev_server_running")):
		return
	var state := _dev_server_btn_state(_plugin.has_managed_server(), _plugin.is_dev_server_running())
	_dev_server_btn.text = state["text"]
	_dev_server_btn.tooltip_text = state["tooltip"]


func _on_dev_server_pressed() -> void:
	if _plugin == null:
		return
	if _plugin.has_managed_server():
		# Managed server running — swap it for a --reload dev server.
		# start_dev_server() calls _stop_server() internally before spawning.
		_plugin.start_dev_server()
	elif _plugin.is_dev_server_running():
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


func _on_refresh_clients_pressed() -> void:
	_request_client_status_refresh(true)


func _on_configure_all_clients() -> void:
	if _client_status_refresh_in_flight:
		return
	for client_id in _client_rows:
		var status: McpClient.Status = _client_rows[client_id].get("status", McpClient.Status.NOT_CONFIGURED)
		if status == McpClient.Status.CONFIGURED:
			continue
		_on_configure_client(String(client_id))
	_refresh_clients_summary()


func _on_open_clients_window() -> void:
	if _clients_window == null:
		return
	## Re-sweep before the user has time to act on stale dot colors. The request
	## is async/stale-while-refreshing so the popup paints immediately with
	## last-known state; the fresh colors land when the background worker returns.
	## This is an explicit user action, so it bypasses the focus-in cooldown.
	_request_client_status_refresh(true)
	## Also re-sync the Tools tab from the persisted setting — another
	## editor instance (or a hand-edit of editor_settings-4.tres) may have
	## changed the excluded list while the window was closed.
	_reset_tools_pending_from_setting()
	_refresh_tools_ui_state()
	# popup_centered() with a minsize forces the window to that size and
	# centers on the parent viewport. Setting .size on a hidden Window
	# doesn't always take effect, so we force it at popup time here.
	_clients_window.popup_centered(Vector2i(640, 600))


func _on_clients_window_close_requested() -> void:
	if _clients_window == null:
		return
	## If the user has checked/unchecked domains without applying, a close
	## would silently throw the pending state away. Prompt; if they confirm
	## discard, reset pending → saved so the window shows the persisted
	## state the next time they open it.
	if _tools_pending_excluded != _tools_saved_excluded:
		_show_tools_close_confirm()
		return
	_clients_window.hide()


# --- Tools tab (domain exclusion) ---

func _build_tools_tab(tabs: TabContainer) -> void:
	## Tab 2 — domain-exclusion checkboxes. Rendered once, on dock construction.
	## `_reset_tools_pending_from_setting()` re-syncs checkbox state from the
	## saved setting each time the window opens.
	var tools_tab := VBoxContainer.new()
	tools_tab.name = "Tools"
	tools_tab.add_theme_constant_override("separation", 8)
	tabs.add_child(tools_tab)

	var intro := Label.new()
	intro.text = (
		"Some MCP clients cap tools per connection (Antigravity: 100). "
		+ "Uncheck a domain to drop its non-core tools from this server. "
		+ "Core tools stay on. Changes require a server restart."
	)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", COLOR_MUTED)
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tools_tab.add_child(intro)

	var count_row := HBoxContainer.new()
	count_row.add_theme_constant_override("separation", 8)
	var count_header := Label.new()
	count_header.text = "Enabled:"
	count_header.add_theme_color_override("font_color", COLOR_MUTED)
	count_row.add_child(count_header)
	_tools_count_label = Label.new()
	_tools_count_label.add_theme_font_size_override("font_size", 15)
	count_row.add_child(_tools_count_label)
	_tools_dirty_warning = Label.new()
	_tools_dirty_warning.add_theme_color_override("font_color", COLOR_AMBER)
	_tools_dirty_warning.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools_dirty_warning.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_tools_dirty_warning.visible = false
	_tools_dirty_warning.text = "Unapplied changes"
	count_row.add_child(_tools_dirty_warning)
	tools_tab.add_child(count_row)

	tools_tab.add_child(HSeparator.new())

	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	tools_tab.add_child(scroll)

	var grid := VBoxContainer.new()
	grid.add_theme_constant_override("separation", 4)
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(grid)

	## Core pseudo-row — disabled checkbox, always checked. Shows the 5
	## always-loaded tools as a single line item so the user can see where
	## their baseline tool budget goes without listing individual core names
	## inline (tooltip has them).
	var core_row := HBoxContainer.new()
	core_row.add_theme_constant_override("separation", 8)
	var core_chk := CheckBox.new()
	core_chk.button_pressed = true
	core_chk.disabled = true
	core_chk.focus_mode = Control.FOCUS_NONE
	core_row.add_child(core_chk)
	var core_label := Label.new()
	core_label.text = "Core (always on)"
	core_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	core_row.add_child(core_label)
	var core_count := Label.new()
	core_count.text = "%d tools" % McpToolCatalog.CORE_TOOLS.size()
	core_count.add_theme_color_override("font_color", COLOR_MUTED)
	core_row.add_child(core_count)
	core_row.tooltip_text = ", ".join(McpToolCatalog.CORE_TOOLS)
	grid.add_child(core_row)

	grid.add_child(HSeparator.new())

	_tools_domain_checkboxes.clear()
	for entry in McpToolCatalog.DOMAINS:
		_build_tools_domain_row(grid, entry)

	tools_tab.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)

	_tools_apply_btn = Button.new()
	_tools_apply_btn.text = "Apply && Restart Server"
	_tools_apply_btn.tooltip_text = "Save the excluded list to Editor Settings and reload the plugin so the server respawns with --exclude-domains."
	_tools_apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tools_apply_btn.pressed.connect(_on_tools_apply)
	footer.add_child(_tools_apply_btn)

	_tools_reset_btn = Button.new()
	_tools_reset_btn.text = "Reset to defaults"
	_tools_reset_btn.tooltip_text = "Re-enable every domain (no --exclude-domains flag). Still needs Apply."
	_tools_reset_btn.pressed.connect(_on_tools_reset)
	footer.add_child(_tools_reset_btn)

	tools_tab.add_child(footer)

	_tools_close_confirm = ConfirmationDialog.new()
	_tools_close_confirm.title = "Discard unapplied changes?"
	_tools_close_confirm.dialog_text = (
		"You've checked/unchecked domains but haven't clicked Apply.\n"
		+ "Close the window and discard those changes?"
	)
	_tools_close_confirm.ok_button_text = "Discard"
	_tools_close_confirm.confirmed.connect(_on_tools_discard_confirmed)
	add_child(_tools_close_confirm)

	_reset_tools_pending_from_setting()
	_refresh_tools_ui_state()


func _build_tools_domain_row(parent: VBoxContainer, entry: Dictionary) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var chk := CheckBox.new()
	chk.button_pressed = true  # default; `_reset_tools_pending_from_setting` corrects
	chk.toggled.connect(_on_tools_domain_toggled.bind(String(entry["id"])))
	row.add_child(chk)

	var name_label := Label.new()
	name_label.text = String(entry["label"])
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)

	var count_label := Label.new()
	count_label.text = "%d tools" % int(entry["count"])
	count_label.add_theme_color_override("font_color", COLOR_MUTED)
	row.add_child(count_label)

	## Hover tooltip = flat list of tool names in this domain. Lets the
	## user decide without leaving the dock (e.g. "I just want to drop
	## `animation_preset_*` — do I lose anything else?").
	var tools_list: Array = entry.get("tools", [])
	row.tooltip_text = ", ".join(tools_list)
	name_label.tooltip_text = row.tooltip_text
	count_label.tooltip_text = row.tooltip_text

	parent.add_child(row)
	_tools_domain_checkboxes[String(entry["id"])] = chk


func _reset_tools_pending_from_setting() -> void:
	## Read the saved setting → pending/saved arrays, then sync checkbox state.
	## Unknown domain names in the setting (e.g. from an older plugin
	## version) are silently dropped — matches the Python side's
	## warn-and-continue behavior when it sees an unknown name.
	var saved_raw := McpClientConfigurator.excluded_domains()
	var saved := PackedStringArray()
	if not saved_raw.is_empty():
		for part in saved_raw.split(","):
			var t := part.strip_edges()
			if t.is_empty():
				continue
			if _tools_domain_checkboxes.has(t) and saved.find(t) == -1:
				saved.append(t)
	saved.sort()
	_tools_saved_excluded = saved
	_tools_pending_excluded = saved.duplicate()
	for id in _tools_domain_checkboxes:
		var chk: CheckBox = _tools_domain_checkboxes[id]
		## `set_pressed_no_signal` — mutating programmatically should not
		## fire the toggled handler, which would mutate pending back.
		chk.set_pressed_no_signal(_tools_pending_excluded.find(id) == -1)


func _on_tools_domain_toggled(pressed: bool, domain_id: String) -> void:
	var idx := _tools_pending_excluded.find(domain_id)
	if pressed and idx != -1:
		_tools_pending_excluded.remove_at(idx)
	elif not pressed and idx == -1:
		_tools_pending_excluded.append(domain_id)
		_tools_pending_excluded.sort()
	_refresh_tools_ui_state()


func _refresh_tools_ui_state() -> void:
	if _tools_count_label == null:
		return
	var enabled := McpToolCatalog.enabled_tool_count(_tools_pending_excluded)
	var total := McpToolCatalog.total_tool_count()
	_tools_count_label.text = "%d / %d" % [enabled, total]
	var dirty := _tools_pending_excluded != _tools_saved_excluded
	_tools_dirty_warning.visible = dirty
	_tools_apply_btn.disabled = not dirty
	## Color the count when the user is over Antigravity's cap — a soft
	## signal that their selection still won't fit. 100 is the Antigravity
	## limit; other clients may cap higher, so this is advisory only.
	if enabled > 100:
		_tools_count_label.add_theme_color_override("font_color", COLOR_AMBER)
	else:
		_tools_count_label.remove_theme_color_override("font_color")


func _on_tools_apply() -> void:
	var canonical_excluded := McpToolCatalog.canonical(_tools_pending_excluded)
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(McpClientConfigurator.SETTING_EXCLUDED_DOMAINS, canonical_excluded)
	_tools_saved_excluded = _tools_pending_excluded.duplicate()
	_refresh_tools_ui_state()
	## Plugin reload respawns the server with the new `--exclude-domains`
	## flag (see `plugin.gd::_build_server_flags`). Mirrors the port-change
	## Apply flow.
	_on_reload_plugin()


func _on_tools_reset() -> void:
	_tools_pending_excluded = PackedStringArray()
	for id in _tools_domain_checkboxes:
		var chk: CheckBox = _tools_domain_checkboxes[id]
		chk.set_pressed_no_signal(true)
	_refresh_tools_ui_state()


func _show_tools_close_confirm() -> void:
	if _tools_close_confirm == null:
		return
	_tools_close_confirm.popup_centered()


func _on_tools_discard_confirmed() -> void:
	_reset_tools_pending_from_setting()
	_refresh_tools_ui_state()
	if _clients_window != null:
		_clients_window.hide()


func _refresh_clients_summary() -> void:
	# Count from cached row status values — `_apply_row_status` is the single
	# source of truth, and reading cached status avoids re-running
	# filesystem/CLI-hitting checks on every refresh. The same cache re-derives
	# the drift banner so per-row mutations (Configure/Reconfigure/Remove on a
	# row in the Clients & Tools window) keep the dock-level banner in sync
	# without an extra sweep. See #166 and #226.
	if _clients_summary_label == null:
		return
	var configured := 0
	var mismatched_ids: Array[String] = []
	for client_id in _client_rows:
		var status: McpClient.Status = _client_rows[client_id].get("status", McpClient.Status.NOT_CONFIGURED)
		if status == McpClient.Status.CONFIGURED:
			configured += 1
		elif status == McpClient.Status.CONFIGURED_MISMATCH:
			mismatched_ids.append(client_id)
	var text := "%d / %d configured" % [configured, _client_rows.size()]
	if mismatched_ids.size() > 0:
		text += " (%d stale)" % mismatched_ids.size()
	if _client_status_refresh_in_flight:
		text += " (checking...)" if not _client_status_refresh_timed_out else " (client probe still running)"
	_clients_summary_label.text = text
	if _client_configure_all_btn != null:
		_client_configure_all_btn.disabled = _client_status_refresh_in_flight
	_refresh_drift_banner(mismatched_ids)


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
	## Compatibility wrapper for older explicit call sites. Treat this as a manual
	## refresh: it bypasses focus-in cooldown but still runs probes off the editor
	## main thread.
	_request_client_status_refresh(true)


func _is_client_status_refresh_in_cooldown() -> bool:
	if _last_client_status_refresh_completed_msec <= 0:
		return false
	return Time.get_ticks_msec() - _last_client_status_refresh_completed_msec < CLIENT_STATUS_REFRESH_COOLDOWN_MSEC


func _has_client_status_refresh_timed_out() -> bool:
	if not _client_status_refresh_in_flight:
		return false
	if _client_status_refresh_started_msec <= 0:
		return false
	return Time.get_ticks_msec() - _client_status_refresh_started_msec >= CLIENT_STATUS_REFRESH_TIMEOUT_MSEC


func _check_client_status_refresh_timeout() -> void:
	if not _has_client_status_refresh_timed_out():
		return
	if _client_status_refresh_timed_out:
		return
	_client_status_refresh_timed_out = true
	_refresh_clients_summary()


func _abandon_client_status_refresh_thread() -> void:
	## GDScript cannot interrupt a blocking `OS.execute(..., true)` call in a
	## worker. If a CLI probe hangs, orphan this run, bump the generation so any
	## late result becomes a no-op, and let a forced/manual refresh start a fresh
	## probe slot. Completed orphan threads are pruned from `_process`.
	_client_status_refresh_generation += 1
	if _client_status_refresh_thread != null:
		_orphaned_client_status_refresh_threads.append(_client_status_refresh_thread)
		_client_status_refresh_thread = null
	_client_status_refresh_in_flight = false
	_client_status_refresh_pending = false
	_client_status_refresh_pending_force = false
	_client_status_refresh_timed_out = false
	_client_status_refresh_started_msec = 0
	_refresh_clients_summary()


func _prune_orphaned_client_status_refresh_threads() -> void:
	for i in range(_orphaned_client_status_refresh_threads.size() - 1, -1, -1):
		var thread := _orphaned_client_status_refresh_threads[i]
		if thread == null:
			_orphaned_client_status_refresh_threads.remove_at(i)
		elif not thread.is_alive():
			thread.wait_to_finish()
			_orphaned_client_status_refresh_threads.remove_at(i)


func _request_client_status_refresh(force: bool = false) -> bool:
	## Stale-while-refreshing: do not clear dots, summary, or the drift banner
	## when a refresh is requested. The existing UI remains visible until the
	## background worker's result is applied on the main thread.
	if _client_status_refresh_in_flight:
		if force and _has_client_status_refresh_timed_out():
			_abandon_client_status_refresh_thread()
		else:
			_client_status_refresh_pending = true
			_client_status_refresh_pending_force = _client_status_refresh_pending_force or force
			_refresh_clients_summary()
			return false
	if _client_status_refresh_shutdown_requested:
		return false
	if not force and _is_client_status_refresh_in_cooldown():
		return false
	if _client_rows.is_empty():
		return false

	var client_probes: Array[Dictionary] = []
	for client_id in _client_rows:
		client_probes.append(McpClientConfigurator.client_status_probe_snapshot(String(client_id)))
	var server_url := McpClientConfigurator.http_url()

	_client_status_refresh_in_flight = true
	_client_status_refresh_pending = false
	_client_status_refresh_pending_force = false
	_client_status_refresh_timed_out = false
	_client_status_refresh_started_msec = Time.get_ticks_msec()
	_client_status_refresh_generation += 1
	var generation := _client_status_refresh_generation
	_refresh_clients_summary()
	_client_status_refresh_thread = Thread.new()
	var err := _client_status_refresh_thread.start(
		Callable(self, "_run_client_status_refresh_worker").bind(client_probes, server_url, generation)
	)
	if err != OK:
		_client_status_refresh_in_flight = false
		_client_status_refresh_timed_out = false
		_client_status_refresh_thread = null
		_refresh_clients_summary()
		return false
	return true


func _run_client_status_refresh_worker(client_probes: Array[Dictionary], server_url: String, generation: int) -> void:
	var results: Dictionary = {}
	for probe in client_probes:
		var client_id := String(probe.get("id", ""))
		if client_id.is_empty():
			continue
		var status := McpClientConfigurator.check_status_for_url_with_cli_path(
			client_id,
			server_url,
			String(probe.get("cli_path", ""))
		)
		var installed := bool(probe.get("installed", false))
		results[client_id] = {"status": status, "installed": installed}
	if not _client_status_refresh_shutdown_requested:
		call_deferred("_apply_client_status_refresh_results", results, generation)


func _apply_client_status_refresh_results(results: Dictionary, generation: int) -> void:
	if generation != _client_status_refresh_generation or _client_status_refresh_shutdown_requested:
		return
	if _client_status_refresh_thread != null:
		_client_status_refresh_thread.wait_to_finish()
		_client_status_refresh_thread = null

	for client_id in results:
		var result: Dictionary = results[client_id]
		_apply_row_status(
			String(client_id),
			result.get("status", McpClient.Status.NOT_CONFIGURED),
			"",
			result.get("installed", false)
		)
	_last_client_status_refresh_completed_msec = Time.get_ticks_msec()
	_client_status_refresh_in_flight = false
	_client_status_refresh_timed_out = false
	_refresh_clients_summary()

	if _client_status_refresh_pending:
		var pending_force := _client_status_refresh_pending_force
		_client_status_refresh_pending = false
		_client_status_refresh_pending_force = false
		_request_client_status_refresh(pending_force)


func _refresh_drift_banner(mismatched_ids: Array[String]) -> void:
	if _drift_banner == null:
		return
	## Sort so set-equality is order-independent — `_client_rows` iteration
	## order is dict-insertion order, but a future change to the iteration
	## site shouldn't make us repaint identical content.
	mismatched_ids = mismatched_ids.duplicate()
	mismatched_ids.sort()
	if mismatched_ids == _last_mismatched_ids:
		return
	_last_mismatched_ids = mismatched_ids
	if mismatched_ids.is_empty():
		_drift_banner.visible = false
		return
	var names: Array[String] = []
	for id in mismatched_ids:
		names.append(McpClientConfigurator.client_display_name(id))
	## Active server URL is already shown on the WS:/HTTP: line above the
	## Clients section, so it doesn't need to repeat here. Lead with the
	## client names — that's the only thing the user can act on.
	var verb := "needs" if mismatched_ids.size() == 1 else "need"
	_drift_label.text = "%s %s to be reconfigured." % [", ".join(names), verb]
	_drift_banner.visible = true


func _on_reconfigure_mismatched() -> void:
	## Re-Configure every client whose URL is currently stale. Iterates the
	## cached list from the most recent sweep instead of re-running
	## `check_status` per row (saves ~18 filesystem reads per click). The
	## trailing `_refresh_all_client_statuses()` re-sweeps anyway, so any
	## entries the user manually fixed between sweep and click get re-counted
	## as CONFIGURED there.
	for client_id in _last_mismatched_ids:
		if _client_rows.has(client_id):
			_on_configure_client(client_id)
	_refresh_all_client_statuses()


func _apply_row_status(
	client_id: String,
	status: McpClient.Status,
	error_msg: String = "",
	installed_override: Variant = null,
) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	row["status"] = status
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
			var installed: bool = installed_override if installed_override != null else McpClientConfigurator.is_installed(client_id)
			name_label.text = base_name if installed else "%s  (not detected)" % base_name
		McpClient.Status.CONFIGURED_MISMATCH:
			## Amber matches the dock-level drift banner so a glance at the
			## row + the banner read as the same condition.
			dot.color = COLOR_AMBER
			configure_btn.text = "Reconfigure"
			remove_btn.visible = true
			name_label.text = "%s  (URL out of date)" % base_name
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
	##
	## `is_dev_checkout()` honours the mode override (dock dropdown first,
	## then `GODOT_AI_MODE` env var), so testers can force `user` mode to
	## exercise the AssetLib update flow from inside a dev tree.
	## `_install_update` still gates on the physical symlink check, so a
	## forced-user mode can never clobber source.
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

	var label_text := "Update available: v%s" % remote_version
	if McpClientConfigurator.mode_override() == "user":
		## Visible hint so testers notice the banner is only showing because
		## of a forced-user override (dock dropdown or GODOT_AI_MODE env
		## var). Clicking Update in a symlinked dev tree safely bails in
		## `_install_update` via the addons_dir_is_symlink guard.
		label_text += " (forced)"
	_update_label.text = label_text
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
	## Belt-and-suspenders data-safety check. `_check_for_updates` is gated
	## on `is_dev_checkout()` (a UX heuristic the user can override via
	## GODOT_AI_MODE=user), but the actual hazard we can never tolerate is
	## writing release-zip files into a symlinked addons dir — that
	## clobbers the canonical `plugin/` source tree. Symlink detection is
	## independent of the mode override: even a forced-user mode aborts
	## here if the target is a symlink. See #116.
	if McpClientConfigurator.addons_dir_is_symlink():
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
	##
	## Stale-PyPI-index recovery (#171/#172): the new `_start_server` self-heals
	## by retrying once with `uvx --refresh` when the first spawn dies without
	## writing the pid-file on the uvx tier. Every spawn path benefits — this
	## removes the need for a dock-side precheck before the reload.
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
