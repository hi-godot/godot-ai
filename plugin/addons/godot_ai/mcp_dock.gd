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
## A future refactor probably wants extract-by-concern instead — e.g.
## `utils/mcp_async_refresh_state_machine.gd` owning the IDLE → RUNNING →
## RUNNING_TIMED_OUT → DEFERRED_FOR_FILESYSTEM → SHUTTING_DOWN transitions
## and pending-flag triplet, `utils/mcp_client_action_dispatcher.gd` owning
## the per-row Configure/Remove worker pool. The dock would keep UI
## construction and lose the state-machine ownership. See issue #360.

const ServerStateScript := preload("res://addons/godot_ai/utils/mcp_server_state.gd")
const ClientRefreshStateScript := preload("res://addons/godot_ai/utils/mcp_client_refresh_state.gd")
const UpdateManagerScript := preload("res://addons/godot_ai/utils/update_manager.gd")
const UpdateMixedStateScript := preload("res://addons/godot_ai/utils/update_mixed_state.gd")
const Client := preload("res://addons/godot_ai/clients/_base.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const ClientRegistry := preload("res://addons/godot_ai/clients/_registry.gd")
const JsonStrategy := preload("res://addons/godot_ai/clients/_json_strategy.gd")
const TomlStrategy := preload("res://addons/godot_ai/clients/_toml_strategy.gd")
const CliStrategy := preload("res://addons/godot_ai/clients/_cli_strategy.gd")
const ToolCatalog := preload("res://addons/godot_ai/tool_catalog.gd")
const LogViewerScript := preload("res://addons/godot_ai/dock_panels/log_viewer.gd")
const PortPickerPanelScript := preload("res://addons/godot_ai/dock_panels/port_picker_panel.gd")

const DEV_MODE_SETTING := "godot_ai/dev_mode"
const CLIENT_STATUS_REFRESH_COOLDOWN_MSEC := 15 * 1000
const CLIENT_STATUS_REFRESH_TIMEOUT_MSEC := 30 * 1000
static var COLOR_MUTED := Color(0.7, 0.7, 0.7)
static var COLOR_HEADER := Color(0.95, 0.95, 0.95)
## Used for "in-progress" / "stale, action needed" UI: the startup-grace
## status icon, the spawn-failure suggested-port hint, the drift banner,
## and the per-row mismatch dot. One constant so a future palette tweak
## doesn't have to find every literal.
static var COLOR_AMBER := Color(1.0, 0.75, 0.25)

var _connection
var _log_buffer
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
var _client_status_refresh_thread: Thread
## Single source of truth for the refresh-sweep state machine. See
## `ClientRefreshStateScript` for the transition table. Replaces the
## previously scattered booleans (`_in_flight`, `_timed_out`,
## `_deferred_until_filesystem_ready`, `_shutdown_requested`).
var _refresh_state: int = ClientRefreshStateScript.IDLE
## Pending-request flags. Kept separate from `_refresh_state` because
## they're "what should the next refresh look like" — not state of
## any current refresh. A pending request is queued when a refresh
## arrives during RUNNING / RUNNING_TIMED_OUT and consumed by
## `_apply_client_status_refresh_results` once the in-flight worker
## drains. `_pending_force` also captures forced retries deferred via
## DEFERRED_FOR_FILESYSTEM so a pending user click survives the wait.
var _client_status_refresh_pending: bool = false
var _client_status_refresh_pending_force: bool = false
var _client_status_refresh_pending_initial: bool = false
var _last_client_status_refresh_completed_msec: int = 0
var _client_status_refresh_started_msec: int = 0
var _client_status_refresh_generation: int = 0
## Owns the self-update slice: GitHub Releases poll, ZIP download, install
## orchestration, and the install-in-flight gate. Dock keeps banner UI
## only and consults the gate via `_is_self_update_in_progress()`.
var _update_manager
static var _orphaned_client_status_refresh_threads: Array[Thread] = []

## Per-row worker state for Configure / Remove. Issue #239: shelling out
## to a hung CLI on main hangs the editor. We dispatch each click to its
## own thread (one slot per client) and apply the result via call_deferred
## once the subprocess returns or the wall-clock budget in McpCliExec
## kicks in. The buttons stay disabled while the slot is busy so the user
## can't queue a re-click on the same row.
##
## Per-client (not single-slot) so Configure-all can fan out — the
## workers are independent, only the row UI is shared, and McpCliExec
## bounds the wall-clock for each.
##
## No orphan-thread list (unlike the refresh worker): action threads
## never get abandoned mid-flight. McpCliExec's wall-clock budget caps
## the worst case at ~10s, so the `_exit_tree` / `McpUpdateManager`
## install-time drain blocks briefly and finishes — there's no path that
## "gives up" on an action thread the way `_abandon_client_status_refresh_thread`
## does for the refresh worker.
var _client_action_threads: Dictionary = {}
var _client_action_generations: Dictionary = {}

# Dev-mode only
var _dev_section: VBoxContainer
var _server_label: Label
var _reload_btn: Button
var _setup_section: VBoxContainer
var _setup_container: VBoxContainer
## Primary dev-section button — always (re)starts a `--reload` dev server.
## Same-version Python edits get adopted as compatible by the lifecycle, so
## neither the drift nor the crash Restart button surfaces; this is the
## unconditional kick contributors need to pick up source changes without
## a version bump.
var _dev_primary_btn: Button
## Small "✕" affordance next to the primary — stops the dev server without
## spawning a replacement. Disabled when no dev server is running.
var _dev_stop_btn: Button
var _log_viewer: LogViewerScript

var _last_connected := false
var _last_status_text := ""
var _startup_grace_until_msec: int = 0

# Spawn-failure panel — rendered when `get_server_status` reports a
# non-OK `state`. One panel, one body paragraph per state, no cascading
# booleans. See `_crash_body_for_state`.
var _crash_panel: VBoxContainer
var _crash_output: RichTextLabel
var _crash_restart_btn: Button
var _crash_reload_btn: Button
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

# Update banner — visible UI only. Releases polling, ZIP download, and
# the install pipeline live on `_update_manager`.
var _update_banner: VBoxContainer
var _update_label: Label
var _update_btn: Button

# Mixed-state banner — surfaces when `addons/godot_ai/` contains
# `*.update_backup` files left by a self-update whose rollback failed
# (`UpdateReloadRunner.InstallStatus.FAILED_MIXED`). Without this banner
# the user sees "plugin won't start" with no actionable context, re-runs
# the update, and compounds the mismatch (issue #354 / audit-v2 #10).
var _mixed_state_banner: VBoxContainer
var _mixed_state_label: Label
var _mixed_state_files: RichTextLabel
var _mixed_state_rescan_btn: Button


func setup(connection: McpConnection, log_buffer: McpLogBuffer, plugin: EditorPlugin) -> void:
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
	_retry_deferred_client_status_refresh()
	_update_status()
	if _log_viewer != null and _log_viewer.visible:
		_log_viewer.tick()


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
	_refresh_state = ClientRefreshStateScript.SHUTTING_DOWN
	_drain_client_status_refresh_workers()
	_drain_client_action_workers()


## Public drain entry consulted by `McpUpdateManager._install_zip` before
## any disk write. Pairs both worker pools so the manager doesn't reach
## into private dock methods. `_exit_tree` still calls the two underlying
## drains directly because it has additional state-machine work
## (SHUTTING_DOWN sticky-set) that the install-time path must NOT inherit.
func prepare_for_self_update_drain() -> void:
	_drain_client_status_refresh_workers()
	_drain_client_action_workers()


func _drain_client_status_refresh_workers() -> void:
	## Block until any in-flight refresh worker (and any orphaned workers from
	## a prior timeout) finish, then clear refresh state. Same blocking
	## semantics as the `_exit_tree` drain — see #232. Used by `_exit_tree`
	## (dock teardown) and `McpUpdateManager._install_zip` (before extract
	## overwrites plugin scripts on disk).
	_client_status_refresh_generation += 1
	if _client_status_refresh_thread != null:
		_client_status_refresh_thread.wait_to_finish()
		_client_status_refresh_thread = null
	for thread in _orphaned_client_status_refresh_threads:
		if thread != null:
			thread.wait_to_finish()
	_orphaned_client_status_refresh_threads.clear()
	## Don't transition out of SHUTTING_DOWN — the drain is called from
	## `_exit_tree` (sticky shutdown) and from
	## `McpUpdateManager._install_zip`'s post-drain reset, which writes
	## the state explicitly.
	if _refresh_state != ClientRefreshStateScript.SHUTTING_DOWN:
		_refresh_state = ClientRefreshStateScript.IDLE
	_client_status_refresh_pending = false
	_client_status_refresh_pending_force = false
	_client_status_refresh_pending_initial = false


func _drain_client_action_workers() -> void:
	## Same drain semantics as the refresh worker (see comment above): the
	## plugin disable / install-update path reloads our script class, so any
	## live Thread must finish before its slot is GC'd or we hit
	## `~Thread … destroyed without its completion having been realized` →
	## VM corruption. Bounded by `McpCliExec` wall-clock budgets, so the
	## worst case is a ~10s blocking drain, vs. an unbounded SIGSEGV.
	##
	## Generation-bumped per-row so any pending `call_deferred(
	## "_apply_client_action_result")` from a worker that finished after we
	## started draining detects the generation mismatch and short-circuits
	## without touching freed UI state.
	##
	## After draining, restore the row UI for any in-flight rows: bare
	## `_client_action_threads.clear()` would leave the dock stuck showing
	## "Configuring…" / "Removing…" with disabled buttons forever — a
	## user-visible failure mode for the install-update bail-out branch
	## (zip extract failure on the manager clears `_install_in_flight` and
	## the dock stays alive).
	for client_id in _client_action_threads.keys():
		var t: Thread = _client_action_threads[client_id]
		if t != null:
			t.wait_to_finish()
		_client_action_generations[client_id] = int(_client_action_generations.get(client_id, 0)) + 1
		_finalize_action_buttons(String(client_id))
		var row: Dictionary = _client_rows.get(String(client_id), {})
		if not row.is_empty():
			_apply_row_status(
				String(client_id),
				row.get("status", Client.Status.NOT_CONFIGURED),
				""
			)
	_client_action_threads.clear()


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

	_crash_panel.add_child(HSeparator.new())
	add_child(_crash_panel)

	_build_mixed_state_banner()
	_refresh_mixed_state_banner()

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
	release_link.pressed.connect(func(): OS.shell_open(UpdateManagerScript.RELEASES_PAGE))
	update_btn_row.add_child(release_link)

	_update_banner.add_child(update_btn_row)
	_update_banner.add_child(HSeparator.new())

	add_child(_update_banner)

	if _update_manager == null:
		_update_manager = UpdateManagerScript.new()
		_update_manager.setup(_plugin, self)
		_update_manager.update_check_completed.connect(_on_update_check_result)
		_update_manager.install_state_changed.connect(_on_install_state_changed)
		add_child(_update_manager)
	_update_manager.check_for_updates.call_deferred()

	# --- Dev-only connection extras (server label + reload button) ---
	_dev_section = VBoxContainer.new()
	_dev_section.add_theme_constant_override("separation", 6)
	add_child(_dev_section)

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

	for client_id in ClientConfigurator.client_ids():
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
	_log_viewer = LogViewerScript.new()
	_log_viewer.setup(_log_buffer)
	_log_viewer.logging_enabled_changed.connect(_on_log_logging_enabled_changed)
	add_child(_log_viewer)

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
		"status": Client.Status.NOT_CONFIGURED,
		"name_label": name_label,
		"configure_btn": configure_btn,
		"remove_btn": remove_btn,
		"manual_panel": manual_panel,
		"manual_text": manual_text,
	}


# --- Status updates ---

func _update_status() -> void:
	var connected: bool = _connection.is_connected
	## During plugin self-update there's a brief window where this dock
	## script is already the new version (Godot hot-reloads scripts on
	## file change) but `_plugin` is still the old `EditorPlugin` instance
	## (only `set_plugin_enabled(false, true)` re-instantiates that). When
	## the new dock calls a method the old plugin doesn't have, `_process`
	## errors every frame until `McpUpdateManager._reload_after_update`
	## lands. Guard every `_plugin.<new_method>()` call with `has_method`
	## so that window stays silent. See #168.
	var server_status: Dictionary = (
		_plugin.get_server_status()
		if _plugin != null and _plugin.has_method("get_server_status")
		else {}
	)
	var state: int = int(server_status.get("state", ServerStateScript.UNINITIALIZED))
	if ServerStateScript.blocks_client_health(state):
		connected = false

	## One `match`/`elif` chain, one source of truth. Adding a new
	## spawn outcome = one `ServerStateScript` constant + one arm here +
	## one body string in `_crash_body_for_state`.
	var status_text: String
	var status_color: Color
	if _server_restart_in_progress:
		status_text = "Restarting server..."
		status_color = COLOR_AMBER
	elif connected:
		if bool(server_status.get("dev_version_mismatch_allowed", false)):
			var actual := str(server_status.get("actual_version", ""))
			status_text = "Connected (dev server v%s)" % actual if not actual.is_empty() else "Connected (dev server)"
			status_color = COLOR_AMBER
		else:
			status_text = "Connected"
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
		status_text = "Port %d held by another process" % ClientConfigurator.http_port()
		status_color = Color.RED
	elif state == ServerStateScript.NO_COMMAND:
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
	_refresh_server_version_label(server_status)

	var changed: bool = connected != _last_connected or status_text != _last_status_text
	if not changed:
		return
	_last_connected = connected
	_last_status_text = status_text
	_status_icon.color = status_color
	_status_label.text = status_text

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

	var port_picker_visible := (
		state == ServerStateScript.PORT_EXCLUDED
		or state == ServerStateScript.FOREIGN_PORT
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
			if not message.is_empty():
				return message
			return "Port %d is occupied by an incompatible server. Stop it or change both HTTP and WS ports." % port
		ServerStateScript.FOREIGN_PORT:
			return "Another process is already bound to port %d. Pick a free port or stop the other process." % port
		ServerStateScript.CRASHED:
			## Both spawn attempts failed on the uvx tier — almost always
			## means PyPI hasn't propagated this version yet (~10 min after
			## publish). `_start_server` already tried `--refresh` once, so
			## the next realistic move is to wait and reload.
			if ClientConfigurator.get_server_launch_mode() == "uvx":
				var version := ClientConfigurator.get_plugin_version()
				return "The server exited before the WebSocket handshake, even after a `uvx --refresh` retry. If this is a brand-new release, PyPI's index may still be propagating (~10 min). Wait a moment and click Reload Plugin to retry, or check Godot's output log for Python's traceback. Target: godot-ai==%s." % version
			return "The server exited before the WebSocket handshake. Check Godot's output log (bottom panel) for Python's traceback."
		ServerStateScript.NO_COMMAND:
			return "No godot-ai server found. Install `uv` via the Setup panel above, or run `pip install godot-ai`."
		_:
			return ""


## Build the mixed-state banner. Hidden until `_refresh_mixed_state_banner`
## confirms `*.update_backup` files exist in the addons tree. Mirrors the
## issue #354 fix shape: structured, agent-readable diagnostic that survives
## a normal editor restart so the user can act on it instead of re-running
## the update.
func _build_mixed_state_banner() -> void:
	_mixed_state_banner = VBoxContainer.new()
	_mixed_state_banner.add_theme_constant_override("separation", 4)
	_mixed_state_banner.visible = false

	_mixed_state_label = Label.new()
	_mixed_state_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mixed_state_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mixed_state_label.add_theme_color_override("font_color", Color.RED)
	_mixed_state_banner.add_child(_mixed_state_label)

	_mixed_state_files = RichTextLabel.new()
	_mixed_state_files.bbcode_enabled = false
	_mixed_state_files.fit_content = true
	_mixed_state_files.autowrap_mode = TextServer.AUTOWRAP_OFF
	_mixed_state_files.selection_enabled = true
	_mixed_state_files.scroll_active = true
	_mixed_state_files.custom_minimum_size = Vector2(0, 90)
	_mixed_state_files.add_theme_color_override("default_color", COLOR_AMBER)
	_mixed_state_banner.add_child(_mixed_state_files)

	_mixed_state_rescan_btn = Button.new()
	_mixed_state_rescan_btn.text = "Re-scan"
	_mixed_state_rescan_btn.tooltip_text = (
		"Scan addons/godot_ai/ for *.update_backup files again."
		+ " Click after restoring the addon manually to dismiss this banner."
	)
	_mixed_state_rescan_btn.pressed.connect(func(): _refresh_mixed_state_banner(true))
	_mixed_state_banner.add_child(_mixed_state_rescan_btn)

	_mixed_state_banner.add_child(HSeparator.new())
	add_child(_mixed_state_banner)


func _refresh_mixed_state_banner(force: bool = false) -> void:
	## Re-scan button passes `force=true` to bypass the scanner's TTL
	## cache so a manual fix is reflected immediately.
	_apply_mixed_state_banner_diagnostic(UpdateMixedStateScript.diagnose(
		UpdateMixedStateScript.ADDON_DIR, force
	))


## Render seam exposed for testing — the GDScript test suite drives this
## directly with synthetic diagnostics so dock banner contracts can be
## pinned without polluting the real `addons/godot_ai/` tree with backup
## files. Callers from production go through `_refresh_mixed_state_banner`.
func _apply_mixed_state_banner_diagnostic(diag: Dictionary) -> void:
	if _mixed_state_banner == null:
		return
	if diag.is_empty():
		_mixed_state_banner.visible = false
		return
	_mixed_state_banner.visible = true
	## `Dictionary.get(...)` returns Variant; Label.text is typed String.
	## Explicit cast keeps the type contract honest and dodges some Godot
	## 4.x point-release quirks around Variant→typed-property assignment.
	_mixed_state_label.text = String(diag.get("message", ""))
	_mixed_state_files.clear()
	for path in diag.get("backup_files", []):
		_mixed_state_files.add_text(String(path))
		_mixed_state_files.newline()
	if bool(diag.get("truncated", false)):
		_mixed_state_files.add_text(
			"… (list truncated at %d entries)" % UpdateMixedStateScript.MAX_BACKUP_RESULTS
		)
		_mixed_state_files.newline()


## Signal handler for the extracted LogViewer — the panel owns its own
## display visibility, the dock owns dispatcher logging routing.
func _on_log_logging_enabled_changed(enabled: bool) -> void:
	if _connection and _connection.dispatcher:
		_connection.dispatcher.mcp_logging = enabled


## Signal handler for the extracted PortPickerPanel — the panel range-validates
## the spinbox value before emitting, so we just write the EditorSetting and
## reload the plugin here.
func _on_port_apply_requested(new_port: int) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(ClientConfigurator.SETTING_HTTP_PORT, new_port)
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
	var ws_port := ClientConfigurator.ws_port()
	if _plugin != null and _plugin.has_method("get_resolved_ws_port"):
		ws_port = int(_plugin.get_resolved_ws_port())
	_server_label.text = "WS: %d  HTTP: %d" % [ws_port, ClientConfigurator.http_port()]


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
	var dev := _dev_mode_toggle.button_pressed
	_dev_section.visible = dev
	if _log_viewer != null:
		_log_viewer.visible = dev

	# Setup section: visible in dev mode, OR in user mode when uv is missing
	# (so users can install uv from the dock).
	var is_dev := ClientConfigurator.is_dev_checkout()
	var uv_missing := not is_dev and ClientConfigurator.check_uv_version().is_empty()
	_setup_section.visible = dev or uv_missing


# --- Button handlers ---

func _on_reload_plugin() -> void:
	# Toggle plugin off/on to reload all GDScript
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


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
		## Re-fetch only when called outside `_update_status`'s frame
		## (e.g. from `_apply_new_port`, `_on_restart_*`). Inside the
		## per-frame loop, the caller threads its cached snapshot through
		## so we don't allocate a fresh Dictionary every frame.
		server_status = (
			_plugin.get_server_status()
			if _plugin != null and _plugin.has_method("get_server_status")
			else {}
		)
	var server_ver: String = _connection.server_version if _connection != null else ""
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
		var dev_allowed := bool(server_status.get("dev_version_mismatch_allowed", false))
		if dev_allowed:
			text = "godot-ai == %s  (plugin %s, dev)" % [server_ver, expected_ver]
			color = COLOR_AMBER
		else:
			text = "godot-ai == %s  (expected %s)" % [server_ver, expected_ver]
			var is_incompatible: bool = state == ServerStateScript.INCOMPATIBLE
			color = Color.RED if is_incompatible else COLOR_AMBER
			var has_managed_proof: bool = (
				_plugin != null
				and _plugin.has_method("can_restart_managed_server")
				and _plugin.can_restart_managed_server()
			)
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
	if _plugin == null or _server_restart_in_progress:
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
	if _plugin == null:
		return false
	var status: Dictionary = (
		_plugin.get_server_status()
		if _plugin.has_method("get_server_status")
		else {}
	)
	if int(status.get("state", ServerStateScript.UNINITIALIZED)) == ServerStateScript.INCOMPATIBLE:
		if _plugin.has_method("recover_incompatible_server"):
			return bool(_plugin.recover_incompatible_server())
	elif _plugin.has_method("force_restart_server"):
		_plugin.force_restart_server()
		return true
	return false


# --- Setup section ---

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
		_dev_primary_btn.text = "Restart Dev Server"
		_dev_primary_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_dev_primary_btn.pressed.connect(_on_dev_primary_pressed)
		btn_row.add_child(_dev_primary_btn)

		_dev_stop_btn = Button.new()
		_dev_stop_btn.text = "✕"
		_dev_stop_btn.tooltip_text = "Stop the dev server without spawning a replacement."
		_dev_stop_btn.pressed.connect(_on_dev_stop_pressed)
		btn_row.add_child(_dev_stop_btn)

		_setup_container.add_child(btn_row)
		_update_dev_section_buttons()
		return

	# User mode — check for uv
	var uv_version := ClientConfigurator.check_uv_version()
	if not uv_version.is_empty():
		_setup_container.add_child(_make_status_row("uv", uv_version, Color.GREEN))
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
		install_btn.text = "Install uv"
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


## Pure helper for the primary "Restart Dev Server" button. Always enabled
## (clicking with nothing running just spawns fresh); tooltip adapts to
## whether a kill+respawn or fresh spawn is what'll happen.
static func _dev_primary_btn_state(has_managed: bool, dev_running: bool) -> Dictionary:
	var port := ClientConfigurator.http_port()
	if has_managed or dev_running:
		return {
			"text": "Restart Dev Server",
			"tooltip": (
				"Kill the server on port %d and start a fresh --reload dev server. "
				+ "Use this to pick up Python source changes that don't bump the version."
			) % port,
		}
	return {
		"text": "Start Dev Server",
		"tooltip": "Spawn a --reload dev server on port %d. Auto-restarts when you edit Python sources." % port,
	}


## Pure helper for the small "✕" stop button — only enabled when a dev
## server is actually running. Stops without respawning; intentionally
## never targets a managed server (that's the lifecycle's responsibility).
static func _dev_stop_btn_state(dev_running: bool) -> Dictionary:
	if dev_running:
		return {"enabled": true, "tooltip": "Stop the dev server without spawning a replacement."}
	return {"enabled": false, "tooltip": "No --reload dev server to stop."}


func _on_dev_primary_pressed() -> void:
	if _plugin == null or _server_restart_in_progress:
		return
	if not _plugin.has_method("force_restart_or_start_dev_server"):
		return
	_server_restart_in_progress = true
	_update_dev_section_buttons()
	if not is_inside_tree():
		## Test path — no scene tree means no timer; run synchronously
		## so suite assertions see the dispatch without `await`.
		_plugin.force_restart_or_start_dev_server()
		_server_restart_in_progress = false
		return
	call_deferred("_perform_dev_restart_after_feedback")


func _on_dev_stop_pressed() -> void:
	if _plugin == null:
		return
	if _plugin.has_method("stop_dev_server"):
		_plugin.stop_dev_server()
	_update_dev_section_buttons.call_deferred()


func _perform_dev_restart_after_feedback() -> void:
	## Brief paint cycle so the user sees "Restarting..." before the
	## blocking _wait_for_port_free freezes the editor for up to 5s.
	await get_tree().create_timer(0.15).timeout
	## Re-check has_method post-await — a self-update mixed-state window
	## could swap _plugin's script class while we were sleeping, leaving
	## the old reference pointing at a class that no longer carries the
	## new method. Same #168 guard pattern as _update_dev_section_buttons.
	if _plugin != null and _plugin.has_method("force_restart_or_start_dev_server"):
		_plugin.force_restart_or_start_dev_server()
	## start_dev_server's spawn happens via a 0.5s SceneTree timer; give
	## it time to land plus a buffer for the WS reconnect before clearing
	## the busy state. The unconditional clear matches sibling restart
	## buttons — overshoot is fine because subsequent _update_status calls
	## refresh the button against live plugin state.
	await get_tree().create_timer(2.0).timeout
	_server_restart_in_progress = false
	_update_dev_section_buttons()


## Single-scan refresh of every dev-section button state. Both buttons
## key off the same `has_managed_server` / `is_dev_server_running` pair,
## and the latter scrapes lsof/ps — so doing the discovery once and
## applying to both avoids the duplicate subprocess fork on every
## connection-state transition.
func _update_dev_section_buttons() -> void:
	if _plugin == null:
		return
	if not (_plugin.has_method("has_managed_server") and _plugin.has_method("is_dev_server_running")):
		return
	var has_managed: bool = _plugin.has_managed_server()
	var dev_running: bool = _plugin.is_dev_server_running()
	if _dev_primary_btn != null:
		if _server_restart_in_progress:
			_dev_primary_btn.disabled = true
			_dev_primary_btn.text = "Restarting..."
			_dev_primary_btn.tooltip_text = "Killing the current server and respawning..."
		else:
			var primary_state := _dev_primary_btn_state(has_managed, dev_running)
			_dev_primary_btn.disabled = false
			_dev_primary_btn.text = primary_state["text"]
			_dev_primary_btn.tooltip_text = primary_state["tooltip"]
	if _dev_stop_btn != null:
		var stop_state := _dev_stop_btn_state(dev_running)
		_dev_stop_btn.disabled = (not stop_state["enabled"]) or _server_restart_in_progress
		_dev_stop_btn.tooltip_text = stop_state["tooltip"]


func _on_install_uv() -> void:
	match OS.get_name():
		"Windows":
			OS.execute("powershell", ["-ExecutionPolicy", "ByPass", "-c", "irm https://astral.sh/uv/install.ps1 | iex"], [], false)
		_:
			OS.execute("bash", ["-c", "curl -LsSf https://astral.sh/uv/install.sh | sh"], [], false)
	## Drop the cached uvx path AND the cached `uvx --version` so the
	## next `_refresh_setup_status` finds and reads the freshly-installed
	## binary instead of returning the pre-install "not found" result.
	## Routing through the configurator here matters on Windows, where
	## the CLI-finder cache key is `uvx.exe` — invalidating just `"uvx"`
	## would leave the cache stale and the dock would keep showing
	## "uv: not found" for the rest of the session.
	ClientConfigurator.invalidate_uvx_cli_cache()
	ClientConfigurator.invalidate_uv_version_cache()
	_refresh_setup_status.call_deferred()


# --- Client section ---

func _on_configure_client(client_id: String) -> void:
	if _server_blocks_client_health():
		_apply_row_status(client_id, Client.Status.ERROR, _server_blocked_client_message())
		_refresh_clients_summary()
		return
	_dispatch_client_action(client_id, "configure")


func _on_remove_client(client_id: String) -> void:
	_dispatch_client_action(client_id, "remove")


## Spawn a worker thread for Configure / Remove so a hung CLI can't lock
## the editor (issue #239). The action verbs are: "configure" → calls
## `ClientConfigurator.configure`; "remove" → calls
## `ClientConfigurator.remove`. Both routes shell out to the per-client
## CLI via `McpCliExec.run`, which is wall-clock-bounded.
##
## Per-row in-flight rules:
##   - One worker at a time per client (the row's slot).
##   - Both buttons disabled while the slot is busy — prevents a
##     double-click queueing a stale Configure on top of a still-running
##     Remove.
##   - The dot turns amber and the row label gets a "Configuring…" /
##     "Removing…" suffix so the user can see the click was registered.
func _dispatch_client_action(client_id: String, action: String) -> void:
	if _is_self_update_in_progress():
		## Same gate as the refresh worker — the install window overwrites
		## plugin scripts on disk, and a worker mid-call into them would
		## SIGABRT in `GDScriptFunction::call`. See `_update_manager`.
		return
	if _client_action_threads.has(client_id):
		return
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return

	_set_row_action_in_flight(client_id, action)
	## Snapshot `server_url` on main: `http_url()` reads
	## `EditorInterface.get_editor_settings()`, which is main-thread-only.
	## The status-refresh worker uses the same pattern — see
	## `_perform_initial_client_status_refresh` and
	## `_request_client_status_refresh`.
	var server_url := ClientConfigurator.http_url()
	var generation := int(_client_action_generations.get(client_id, 0)) + 1
	_client_action_generations[client_id] = generation
	var thread := Thread.new()
	_client_action_threads[client_id] = thread
	var err := thread.start(
		Callable(self, "_run_client_action_worker").bind(client_id, action, server_url, generation)
	)
	if err != OK:
		_client_action_threads.erase(client_id)
		_finalize_action_buttons(client_id)
		_apply_row_status(client_id, Client.Status.ERROR, "couldn't start worker thread")
		_refresh_clients_summary()


func _run_client_action_worker(client_id: String, action: String, server_url: String, generation: int) -> void:
	var result: Dictionary
	if action == "remove":
		result = ClientConfigurator.remove(client_id, server_url)
	else:
		result = ClientConfigurator.configure(client_id, server_url)
	if _refresh_state != ClientRefreshStateScript.SHUTTING_DOWN:
		call_deferred("_apply_client_action_result", client_id, action, result, generation)


func _apply_client_action_result(client_id: String, action: String, result: Dictionary, generation: int) -> void:
	if int(_client_action_generations.get(client_id, 0)) != generation:
		return
	if _refresh_state == ClientRefreshStateScript.SHUTTING_DOWN:
		return
	if _client_action_threads.has(client_id):
		var t: Thread = _client_action_threads[client_id]
		if t != null:
			t.wait_to_finish()
		_client_action_threads.erase(client_id)
	_finalize_action_buttons(client_id)
	if _server_blocks_client_health():
		_apply_row_status(client_id, Client.Status.ERROR, _server_blocked_client_message())
		_refresh_clients_summary()
		return

	var success_status := Client.Status.NOT_CONFIGURED if action == "remove" else Client.Status.CONFIGURED
	if result.get("status") == "ok":
		_apply_row_status(client_id, success_status)
		var row: Dictionary = _client_rows.get(client_id, {})
		if not row.is_empty():
			(row["manual_panel"] as VBoxContainer).visible = false
	else:
		_apply_row_status(client_id, Client.Status.ERROR, str(result.get("message", "failed")))
		if action == "configure":
			_show_manual_command_for(client_id)
	_refresh_clients_summary()


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
## `_apply_row_status` sets `configure_btn.text` per the resulting
## Status (Configure / Reconfigure / Retry), so we only need to reset
## `remove_btn.text` here — its sibling visibility toggle already
## handles whether to show it at all.
func _finalize_action_buttons(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	(row["configure_btn"] as Button).disabled = false
	var remove_btn: Button = row["remove_btn"]
	remove_btn.disabled = false
	remove_btn.text = "Remove"


func _on_refresh_clients_pressed() -> void:
	_request_client_status_refresh(true)


func _on_configure_all_clients() -> void:
	if _server_blocks_client_health():
		for client_id in _client_rows:
			_apply_row_status(String(client_id), Client.Status.ERROR, _server_blocked_client_message())
		_refresh_clients_summary()
		return
	if ClientRefreshStateScript.has_worker_alive(_refresh_state):
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
	core_count.text = "%d tools" % ToolCatalog.CORE_TOOLS.size()
	core_count.add_theme_color_override("font_color", COLOR_MUTED)
	core_row.add_child(core_count)
	core_row.tooltip_text = ", ".join(ToolCatalog.CORE_TOOLS)
	grid.add_child(core_row)

	grid.add_child(HSeparator.new())

	_tools_domain_checkboxes.clear()
	for entry in ToolCatalog.DOMAINS:
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
	var canonical_excluded := ToolCatalog.canonical(_tools_pending_excluded)
	var es := EditorInterface.get_editor_settings()
	if es != null:
		es.set_setting(ClientConfigurator.SETTING_EXCLUDED_DOMAINS, canonical_excluded)
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
		var status: Client.Status = _client_rows[client_id].get("status", Client.Status.NOT_CONFIGURED)
		if status == Client.Status.CONFIGURED:
			configured += 1
		elif status == Client.Status.CONFIGURED_MISMATCH:
			mismatched_ids.append(client_id)
	var text := "%d / %d configured" % [configured, _client_rows.size()]
	if mismatched_ids.size() > 0:
		text += " (%d stale)" % mismatched_ids.size()
	if ClientRefreshStateScript.should_show_checking_badge(_refresh_state):
		text += (
			" (checking...)"
			if _refresh_state != ClientRefreshStateScript.RUNNING_TIMED_OUT
			else " (client probe still running)"
		)
	_clients_summary_label.text = text
	if _client_configure_all_btn != null:
		_client_configure_all_btn.disabled = ClientRefreshStateScript.has_worker_alive(_refresh_state)
	_refresh_drift_banner(mismatched_ids)


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


func _on_copy_manual_command(client_id: String) -> void:
	var row: Dictionary = _client_rows.get(client_id, {})
	if row.is_empty():
		return
	DisplayServer.clipboard_set(row["manual_text"].text)


func _refresh_all_client_statuses() -> void:
	## Compatibility wrapper for older explicit call sites. Treat this as a manual
	## refresh: it bypasses focus-in cooldown but still runs probes off the editor
	## main thread.
	if _server_blocks_client_health():
		for client_id in _client_rows:
			_apply_row_status(String(client_id), Client.Status.ERROR, _server_blocked_client_message())
		_refresh_clients_summary()
		return
	_request_client_status_refresh(true)


func _is_client_status_refresh_in_cooldown() -> bool:
	if _last_client_status_refresh_completed_msec <= 0:
		return false
	return Time.get_ticks_msec() - _last_client_status_refresh_completed_msec < CLIENT_STATUS_REFRESH_COOLDOWN_MSEC


func _has_client_status_refresh_timed_out() -> bool:
	if not ClientRefreshStateScript.has_worker_alive(_refresh_state):
		return false
	if _client_status_refresh_started_msec <= 0:
		return false
	return Time.get_ticks_msec() - _client_status_refresh_started_msec >= CLIENT_STATUS_REFRESH_TIMEOUT_MSEC


func _check_client_status_refresh_timeout() -> void:
	if not _has_client_status_refresh_timed_out():
		return
	if _refresh_state == ClientRefreshStateScript.RUNNING_TIMED_OUT:
		return
	_refresh_state = ClientRefreshStateScript.RUNNING_TIMED_OUT
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
	if _refresh_state != ClientRefreshStateScript.SHUTTING_DOWN:
		_refresh_state = ClientRefreshStateScript.IDLE
	## Reset the full pending-request triplet, not just the
	## focus-in / cooldown half. A timed-out worker has already
	## warmed bytecode, so any stale `_pending_initial` from an
	## earlier deferred-during-busy startup is no longer load-bearing
	## — leaving it set would cause `_retry_deferred_*` to dispatch
	## `_perform_initial_*` a second time after this abandon
	## (which would then no-op because no fresh worker is needed
	## but still re-warm bytecode and walk the row set redundantly).
	_client_status_refresh_pending = false
	_client_status_refresh_pending_force = false
	_client_status_refresh_pending_initial = false
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


func _perform_initial_client_status_refresh() -> void:
	## Pre-warm strategy bytecode on main, then hand every client probe
	## (JSON / TOML / CLI alike) to the worker.
	##
	## Godot's GDScript hot-reload of overwritten plugin files is lazy: the
	## bytecode swap happens on first dereference, not at `set_plugin_enabled`
	## time. A worker thread spawned from a fresh `_build_ui` walks into
	## `_json_strategy.*` / `_cli_strategy.*` / `client_configurator.*` while
	## bytecode pages are mid-swap → SIGABRT. Dereferencing those scripts on
	## main first forces the swap to complete here; the worker then finds
	## stable bytecode. Filesystem signals don't bracket the swap window
	## (they fire before bytecode replacement), and FOCUS_IN doesn't fire on
	## in-place plugin reload because the editor stays focused — so neither
	## works as a gate. See #233 / #235.
	##
	## Phase 1 (sync, on main): a single explicit `_warm_strategy_bytecode`
	## call invokes a pure-memory helper on each strategy script —
	## `_json_strategy.gd`, `_toml_strategy.gd`, `_cli_strategy.gd`, plus
	## `client_configurator.gd` via `client_ids()` / `get_by_id`. No disk,
	## no `OS.execute`, no JSON parse on main. `client_status_probe_snapshot`
	## per client adds the `installed` flag and (for CLI clients) a cached
	## CLI path to each probe.
	##
	## Phase 2 (worker): every probe — JSON, TOML, CLI — runs through the
	## same `_run_client_status_refresh_worker` pipeline. Disk reads + JSON
	## parses for the ~17 non-CLI clients now happen off the main thread,
	## so the dock paints immediately on cold open instead of stalling
	## behind ~16 sync `FileAccess.open` + `JSON.parse_string` calls.
	##
	## No-op outside the tree — GDScript tests instantiate via `new()`.
	if not is_inside_tree():
		return
	if _client_rows.is_empty():
		return
	if _refresh_state == ClientRefreshStateScript.SHUTTING_DOWN:
		return
	if _is_self_update_in_progress():
		return
	if _is_editor_filesystem_busy():
		_defer_initial_client_status_refresh_until_filesystem_ready()
		return
	if ClientRefreshStateScript.has_worker_alive(_refresh_state):
		return

	if _server_blocks_client_health():
		for client_id in _client_rows:
			_apply_row_status(String(client_id), Client.Status.ERROR, _server_blocked_client_message())
		_refresh_clients_summary()
		return

	_warm_strategy_bytecode()

	var generation := _begin_client_status_refresh_run()
	var server_url := ClientConfigurator.http_url()
	var all_probes: Array[Dictionary] = []

	for client_id in _client_rows:
		var probe := ClientConfigurator.client_status_probe_snapshot(String(client_id))
		if probe.is_empty():
			continue
		all_probes.append(probe)
	_refresh_clients_summary()

	if all_probes.is_empty():
		_finalize_completed_refresh()
		return

	_client_status_refresh_thread = Thread.new()
	var err := _client_status_refresh_thread.start(
		Callable(self, "_run_client_status_refresh_worker").bind(
			all_probes, server_url, generation
		)
	)
	if err != OK:
		_refresh_state = ClientRefreshStateScript.IDLE
		_client_status_refresh_thread = null
		_refresh_clients_summary()


## Force GDScript's lazy bytecode swap to complete for every script the
## worker thread will reach into. Each call is pure-memory — no disk, no
## network, no `OS.execute` — so it only costs the bytecode dereference
## itself. See `_perform_initial_client_status_refresh` for context and
## #233 / #235 for the SIGABRT this exists to prevent.
func _warm_strategy_bytecode() -> void:
	var ids := ClientConfigurator.client_ids()
	if ids.is_empty():
		return
	var any_client := ClientRegistry.get_by_id(String(ids[0]))
	if any_client != null:
		JsonStrategy.verify_entry(any_client, {}, "")
	TomlStrategy.format_body(PackedStringArray(), "")
	CliStrategy.format_args(PackedStringArray(), "", "")


func _begin_client_status_refresh_run() -> int:
	## Marks a refresh as starting and returns the new generation token.
	## Generation is bumped here (not at completion) so that a worker callback
	## arriving after `_abandon_client_status_refresh_thread` or `_exit_tree`
	## fires can be detected as stale via generation mismatch.
	_refresh_state = ClientRefreshStateScript.RUNNING
	_client_status_refresh_pending = false
	_client_status_refresh_pending_force = false
	_client_status_refresh_started_msec = Time.get_ticks_msec()
	_client_status_refresh_generation += 1
	_refresh_clients_summary()
	return _client_status_refresh_generation


func _finalize_completed_refresh() -> void:
	## Stamps cooldown and clears in-flight state. Called at the end of every
	## refresh that successfully applied results — the worker callback path
	## and the no-CLI fast path in `_perform_initial_client_status_refresh`.
	_last_client_status_refresh_completed_msec = Time.get_ticks_msec()
	if _refresh_state != ClientRefreshStateScript.SHUTTING_DOWN:
		_refresh_state = ClientRefreshStateScript.IDLE
	_refresh_clients_summary()


func _request_client_status_refresh(force: bool = false) -> bool:
	## Stale-while-refreshing: do not clear dots, summary, or the drift banner
	## when a refresh is requested. The existing UI remains visible until the
	## background worker's result is applied on the main thread.
	if _server_blocks_client_health():
		for client_id in _client_rows:
			_apply_row_status(String(client_id), Client.Status.ERROR, _server_blocked_client_message())
		_refresh_clients_summary()
		return false
	if _is_self_update_in_progress():
		## Self-update is overwriting plugin scripts on disk; spawning a worker
		## now would crash it inside `GDScriptFunction::call` once the bytecode
		## swap reaches a script the worker is mid-call into. Focus-in /
		## manual button / cooldown timer all funnel through here, so one
		## gate covers every spawn path during the install window. The flag
		## lives on `_update_manager` and dies with the dock instance during
		## `set_plugin_enabled(false)`.
		return false
	if ClientRefreshStateScript.has_worker_alive(_refresh_state):
		if force and _has_client_status_refresh_timed_out():
			_abandon_client_status_refresh_thread()
		else:
			_client_status_refresh_pending = true
			_client_status_refresh_pending_force = _client_status_refresh_pending_force or force
			_refresh_clients_summary()
			return false
	if _refresh_state == ClientRefreshStateScript.SHUTTING_DOWN:
		return false
	if not force and _is_client_status_refresh_in_cooldown():
		return false
	if _client_rows.is_empty():
		return false
	if _is_editor_filesystem_busy():
		if force:
			_defer_client_status_refresh_until_filesystem_ready(force)
		return false

	## Manual refresh (any `force=true` path: button click, popup open,
	## external API caller) implies "may have installed a CLI since the
	## last sweep" — flush CliFinder so freshly-installed binaries get
	## re-detected. Focus-in (`force=false`) stays cached so the cheap
	## case stays cheap. Per-CLI invalidation
	## (`invalidate_uvx_cli_cache`) still pairs with specific events
	## like `_on_install_uv` where the binary name is known.
	if force:
		ClientConfigurator.invalidate_cli_cache()

	## Force the bytecode swap on the same scripts the worker will reach
	## into — same #233/#235 guard `_perform_initial_*` already had.
	## Without this, a manual refresh dispatched before the initial sweep
	## has run (e.g. user clicks Refresh during the deferred-initial
	## window after `_defer_client_status_refresh_until_filesystem_ready`
	## cleared `_pending_initial`) walks into mid-swap bytecode and
	## SIGABRTs.
	_warm_strategy_bytecode()

	var client_probes: Array[Dictionary] = []
	for client_id in _client_rows:
		client_probes.append(ClientConfigurator.client_status_probe_snapshot(String(client_id)))
	var server_url := ClientConfigurator.http_url()

	var generation := _begin_client_status_refresh_run()
	_client_status_refresh_thread = Thread.new()
	var err := _client_status_refresh_thread.start(
		Callable(self, "_run_client_status_refresh_worker").bind(client_probes, server_url, generation)
	)
	if err != OK:
		_refresh_state = ClientRefreshStateScript.IDLE
		_client_status_refresh_thread = null
		_refresh_clients_summary()
		return false
	return true


func _is_editor_filesystem_busy() -> bool:
	var fs := EditorInterface.get_resource_filesystem()
	return fs != null and fs.is_scanning()


func _defer_initial_client_status_refresh_until_filesystem_ready() -> void:
	_refresh_state = ClientRefreshStateScript.DEFERRED_FOR_FILESYSTEM
	_client_status_refresh_pending_initial = true


func _defer_client_status_refresh_until_filesystem_ready(force: bool) -> void:
	## Godot can still be reparsing/reloading plugin scripts while the editor
	## filesystem is busy. Do not spawn a worker into that window: the worker
	## can call plugin GDScript while the main thread is reloading it, which
	## crashes in `GDScriptFunction::call`.
	##
	## A manual refresh request is more recent intent than any earlier
	## deferred-initial sweep, so we clear `_pending_initial` here.
	## `_request_client_status_refresh` warms strategy bytecode itself
	## now (see #233/#235), so the safety net the initial path provided
	## still applies to the replayed manual refresh.
	_refresh_state = ClientRefreshStateScript.DEFERRED_FOR_FILESYSTEM
	_client_status_refresh_pending_force = _client_status_refresh_pending_force or force
	_client_status_refresh_pending_initial = false


func _retry_deferred_client_status_refresh() -> void:
	if _refresh_state != ClientRefreshStateScript.DEFERRED_FOR_FILESYSTEM:
		return
	if _is_self_update_in_progress():
		return
	if _is_editor_filesystem_busy():
		return

	var initial := _client_status_refresh_pending_initial
	var force := _client_status_refresh_pending_force
	_refresh_state = ClientRefreshStateScript.IDLE
	_client_status_refresh_pending_force = false
	_client_status_refresh_pending_initial = false
	if initial:
		_perform_initial_client_status_refresh()
	else:
		_request_client_status_refresh(force)


func _run_client_status_refresh_worker(client_probes: Array[Dictionary], server_url: String, generation: int) -> void:
	var results: Dictionary = {}
	for probe in client_probes:
		var client_id := String(probe.get("id", ""))
		if client_id.is_empty():
			continue
		var details := ClientConfigurator.check_status_details_for_url_with_cli_path(
			client_id,
			server_url,
			String(probe.get("cli_path", ""))
		)
		var installed := bool(probe.get("installed", false))
		results[client_id] = {
			"status": details.get("status", Client.Status.NOT_CONFIGURED),
			"installed": installed,
			"error_msg": details.get("error_msg", ""),
		}
	if _refresh_state != ClientRefreshStateScript.SHUTTING_DOWN:
		call_deferred("_apply_client_status_refresh_results", results, generation)


func _apply_client_status_refresh_results(results: Dictionary, generation: int) -> void:
	if generation != _client_status_refresh_generation or _refresh_state == ClientRefreshStateScript.SHUTTING_DOWN:
		return
	if _client_status_refresh_thread != null:
		_client_status_refresh_thread.wait_to_finish()
		_client_status_refresh_thread = null
	if _server_blocks_client_health():
		for client_id in _client_rows:
			_apply_row_status(String(client_id), Client.Status.ERROR, _server_blocked_client_message())
		_finalize_completed_refresh()
		return

	for client_id in results:
		## Skip rows whose Configure / Remove worker is still running so the
		## status refresh doesn't overwrite the "Configuring…" / "Removing…"
		## badge with a stale dot color. The action's own completion handler
		## will repaint the row when it lands.
		if _client_action_threads.has(String(client_id)):
			continue
		var result: Dictionary = results[client_id]
		_apply_row_status(
			String(client_id),
			result.get("status", Client.Status.NOT_CONFIGURED),
			str(result.get("error_msg", "")),
			result.get("installed", false)
		)
	_finalize_completed_refresh()

	if _client_status_refresh_pending:
		var pending_force := _client_status_refresh_pending_force
		_client_status_refresh_pending = false
		_client_status_refresh_pending_force = false
		_request_client_status_refresh(pending_force)


func _server_blocks_client_health() -> bool:
	if _plugin == null or not _plugin.has_method("get_server_status"):
		return false
	var status: Dictionary = _plugin.get_server_status()
	return ServerStateScript.blocks_client_health(
		int(status.get("state", ServerStateScript.UNINITIALIZED))
	)


func _server_blocked_client_message() -> String:
	if _plugin == null or not _plugin.has_method("get_server_status"):
		return "server incompatible"
	var status: Dictionary = _plugin.get_server_status()
	var message := str(status.get("message", ""))
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
	match status:
		Client.Status.CONFIGURED:
			dot.color = Color.GREEN
			configure_btn.text = "Reconfigure"
			remove_btn.visible = true
			name_label.text = base_name
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
			name_label.text = "%s  (URL out of date)" % base_name
		_:
			dot.color = Color.RED
			configure_btn.text = "Retry"
			remove_btn.visible = false
			name_label.text = "%s — %s" % [base_name, error_msg] if not error_msg.is_empty() else base_name


# --- Update check & self-update ---

## Tolerates a null manager so test fixtures that build the dock without
## `_build_ui()` don't false-positive on the worker-spawn gate.
func _is_self_update_in_progress() -> bool:
	return _update_manager != null and bool(_update_manager.is_install_in_flight())


func _on_update_pressed() -> void:
	if _update_manager != null:
		_update_manager.start_install()


func _on_update_check_result(result: Dictionary) -> void:
	_update_label.text = String(result.get("label_text", ""))
	_update_banner.visible = true


## Apply only the keys present so the manager can ship partial updates
## (e.g. button-text-only during the download phase) without clobbering
## banner state.
func _on_install_state_changed(state: Dictionary) -> void:
	if state.has("button_text") and _update_btn != null:
		_update_btn.text = String(state["button_text"])
	if state.has("button_disabled") and _update_btn != null:
		_update_btn.disabled = bool(state["button_disabled"])
	if state.has("label_text") and _update_label != null:
		_update_label.text = String(state["label_text"])
	if state.has("banner_visible") and _update_banner != null:
		_update_banner.visible = bool(state["banner_visible"])
	if String(state.get("outcome", "")) == "success" and _update_label != null:
		## Visual confirmation for the pre-4.4 "Updated! Restart the editor."
		## terminal state — the only outcome the manager paints green for.
		_update_label.add_theme_color_override("font_color", Color.GREEN)
