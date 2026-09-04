@tool
class_name McpDock
extends VBoxContainer

## Editor dock panel showing MCP connection status, client config, and command log.
##
## Audit-v2 #360 partial extraction. Two cohesive subpanels live in
## res://addons/godot_ai/dock_panels/:
##   - log_viewer.gd: MCP request/response log (dev-mode only).
##   - port_picker_panel.gd: spawn-failure escape hatch nested in the crash panel.
##
## The audit also called for ServerStatusPanel and ClientRowController
## extractions; those were *deliberately deferred*. Their UI scatters across
## the dock layout (status icon at top, crash panel mid, setup section lower;
## client rows + drift banner + scroll grid spread similarly), so a clean
## extract-by-panel needs either visible UI reorganization or a coordinator-
## Node pattern with property-accessor façades on McpDock that re-tangle the
## very state they claim to move.
##
## Client workers and update orchestration have plugin lifetime and are owned
## by plugin.gd. This replaceable view emits intents and paints copied
## snapshots/outcomes; detaching it cannot destroy domain work.

const ServerStateScript := preload("res://addons/godot_ai/utils/mcp_server_state.gd")
const ClientRefreshStateScript := preload("res://addons/godot_ai/utils/mcp_client_refresh_state.gd")
const Client := preload("res://addons/godot_ai/clients/_base.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const ClientRegistry := preload("res://addons/godot_ai/clients/_registry.gd")
const ToolCatalog := preload("res://addons/godot_ai/tool_catalog.gd")
const LogViewerScript := preload("res://addons/godot_ai/dock_panels/log_viewer.gd")
const PortPickerPanelScript := preload("res://addons/godot_ai/dock_panels/port_picker_panel.gd")
const VisionRoutingScript := preload("res://addons/godot_ai/vision_routing.gd")

const DEV_MODE_SETTING := "godot_ai/dev_mode"
## "Change the port + reconfigure your clients" guide. Surfaced from the crash
## panel when a foreign process holds the HTTP port — the one piece of recovery
## (per-client config rewrite) that doesn't fit in the inline crash body.
## Resolved against the installed plugin version at click time (see
## `_port_conflict_docs_url`) so a shipped build opens the guide as it shipped,
## not tip-of-main, which may have drifted from that build's UI.
const PORT_CONFLICT_DOCS_PATH := "docs/port-conflicts.md"
const REPO_BLOB_BASE := "https://github.com/hi-godot/godot-ai/blob"
const RELEASES_PAGE := "https://github.com/hi-godot/godot-ai/releases/latest"
## Opened by the "How to install uv" button. See _on_install_uv for why the
## dock links here instead of running an installer itself.
const UV_INSTALL_DOCS_URL := "https://docs.astral.sh/uv/getting-started/installation/"
static var COLOR_MUTED := Color(0.7, 0.7, 0.7)
static var COLOR_HEADER := Color(0.95, 0.95, 0.95)
## Used for "in-progress" / "stale, action needed" UI: the startup-grace
## status icon, the spawn-failure suggested-port hint, the drift banner,
## and the per-row mismatch dot. One constant so a future palette tweak
## doesn't have to find every literal.
static var COLOR_AMBER := Color(1.0, 0.75, 0.25)

signal update_requested
signal client_action_requested(client_id: String, action: String)
signal client_status_refresh_requested(client_ids: Array[String], force: bool)
signal status_snapshot_requested
signal live_server_probe_requested(port: int)
signal lifecycle_action_requested(action: int)
signal dev_server_action_requested(action: int)
signal mcp_logging_changed(enabled: bool)
signal log_snapshot_requested(after_sequence: int)
signal plugin_reload_requested(reason: String)
signal settings_apply_requested(changes: Dictionary, reload: bool)
signal post_update_action_requested(action: String)

enum LifecycleAction { RECOVER_INCOMPATIBLE, RESTART_SERVER }
enum DevServerAction { START_OR_RESTART, STOP }

## Copied root-owned values only. The Dock never retains Connection, lifecycle,
## plugin, log-buffer, or process owners.
var _transport_snapshot: Dictionary = {
	"connected": false,
	"server_version": "",
	"status": {},
}
var _lifecycle_snapshot: Dictionary = {
	"state": ServerStateScript.UNINITIALIZED,
	"server_pid": -1,
	"resolved_ws_port": 0,
	"can_restart_managed": false,
	"can_recover_incompatible": false,
	"normal_start_released": false,
}
var _live_server_probe_result: Dictionary = {}

# Always visible
var _redock_btn: Button
var _status_icon: ColorRect
var _status_label: Label
var _body_scroll: ScrollContainer
var _body: VBoxContainer
var _client_grid: VBoxContainer
var _client_configure_all_btn: Button
var _client_empty_cta_btn: Button
var _clients_summary_label: Label
var _clients_window: Window
var _dev_mode_toggle: CheckButton
var _install_label: Label

# Tools tab (secondary window, Tab 2) — domain-exclusion UI for clients
# that cap total tool count (Antigravity: 100). Pending set is mutated by
# checkbox clicks; saved set reflects what the spawned server actually
# sees. `Apply and Restart Server` writes pending → setting and triggers a
# plugin reload so the new server comes up with the trimmed list.
var _tools_pending_excluded: PackedStringArray = PackedStringArray()
var _tools_saved_excluded: PackedStringArray = PackedStringArray()
## Custom (addon-registered) tools list — rebuilt live on registry
## tools_changed; per-tool checkboxes apply immediately (no restart).
var _custom_tools_list: VBoxContainer
var _custom_tools_count_label: Label
var _tools_domain_checkboxes: Dictionary = {}
var _tools_count_label: Label
var _tools_apply_btn: Button
var _tools_reset_btn: Button
var _tools_dirty_warning: Label
var _tools_close_confirm: ConfirmationDialog
## Update saves the project and relaunches the editor; the user says so first.
var _update_confirm: ConfirmationDialog
var _update_candidate_version := ""
var _telemetry_toggle: CheckButton
var _telemetry_pending_enabled: bool = true
var _telemetry_saved_enabled: bool = true

# Settings tab (secondary window, Tab 3) — Vision Routing section plus the
# LAN opt-in (#507): "Allow remote hosts (CIDR)" behind a collapsed
# "Remote access (advanced)" disclosure (auto-expands when a non-empty
# allowlist is configured). The value feeds `--allow-host` at server spawn
# (see plugin.gd::_build_server_flags). The LineEdit's live text is the
# pending state; `_allow_hosts_saved` mirrors the persisted EditorSetting,
# same pending/saved shape as the Tools tab above.
var _allow_hosts_section: VBoxContainer
var _allow_hosts_fold: FoldableContainer
var _allow_hosts_edit: LineEdit
var _allow_hosts_hint: Label
var _allow_hosts_apply_btn: Button
var _allow_hosts_saved: String = ""

## Per-client UI handles, keyed by client id. Each entry holds the row's
## status dot, configure/remove buttons, config-file buttons, and manual panel.
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
## Set when the user clicks "How to install uv"; consumed by the next
## application focus-in so the uv row is re-probed after the user has had a
## chance to install, not immediately. See _on_install_uv and _notification.
## (Deliberately spelled without the focus-in constant name: the guard in
## tests/unit/test_editor_focus_refocus.py locates the notification handler
## by first occurrence of that token.)
var _uv_recheck_pending := false
## Handles for the Setup section's "Server" row. `_update_status` keeps
## the label text/color in sync with `McpConnection.server_version` so the
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
## `McpConnection.server_version` drifts from the plugin version. Hidden
## in the match case so the UI stays calm.
var _version_restart_btn: Button
var _server_restart_in_progress := false
## Sorted snapshot of the most recent mismatched-client set. Powers two things:
## (a) the Reconfigure button reuses this list instead of re-running
## `check_status` per row (saves ~18 filesystem reads per click), and
## (b) `_refresh_drift_banner` early-returns when the set is unchanged so
## repeated explicit refreshes don't repaint identical text. Mirrors the
## `_last_server_status` pattern used by the crash panel.
var _last_mismatched_ids: Array[String] = []
## Copied plugin-lifetime client-job state. This contains no Thread, mutex,
## cancellation map, generation, or mutable owner record.
var _client_work_snapshot: Dictionary = {
	"accepting_work": false,
	"refresh_state": ClientRefreshStateScript.IDLE,
	"refresh_completed": false,
	"busy_actions": [],
	"action_names": {},
	"action_phases": {},
}
var _update_install_in_flight := false

# Dev-mode only
var _dev_section: VBoxContainer
var _server_label: Label
var _reload_btn: Button
var _setup_section: VBoxContainer
var _setup_container: VBoxContainer
## Developer controls are a view of the ordinary lifecycle owner. They never
## start a second process topology or kill an externally launched server.
var _dev_primary_btn: Button
## Small "✕" affordance next to the primary — enabled only for the exact
## plugin-owned process grant.
var _dev_stop_btn: Button
var _log_viewer: LogViewerScript
## Vision Routing (optional) - set by plugin.gd; builds the "Vision Routing"
## tab in Clients & Tools and the quick toggle under Developer mode.
var vision_routing: VisionRoutingScript = null

var _last_connected := false
var _last_status_text := ""
var _last_status_tooltip := ""
var _startup_grace_until_msec: int = 0

# Spawn-failure panel — rendered when `get_server_status` reports a
# non-OK `state`. One panel, one body paragraph per state, no cascading
# booleans. See `_crash_body_for_state`.
var _crash_panel: VBoxContainer
var _crash_output: RichTextLabel
var _crash_restart_btn: Button
var _crash_reload_btn: Button
## Help link — visible only for the genuinely-foreign-occupant INCOMPATIBLE
## case (no `can_recover_incompatible` proof). The inline body names a free
## port; this button carries the per-client reconfigure steps that don't fit
## inline. See `PORT_CONFLICT_DOCS` and `_update_crash_panel`.
var _crash_docs_btn: Button
## Port-picker escape hatch — visible inside the crash panel when the root
## cause is port contention (PORT_EXCLUDED or FOREIGN_PORT). The dock writes
## the EditorSetting and reloads the plugin in response to the panel's
## `port_apply_requested` signal.
var _port_picker_panel: PortPickerPanelScript
## Last status Dict rendered into the panel — used to skip re-population
## when nothing changed, which would otherwise reset the user's scroll
## position on every frame. GDScript Dicts compare by value with `==`.
var _last_server_status: Dictionary = {}

# First-run grace: uvx installs 60+ Python packages on first run (can take
# 10-30s on a slow connection). Don't scare users with "Disconnected" during
# that window — show "Starting server…" instead. After this expires, fall
# back to the normal disconnect UI.
const STARTUP_GRACE_MSEC := 60 * 1000

# Update banner — visible UI only. Release polling, ZIP download, and
# installation remain root-owned and arrive here as copied presentation state.
var _update_banner: VBoxContainer
var _update_label: Label
var _update_btn: Button
var _post_update_action := ""

func _ready() -> void:
	_startup_grace_until_msec = Time.get_ticks_msec() + STARTUP_GRACE_MSEC
	_build_ui()


func _process(_delta: float) -> void:
	_update_status()
	if _log_viewer != null and _log_viewer.visible:
		log_snapshot_requested.emit(_log_viewer.sequence())


func present_transport_snapshot(snapshot: Dictionary) -> void:
	_transport_snapshot = snapshot.duplicate(true)


func present_lifecycle_snapshot(snapshot: Dictionary) -> void:
	_lifecycle_snapshot = snapshot.duplicate(true)


func present_live_server_probe_result(result: Dictionary) -> void:
	_live_server_probe_result = result.duplicate(true)


func present_log_snapshot(snapshot: Dictionary) -> void:
	if _log_viewer != null:
		_log_viewer.present_snapshot(snapshot)


func _notification(what: int) -> void:
	# Detect dock/undock by watching for reparenting events.
	if what == NOTIFICATION_PARENTED or what == NOTIFICATION_UNPARENTED:
		_update_redock_visibility.call_deferred()
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if _should_refresh_client_statuses_on_focus_in():
			_request_client_status_refresh(false)
		## Re-probe uv only when the user actually went off to install it
		## (see _on_install_uv). `check_uv_version()` is cached, so an
		## ungated refresh here would usually be free — but after the
		## button invalidated that cache it costs one blocking
		## `uvx --version`, and this notification must not grow a probe on
		## the common focus-in path. One-shot: clear before refreshing.
		if _uv_recheck_pending:
			_uv_recheck_pending = false
			_refresh_setup_status.call_deferred()


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


func _build_margin_container(margin: int = 12) -> MarginContainer:
	var margin_container := MarginContainer.new()
	margin_container.add_theme_constant_override("margin_left", margin)
	margin_container.add_theme_constant_override("margin_right", margin)
	margin_container.add_theme_constant_override("margin_top", margin)
	margin_container.add_theme_constant_override("margin_bottom", margin)
	return margin_container


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

	_body_scroll = ScrollContainer.new()
	_body_scroll.name = "DockBodyScroll"
	_body_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body_scroll.custom_minimum_size = Vector2(0, 48)
	_body_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_body_scroll)

	_body = VBoxContainer.new()
	_body.name = "DockBody"
	_body.add_theme_constant_override("separation", 8)
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_scroll.add_child(_body)

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

	_port_picker_panel = PortPickerPanelScript.new()
	_port_picker_panel.setup()
	_port_picker_panel.port_apply_requested.connect(_on_port_apply_requested)
	_crash_panel.add_child(_port_picker_panel)

	_crash_restart_btn = Button.new()
	_crash_restart_btn.text = "Restart Server"
	_crash_restart_btn.tooltip_text = "Stop the old server on this port and start the bundled godot-ai server"
	_crash_restart_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_crash_restart_btn.add_theme_color_override("font_color", Color.WHITE)
	_crash_restart_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	_crash_restart_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	_crash_restart_btn.pressed.connect(_on_restart_stale_server)
	_crash_restart_btn.visible = false
	_crash_panel.add_child(_crash_restart_btn)

	_crash_reload_btn = Button.new()
	_crash_reload_btn.text = "Reload Plugin"
	_crash_reload_btn.tooltip_text = "Re-run the spawn after fixing the underlying issue"
	_crash_reload_btn.pressed.connect(_on_reload_plugin)
	_crash_panel.add_child(_crash_reload_btn)

	_crash_docs_btn = Button.new()
	_crash_docs_btn.text = "How to change the port"
	_crash_docs_btn.tooltip_text = "Open the guide: change godot_ai/http_port and reconfigure your MCP clients"
	_crash_docs_btn.visible = false
	_crash_docs_btn.pressed.connect(func(): OS.shell_open(_port_conflict_docs_url()))
	_crash_panel.add_child(_crash_docs_btn)

	_crash_panel.add_child(HSeparator.new())
	_body.add_child(_crash_panel)

	# --- Update banner (top of dock, hidden until check finds a newer version) ---
	_update_banner = VBoxContainer.new()
	_update_banner.add_theme_constant_override("separation", 4)
	_update_banner.visible = false

	_update_label = Label.new()
	_update_label.add_theme_font_size_override("font_size", 15)
	_update_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.3))
	## Wrap long banner text (e.g. the < 4.5 support-floor guidance) instead
	## of letting a single line stretch the whole dock wide. The dock is a
	## fixed-width side panel, so constrain horizontally and wrap.
	_update_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_update_label.size_flags_horizontal = Control.SIZE_FILL
	_update_label.custom_minimum_size = Vector2(0, 0)
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

	_body.add_child(_update_banner)

	# --- Dev-only connection extras (server label + reload button) ---
	_dev_section = VBoxContainer.new()
	_dev_section.add_theme_constant_override("separation", 6)
	_body.add_child(_dev_section)

	_server_label = Label.new()
	_server_label.add_theme_color_override("font_color", COLOR_MUTED)
	_dev_section.add_child(_server_label)
	_refresh_server_label()

	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 6)

	_reload_btn = Button.new()
	_reload_btn.text = "Dev: Reload Plugin"
	_reload_btn.tooltip_text = "Developer utility: reload the GDScript plugin. This does not restart or replace the server."
	_reload_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reload_btn.pressed.connect(_on_reload_plugin)
	btn_row.add_child(_reload_btn)

	_dev_section.add_child(btn_row)

	# --- Setup section (dev-only or when uv missing) ---
	_setup_section = VBoxContainer.new()
	_setup_section.add_theme_constant_override("separation", 6)
	_body.add_child(_setup_section)

	_setup_section.add_child(HSeparator.new())
	_setup_section.add_child(_make_header("Setup"))
	_setup_container = VBoxContainer.new()
	_setup_container.add_theme_constant_override("separation", 6)
	_setup_section.add_child(_setup_container)

	_body.add_child(HSeparator.new())

	# --- Clients ---
	var clients_header_row := HBoxContainer.new()
	clients_header_row.add_theme_constant_override("separation", 8)

	var clients_header := _make_header("Clients")
	clients_header_row.add_child(clients_header)

	_clients_summary_label = Label.new()
	_clients_summary_label.add_theme_color_override("font_color", COLOR_MUTED)
	_clients_summary_label.clip_text = true
	_clients_summary_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_clients_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	clients_header_row.add_child(_clients_summary_label)

	var clients_actions := HFlowContainer.new()
	clients_actions.add_theme_constant_override("h_separation", 8)
	clients_actions.add_theme_constant_override("v_separation", 4)

	var clients_refresh_btn := Button.new()
	clients_refresh_btn.text = "Refresh"
	clients_refresh_btn.tooltip_text = "Refresh client status in the background. Cached status stays visible while checks run."
	clients_refresh_btn.pressed.connect(_on_refresh_clients_pressed)
	clients_actions.add_child(clients_refresh_btn)

	var clients_open_btn := Button.new()
	clients_open_btn.text = "Clients & Tools"
	clients_open_btn.tooltip_text = "Open the Clients & Tools window — configure AI clients, choose telemetry preferences, or disable tool domains to fit under a client's hard tool-count cap (e.g. Antigravity's 100)."
	clients_open_btn.pressed.connect(_on_open_clients_window)
	clients_actions.add_child(clients_open_btn)

	_body.add_child(clients_header_row)
	_body.add_child(clients_actions)

	_client_empty_cta_btn = Button.new()
	_client_empty_cta_btn.text = "Configure an AI client ->"
	_client_empty_cta_btn.tooltip_text = "Open the Clients tab to configure an AI coding client for this Godot AI server."
	_client_empty_cta_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_client_empty_cta_btn.visible = false
	_client_empty_cta_btn.pressed.connect(_on_open_clients_window)
	_body.add_child(_client_empty_cta_btn)

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
	_body.add_child(_drift_banner)

	_clients_window = Window.new()
	_clients_window.title = "Godot AI Settings"
	## `Vector2i * float` yields Vector2; wrap the result back to Vector2i.
	_clients_window.min_size = Vector2i(Vector2(560, 460) * EditorInterface.get_editor_scale())
	_clients_window.visible = false
	_clients_window.close_requested.connect(_on_clients_window_close_requested)
	add_child(_clients_window)

	## Tabbed secondary window: Clients (per-client rows), Tools (domain-
	## exclusion checkboxes for clients that cap total tool count, like
	## Antigravity at 100), and Settings (allow-host LAN opt-in, #507).
	## Adding another tab is one more _build_*_tab call — no surgery on the
	## rest of the window.
	var tabs := TabContainer.new()
	tabs.anchor_right = 1.0
	tabs.anchor_bottom = 1.0
	_clients_window.add_child(tabs)

	var clients_tab := VBoxContainer.new()
	clients_tab.add_theme_constant_override("separation", 8)
	var clients_margin := _build_margin_container()
	clients_margin.name = "Clients"
	clients_margin.add_child(clients_tab)
	tabs.add_child(clients_margin)

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

	for client_id in ClientConfigurator.client_ids():
		_build_client_row(client_id)

	_build_tools_tab(tabs)
	_build_settings_tab(tabs)

	_body.add_child(HSeparator.new())

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
	_body.add_child(dev_toggle_row)

	# --- Log section (dev-only) ---
	_log_viewer = LogViewerScript.new()
	_log_viewer.setup()
	_log_viewer.logging_enabled_changed.connect(_on_log_logging_enabled_changed)
	_body.add_child(_log_viewer)

	# Apply initial dev-mode visibility
	_apply_dev_mode_visibility()
	_refresh_setup_status.call_deferred()
	_perform_initial_client_status_refresh()


## Static so `dock_panels/*.gd` subpanels can call it via `McpDock._make_header(...)`
## without re-declaring identical helpers + COLOR_HEADER constants.
static func _make_header(text: String) -> Label:
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
	name_label.text = ClientConfigurator.client_display_name(client_id)
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	## Every advertised client uses the authenticated local attach bridge.
	var transport_tag := Label.new()
	transport_tag.text = _client_transport_tag(client_id)
	transport_tag.add_theme_color_override("font_color", COLOR_MUTED)
	transport_tag.tooltip_text = "Configure writes a local `godot-ai attach` launch command for this client."
	## Long error messages from `_verify_post_state` (e.g. "reported remove ok
	## but verification still reads configured…") used to push the Retry /
	## Configure button off-screen — the row's Label wanted its full text
	## width as minimum size, so the buttons got squeezed out. Wrap onto
	## multiple lines instead so the row keeps its right edge stable and
	## the buttons remain visible; the user can also read the whole message
	## without resizing the window.
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_label)
	row.add_child(transport_tag)

	var configure_btn := Button.new()
	configure_btn.text = "Configure"
	configure_btn.pressed.connect(_on_configure_client.bind(client_id))
	row.add_child(configure_btn)

	var remove_btn := Button.new()
	remove_btn.text = "Remove"
	remove_btn.visible = false
	remove_btn.pressed.connect(_on_remove_client.bind(client_id))
	row.add_child(remove_btn)

	# F-3-4: use the authoritative facade so Open/Reveal land on the same
	# file `_check_status_merged` drives (last-wins across project tiers,
	# matching the F2 status fix).
	var config_path := ClientConfigurator.effective_authoritative_path(client_id)
	var open_config_btn := Button.new()
	_apply_editor_icon(open_config_btn, "ExternalLink", "Open")
	open_config_btn.custom_minimum_size = Vector2(28, 28)
	open_config_btn.visible = not config_path.is_empty()
	open_config_btn.pressed.connect(_on_open_config_file.bind(client_id))
	row.add_child(open_config_btn)

	var reveal_btn := Button.new()
	_apply_editor_icon(reveal_btn, "Folder", "Reveal")
	reveal_btn.custom_minimum_size = Vector2(28, 28)
	reveal_btn.visible = not config_path.is_empty()
	reveal_btn.pressed.connect(_on_reveal_config_folder.bind(client_id))
	row.add_child(reveal_btn)

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
		"status": Client.Status.NOT_CONFIGURED,
		"name_label": name_label,
		"configure_btn": configure_btn,
		"remove_btn": remove_btn,
		"open_config_btn": open_config_btn,
		"reveal_btn": reveal_btn,
		"config_path": config_path,
		"manual_panel": manual_panel,
		"manual_text": manual_text,
	}
	_refresh_client_config_file_buttons(client_id)


func _apply_editor_icon(button: Button, icon_name: String, fallback_text: String) -> void:
	if has_theme_icon(icon_name, "EditorIcons"):
		button.icon = get_theme_icon(icon_name, "EditorIcons")
	else:
		button.text = fallback_text


# --- Status updates ---

func _update_status() -> void:
	## Signal delivery is synchronous: the composition root copies current
	## transport/lifecycle values into the presentation methods below before
	## this frame renders. If no root is attached, the last snapshot remains.
	status_snapshot_requested.emit()
	var connected := bool(_transport_snapshot.get("connected", false))
	var transport_status: Dictionary = _transport_snapshot.get("status", {})
	var server_status := _lifecycle_snapshot
	var state: int = int(server_status.get("state", ServerStateScript.UNINITIALIZED))
	if ServerStateScript.blocks_client_health(state):
		connected = false

	## One `match`/`elif` chain, one source of truth. Adding a new
	## spawn outcome = one `ServerStateScript` constant + one arm here +
	## one body string in `_crash_body_for_state`.
	## Default covers both a missing/old Connection instance and an unknown
	## future transport phase. Every recognized state below overrides it, so
	## startup grace and settled disconnect have one rendering path.
	var inside_startup_grace := Time.get_ticks_msec() < _startup_grace_until_msec
	var status_text := "Starting server…" if inside_startup_grace else "Disconnected"
	var status_color := COLOR_AMBER if inside_startup_grace else Color.RED
	if _server_restart_in_progress:
		status_text = "Restarting server..."
		status_color = COLOR_AMBER
	elif connected:
		status_text = _connected_status_text()
		status_color = Color.GREEN
	elif state == ServerStateScript.CRASHED:
		var exit_ms: int = server_status.get("exit_ms", 0)
		status_text = "Server exited after %.1fs" % (exit_ms / 1000.0)
		status_color = Color.RED
	elif state == ServerStateScript.PORT_EXCLUDED:
		status_text = "Port %d reserved by Windows" % ClientConfigurator.http_port()
		status_color = Color.RED
	elif state == ServerStateScript.INCOMPATIBLE:
		status_text = "Incompatible server on port %d" % ClientConfigurator.http_port()
		status_color = Color.RED
	elif state == ServerStateScript.FOREIGN_PORT:
		## #647: the post-crash probe names the actual conflicting port
		## (HTTP or WS) — don't blame port 8000 when 9500 is the occupant.
		var conflict_port: int = int(server_status.get("conflict_port", 0))
		if conflict_port <= 0:
			conflict_port = ClientConfigurator.http_port()
		status_text = "Port %d held by another process" % conflict_port
		status_color = Color.RED
	elif state == ServerStateScript.NO_COMMAND:
		status_text = "No server command found"
		status_color = Color.RED
	elif not transport_status.is_empty():
		var transport_phase := str(transport_status.get("phase", ""))
		if transport_phase == "connecting":
			status_text = _transport_status_text(transport_status)
			status_color = COLOR_AMBER
		elif transport_phase == "retrying":
			status_text = _transport_status_text(transport_status)
			status_color = COLOR_AMBER
		elif transport_phase == "closing":
			status_text = _transport_status_text(transport_status)
			status_color = COLOR_AMBER
		elif transport_phase == "blocked":
			## Exact terminal labels come from lifecycle state above. This is a
			## generic fallback for a blocked connection without a diagnosis.
			status_text = _transport_status_text(transport_status)
			status_color = Color.RED

	## keep_server_on_exit (#800): the reaper env opt-outs are staged at
	## spawn, so a mid-session toggle only lands on the next server start —
	## say so while the running server still carries the old behavior.
	if connected and ClientConfigurator.keep_server_on_exit() != bool(server_status.get("keep_alive", false)):
		status_text += " — keep-server-on-exit applies after Restart"

	_update_crash_panel(server_status)
	_refresh_server_version_label(server_status)
	_refresh_server_label(server_status)

	## A transient disconnect reason remains in the transport snapshot until
	## handshake_ack. Once the dock renders the connection as OPEN, do not pair
	## its green label with the previous peer's recovery diagnostic.
	var status_tooltip := "" if connected else str(transport_status.get("reason", ""))
	var changed: bool = (
		connected != _last_connected
		or status_text != _last_status_text
		or status_tooltip != _last_status_tooltip
	)
	if not changed:
		return
	var just_connected: bool = connected and not _last_connected
	_last_connected = connected
	_last_status_text = status_text
	_last_status_tooltip = status_tooltip
	_status_icon.color = status_color
	_status_label.text = status_text
	_status_label.tooltip_text = status_tooltip
	if just_connected:
		## #739: the server just came up. If the startup uv probe failed
		## (the reporter's screenshot: green "Server connected" beside a
		## red "uv: not found" row), the failure was transient — re-probe
		## instead of pinning the red row for the whole session. Runs
		## AFTER the label writes above and via the deferred queue, so the
		## status-machine state is committed before the probe can block.
		_schedule_uv_reprobe()

	## Status transitions are exactly when "is the launch still settling?"
	## can change (Starting server… -> connected / Disconnected / terminal
	## diagnosis), so re-evaluate the Setup section's visibility here (#744).
	## Cheap: runs only on `changed`, and the uv probe result is cached.
	_apply_dev_mode_visibility()

	_update_dev_section_buttons()


## Render the diagnostic panel body for a given spawn state. The top
## status label already names the problem; this answers "what do I do?".
## Panel shows for any non-OK state; picker shows only when moving the HTTP
## port alone is a valid recovery. Incompatible godot-ai servers commonly
## hold both HTTP and WS ports, so their message points to Editor Settings
## instead of offering the HTTP-only quick picker.
func _update_crash_panel(server_status: Dictionary) -> void:
	var state: int = int(server_status.get("state", ServerStateScript.UNINITIALIZED))
	if not ServerStateScript.is_terminal_diagnosis(state):
		if _crash_panel.visible:
			_crash_panel.visible = false
			_last_server_status = {}
		return
	if server_status == _last_server_status:
		return
	_last_server_status = server_status.duplicate()
	_crash_panel.visible = true
	_crash_output.clear()
	_crash_output.add_text(_crash_body_for_state(state, server_status))
	var show_recovery_restart := (
		state == ServerStateScript.INCOMPATIBLE
		and bool(server_status.get("can_recover_incompatible", false))
	)
	if _crash_restart_btn != null:
		_crash_restart_btn.visible = show_recovery_restart
		_crash_restart_btn.disabled = _server_restart_in_progress
		_crash_restart_btn.text = "Restarting..." if _server_restart_in_progress else "Restart Server"
	if _crash_reload_btn != null:
		_crash_reload_btn.visible = (
			not show_recovery_restart
			and state != ServerStateScript.INCOMPATIBLE
		)
	## Docs link only for the genuinely-foreign occupant: a recoverable
	## (older godot-ai) server gets Restart Server instead, and the inline
	## body already names a free port — the link carries the per-client
	## reconfigure steps that don't fit inline.
	if _crash_docs_btn != null:
		_crash_docs_btn.visible = (
			state == ServerStateScript.INCOMPATIBLE
			and not bool(server_status.get("can_recover_incompatible", false))
		)

	## #647: the quick picker only moves `godot_ai/http_port`, so hide it
	## when the diagnosed conflict is on the WebSocket port — the crash
	## body already points at `godot_ai/ws_port` in Editor Settings.
	var conflict_port := int(server_status.get("conflict_port", 0))
	var http_conflict := conflict_port <= 0 or conflict_port == ClientConfigurator.http_port()
	var port_picker_visible := (
		state == ServerStateScript.PORT_EXCLUDED
		or (state == ServerStateScript.FOREIGN_PORT and http_conflict)
	)
	_port_picker_panel.visible = port_picker_visible
	if port_picker_visible:
		## Seed the spinbox with a suggested non-reserved port each time the
		## panel surfaces. Idempotent when the user already has a good
		## candidate queued up.
		_port_picker_panel.seed_suggested_port()


static func _crash_body_for_state(state: int, server_status: Dictionary = {}) -> String:
	## Single sentence per state. The top status label already names the
	## problem; don't repeat it here. This copy answers "what do I do?".
	var port := ClientConfigurator.http_port()
	match state:
		ServerStateScript.PORT_EXCLUDED:
			return "Windows (Hyper-V / WSL2 / Docker) reserved port %d. Pick a free port or try `net stop winnat; net start winnat` in an admin shell." % port
		ServerStateScript.INCOMPATIBLE:
			var message := str(server_status.get("message", ""))
			if bool(server_status.get("can_recover_incompatible", false)):
				var expected := str(server_status.get("expected_version", ""))
				if expected.is_empty():
					expected = ClientConfigurator.get_plugin_version()
				if not message.is_empty():
					return "%s Click Restart Server below to replace it with godot-ai v%s." % [message, expected]
				return "Port %d is occupied by an older godot-ai server. Click Restart Server below to replace it with godot-ai v%s." % [port, expected]
			## Genuinely foreign occupant (no recovery proof). Name a concrete
			## free port so the user doesn't have to hunt for one, and let the
			## crash panel's "How to change the port" link carry the per-client
			## reconfigure steps. `suggest_free_port` already routes through the
			## Windows reservation table, so the named port won't itself fail
			## with WinError 10013.
			var hint := _free_port_hint(port)
			if not message.is_empty():
				return "%s %s" % [message, hint]
			return "Port %d is occupied by an incompatible server. %s" % [port, hint]
		ServerStateScript.FOREIGN_PORT:
			## #647: prefer the lifecycle's diagnosis (it names the right
			## port — HTTP vs WS — and the Editor Setting to change) over
			## the generic HTTP-port fallback.
			var foreign_message := str(server_status.get("message", ""))
			if not foreign_message.is_empty():
				return foreign_message
			return "Another process is already bound to port %d. Pick a free port or stop the other process." % port
		ServerStateScript.CRASHED:
			## #805: a specific crash diagnosis from the lifecycle (e.g. the
			## flapping-occupant latch) beats the generic launch-mode copy.
			## Generic crash paths clear the message, so stale text from an
			## earlier state can't leak in here.
			var crash_message := str(server_status.get("message", ""))
			if not crash_message.is_empty():
				return crash_message
			## Both spawn attempts failed on the uvx tier — stock releases:
			## PyPI lag. Local builds (version with +metadata): almost always the
			## dev venv was not found (unresolved junction/symlink) so uvx tried
			## a pin that may lack checkout-local extras.
			if ClientConfigurator.get_server_launch_mode() == "uvx":
				var version := ClientConfigurator.get_plugin_version()
				var pin := ClientConfigurator._pypi_pin_version(version)
				if pin != version:
					## `%` binds tighter than `+` in GDScript — format the fully
					## concatenated string, never the last fragment alone.
					return (
						"The server exited before the WebSocket handshake. "
						+ "Local plugin version is %s (PEP 440 local build metadata) — uvx pins PyPI godot-ai==%s. "
						+ "If you need checkout-local server code, ensure addons/godot_ai resolves to your "
						+ "dev tree (symlink/junction) with a `.venv`, or set GODOT_AI_VENV_PYTHON to that "
						+ "venv's python binary, then Reload Plugin. Log should show 'MCP | using dev venv: ...'."
					) % [version, pin]
				return (
					"The server exited before the WebSocket handshake, even after a `uvx --refresh` retry. "
					+ "If this is a brand-new release, PyPI's index may still be propagating (~10 min). "
					+ "Wait a moment and click Reload Plugin to retry, or check Godot's output log for Python's traceback. "
					+ "Target: godot-ai==%s."
				) % pin
			return "The server exited before the WebSocket handshake. Check Godot's output log (bottom panel) for Python's traceback."
		ServerStateScript.NO_COMMAND:
			return "No godot-ai server found. Install `uv` via the Setup panel above, or run `pip install godot-ai`."
		_:
			return ""


## One sentence naming concrete free ports for the user to switch to. Names
## BOTH http and ws: this branch also fires for an incompatible godot-ai
## server we can't prove we own, which commonly holds both ports — moving only
## http would then leave the new server unable to bind ws. Both suggestions are
## routed through `suggest_free_port` so they clear Windows' winnat reservation
## table (no point suggesting a port that 10013s on bind). Only the http port
## reaches client configs; the ws port is server↔plugin, hence the wording.
## The per-client reconfigure steps live behind the crash panel's docs link.
static func _free_port_hint(port: int) -> String:
	var free_http := ClientConfigurator.suggest_free_port(port + 1)
	var free_ws := ClientConfigurator.suggest_free_port(ClientConfigurator.ws_port() + 1)
	return "Ports %d (HTTP) and %d (WS) are free — set `godot_ai/http_port` and `godot_ai/ws_port` in Editor Settings, then update your client config with the new HTTP port (How to change the port, below)." % [free_http, free_ws]


## URL for the port-conflict guide, pinned to the release tag that matches the
## installed plugin version (releases are tagged `v<version>`). The crash-panel
## button only exists in builds that ship `docs/port-conflicts.md`, so the
## versioned ref always resolves — and a shipped build never points users at a
## tip-of-main guide that has drifted from its own UI.
static func _port_conflict_docs_url() -> String:
	var version := ClientConfigurator.get_plugin_version()
	var git_ref := ("v%s" % version) if not version.is_empty() else "main"
	return "%s/%s/%s" % [REPO_BLOB_BASE, git_ref, PORT_CONFLICT_DOCS_PATH]


## Signal handler for the extracted LogViewer — the panel owns its own
## display visibility, the dock owns logging routing. Routes to BOTH the
## dispatcher (gates [recv]/[send] recording) and the log buffer's console
## echo — the connection logs [event]/[defer] lines directly to the buffer,
## bypassing the dispatcher, so gating only `mcp_logging` left the console
## spamming with the toggle off (#626). Ring recording is unaffected, so
## the dock's log panel keeps working while the console stays quiet.
func _on_log_logging_enabled_changed(enabled: bool) -> void:
	mcp_logging_changed.emit(enabled)


## Signal handler for the extracted PortPickerPanel. The replaceable Dock emits
## a copied value intent; the composition root owns persistence and reload.
func _on_port_apply_requested(new_port: int) -> void:
	settings_apply_requested.emit({"http_port": new_port}, true)


func _refresh_server_label(server_status: Dictionary = {}) -> void:
	if _server_label == null:
		return
	var ws_port := int(_lifecycle_snapshot.get("resolved_ws_port", 0))
	if ws_port <= 0:
		ws_port = ClientConfigurator.ws_port()
	var text := "WS: %d  HTTP: %d" % [ws_port, ClientConfigurator.http_port()]
	if server_status.is_empty():
		server_status = _lifecycle_snapshot
	var ownership := _server_ownership_tag(
		int(server_status.get("state", ServerStateScript.UNINITIALIZED)),
		int(server_status.get("server_pid", -1)),
	)
	if not ownership.is_empty():
		text += "  ·  %s" % ownership
	_server_label.text = text


## #838/#816 step 11: name which backend flavor the editor is riding.
## Diagnostic display only — never kill proof (external adoption clears PID
## authority, see server_lifecycle.gd::adopt_compatible_server / #669).
static func _server_ownership_tag(state: int, server_pid: int) -> String:
	if state != ServerStateScript.READY:
		return ""
	return "plugin-managed backend" if server_pid > 0 else "externally adopted backend"


static func _client_transport_tag(client_id: String) -> String:
	var client := ClientRegistry.get_by_id(client_id)
	if client == null:
		return ""
	return "attach"


# --- Telemetry setting persistence ---


## Returns true if GODOT_AI_DISABLE_TELEMETRY or DISABLE_TELEMETRY is set
## to a truthy value, false if either is set and non-truthy, null if neither
## env var is present at all.
func _is_telemetry_disabled_via_env() -> Variant:
	if not (OS.has_environment("GODOT_AI_DISABLE_TELEMETRY") or OS.has_environment("DISABLE_TELEMETRY")):
		return null
	return McpSettings.env_truthy("GODOT_AI_DISABLE_TELEMETRY") or McpSettings.env_truthy("DISABLE_TELEMETRY")


## Reads the telemetry preference, applying env-var override when present.
## Initialises _telemetry_pending_enabled / _telemetry_saved_enabled and
## sets the checkbox state + locked tooltip. Call after _telemetry_toggle
## has been created.
func _load_telemetry_setting() -> void:
	var env_disabled = _is_telemetry_disabled_via_env()

	var enabled: bool
	if env_disabled != null:
		## Environment policy controls this activation but does not rewrite the
		## user's persisted preference.
		enabled = not bool(env_disabled)
	else:
		## Defaults are registered by the composition root before Dock creation.
		var es := EditorInterface.get_editor_settings()
		if es != null and es.has_setting(McpSettings.SETTING_TELEMETRY_ENABLED):
			enabled = bool(es.get_setting(McpSettings.SETTING_TELEMETRY_ENABLED))
		else:
			enabled = true

	_telemetry_pending_enabled = enabled
	_telemetry_saved_enabled = enabled

	if _telemetry_toggle == null:
		return
	_telemetry_toggle.set_pressed_no_signal(enabled)
	if env_disabled != null:
		_telemetry_toggle.disabled = true
		_telemetry_toggle.tooltip_text = (
			"Telemetry is controlled by an environment variable "
			+ "(GODOT_AI_DISABLE_TELEMETRY / DISABLE_TELEMETRY)."
		)
	else:
		_telemetry_toggle.disabled = false
		_telemetry_toggle.tooltip_text = _live_telemetry_tooltip(enabled)


func _on_telemetry_toggled(pressed: bool) -> void:
	_telemetry_pending_enabled = pressed
	if _telemetry_toggle != null:
		_telemetry_toggle.tooltip_text = _live_telemetry_tooltip(pressed)
	_refresh_tools_ui_state()


## Report the running server's telemetry state, not just this editor's
## checkbox. Apply & Restart injects opt-out into a server this plugin
## spawns; it cannot change an adopted process's environment. Ported from
## upstream PR #931 / issue #913.
func _live_telemetry_tooltip(local_enabled: bool) -> String:
	_live_server_probe_result = {}
	live_server_probe_requested.emit(ClientConfigurator.http_port())
	var live := _live_server_probe_result
	if not (live.get("telemetry_enabled") is bool):
		return ""
	var server_enabled: bool = live.get("telemetry_enabled")
	if server_enabled == local_enabled:
		return "Running server telemetry is %s." % ("on" if server_enabled else "off")
	return (
		"This editor wants telemetry %s, but the running server still has it %s. "
		+ "Opt-out only reaches a server this plugin spawned. Stop that process "
		+ "or set GODOT_AI_DISABLE_TELEMETRY in its environment."
	) % ["on" if local_enabled else "off", "on" if server_enabled else "off"]


# --- Dev mode persistence ---


func _load_dev_mode() -> bool:
	# Default OFF for every install (including dev checkouts). Contributors
	# who want the extra diagnostic UI (Reload Plugin, MCP log
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
	if _dev_mode_toggle == null:
		return  ## dock UI not built yet (unit tests, teardown window)
	var dev := _dev_mode_toggle.button_pressed
	_dev_section.visible = dev
	if _log_viewer != null:
		_log_viewer.visible = dev
	# Setup section: visible in dev mode, OR in user mode when uv is missing
	# (so users can install uv from the dock) — but not while the server
	# launch is still settling (#744): mid-launch a red "uv: not found" row
	# is usually a transient probe failure (#739) or irrelevant because the
	# launch is succeeding via the .venv or system tiers. `_update_status`
	# re-applies visibility on every status transition, so the section
	# appears the moment the launch outcome makes it relevant.
	var is_dev := ClientConfigurator.is_dev_checkout()
	var uv_missing := not is_dev and ClientConfigurator.check_uv_version().is_empty()
	_setup_section.visible = _setup_section_should_show(dev, uv_missing, _server_launch_pending())


## Pure visibility decision for the Setup section (#744). Split out so the
## truth table is unit-testable without faking the uv probe or a dev
## checkout: dev toggle always shows the section; a missing uv only shows
## it once the server launch has settled.
static func _setup_section_should_show(
	dev_toggle: bool, uv_missing: bool, launch_pending: bool
) -> bool:
	return dev_toggle or (uv_missing and not launch_pending)


## True while the server launch outcome is still unknown: not connected,
## no terminal diagnosis yet, and the startup grace window ("Starting
## server…" in the status row) is still running. Mirrors the status-label
## logic in `_update_status` so the Setup section and the amber status
## text agree on what "still launching" means.
func _server_launch_pending() -> bool:
	if _last_connected:
		return false
	var state := int(_lifecycle_snapshot.get("state", ServerStateScript.UNINITIALIZED))
	if ServerStateScript.is_terminal_diagnosis(state):
		return false
	return Time.get_ticks_msec() < _startup_grace_until_msec


# --- Button handlers ---


func _on_reload_plugin() -> void:
	plugin_reload_requested.emit("dock_button")


## Setup-section "Server" row: always report the TRUE running server
## version (from the handshake_ack) rather than the plugin's expected
## version, and highlight the mismatch so self-update drift is visible
## at a glance instead of silently masked by a green label.
##
## Render states, keyed off live version metadata:
## - empty (pre-ack): show the expected version only as an unverified target
## - matches plugin: show it green, no Restart button
## - dev mismatch: show amber with an explicit dev marker
## - release mismatch: show actual vs expected; only surface Restart when the
##   plugin has ownership proof for the process
func _refresh_server_version_label(server_status: Dictionary = {}) -> void:
	if _setup_server_label == null:
		return
	var plugin_ver := ClientConfigurator.get_plugin_version()
	if server_status.is_empty():
		server_status = _lifecycle_snapshot
	var server_ver := str(_transport_snapshot.get("server_version", ""))
	if server_ver.is_empty():
		server_ver = str(server_status.get("actual_version", ""))
	var expected_ver := str(server_status.get("expected_version", ""))
	if expected_ver.is_empty():
		expected_ver = plugin_ver
	var state: int = int(server_status.get("state", ServerStateScript.UNINITIALIZED))
	if _server_restart_in_progress and (
		server_ver == expected_ver
		or (
			ServerStateScript.is_terminal_diagnosis(state)
			and state != ServerStateScript.INCOMPATIBLE
		)
	):
		_server_restart_in_progress = false
	var text: String
	var color: Color
	var show_restart := false
	if _server_restart_in_progress:
		text = "restarting server..."
		color = COLOR_AMBER
		show_restart = true
	elif server_ver.is_empty():
		text = "checking live version (expected godot-ai == %s)" % expected_ver
		color = COLOR_MUTED
	elif server_ver == expected_ver:
		text = "godot-ai == %s" % server_ver
		color = Color.GREEN
	else:
		text = "godot-ai == %s  (expected %s)" % [server_ver, expected_ver]
		var is_incompatible: bool = state == ServerStateScript.INCOMPATIBLE
		color = Color.RED if is_incompatible else COLOR_AMBER
		var has_managed_proof := bool(server_status.get("can_restart_managed", false))
		var can_recover: bool = bool(server_status.get("can_recover_incompatible", false))
		show_restart = (
			(not is_incompatible and has_managed_proof)
			## Recoverable incompatible servers get the primary action in
			## the top error panel. Duplicating it in Setup made the UI
			## look like it had multiple restart paths.
			or (is_incompatible and can_recover and _crash_restart_btn == null)
		)
	if text == _last_rendered_server_text:
		_setup_server_label.add_theme_color_override("font_color", color)
		_update_restart_button(show_restart)
		return
	_last_rendered_server_text = text
	_setup_server_label.text = text
	_setup_server_label.add_theme_color_override("font_color", color)
	_update_restart_button(show_restart)


func _update_restart_button(visible: bool) -> void:
	if _version_restart_btn != null:
		_version_restart_btn.visible = visible
		_version_restart_btn.disabled = _server_restart_in_progress
		_version_restart_btn.text = "Restarting..." if _server_restart_in_progress else "Restart"
	if _crash_restart_btn != null:
		_crash_restart_btn.disabled = _server_restart_in_progress
		_crash_restart_btn.text = "Restarting..." if _server_restart_in_progress else "Restart Server"


func _on_restart_stale_server() -> void:
	if _server_restart_in_progress:
		return
	_server_restart_in_progress = true
	_last_rendered_server_text = ""
	_refresh_server_version_label()
	if not is_inside_tree():
		_dispatch_stale_server_restart()
		_server_restart_in_progress = false
		_last_rendered_server_text = ""
		_refresh_server_version_label()
		return
	call_deferred("_restart_stale_server_after_feedback")


func _restart_stale_server_after_feedback() -> void:
	await get_tree().create_timer(0.15).timeout
	if not _dispatch_stale_server_restart():
		_server_restart_in_progress = false
		_last_rendered_server_text = ""
		_refresh_server_version_label()


func _dispatch_stale_server_restart() -> bool:
	if int(_lifecycle_snapshot.get("state", ServerStateScript.UNINITIALIZED)) == ServerStateScript.INCOMPATIBLE:
		lifecycle_action_requested.emit(LifecycleAction.RECOVER_INCOMPATIBLE)
		return true
	if not bool(_lifecycle_snapshot.get("can_restart_managed", false)):
		return false
	lifecycle_action_requested.emit(LifecycleAction.RESTART_SERVER)
	return true


## Root acknowledgement for an asynchronous lifecycle intent. Successful
## restarts stay busy until the next lifecycle/transport snapshot settles;
## rejection restores the controls immediately.
func present_lifecycle_action_result(accepted: bool) -> void:
	if accepted:
		return
	_server_restart_in_progress = false
	_last_rendered_server_text = ""
	_refresh_server_version_label()


# --- Setup section ---

## #739: a `uvx --version` probe that failed once at editor startup used
## to pin "uv: not found" for the whole session — the Install-uv click
## was the only invalidation path, so the fix users discovered was
## re-clicking Install on every launch. Re-probe on events that suggest
## the failure was transient (server-connect transition, manual Refresh).
## No-op once uv has been found, so this costs nothing in the healthy
## steady state; when uv is genuinely absent, the re-probe is a fast
## negative (CliFinder's well-known-dir walk plus one bounded `where`).
## Runs on the main thread like the initial probe — same wall-clock
## bound, and the triggering events are rare (once per connect / click).
##
## Callers go through _schedule_uv_reprobe() rather than calling this
## inline: the cache-miss probe shells out (bounded at 3s) on the
## calling thread, and both call sites sit mid-flow in UI handlers —
## the connect transition wants its status-label writes committed
## first, and the Refresh click wants the client sweep dispatched
## without waiting on the probe. Same deferred convention as
## _on_install_uv. (The deferred queue still flushes on the main
## thread, so a worst-case 3s probe delays that frame — acceptable for
## a rare, bounded event; a worker thread would be the heavier cure.)
func _schedule_uv_reprobe() -> void:
	_reprobe_uv_if_negative.call_deferred()


func _reprobe_uv_if_negative() -> void:
	if not ClientConfigurator.uv_probe_negative():
		return
	ClientConfigurator.invalidate_uv_detection()
	_refresh_setup_status()
	_apply_dev_mode_visibility()


func _refresh_setup_status() -> void:
	if _setup_container == null:
		return
	for child in _setup_container.get_children():
		child.queue_free()
	_dev_primary_btn = null
	_dev_stop_btn = null

	var is_dev := ClientConfigurator.is_dev_checkout()
	if is_dev:
		_setup_container.add_child(_make_status_row("Mode", "Dev (venv)", Color.CYAN))

		var btn_row := HBoxContainer.new()
		btn_row.add_theme_constant_override("separation", 4)
		btn_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL

		_dev_primary_btn = Button.new()
		_dev_primary_btn.text = "Restart Managed Server"
		_dev_primary_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_dev_primary_btn.pressed.connect(_on_dev_primary_pressed)
		btn_row.add_child(_dev_primary_btn)

		_dev_stop_btn = Button.new()
		_dev_stop_btn.text = "✕"
		_dev_stop_btn.tooltip_text = "Stop the exact plugin-owned server."
		_dev_stop_btn.pressed.connect(_on_dev_stop_pressed)
		btn_row.add_child(_dev_stop_btn)

		_setup_container.add_child(btn_row)
		_update_dev_section_buttons()
		return

	# User mode — check for uv
	var uv_version := ClientConfigurator.check_uv_version()
	if not uv_version.is_empty():
		var compact_uv_version := _compact_uv_version_text(uv_version)
		var uv_tooltip := uv_version if compact_uv_version != uv_version else ""
		_setup_container.add_child(_make_status_row("uv", compact_uv_version, Color.GREEN, uv_tooltip))
		## Build the Server row with a placeholder label we can update every
		## frame. `_refresh_server_version_label` replaces the text + color
		## once `McpConnection.server_version` lands via `handshake_ack`, and
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
		_version_restart_btn.tooltip_text = "Kill the server on port %d and respawn with the plugin's bundled version" % ClientConfigurator.http_port()
		_version_restart_btn.pressed.connect(_on_restart_stale_server)
		_version_restart_btn.visible = false
		server_row.add_child(_version_restart_btn)
		_setup_container.add_child(server_row)
		_last_rendered_server_text = ""
		_refresh_server_version_label()
	else:
		_setup_container.add_child(_make_status_row("uv", "not found", Color.RED))
		var install_btn := Button.new()
		install_btn.text = "How to install uv"
		install_btn.tooltip_text = (
			"Opens the official uv installation docs. Godot AI deliberately does "
			+ "not run the installer for you — see _on_install_uv."
		)
		install_btn.pressed.connect(_on_install_uv)
		_setup_container.add_child(install_btn)


func _install_mode_text() -> String:
	if ClientConfigurator.is_dev_checkout():
		return "Install: dev checkout — update via git pull"
	return "Install: v%s" % ClientConfigurator.get_plugin_version()


func _install_mode_tooltip() -> String:
	if not ClientConfigurator.is_dev_checkout():
		return "Plugin installed from a release ZIP, Asset Library, or source copy. Update button in this dock downloads the latest GitHub release."
	var target := _resolve_plugin_symlink_target()
	if target.is_empty():
		return "Plugin source tree resolved via local .venv — press Reload Plugin after editing."
	return "Plugin source: %s\nPress Reload Plugin after editing." % target


func _resolve_plugin_symlink_target() -> String:
	var logical := ProjectSettings.globalize_path("res://addons/godot_ai").rstrip("/").rstrip("\\")
	var resolved := ClientConfigurator.resolve_addons_realpath()
	if resolved.is_empty() or resolved == logical:
		return ""
	return resolved


static func _compact_uv_version_text(uv_version: String) -> String:
	var text := uv_version.strip_edges()
	if text.ends_with(")"):
		var metadata_start := text.rfind(" (")
		if metadata_start >= 0:
			return text.substr(0, metadata_start).strip_edges()
	return text


func _make_status_row(
	label_text: String,
	value_text: String,
	value_color: Color,
	tooltip_text: String = ""
) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	if not tooltip_text.is_empty():
		row.tooltip_text = tooltip_text

	var label := Label.new()
	label.text = label_text
	label.add_theme_color_override("font_color", COLOR_MUTED)
	label.custom_minimum_size.x = 60
	if not tooltip_text.is_empty():
		label.tooltip_text = tooltip_text
	row.add_child(label)

	var value := Label.new()
	value.text = value_text
	value.add_theme_color_override("font_color", value_color)
	if not tooltip_text.is_empty():
		value.tooltip_text = tooltip_text
	row.add_child(value)

	return row


## Pure view of the lifecycle's process authority. "External" means transport
## may be adopted, but this plugin has no right to stop its launcher.
static func _dev_primary_btn_state(managed: bool, external: bool) -> Dictionary:
	var port := ClientConfigurator.http_port()
	if managed:
		return {
			"text": "Restart Managed Server",
			"enabled": true,
			"tooltip": "Restart the exact plugin-owned server on port %d." % port,
		}
	if external:
		return {
			"text": "External Server Running",
			"enabled": false,
			"tooltip": "Stop the server on port %d from the process that launched it." % port,
		}
	return {
		"text": "Start Managed Server",
		"enabled": true,
		"tooltip": "Start a plugin-owned server on port %d from the current checkout." % port,
	}


static func _dev_stop_btn_state(managed: bool) -> Dictionary:
	if managed:
		return {"enabled": true, "tooltip": "Stop the exact plugin-owned server."}
	return {"enabled": false, "tooltip": "No plugin-owned server to stop."}


func _on_dev_primary_pressed() -> void:
	if _server_restart_in_progress:
		return
	_server_restart_in_progress = true
	_update_dev_section_buttons()
	if not is_inside_tree():
		## Test path — no scene tree means no timer; run synchronously
		## so suite assertions see the dispatch without `await`.
		dev_server_action_requested.emit(DevServerAction.START_OR_RESTART)
		_server_restart_in_progress = false
		return
	call_deferred("_perform_dev_restart_after_feedback")


func _on_dev_stop_pressed() -> void:
	dev_server_action_requested.emit(DevServerAction.STOP)
	_update_dev_section_buttons.call_deferred()


func _perform_dev_restart_after_feedback() -> void:
	## Brief paint cycle so the user sees "Restarting..." before dispatch.
	await get_tree().create_timer(0.15).timeout
	dev_server_action_requested.emit(DevServerAction.START_OR_RESTART)
	## Lifecycle snapshots normally repaint first; this is a bounded UI fallback.
	await get_tree().create_timer(2.0).timeout
	_server_restart_in_progress = false
	_update_dev_section_buttons()


## Derive both buttons from the already-copied lifecycle value. No second port
## scan or dev-only ownership state exists.
func _update_dev_section_buttons() -> void:
	var managed := int(_lifecycle_snapshot.get("server_pid", -1)) > 1
	var normal_start_released := bool(
		_lifecycle_snapshot.get("normal_start_released", false)
	)
	var state := int(_lifecycle_snapshot.get("state", ServerStateScript.UNINITIALIZED))
	var external := not managed and (
		str(_lifecycle_snapshot.get("ready_kind", "")) == "adopted"
		or state in [ServerStateScript.INCOMPATIBLE, ServerStateScript.FOREIGN_PORT]
	)
	if _dev_primary_btn != null:
		if _server_restart_in_progress:
			_dev_primary_btn.disabled = true
			_dev_primary_btn.text = "Restarting..."
			_dev_primary_btn.tooltip_text = "Restarting the plugin-owned server..."
		elif not normal_start_released:
			_dev_primary_btn.disabled = true
			_dev_primary_btn.text = "Server Start Blocked"
			_dev_primary_btn.tooltip_text = (
				"Complete post-update client migration before starting the server."
			)
		else:
			var primary_state := _dev_primary_btn_state(managed, external)
			_dev_primary_btn.disabled = not bool(primary_state["enabled"])
			_dev_primary_btn.text = primary_state["text"]
			_dev_primary_btn.tooltip_text = primary_state["tooltip"]
	if _dev_stop_btn != null:
		var stop_state := _dev_stop_btn_state(managed)
		_dev_stop_btn.disabled = (not stop_state["enabled"]) or _server_restart_in_progress
		_dev_stop_btn.tooltip_text = stop_state["tooltip"]


func _client_status_refresh_has_completed() -> bool:
	return bool(_client_work_snapshot.get("refresh_completed", false))


func _client_refresh_state() -> int:
	return int(_client_work_snapshot.get("refresh_state", ClientRefreshStateScript.IDLE))


func _connected_status_text() -> String:
	return "Server connected"


static func _transport_status_text(snapshot: Dictionary) -> String:
	## Total over the transport enum for isolated consumers/tests. The dock's
	## connected fast path renders `_connected_status_text()` before calling it.
	var phase := str(snapshot.get("phase", ""))
	var attempt := maxi(1, int(snapshot.get("attempt", 0)))
	match phase:
		"connected":
			return "Server connected"
		"connecting":
			return "Connecting — attempt %d" % attempt
		"retrying":
			var retry_in_sec := ceili(maxf(0.0, float(snapshot.get("retry_in_sec", 0.0))))
			return "Retrying in %ds — attempt %d" % [retry_in_sec, attempt]
		"closing":
			return "Disconnecting…"
		"blocked":
			return "Connection blocked"
	return "Disconnected"


## Open uv's official install documentation rather than executing an
## installer on the user's behalf.
##
## This used to shell out to `curl -LsSf https://astral.sh/uv/install.sh | sh`
## (and the PowerShell `irm … | iex` equivalent). That is arbitrary remote
## code execution as the editor user, one dock click deep, with no version
## pin, no checksum, and no signature — while this same plugin verifies its
## OWN updates with an RSA-4096 signature over a SHA-256 sidecar, pinned to a
## GitHub host and this repo's release-asset path. Holding a third-party
## installer to a weaker standard than our own payload is the wrong trade,
## and pinning a digest here would only cover the bootstrap script, not the
## uv binary it goes on to fetch.
##
## Opening the docs keeps the discovery value of the button (the user still
## learns uv is missing and how to get it) while leaving the decision to
## install — and the choice of install method — with the user. Mirrors the
## dock's existing "Run this manually" fallback for client CLIs.
func _on_install_uv() -> void:
	OS.shell_open(UV_INSTALL_DOCS_URL)
	## Drop the cached uvx path AND the cached `uvx --version` so that once
	## the user has installed uv (in a terminal, from the docs we just
	## opened), the dock finds the new binary instead of replaying the
	## cached "not found" result for the rest of the session.
	## Routing through the configurator matters on Windows, where the
	## CLI-finder cache key is `uvx.exe` — invalidating just `"uvx"`
	## would leave the cache stale and the dock would keep showing
	## "uv: not found" for the rest of the session.
	ClientConfigurator.invalidate_uv_detection()
	## Deliberately do NOT refresh here. `OS.shell_open` returns as soon as
	## the browser is handed the URL, so an immediate refresh would run long
	## before the user could install anything and would simply re-cache
	## "not found" — undoing the invalidation above. (The old shell-out was
	## a blocking `OS.execute`, so refreshing straight after it was correct
	## then; it stopped being correct when the installer call went away.)
	## Re-probe when the editor regains focus instead — see _notification.
	_uv_recheck_pending = true


# --- Client section ---

func _on_configure_client(client_id: String) -> void:
	## Configure writes an explicit url + live plugin version; it does not
	## need a healthy occupant. INCOMPATIBLE only suppresses status
	## interpretation (#916).
	_dispatch_client_action(client_id, "configure")


func _on_remove_client(client_id: String) -> void:
	_dispatch_client_action(client_id, "remove")


## Emit a value intent; plugin.gd routes it to the plugin-lifetime job owner.
## The Dock updates only view-local button state and never holds a Thread.
func _dispatch_client_action(client_id: String, action: String) -> void:
	if _is_self_update_in_progress():
		return
	if _busy_client_actions().has(client_id):
		return
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	_set_row_action_in_flight(client_id, action)
	client_action_requested.emit(client_id, action)


func present_client_action_result(
	client_id: String,
	action: String,
	result: Dictionary,
	prewarm: Dictionary = {},
) -> void:
	_report_prewarm_outcome(client_id, prewarm)
	_finalize_action_buttons(client_id)
	var success_status := Client.Status.NOT_CONFIGURED if action == "remove" else Client.Status.CONFIGURED
	if result.get("status") == "ok":
		## #877: Remove targets only the selected scope, so a configure is the
		## only action with an all-scope sweep to disclose. The manual panel
		## that lists those removes is shown on the failure path below, which
		## left the success path — where the sweep actually ran — silent.
		var sweep_note := (
			ClientConfigurator.configure_sweep_note(client_id) if action == "configure" else ""
		)
		_apply_row_status(client_id, success_status, sweep_note)
		var row: Dictionary = _client_rows.get(client_id, {})
		if not row.is_empty():
			(row["manual_panel"] as VBoxContainer).visible = false
	else:
		_apply_row_status(client_id, Client.Status.ERROR, str(result.get("message", "failed")))
		if action == "configure":
			_show_manual_command_for(client_id)
	_refresh_clients_summary()


func present_client_action_timeout(client_id: String, _action: String, detail: String) -> void:
	_apply_row_status(client_id, Client.Status.ERROR, detail)
	_refresh_clients_summary()


func present_client_work_snapshot(snapshot: Dictionary) -> void:
	_client_work_snapshot = snapshot.duplicate(true)
	var busy := _busy_client_actions()
	var names: Dictionary = _client_work_snapshot.get("action_names", {})
	var phases: Dictionary = _client_work_snapshot.get("action_phases", {})
	for client_id in _client_rows:
		var id := String(client_id)
		if busy.has(id):
			_set_row_action_in_flight(id, String(names.get(id, "configure")))
			if String(phases.get(id, "")) == "prewarm":
				(_client_rows[id]["configure_btn"] as Button).text = "Installing…"
		else:
			_finalize_action_buttons(id)
	_refresh_clients_summary()


func _busy_client_actions() -> Array[String]:
	var result: Array[String] = []
	result.assign(_client_work_snapshot.get("busy_actions", []))
	return result


## One line per Configure so a cold build is attributable after the fact —
## the dock label is transient, and #851's symptom (a terminal window on
## Windows) is easiest to correlate against a timestamped log entry. Silent
## on the skip paths: a dev-venv/system tier having no env to warm is the
## normal case, not news.
func _report_prewarm_outcome(client_id: String, prewarm: Variant) -> void:
	if not (prewarm is Dictionary):
		return
	var data := prewarm as Dictionary
	if data.is_empty() or bool(data.get("skipped", false)):
		return
	if bool(data.get("timed_out", false)):
		print(
			"MCP | %s: package pre-warm timed out; the first client launch will build the environment"
			% client_id
		)
		return
	if int(data.get("exit_code", -1)) != 0:
		print(
			"MCP | %s: package pre-warm failed (exit %d); the first client launch will build the environment"
			% [client_id, int(data.get("exit_code", -1))]
		)
		return
	print("MCP | %s: package environment pre-warmed" % client_id)


## In-flight visual: rewrite the verb onto the button the user just
## clicked ("Configuring…" / "Removing…") so the feedback lands where
## their attention already is. Don't pollute the row label — that'd
## clobber any drift hint ("URL out of date") still relevant to the row.
## The dot turns amber so the row reads as "busy" at a glance, not as
## green (premature success) or red (premature failure). Both buttons
## go disabled so a double-click or second action can't queue stale
## work behind the in-flight worker.
func _set_row_action_in_flight(client_id: String, action: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	var configure_btn: Button = row["configure_btn"]
	var remove_btn: Button = row["remove_btn"]
	configure_btn.disabled = true
	remove_btn.disabled = true
	if action == "remove":
		remove_btn.text = "Removing…"
	else:
		configure_btn.text = "Configuring…"
	(row["dot"] as ColorRect).color = COLOR_AMBER


## Re-enable both buttons and reset their text back to canonical labels.
## Restore labels from cached row status as well as enabling the controls.
## This matters when a timed-out orphan finishes: the owner publishes a new
## snapshot but has no action result to repaint the row for us.
func _finalize_action_buttons(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	var configure_btn := row["configure_btn"] as Button
	configure_btn.disabled = false
	match row.get("status", Client.Status.NOT_CONFIGURED):
		Client.Status.CONFIGURED, Client.Status.CONFIGURED_MISMATCH:
			configure_btn.text = "Reconfigure"
		Client.Status.NOT_CONFIGURED:
			configure_btn.text = "Configure"
		_:
			configure_btn.text = "Retry"
	var remove_btn: Button = row["remove_btn"]
	remove_btn.disabled = false
	remove_btn.text = "Remove"


func _on_refresh_clients_pressed() -> void:
	## Explicit user action — also give a failed uv probe another chance
	## (#739), mirroring how the same click already re-sweeps client CLIs.
	_schedule_uv_reprobe()
	_request_client_status_refresh(true)


func _on_configure_all_clients() -> void:
	## Per-row Configure already bypasses the RUNNING gate. INCOMPATIBLE
	## skips health interpretation (#916), so Configure all must do the same
	## even if a status sweep is still in flight — `_set_incompatible_server`
	## does not reset `_refresh_state`.
	if (
		ClientRefreshStateScript.should_disable_client_actions(_client_refresh_state())
		and not _server_blocks_client_health()
	):
		return
	for client_id in _client_rows:
		var status: Client.Status = _client_rows[client_id].get("status", Client.Status.NOT_CONFIGURED)
		if status == Client.Status.CONFIGURED:
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
	if vision_routing != null:
		vision_routing.refresh_ui()
	# popup_centered() with a minsize forces the window to that size and
	# centers on the parent viewport. Setting .size on a hidden Window
	# doesn't always take effect, so we force it at popup time here.
	_clients_window.popup_centered(Vector2i(640, 600))


func _settings_are_dirty() -> bool:
	return (
		_tools_pending_excluded != _tools_saved_excluded
		or _telemetry_pending_enabled != _telemetry_saved_enabled
		or _allow_hosts_is_dirty()
	)


func _on_clients_window_close_requested() -> void:
	if _clients_window == null:
		return
	## If the user has unapplied settings, a close would silently throw the
	## pending state away. Prompt before discarding current options and if
	## they confirm, reset pending → saved so the window shows the persisted
	## state the next time they open it.
	if _settings_are_dirty():
		_show_tools_close_confirm()
		return
	_clients_window.hide()


# --- Tools tab (domain exclusion) ---

func _build_tools_tab(tabs: TabContainer) -> void:
	## Tab 2 — domain-exclusion checkboxes. Rendered once, on dock construction.
	## `_reset_tools_pending_from_setting()` re-syncs checkbox state from the
	## saved setting each time the window opens.
	var tools_tab := VBoxContainer.new()
	tools_tab.add_theme_constant_override("separation", 8)
	var tools_margin := _build_margin_container()
	tools_margin.name = "Tools"
	tools_margin.add_child(tools_tab)
	tabs.add_child(tools_margin)

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
	count_header.text = "Tools Enabled:"
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
	core_count.text = "%d tools" % (ToolCatalog.CORE_TOOLS.size() + ToolCatalog.ALWAYS_ON_TOOLS.size())
	core_count.add_theme_color_override("font_color", COLOR_MUTED)
	core_row.add_child(core_count)
	core_row.tooltip_text = "%s · always on: %s" % [
		", ".join(ToolCatalog.CORE_TOOLS),
		", ".join(ToolCatalog.ALWAYS_ON_TOOLS),
	]
	grid.add_child(core_row)

	grid.add_child(HSeparator.new())

	_tools_domain_checkboxes.clear()
	for entry in ToolCatalog.DOMAINS:
		_build_tools_domain_row(grid, entry)

	## Custom (addon-registered) tools — unlike the domain rows above,
	## toggles apply LIVE: the registry re-pushes the filtered catalog to
	## the server on every change, no restart needed.
	grid.add_child(HSeparator.new())
	var custom_header_row := HBoxContainer.new()
	custom_header_row.add_theme_constant_override("separation", 8)
	var custom_header := Label.new()
	custom_header.text = "Custom tools (addon-registered)"
	custom_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_header_row.add_child(custom_header)
	_custom_tools_count_label = Label.new()
	_custom_tools_count_label.add_theme_color_override("font_color", COLOR_MUTED)
	custom_header_row.add_child(_custom_tools_count_label)
	grid.add_child(custom_header_row)
	var custom_hint := Label.new()
	custom_hint.text = "Applies immediately — disabled tools are hidden from agents and rejected if called."
	custom_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	custom_hint.add_theme_color_override("font_color", COLOR_MUTED)
	custom_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(custom_hint)
	_custom_tools_list = VBoxContainer.new()
	_custom_tools_list.add_theme_constant_override("separation", 4)
	_custom_tools_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(_custom_tools_list)
	_connect_custom_tool_registry()
	_refresh_custom_tools_rows()

	tools_tab.add_child(HSeparator.new())

	var telemetry_row := HBoxContainer.new()
	telemetry_row.add_theme_constant_override("separation", 8)
	var telemetry_label := Label.new()
	telemetry_label.text = "Telemetry"
	telemetry_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	telemetry_row.add_child(telemetry_label)
	_telemetry_toggle = CheckButton.new()
	_telemetry_toggle.toggled.connect(_on_telemetry_toggled)
	telemetry_row.add_child(_telemetry_toggle)
	tools_tab.add_child(telemetry_row)

	tools_tab.add_child(HSeparator.new())

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 8)

	_tools_apply_btn = Button.new()
	_tools_apply_btn.text = "Apply and Restart Server"
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
	## Generic wording: _settings_are_dirty() covers domain toggles, the
	## telemetry switch, AND the Settings tab's allow-host field (#507) —
	## the old "checked/unchecked domains" text misled non-domain edits.
	_tools_close_confirm.dialog_text = (
		"You have unapplied changes in this window.\n"
		+ "Close it and discard those changes?"
	)
	_tools_close_confirm.ok_button_text = "Discard"
	_tools_close_confirm.confirmed.connect(_on_tools_discard_confirmed)
	add_child(_tools_close_confirm)

	_update_confirm = ConfirmationDialog.new()
	_update_confirm.title = "Update Godot AI?"
	_update_confirm.ok_button_text = "Save & Update"
	_update_confirm.confirmed.connect(_on_update_confirmed)
	add_child(_update_confirm)

	_reset_tools_pending_from_setting()
	_refresh_tools_ui_state()


## --- Custom (addon-registered) tools section ---

func _connect_custom_tool_registry() -> void:
	var registry := McpToolRegistry.get_instance()
	if registry == null:
		return
	if not registry.tools_changed.is_connected(_on_custom_tool_registry_changed):
		registry.tools_changed.connect(_on_custom_tool_registry_changed)


func _on_custom_tool_registry_changed() -> void:
	## Deferred: tools_changed can fire from inside a checkbox toggle in
	## this very list — rebuilding synchronously would free the emitting
	## control mid-signal.
	_refresh_custom_tools_rows.call_deferred()


func _refresh_custom_tools_rows() -> void:
	if _custom_tools_list == null or not is_instance_valid(_custom_tools_list):
		return
	for child in _custom_tools_list.get_children():
		child.queue_free()
	var registry := McpToolRegistry.get_instance()
	var specs: Array = [] if registry == null else registry.all()
	specs.sort_custom(func(a, b): return String(a.name) < String(b.name))
	var enabled_count := 0
	for spec in specs:
		if registry.is_tool_enabled(spec.name):
			enabled_count += 1
		_custom_tools_list.add_child(_build_custom_tool_row(registry, spec))
	if _custom_tools_count_label != null and is_instance_valid(_custom_tools_count_label):
		_custom_tools_count_label.text = "%d/%d enabled" % [enabled_count, specs.size()]
	if specs.is_empty():
		var empty := Label.new()
		empty.text = "None registered. Addons add tools via McpToolRegistry — see docs/plugin-architecture.md."
		empty.add_theme_color_override("font_color", COLOR_MUTED)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		empty.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_custom_tools_list.add_child(empty)


func _build_custom_tool_row(registry: McpToolRegistry, spec: McpCustomToolSpec) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var chk := CheckBox.new()
	chk.button_pressed = registry.is_tool_enabled(spec.name)
	chk.toggled.connect(func(pressed: bool): registry.set_tool_enabled(spec.name, pressed))
	row.add_child(chk)
	var name_label := Label.new()
	name_label.text = spec.name + (" · promoted" if spec.promoted else "")
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(name_label)
	var source_label := Label.new()
	source_label.text = spec.source if not spec.source.is_empty() else spec.source_path.get_base_dir().get_file()
	source_label.add_theme_color_override("font_color", COLOR_MUTED)
	row.add_child(source_label)
	## Tooltip = the agent-facing description plus provenance, so the user
	## can judge what they're enabling without leaving the dock.
	row.tooltip_text = "%s\n\nsource: %s%s" % [
		spec.description,
		spec.source_path,
		"\npromoted: registers as first-class MCP tool custom_%s" % spec.name if spec.promoted else "",
	]
	name_label.tooltip_text = row.tooltip_text
	return row


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
	## version) are dropped from the display here (only ids with a checkbox
	## survive). The startup path is protected separately:
	## `ClientConfigurator.excluded_domains()` filters unknown names before
	## they reach `--exclude-domains`, whose `parse_exclude_list` hard-fails
	## on them.
	var saved_raw := ClientConfigurator.excluded_domains()
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
	## Also reset telemetry pending state from the persisted setting.
	if _telemetry_toggle != null:
		_load_telemetry_setting()
	## And the Settings tab's allow-host field (#507) — same window-open /
	## discard-confirm re-sync contract as the tools checkboxes.
	_reset_allow_hosts_from_setting()


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
	var enabled := ToolCatalog.enabled_tool_count(_tools_pending_excluded)
	var total := ToolCatalog.total_tool_count()
	_tools_count_label.text = "%d / %d" % [enabled, total]
	var dirty := _settings_are_dirty()
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
	var canonical_excluded := ToolCatalog.canonical(_tools_pending_excluded)
	_tools_saved_excluded = _tools_pending_excluded.duplicate()
	_telemetry_saved_enabled = _telemetry_pending_enabled
	_refresh_tools_ui_state()
	settings_apply_requested.emit({
		"excluded_domains": canonical_excluded,
		"telemetry_enabled": _telemetry_pending_enabled,
	}.duplicate(true), true)


func _on_tools_reset() -> void:
	## Resets only the tool-domain exclusions, not the telemetry toggle.
	## Telemetry is a privacy preference users typically want to set once
	## and have honored — flipping it back to "on" via a generic Reset
	## button would be a surprising privacy regression. The button label
	## is scoped to tools accordingly.
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


# --- Settings tab (allow-host LAN opt-in, #507) ---

func _build_settings_tab(tabs: TabContainer) -> void:
	## Tab 3 — settings-style controls that don't fit Clients or Tools: the
	## Vision Routing section plus the `--allow-host` LAN opt-in behind a
	## collapsed "Remote access (advanced)" disclosure, so its security
	## warning renders exactly at the point of configuration. Rendered once
	## on dock construction, mirroring `_build_tools_tab`;
	## `_reset_allow_hosts_from_setting()` and `vision_routing.refresh_ui()`
	## re-sync each time the window opens (via
	## `_reset_tools_pending_from_setting` / `_on_open_clients_window`).
	var settings_tab := VBoxContainer.new()
	settings_tab.add_theme_constant_override("separation", 8)
	var settings_margin := _build_margin_container()
	settings_margin.name = "Settings"
	settings_margin.add_child(settings_tab)
	tabs.add_child(settings_margin)

	## Vision Routing is configuration, not status — it lives here rather
	## than in the dock. Not dev-gated: it is the Settings tab's primary
	## content and must work for every user.
	if vision_routing != null:
		vision_routing.build_section(settings_tab)

	## Remote access (advanced): collapsed by default; auto-expands when a
	## non-empty CIDR allowlist is already configured so an active
	## off-loopback bind is never hidden behind a collapsed header. The
	## disclosure replaces the former developer-mode gate for this block.
	_allow_hosts_fold = FoldableContainer.new()
	_allow_hosts_fold.title = "Remote access (advanced)"
	_allow_hosts_fold.folded = true
	settings_tab.add_child(_allow_hosts_fold)

	_allow_hosts_section = VBoxContainer.new()
	_allow_hosts_section.add_theme_constant_override("separation", 6)
	_allow_hosts_fold.add_child(_allow_hosts_section)

	_allow_hosts_section.add_child(_make_header("Allow remote hosts (CIDR)"))

	var intro := Label.new()
	intro.text = (
		"Comma-separated CIDRs or bare IPs (e.g. 192.168.1.0/24, 10.0.0.5). "
		+ "When non-empty, the server binds off loopback and accepts MCP "
		+ "connections from these ranges (--allow-host)."
	)
	intro.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	intro.add_theme_color_override("font_color", COLOR_MUTED)
	intro.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_allow_hosts_section.add_child(intro)

	## Warning banner — the DNS-rebinding guard is widened to every machine
	## in the named ranges, so make the user name a network they trust
	## instead of offering a blanket "expose everything" toggle (#507).
	var warning := Label.new()
	warning.text = (
		"Warning: every machine in these ranges can drive this Godot editor, "
		+ "and the DNS-rebinding guard's Host allowlist is widened to match. "
		+ "Only name networks you trust. On untrusted or shared networks, "
		+ "prefer an SSH tunnel or Tailscale instead of exposing the port."
	)
	warning.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	warning.add_theme_color_override("font_color", COLOR_AMBER)
	warning.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_allow_hosts_section.add_child(warning)

	_allow_hosts_edit = LineEdit.new()
	_allow_hosts_edit.placeholder_text = "e.g. 192.168.1.0/24, 10.0.0.5 — empty = loopback only"
	_allow_hosts_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_allow_hosts_edit.text_changed.connect(_on_allow_hosts_text_changed)
	_allow_hosts_section.add_child(_allow_hosts_edit)

	_allow_hosts_hint = Label.new()
	_allow_hosts_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_allow_hosts_hint.add_theme_color_override("font_color", Color.RED)
	_allow_hosts_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_allow_hosts_hint.visible = false
	_allow_hosts_section.add_child(_allow_hosts_hint)

	_allow_hosts_apply_btn = Button.new()
	_allow_hosts_apply_btn.text = "Apply and Restart Server"
	_allow_hosts_apply_btn.tooltip_text = (
		"Save the allowlist to Editor Settings and reload the plugin so the "
		+ "server respawns with --allow-host. Clear the field and Apply to "
		+ "return to loopback-only."
	)
	_allow_hosts_apply_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_allow_hosts_apply_btn.pressed.connect(_on_allow_hosts_apply)
	_allow_hosts_section.add_child(_allow_hosts_apply_btn)

	_reset_allow_hosts_from_setting()


func _reset_allow_hosts_from_setting() -> void:
	_allow_hosts_saved = ClientConfigurator.allow_hosts()
	_refresh_allow_hosts_fold_state()
	if _allow_hosts_edit == null:
		return
	_allow_hosts_edit.text = _allow_hosts_saved
	_refresh_allow_hosts_ui_state()


## Auto-expands the "Remote access (advanced)" disclosure whenever a
## non-empty allowlist is configured, so an active off-loopback bind is
## never hidden behind a collapsed header.
func _refresh_allow_hosts_fold_state() -> void:
	if _allow_hosts_fold == null:
		return
	if ClientConfigurator.allow_hosts().is_empty():
		_allow_hosts_fold.fold()
	else:
		_allow_hosts_fold.expand()


func _allow_hosts_is_dirty() -> bool:
	if _allow_hosts_edit == null:
		return false
	return McpAllowHosts.normalize(_allow_hosts_edit.text) != _allow_hosts_saved


func _on_allow_hosts_text_changed(_new_text: String) -> void:
	_refresh_allow_hosts_ui_state()


func _refresh_allow_hosts_ui_state() -> void:
	if _allow_hosts_edit == null or _allow_hosts_apply_btn == null:
		return
	var invalid := McpAllowHosts.invalid_tokens(_allow_hosts_edit.text)
	if invalid.is_empty():
		_allow_hosts_hint.visible = false
	else:
		## Name the accepted syntax in the hint — matches the server's
		## `parse_allow_hosts` (CIDR / bare IP, comma-separated).
		_allow_hosts_hint.text = (
			"Invalid entries (must be a CIDR like 192.168.1.0/24 or a bare IP, comma-separated): %s"
			% ", ".join(invalid)
		)
		_allow_hosts_hint.visible = true
	_allow_hosts_apply_btn.disabled = not _allow_hosts_is_dirty() or not invalid.is_empty()


func _on_allow_hosts_apply() -> void:
	if _allow_hosts_edit == null:
		return
	var normalized := McpAllowHosts.normalize(_allow_hosts_edit.text)
	if not McpAllowHosts.invalid_tokens(normalized).is_empty():
		return
	_allow_hosts_saved = normalized
	_allow_hosts_edit.text = normalized
	_refresh_allow_hosts_ui_state()
	settings_apply_requested.emit({"allow_hosts": normalized}, true)


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
		var status: Client.Status = _client_rows[client_id].get("status", Client.Status.NOT_CONFIGURED)
		if status == Client.Status.CONFIGURED:
			configured += 1
		elif status == Client.Status.CONFIGURED_MISMATCH:
			mismatched_ids.append(client_id)
	var text := "%d / %d configured" % [configured, _client_rows.size()]
	if mismatched_ids.size() > 0:
		text += " (%d stale)" % mismatched_ids.size()
	var refresh_state := _client_refresh_state()
	if ClientRefreshStateScript.should_show_checking_badge(refresh_state):
		text += (
			" (checking...)"
			if refresh_state != ClientRefreshStateScript.RUNNING_TIMED_OUT
			else " (client probe still running)"
		)
	_clients_summary_label.text = text
	if _client_configure_all_btn != null:
		_client_configure_all_btn.disabled = (
			ClientRefreshStateScript.should_disable_client_actions(refresh_state)
			and not _server_blocks_client_health()
		)
	if _client_empty_cta_btn != null:
		_client_empty_cta_btn.visible = configured == 0 and _client_status_refresh_has_completed()
	_refresh_drift_banner(mismatched_ids)
	_update_status()


func _show_manual_command_for(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	var cmd := ClientConfigurator.manual_command(client_id)
	if cmd.is_empty():
		row["manual_panel"].visible = false
		return
	row["manual_text"].text = cmd
	row["manual_panel"].visible = true
	## #680: for rows low in the list the panel materializes below the
	## visible scroll area and the Configure click looks like a no-op.
	## Deferred so the just-shown panel has a settled rect to scroll to.
	_scroll_manual_panel_into_view.call_deferred(row["manual_panel"])


func _scroll_manual_panel_into_view(panel: Control) -> void:
	if panel == null or not panel.is_inside_tree():
		return
	var ancestor := panel.get_parent()
	while ancestor != null and not (ancestor is ScrollContainer):
		ancestor = ancestor.get_parent()
	if ancestor != null:
		(ancestor as ScrollContainer).ensure_control_visible(panel)


func _on_copy_manual_command(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	DisplayServer.clipboard_set(row["manual_text"].text)


func _on_open_config_file(client_id: String) -> void:
	var path := _client_config_path_for_row(client_id)
	if path.is_empty():
		return
	if FileAccess.file_exists(path):
		OS.shell_open(path)
		return
	_reveal_config_folder(path)


func _on_reveal_config_folder(client_id: String) -> void:
	var path := _client_config_path_for_row(client_id)
	if path.is_empty():
		return
	_reveal_config_folder(path)


func _client_config_path_for_row(client_id: String) -> String:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return ""
	return String(row.get("config_path", ""))


func _reveal_config_folder(path: String) -> void:
	var dir := path.get_base_dir()
	if dir.is_empty():
		return
	OS.shell_open(dir)


func _refresh_all_client_statuses() -> void:
	_request_client_status_refresh(true)


func _perform_initial_client_status_refresh() -> void:
	if not is_inside_tree():
		return
	_request_client_status_refresh(false)


func _request_client_status_refresh(force: bool = false) -> bool:
	if _server_blocks_client_health():
		return false
	if _is_self_update_in_progress() or _client_rows.is_empty():
		return false
	var ids: Array[String] = []
	for client_id in _client_rows:
		ids.append(String(client_id))
	client_status_refresh_requested.emit(ids, force)
	return true


func present_client_status_refresh_results(results: Dictionary) -> void:
	if _server_blocks_client_health():
		return
	var busy := _busy_client_actions()
	for client_id in results:
		if busy.has(String(client_id)):
			continue
		var result: Dictionary = results[client_id]
		_apply_row_status(
			String(client_id),
			result.get("status", Client.Status.NOT_CONFIGURED),
			str(result.get("error_msg", "")),
			result.get("installed", false)
		)
	_refresh_clients_summary()


func _server_blocks_client_health() -> bool:
	return ServerStateScript.blocks_client_health(
		int(_lifecycle_snapshot.get("state", ServerStateScript.UNINITIALIZED))
	)


func _server_blocked_client_message() -> String:
	var message := str(_lifecycle_snapshot.get("message", ""))
	return message if not message.is_empty() else "server incompatible"


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
		names.append(ClientConfigurator.client_display_name(id))
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
	status: Client.Status,
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
	var base_name := ClientConfigurator.client_display_name(client_id)
	_refresh_client_config_file_buttons(client_id)
	match status:
		Client.Status.CONFIGURED:
			dot.color = Color.GREEN
			configure_btn.text = "Reconfigure"
			remove_btn.visible = true
			## `error_msg` doubles as a detail slot on the green path: a
			## successful configure passes the sweep note (#877). Transient by
			## design — the next status refresh re-applies CONFIGURED with no
			## detail, so the row settles back to its plain name.
			name_label.text = (
				"%s  (%s)" % [base_name, error_msg] if not error_msg.is_empty() else base_name
			)
		Client.Status.NOT_CONFIGURED:
			dot.color = COLOR_MUTED
			configure_btn.text = "Configure"
			remove_btn.visible = false
			var installed: bool = installed_override if installed_override != null else ClientConfigurator.is_installed(client_id)
			name_label.text = base_name if installed else "%s  (not detected)" % base_name
		Client.Status.CONFIGURED_MISMATCH:
			## Amber matches the dock-level drift banner so a glance at the
			## row + the banner read as the same condition.
			dot.color = COLOR_AMBER
			configure_btn.text = "Reconfigure"
			remove_btn.visible = true
			## Drift is usually a stale URL, but a `{scope}` client can also be
			## registered in a scope the user did not select (#872), and
			## "URL out of date" would be a wrong description of that. Prefer
			## the probe's own words whenever it supplied any.
			name_label.text = (
				"%s  (%s)" % [base_name, error_msg]
				if not error_msg.is_empty()
				else "%s  (URL out of date)" % base_name
			)
		_:
			dot.color = Color.RED
			configure_btn.text = "Retry"
			remove_btn.visible = false
			name_label.text = "%s — %s" % [base_name, error_msg] if not error_msg.is_empty() else base_name


func _refresh_client_config_file_buttons(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	# Re-resolve on every refresh so the Open/Reveal buttons follow the entry
	# when it lands in (or moves to) a higher-precedence merge tier (codex F3).
	# F-3-4: switched from `effective_config_path` to the authoritative facade
	# so multi-project-tier cases resolve to the LATEST tier (matching F2
	# status semantics) instead of failing closed to `path_template`.
	row["config_path"] = ClientConfigurator.effective_authoritative_path(client_id)
	var config_path := String(row["config_path"])
	var has_path := not config_path.is_empty()
	var open_config_btn: Button = row["open_config_btn"]
	var reveal_btn: Button = row["reveal_btn"]
	open_config_btn.visible = has_path
	reveal_btn.visible = has_path
	open_config_btn.disabled = not has_path
	reveal_btn.disabled = not has_path
	if has_path:
		open_config_btn.tooltip_text = "Open config file:\n%s" % config_path
		reveal_btn.tooltip_text = "Reveal in folder:\n%s" % config_path.get_base_dir()
	else:
		open_config_btn.tooltip_text = ""
		reveal_btn.tooltip_text = ""


# --- Update check & self-update ---

## Tolerates a null manager so test fixtures that build the dock without
## `_build_ui()` don't false-positive on the worker-spawn gate.
func _is_self_update_in_progress() -> bool:
	return _update_install_in_flight


func _on_update_pressed() -> void:
	if not _post_update_action.is_empty():
		post_update_action_requested.emit(_post_update_action)
		return
	## The update saves every open scene, swaps the add-on tree and relaunches
	## the editor (docs/self-update.md, step 8). Ask before doing that to a
	## user's session. A dock that is not in a scene tree has no dialog to
	## show and proceeds directly.
	if _update_confirm != null and is_inside_tree():
		_update_confirm.dialog_text = update_confirm_text(_update_candidate_version)
		_update_confirm.popup_centered()
		return
	update_requested.emit()


func _on_update_confirmed() -> void:
	update_requested.emit()


static func update_confirm_text(version: String) -> String:
	var target := "Godot AI v%s" % version if not version.is_empty() else "the new Godot AI"
	return (
		"This will save your project and relaunch the editor to install %s.\n"
		+ "AI clients connected right now must be restarted afterwards.\n\nContinue?"
	) % target


func present_update_check(result: Dictionary) -> void:
	_update_candidate_version = String(result.get("version", ""))
	_update_label.text = String(result.get("label_text", ""))
	_update_banner.visible = true


## Apply only the keys present so the manager can ship partial updates
## (e.g. button-text-only during the download phase) without clobbering
## banner state.
func present_update_state(state: Dictionary) -> void:
	if state.has("post_update_action"):
		_post_update_action = String(state["post_update_action"])
	if state.has("install_in_flight"):
		_update_install_in_flight = bool(state["install_in_flight"])
	if state.has("button_text") and _update_btn != null:
		_update_btn.text = String(state["button_text"])
	if state.has("button_disabled") and _update_btn != null:
		_update_btn.disabled = bool(state["button_disabled"])
	if state.has("label_text") and _update_label != null:
		_update_label.text = String(state["label_text"])
	if state.has("banner_visible") and _update_banner != null:
		_update_banner.visible = bool(state["banner_visible"])
	if String(state.get("outcome", "")) == "success" and _update_label != null:
		## Visual confirmation for successful terminal update states.
		_update_label.add_theme_color_override("font_color", Color.GREEN)
