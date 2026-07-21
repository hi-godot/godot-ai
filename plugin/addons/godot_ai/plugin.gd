@tool
extends EditorPlugin

const GAME_HELPER_AUTOLOAD_NAME := "_mcp_game_helper"
const GAME_HELPER_AUTOLOAD_PATH := "res://addons/godot_ai/runtime/game_helper.gd"

## Editor-process Logger subclass — captures parse errors, @tool runtime
## errors, and push_error/push_warning so the LLM can read them via
## `logs_read(source="editor")`.
const EditorLogger := preload("res://addons/godot_ai/runtime/editor_logger.gd")

## EditorSettings keys used to remember which server process the plugin
## spawned — survives editor restarts, lets a later editor session adopt
## and manage a server it didn't spawn itself. See #135.
const MANAGED_SERVER_PID_SETTING := "godot_ai/managed_server_pid"
const MANAGED_SERVER_VERSION_SETTING := "godot_ai/managed_server_version"
const MANAGED_SERVER_WS_PORT_SETTING := "godot_ai/managed_server_ws_port"
## Per-launch WS handshake auth token (#690), generated at spawn and handed
## to the server via the GODOT_AI_WS_TOKEN spawn env. Persisted alongside
## the managed-server record so a reloaded plugin instance adopting the
## same server keeps authenticating; cleared with the rest of the record.
const MANAGED_SERVER_WS_TOKEN_SETTING := "godot_ai/managed_server_ws_token"
const UPDATE_RELOAD_RUNNER_SCRIPT := preload("res://addons/godot_ai/update_reload_runner.gd")

## Server lifecycle + port discovery extracted from this file (#297 PR 5).
## State enums + version-check seam extracted in PR 6 (#297). Plugin.gd
## keeps thin shims so the dock and characterization tests see an
## unchanged public surface; spawn-machinery state now lives in the
## lifecycle manager.
const ServerLifecycleManager := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")
const ServerStateScript := preload("res://addons/godot_ai/utils/mcp_server_state.gd")

## Plugin-class scripts used by this file. The script-local preload aliases
## are ordinary dependency shorthand and keep construction sites compact.
## They are not the self-update safety boundary; #398 was stale Script-object
## content from a mixed old/new snapshot, fixed by the runner's single-phase
## write-before-scan model.
const Connection := preload("res://addons/godot_ai/connection.gd")
const Dispatcher := preload("res://addons/godot_ai/dispatcher.gd")
const Telemetry := preload("res://addons/godot_ai/telemetry.gd")
const LogBuffer := preload("res://addons/godot_ai/utils/log_buffer.gd")
const GameLogBuffer := preload("res://addons/godot_ai/utils/game_log_buffer.gd")
const EditorLogBuffer := preload("res://addons/godot_ai/utils/editor_log_buffer.gd")
const SurfacedErrorTracker := preload("res://addons/godot_ai/utils/surfaced_error_tracker.gd")
const Dock := preload("res://addons/godot_ai/mcp_dock.gd")
const DebuggerPlugin := preload("res://addons/godot_ai/debugger/mcp_debugger_plugin.gd")
const ExportPlugin := preload("res://addons/godot_ai/export/mcp_export_plugin.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const WindowsPortReservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")

## Handlers are intentionally NOT preloaded here (#736). The old
## `const X := preload("res://addons/godot_ai/handlers/...")` block pulled
## every handler — and everything handlers preload — into plugin.gd's
## compile closure, so Godot parsed/compiled ~119 addon scripts before the
## first instruction of _enter_tree ran. GDScript has no cross-restart
## compile cache, so that stalled "Initializing plugins" on every editor
## boot and every plugin re-enable. Handlers are now registered by script
## path via McpDispatcher.register_lazy_handler / register_lazy and are
## load()ed at the first dispatch of one of their commands.
##
## Handlers remain preload-style scripts with no `class_name` so they don't
## pollute the project-wide global scope (#253): a user project that happens
## to define its own `InputHandler`, `SceneHandler`, etc. would otherwise
## hard-error on plugin enable.
const HANDLERS_DIR := "res://addons/godot_ai/handlers/"

## The Python server writes its own PID here on startup (passed as
## `--pid-file`) and unlinks on clean exit. Deterministic replacement
## for scraping `netstat -ano` to find the port owner — especially on
## Windows where `OS.kill` on the uvx launcher doesn't take the Python
## child with it, and the scrape was the only path to the real PID.
## See issue for #154-era Windows update friction.
## Re-export of PortResolver.SERVER_PID_FILE so the spawn flags, the
## resolver, and characterization tests share one source of truth.
const SERVER_PID_FILE := PortResolver.SERVER_PID_FILE

## How long we watch the spawned server for early exit. If the process is
## still alive when this expires, we stop watching. Mid-session crashes
## after this point get caught by the WebSocket disconnect flow.
const SERVER_WATCH_MS := 30 * 1000
## Python's import graph (FastMCP + Rich + uvicorn) plus the pid-file write
## take a beat on cold starts, especially on Windows. Hold off on declaring
## a spawn a crash until this window elapses so the watch loop has time to
## observe either the pid-file (dev venv) or the port listening (uvx).
const SPAWN_GRACE_MS := 5 * 1000
const SERVER_STATUS_PATH := "/godot-ai/status"
const SERVER_STATUS_PROBE_TIMEOUT_MS := 800
const STARTUP_TRACE_COUNTER_NAMES := [
	"powershell",
	"netstat",
	"netsh",
	"lsof",
	"http_status_probe",
	"server_command_discovery",
]

## Untyped on purpose — see policy below. Type fences move to handler `_init`
## sites that take typed parameters.
##
## Self-update field and load-surface policy: plugin entry-load fields that
## survive reload stay untyped. Typed fields against plugin-defined classes
## were the #242 / #244 crash class: Godot can reparse a long-lived script
## while its old field storage and the new type shape disagree. Static-var
## initializers are the most dangerous form because they execute at
## script-load; a top-level typed Dictionary/Array storage change can fail
## before `_enter_tree` runs.
##
## The mitigation is two-part:
##   (1) Field declarations are untyped (this block).
##   (2) Construction and static access use local names declared at the top
##       of the file (e.g. `Connection`, `Dispatcher`, `LogBuffer`,
##       `ClientConfigurator`, `WindowsPortReservation`, ...), which keeps
##       this entry script's load surface explicit and reviewable.
##
## Constructors, constants, and static methods on `Mcp*` classes are not the
## self-update safety metric under the single-phase runner. The old syntactic
## lint counted bare `Mcp*.MEMBER` references, but #398 was caused by the
## runner scanning a mixed old/new snapshot and reusing stale Script-object
## content. Bare names and preload aliases can both be parsed against stale
## content under an old two-phase runner; from the fixed runner onward the
## full v(N+1) snapshot is written before the scan. In short: preload aliases
## are not the self-update safety metric.
##
## `tests/unit/test_plugin_self_update_safety.py` locks this wording in.
##
var _connection
var _dispatcher
var _telemetry
var _log_buffer
var _game_log_buffer
var _editor_log_buffer
var _surfaced_error_tracker
var _editor_logger: Logger
var _dock
var _debugger_plugin
var _export_plugin
## Spawn / stop / adopt orchestration plus state machine; allocated in
## `_init` so test fixtures (which never enter the tree) can drive
## `_start_server`. Owns `_server_pid`, `_server_state`, the version-
## check seam, and the adoption-confirmation deadline — see
## `utils/server_lifecycle.gd`.
var _lifecycle
static var _server_started_this_session := false  # guard against re-entrant spawns
static var _resolved_ws_port := ClientConfigurator.DEFAULT_WS_PORT
## True once a startup walk has published a port via `_set_resolved_ws_port`
## this editor session. Gates the `_enter_tree` pre-resolution seed: a fresh
## session seeds `_resolved_ws_port` from the configured EditorSettings
## value, but a plugin reload must keep the prior instance's published
## resolution, which can legitimately differ from the configured value
## (Windows-reservation remap, adopted-server record).
static var _ws_port_resolution_published := false
## Per-launch WS handshake auth token (#690). Static for the same reason as
## _resolved_ws_port: a plugin reload in the same editor session adopts the
## server the previous instance spawned, and must keep its token. Empty
## when this editor never spawned a token-carrying server (dev servers,
## fresh installs) — the handshake then omits the field.
static var _ws_auth_token := ""

## Server-watch timer lives on the plugin because it's a Node — the
## manager is RefCounted and can't host children.
var _server_watch_timer: Timer = null
var _headless_disabled := false
var _startup_trace_enabled := false
var _startup_trace_start_ms := 0
var _startup_trace_last_ms := 0
var _startup_trace_counters: Dictionary = {}
## Startup-path probes can now run on a worker thread (#678); the trace
## counters they bump are shared with the main thread, so serialize.
var _startup_trace_mutex := Mutex.new()
var _startup_trace_netsh_start_count := 0


func _init() -> void:
	_lifecycle = ServerLifecycleManager.new(self)


func _enter_tree() -> void:
	_startup_trace_begin()

	## `_process` is only used by the adoption-confirmation watcher; keep
	## it off until `_watch_for_adoption_confirmation` arms it, so the
	## plugin has zero per-frame cost in the common case.
	set_process(false)

	## #740: register the export plugin BEFORE the headless guard so
	## `godot --headless --export-*` runs strip the game-helper autoload
	## from exported packs too — CI export pipelines are headless. The
	## export plugin is inert outside exports: no server, no sockets.
	_export_plugin = ExportPlugin.new()
	add_export_plugin(_export_plugin)

	if _mcp_disabled_for_headless_launch():
		_headless_disabled = true
		print("MCP | plugin disabled in headless mode")
		return

	## Self-update extracts over the live addon and doesn't prune files that
	## disappeared from the new ZIP. Remove obsolete Logger-loader quarantine
	## files/folders once so upgraders match a fresh install.
	_cleanup_legacy_logger_scripts()

	## Register port overrides before spawn so `http_port()` / `ws_port()`
	## return the user's configured values (if any) when `_start_server`
	## builds the CLI args.
	ClientConfigurator.ensure_settings_registered()
	_startup_trace_phase("settings_registered")

	## With the startup walk's blocking port resolution deferred to a worker
	## (#678), the Connection below dials before `_set_resolved_ws_port`
	## publishes. Seed the pre-resolution port from the configured
	## EditorSettings value (a cheap main-thread read, not a blocking probe)
	## so the first dial honors a `godot_ai/ws_port` override — without this
	## it targeted the compile-time default and the override only took
	## effect on the 1s retry.
	_resolved_ws_port = _startup_ws_port_seed(
		_ws_port_resolution_published,
		_resolved_ws_port,
		ClientConfigurator.ws_port(),
	)

	## #691: pre-warm the env snapshot on the main thread before any worker
	## exists, so worker-thread env reads (dock refresh/action workers, the
	## #678 startup walk's discovery worker) serve from the snapshot and can
	## never race the spawn window's setenv/unsetenv around
	## OS.create_process.
	ClientConfigurator.warm_env_snapshot()

	_log_buffer = LogBuffer.new()
	## Apply the persisted dock "Log" toggle before anything logs through the
	## buffer. Without this the choice only took effect after a manual toggle
	## and reset to noisy on every editor restart (#626).
	_log_buffer.enabled = McpSettings.mcp_logging_enabled()
	## #678: in the real editor, run the startup path's blocking probes and
	## kill-drain waits off the main thread so a contended port can't freeze
	## plugin init/reload. Set here (not _init) so test fixtures — which
	## extend this plugin but never enter the tree — keep the synchronous
	## default and can call-then-assert.
	_lifecycle.defer_blocking_work = true
	_start_server()
	_startup_trace_phase("server_start")

	_game_log_buffer = GameLogBuffer.new()
	_editor_log_buffer = EditorLogBuffer.new()
	_surfaced_error_tracker = SurfacedErrorTracker.new(_editor_log_buffer, _game_log_buffer)
	_attach_editor_logger()
	_dispatcher = Dispatcher.new(_log_buffer, _surfaced_error_tracker)
	_dispatcher.mcp_logging = _log_buffer.enabled
	_startup_trace_phase("core_objects")

	_connection = Connection.new()
	_connection.log_buffer = _log_buffer
	_connection.surfaced_error_tracker = _surfaced_error_tracker
	_connection.ws_port = _resolved_ws_port
	## Restore the token before the first connect: after an editor restart
	## the static is empty but the managed-server record still names the
	## token the running server was spawned with (#690). A fresh spawn later
	## overwrites both via _set_ws_auth_token.
	if _ws_auth_token.is_empty():
		_ws_auth_token = str(_read_managed_server_record().get("ws_token", ""))
	_connection.auth_token = _ws_auth_token
	## Pause-depth restore boundary (#712): the dispatcher rebalances any
	## pause_processing level a crashed handler leaked.
	_dispatcher.pause_target = _connection
	_connection.connect_blocked = _lifecycle.is_connection_blocked()
	_connection.connect_block_reason = _lifecycle.get_status_dict().get("message", "")
	if (
		not _lifecycle.is_connection_blocked()
		and not ServerStateScript.is_terminal_diagnosis(_lifecycle.get_state())
	):
		_arm_server_version_check()

	_telemetry = Telemetry.new(_connection)

	_debugger_plugin = DebuggerPlugin.new(_log_buffer, _game_log_buffer, _editor_log_buffer, _surfaced_error_tracker)
	add_debugger_plugin(_debugger_plugin)
	_connection.debugger_plugin = _debugger_plugin
	_ensure_game_helper_autoload()

	## Lazy handler registration (#736): declare each handler's script path
	## and constructor args, then map every command to (handler_key, method).
	## The dispatcher load()s + constructs a handler at the first dispatch of
	## one of its commands and caches the instance, so this block is the
	## authoritative command list without pulling any handler script into the
	## boot-time compile closure. Constructor args are captured now (they are
	## all plugin-lifetime objects) and released by _dispatcher.clear() in
	## _exit_tree.
	var undo := get_undo_redo()
	_dispatcher.register_lazy_handler("editor", HANDLERS_DIR + "editor_handler.gd", [_log_buffer, _connection, _debugger_plugin, _game_log_buffer, _editor_log_buffer, null, _surfaced_error_tracker])
	_dispatcher.register_lazy_handler("scene", HANDLERS_DIR + "scene_handler.gd", [_connection])
	_dispatcher.register_lazy_handler("node", HANDLERS_DIR + "node_handler.gd", [undo])
	_dispatcher.register_lazy_handler("project", HANDLERS_DIR + "project_handler.gd", [_connection, _debugger_plugin, _editor_log_buffer])
	_dispatcher.register_lazy_handler("client", HANDLERS_DIR + "client_handler.gd", [])
	_dispatcher.register_lazy_handler("script", HANDLERS_DIR + "script_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("resource", HANDLERS_DIR + "resource_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("api", HANDLERS_DIR + "api_handler.gd", [])
	_dispatcher.register_lazy_handler("filesystem", HANDLERS_DIR + "filesystem_handler.gd", [_connection])
	_dispatcher.register_lazy_handler("signal", HANDLERS_DIR + "signal_handler.gd", [undo])
	_dispatcher.register_lazy_handler("autoload", HANDLERS_DIR + "autoload_handler.gd", [])
	_dispatcher.register_lazy_handler("input", HANDLERS_DIR + "input_handler.gd", [])
	_dispatcher.register_lazy_handler("test", HANDLERS_DIR + "test_handler.gd", [undo, _log_buffer, _dispatcher])
	_dispatcher.register_lazy_handler("batch", HANDLERS_DIR + "batch_handler.gd", [_dispatcher, undo])
	_dispatcher.register_lazy_handler("ui", HANDLERS_DIR + "ui_handler.gd", [undo])
	_dispatcher.register_lazy_handler("theme", HANDLERS_DIR + "theme_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("animation", HANDLERS_DIR + "animation_handler.gd", [undo])
	_dispatcher.register_lazy_handler("material", HANDLERS_DIR + "material_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("particle", HANDLERS_DIR + "particle_handler.gd", [undo])
	_dispatcher.register_lazy_handler("camera", HANDLERS_DIR + "camera_handler.gd", [undo])
	_dispatcher.register_lazy_handler("audio", HANDLERS_DIR + "audio_handler.gd", [undo])
	_dispatcher.register_lazy_handler("physics_shape", HANDLERS_DIR + "physics_shape_handler.gd", [undo])
	_dispatcher.register_lazy_handler("environment", HANDLERS_DIR + "environment_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("texture", HANDLERS_DIR + "texture_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("curve", HANDLERS_DIR + "curve_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("control_draw_recipe", HANDLERS_DIR + "control_draw_recipe_handler.gd", [undo])
	_dispatcher.register_lazy_handler("tilemap", HANDLERS_DIR + "tilemap_handler.gd", [undo])
	_dispatcher.register_lazy_handler("tileset", HANDLERS_DIR + "tileset_handler.gd", [])

	_dispatcher.register_lazy("get_editor_state", "editor", &"get_editor_state")
	_dispatcher.register_lazy("get_scene_tree", "scene", &"get_scene_tree")
	_dispatcher.register_lazy("get_open_scenes", "scene", &"get_open_scenes")
	_dispatcher.register_lazy("find_nodes", "scene", &"find_nodes")
	_dispatcher.register_lazy("create_scene", "scene", &"create_scene")
	_dispatcher.register_lazy("open_scene", "scene", &"open_scene")
	_dispatcher.register_lazy("save_scene", "scene", &"save_scene")
	_dispatcher.register_lazy("save_scene_as", "scene", &"save_scene_as")
	_dispatcher.register_lazy("get_selection", "editor", &"get_selection")
	_dispatcher.register_lazy("create_node", "node", &"create_node")
	_dispatcher.register_lazy("delete_node", "node", &"delete_node")
	_dispatcher.register_lazy("reparent_node", "node", &"reparent_node")
	_dispatcher.register_lazy("set_property", "node", &"set_property")
	_dispatcher.register_lazy("rename_node", "node", &"rename_node")
	_dispatcher.register_lazy("duplicate_node", "node", &"duplicate_node")
	_dispatcher.register_lazy("move_node", "node", &"move_node")
	_dispatcher.register_lazy("add_to_group", "node", &"add_to_group")
	_dispatcher.register_lazy("remove_from_group", "node", &"remove_from_group")
	_dispatcher.register_lazy("set_selection", "node", &"set_selection")
	_dispatcher.register_lazy("get_node_properties", "node", &"get_node_properties")
	_dispatcher.register_lazy("get_children", "node", &"get_children")
	_dispatcher.register_lazy("get_groups", "node", &"get_groups")
	_dispatcher.register_lazy("get_logs", "editor", &"get_logs")
	_dispatcher.register_lazy("clear_logs", "editor", &"clear_logs")
	_dispatcher.register_lazy("take_screenshot", "editor", &"take_screenshot")
	_dispatcher.register_lazy("get_performance_monitors", "editor", &"get_performance_monitors")
	_dispatcher.register_lazy("reload_plugin", "editor", &"reload_plugin")
	_dispatcher.register_lazy("quit_editor", "editor", &"quit_editor")
	_dispatcher.register_lazy("game_eval", "editor", &"game_eval")
	_dispatcher.register_lazy("game_command", "editor", &"game_command")
	_dispatcher.register_lazy("get_project_setting", "project", &"get_project_setting")
	_dispatcher.register_lazy("set_project_setting", "project", &"set_project_setting")
	_dispatcher.register_lazy("run_project", "project", &"run_project")
	_dispatcher.register_lazy("stop_project", "project", &"stop_project")
	_dispatcher.register_lazy("search_filesystem", "project", &"search_filesystem")
	_dispatcher.register_lazy("configure_client", "client", &"configure_client")
	_dispatcher.register_lazy("remove_client", "client", &"remove_client")
	_dispatcher.register_lazy("check_client_status", "client", &"check_client_status")
	_dispatcher.register_lazy("create_script", "script", &"create_script")
	_dispatcher.register_lazy("patch_script", "script", &"patch_script")
	_dispatcher.register_lazy("read_script", "script", &"read_script")
	_dispatcher.register_lazy("attach_script", "script", &"attach_script")
	_dispatcher.register_lazy("detach_script", "script", &"detach_script")
	_dispatcher.register_lazy("find_symbols", "script", &"find_symbols")
	_dispatcher.register_lazy("search_resources", "resource", &"search_resources")
	_dispatcher.register_lazy("load_resource", "resource", &"load_resource")
	_dispatcher.register_lazy("assign_resource", "resource", &"assign_resource")
	_dispatcher.register_lazy("create_resource", "resource", &"create_resource")
	_dispatcher.register_lazy("get_resource_info", "resource", &"get_resource_info")
	_dispatcher.register_lazy("get_class_info", "api", &"get_class_info")
	_dispatcher.register_lazy("read_file", "filesystem", &"read_file")
	_dispatcher.register_lazy("write_file", "filesystem", &"write_file")
	_dispatcher.register_lazy("reimport", "filesystem", &"reimport")
	_dispatcher.register_lazy("scan_filesystem", "filesystem", &"scan_filesystem")
	_dispatcher.register_lazy("list_signals", "signal", &"list_signals")
	_dispatcher.register_lazy("connect_signal", "signal", &"connect_signal")
	_dispatcher.register_lazy("disconnect_signal", "signal", &"disconnect_signal")
	_dispatcher.register_lazy("list_autoloads", "autoload", &"list_autoloads")
	_dispatcher.register_lazy("add_autoload", "autoload", &"add_autoload")
	_dispatcher.register_lazy("remove_autoload", "autoload", &"remove_autoload")
	_dispatcher.register_lazy("list_actions", "input", &"list_actions")
	_dispatcher.register_lazy("add_action", "input", &"add_action")
	_dispatcher.register_lazy("ensure_action", "input", &"ensure_action")
	_dispatcher.register_lazy("remove_action", "input", &"remove_action")
	_dispatcher.register_lazy("bind_event", "input", &"bind_event")
	_dispatcher.register_lazy("ensure_binding", "input", &"ensure_binding")
	_dispatcher.register_lazy("run_tests", "test", &"run_tests")
	_dispatcher.register_lazy("get_test_results", "test", &"get_test_results")
	_dispatcher.register_lazy("batch_execute", "batch", &"batch_execute")
	_dispatcher.register_lazy("set_anchor_preset", "ui", &"set_anchor_preset")
	_dispatcher.register_lazy("set_text", "ui", &"set_text")
	_dispatcher.register_lazy("build_layout", "ui", &"build_layout")
	_dispatcher.register_lazy("create_theme", "theme", &"create_theme")
	_dispatcher.register_lazy("theme_set_color", "theme", &"set_color")
	_dispatcher.register_lazy("theme_set_constant", "theme", &"set_constant")
	_dispatcher.register_lazy("theme_set_font_size", "theme", &"set_font_size")
	_dispatcher.register_lazy("theme_set_stylebox_flat", "theme", &"set_stylebox_flat")
	_dispatcher.register_lazy("apply_theme", "theme", &"apply_theme")
	_dispatcher.register_lazy("animation_player_create", "animation", &"create_player")
	_dispatcher.register_lazy("animation_create", "animation", &"create_animation")
	_dispatcher.register_lazy("animation_add_property_track", "animation", &"add_property_track")
	_dispatcher.register_lazy("animation_add_method_track", "animation", &"add_method_track")
	_dispatcher.register_lazy("animation_set_autoplay", "animation", &"set_autoplay")
	_dispatcher.register_lazy("animation_play", "animation", &"play")
	_dispatcher.register_lazy("animation_stop", "animation", &"stop")
	_dispatcher.register_lazy("animation_list", "animation", &"list_animations")
	_dispatcher.register_lazy("animation_get", "animation", &"get_animation")
	_dispatcher.register_lazy("animation_create_simple", "animation", &"create_simple")
	_dispatcher.register_lazy("animation_delete", "animation", &"delete_animation")
	_dispatcher.register_lazy("animation_validate", "animation", &"validate_animation")
	_dispatcher.register_lazy("animation_preset_fade", "animation", &"preset_fade")
	_dispatcher.register_lazy("animation_preset_slide", "animation", &"preset_slide")
	_dispatcher.register_lazy("animation_preset_shake", "animation", &"preset_shake")
	_dispatcher.register_lazy("animation_preset_pulse", "animation", &"preset_pulse")
	_dispatcher.register_lazy("material_create", "material", &"create_material")
	_dispatcher.register_lazy("material_set_param", "material", &"set_param")
	_dispatcher.register_lazy("material_set_shader_param", "material", &"set_shader_param")
	_dispatcher.register_lazy("material_get", "material", &"get_material")
	_dispatcher.register_lazy("material_list", "material", &"list_materials")
	_dispatcher.register_lazy("material_assign", "material", &"assign_material")
	_dispatcher.register_lazy("material_apply_to_node", "material", &"apply_to_node")
	_dispatcher.register_lazy("material_apply_preset", "material", &"apply_preset")
	_dispatcher.register_lazy("particle_create", "particle", &"create_particle")
	_dispatcher.register_lazy("particle_set_main", "particle", &"set_main")
	_dispatcher.register_lazy("particle_set_process", "particle", &"set_process")
	_dispatcher.register_lazy("particle_set_draw_pass", "particle", &"set_draw_pass")
	_dispatcher.register_lazy("particle_restart", "particle", &"restart_particle")
	_dispatcher.register_lazy("particle_get", "particle", &"get_particle")
	_dispatcher.register_lazy("particle_apply_preset", "particle", &"apply_preset")
	_dispatcher.register_lazy("camera_create", "camera", &"create_camera")
	_dispatcher.register_lazy("camera_configure", "camera", &"configure")
	_dispatcher.register_lazy("camera_set_limits_2d", "camera", &"set_limits_2d")
	_dispatcher.register_lazy("camera_set_damping_2d", "camera", &"set_damping_2d")
	_dispatcher.register_lazy("camera_follow_2d", "camera", &"follow_2d")
	_dispatcher.register_lazy("camera_get", "camera", &"get_camera")
	_dispatcher.register_lazy("camera_list", "camera", &"list_cameras")
	_dispatcher.register_lazy("camera_apply_preset", "camera", &"apply_preset")
	_dispatcher.register_lazy("audio_player_create", "audio", &"create_player")
	_dispatcher.register_lazy("audio_player_set_stream", "audio", &"set_stream")
	_dispatcher.register_lazy("audio_player_set_playback", "audio", &"set_playback")
	_dispatcher.register_lazy("audio_play", "audio", &"play")
	_dispatcher.register_lazy("audio_stop", "audio", &"stop")
	_dispatcher.register_lazy("audio_list", "audio", &"list_streams")
	_dispatcher.register_lazy("physics_shape_autofit", "physics_shape", &"autofit")
	_dispatcher.register_lazy("environment_create", "environment", &"create_environment")
	_dispatcher.register_lazy("gradient_texture_create", "texture", &"create_gradient_texture")
	_dispatcher.register_lazy("noise_texture_create", "texture", &"create_noise_texture")
	_dispatcher.register_lazy("curve_set_points", "curve", &"set_points")
	_dispatcher.register_lazy("control_draw_recipe", "control_draw_recipe", &"control_draw_recipe")
	_dispatcher.register_lazy("tilemap_set_cell", "tilemap", &"set_cell")
	_dispatcher.register_lazy("tilemap_set_cells_rect", "tilemap", &"set_cells_rect")
	_dispatcher.register_lazy("tilemap_clear", "tilemap", &"clear_layer")
	_dispatcher.register_lazy("tilemap_get_cells", "tilemap", &"get_used_cells")
	_dispatcher.register_lazy("tileset_get_atlas_tiles", "tileset", &"get_atlas_tiles")
	_dispatcher.register_lazy("tileset_get_atlas_image", "tileset", &"get_atlas_image")

	_connection.dispatcher = _dispatcher
	add_child(_connection)
	_startup_trace_phase("handlers_registered")

	# Dock panel
	_dock = Dock.new()
	_dock.name = "Godot AI"
	_dock.setup(_connection, _log_buffer, self)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	_startup_trace_phase("dock_attached")

	_log_buffer.log("plugin loaded")
	if _telemetry != null:
		_telemetry.record_dock_startup()
		_flush_pending_self_update_telemetry()
		_telemetry.flush_pending_plugin_reload()
	## The startup-trace 'done' line is stamped by _start_server after the
	## (possibly suspended) walk completes — not here (#682 review).


## Public wrapper around the dev-server-toggle telemetry emit. Lets the
## dock (or any other caller) record without reaching into ``_telemetry``
## directly — keeps the plugin's internal field encapsulated. The dev
## server is a Python subprocess unrelated to the plugin's own
## lifecycle, so emission can be synchronous (no EditorSettings persist
## dance like ``plugin_reload`` / ``self_update``).
func record_dev_server_toggle(action: String) -> void:
	if _telemetry == null:
		return
	_telemetry.record_dev_server_toggle(action)


## Drain any self_update event written by `update_reload_runner` during the
## previous disable -> enable window.
func _flush_pending_self_update_telemetry() -> void:
	var key := UPDATE_RELOAD_RUNNER_SCRIPT.PENDING_SELF_UPDATE_TELEMETRY_KEY
	var parsed = Telemetry._drain_editor_setting_dict(key)
	if parsed == null:
		return
	var status := str(parsed.get("status", "unknown"))
	var error := str(parsed.get("error", ""))
	## Positional args: GDScript doesn't support keyword args in calls
	## (unlike Python). from_version + to_version are empty strings here
	## — only ``status`` and ``error`` are known at flush time.
	_telemetry.record_self_update(status, "", "", error)




func _exit_tree() -> void:
	## Registered before the headless guard in _enter_tree, so it must be
	## removed before the headless early-return here too.
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

	if _headless_disabled:
		_server_started_this_session = false
		_headless_disabled = false
		return

	## Outer-to-inner teardown. Dispatcher Callables hold RefCounted handlers
	## alive past the point where Godot reloads their class_name scripts — the
	## first post-reload call into a typed-array-holding handler (e.g.
	## McpGameLogBuffer._storage) then SIGSEGVs against a stale class descriptor.
	## See issue #46.

	# Stop inbound work first so _process can't enqueue new commands or
	# null-deref log_buffer on the next tick mid-teardown.
	if _connection:
		_connection.teardown()

	# Drop the dispatcher's Callables AND its lazily-constructed handler
	# instances (#736: handlers live in the dispatcher's cache now). Handler
	# destructors run here, while their scripts are still loaded.
	if _dispatcher:
		_dispatcher.clear()

	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _connection:
		_connection.queue_free()
		_connection = null
	if _debugger_plugin:
		remove_debugger_plugin(_debugger_plugin)
		_debugger_plugin = null

	## Detach the editor logger BEFORE nulling the buffer. After remove_logger
	## returns, Godot guarantees no further virtual calls — so the logger's
	## next access to `_buffer` (if any in flight) lands on a still-live
	## ref-counted buffer, not a freed one.
	_detach_editor_logger()

	_dispatcher = null
	_log_buffer = null
	_game_log_buffer = null
	_editor_log_buffer = null
	_surfaced_error_tracker = null

	_stop_server()
	## Symmetric with prepare_for_update_reload: the static guard persists
	## across disable/enable within a single editor session, so the re-enabled
	## plugin instance's _start_server would short-circuit and never respawn.
	## Pre-#159 this was masked — the old kill path usually left Python alive
	## and the new instance adopted it on port 8000. Now that _stop_server is
	## deterministic, nothing is left to adopt and the reload hangs.
	_server_started_this_session = false
	print("MCP | plugin unloaded")


## Attach editor_logger.gd as a Godot logger so editor-process script
## errors (parse errors, @tool runtime errors, EditorPlugin errors,
## push_error/push_warning) flow into _editor_log_buffer for
## logs_read(source="editor").
##
## Limitation called out in the issue: parse errors fired *before* the
## plugin's _enter_tree (e.g. during the editor's initial filesystem
## scan, or for scripts that fail on first project open) happen before
## add_logger is called and are not captured. There's no public API to
## drain the editor's already-emitted error history; rescanning the
## file would re-emit them but at the cost of disrupting the user's
## editing state, so we accept the gap.
func _attach_editor_logger() -> void:
	_editor_logger = EditorLogger.new(_editor_log_buffer)
	OS.add_logger(_editor_logger)


## Remove old Logger-quarantine artifacts left by extract-over-live
## self-update. Idempotent: existence-guarded, so it's a no-op on fresh
## installs and symlinked dev checkouts.
func _cleanup_legacy_logger_scripts() -> void:
	var legacy_files := [
		"res://addons/godot_ai/runtime/logger_loader.gd",
		"res://addons/godot_ai/runtime/logger_loader.gd.uid",
		"res://addons/godot_ai/testing/script_error_capture_loader.gd",
		"res://addons/godot_ai/testing/script_error_capture_loader.gd.uid",
	]
	for res_path in legacy_files:
		if FileAccess.file_exists(res_path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(res_path))
	var legacy_dirs := [
		"res://addons/godot_ai/runtime/loggers",
		"res://addons/godot_ai/testing/loggers",
	]
	for res_path in legacy_dirs:
		var absolute := ProjectSettings.globalize_path(res_path)
		if DirAccess.dir_exists_absolute(absolute):
			_remove_dir_recursive_absolute(absolute)


static func _remove_dir_recursive_absolute(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		var child := path.path_join(name)
		if dir.current_is_dir():
			_remove_dir_recursive_absolute(child)
		else:
			DirAccess.remove_absolute(child)
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(path)


func _detach_editor_logger() -> void:
	if _editor_logger != null:
		OS.remove_logger(_editor_logger)
	_editor_logger = null


## Register the game-side autoload on plugin enable. Runs the helper inside
## the game process so the editor-side debugger plugin can request
## framebuffer captures over EngineDebugger messages. Removed on
## _disable_plugin so disabling the plugin leaves project.godot clean.
func _enable_plugin() -> void:
	if _mcp_disabled_for_headless_launch():
		return
	_ensure_game_helper_autoload()


static func _mcp_disabled_for_headless_launch() -> bool:
	return _mcp_disabled_for_headless(
		OS.get_cmdline_args(),
		DisplayServer.get_name(),
		OS.get_environment("GODOT_AI_ALLOW_HEADLESS")
	)


static func _mcp_disabled_for_headless(args: PackedStringArray, display_name: String, allow_value: String) -> bool:
	if McpSettings.truthy(allow_value):
		return false
	return _args_request_headless(args) or display_name.to_lower() == "headless"


static func _args_request_headless(args: PackedStringArray) -> bool:
	for i in range(args.size()):
		var arg := args[i]
		if arg == "--headless":
			return true
		if arg == "--display-driver" and i + 1 < args.size() and args[i + 1] == "headless":
			return true
		if arg.begins_with("--display-driver=") and arg.get_slice("=", 1) == "headless":
			return true
	return false




func _disable_plugin() -> void:
	var key := "autoload/" + GAME_HELPER_AUTOLOAD_NAME
	if not ProjectSettings.has_setting(key):
		return
	ProjectSettings.clear(key)
	ProjectSettings.save()


func _ensure_game_helper_autoload() -> void:
	## Write the autoload directly to ProjectSettings and save immediately.
	## EditorPlugin.add_autoload_singleton only mutates in-memory settings —
	## the on-disk project.godot is only persisted when the editor saves
	## (e.g. on quit). CI spawns the game subprocess before any save fires,
	## so the child process never sees the autoload and the capture times
	## out. Mirror AutoloadHandler's pattern: set_setting + save().
	var key := "autoload/" + GAME_HELPER_AUTOLOAD_NAME
	var value := "*" + GAME_HELPER_AUTOLOAD_PATH  # "*" prefix = singleton
	if ProjectSettings.get_setting(key, "") == value:
		return  ## already registered with the right target
	ProjectSettings.set_setting(key, value)
	ProjectSettings.set_initial_value(key, "")
	ProjectSettings.set_as_basic(key, true)
	var err := ProjectSettings.save()
	if err != OK:
		push_warning("MCP: failed to save project.godot after registering %s autoload (error %d)"
			% [GAME_HELPER_AUTOLOAD_NAME, err])


func _startup_trace_begin() -> void:
	_startup_trace_enabled = ClientConfigurator.startup_trace_enabled()
	if not _startup_trace_enabled:
		return
	_startup_trace_start_ms = Time.get_ticks_msec()
	_startup_trace_last_ms = _startup_trace_start_ms
	_startup_trace_netsh_start_count = WindowsPortReservation.netsh_query_count()
	_startup_trace_counters.clear()
	for counter in STARTUP_TRACE_COUNTER_NAMES:
		_startup_trace_counters[counter] = 0
	print(
		"MCP startup trace | begin platform=%s http_port=%d ws_port=%d"
		% [
			OS.get_name(),
			ClientConfigurator.http_port(),
			ClientConfigurator.ws_port(),
		]
	)


func _startup_trace_count(counter: String, amount: int = 1) -> void:
	if not _startup_trace_enabled:
		return
	_startup_trace_mutex.lock()
	_startup_trace_counters[counter] = int(_startup_trace_counters.get(counter, 0)) + amount
	_startup_trace_mutex.unlock()


func _startup_trace_phase(name: String) -> void:
	if not _startup_trace_enabled:
		return
	var now := Time.get_ticks_msec()
	print(
		"MCP startup trace | phase=%s delta_ms=%d total_ms=%d"
		% [name, now - _startup_trace_last_ms, now - _startup_trace_start_ms]
	)
	_startup_trace_last_ms = now


func _startup_trace_finish(path: String) -> void:
	if not _startup_trace_enabled:
		return
	var now := Time.get_ticks_msec()
	## Same lock as _startup_trace_count — a worker probe may still be
	## bumping counters while this reads/writes the shared dictionary.
	_startup_trace_mutex.lock()
	_startup_trace_counters["netsh"] = (
		WindowsPortReservation.netsh_query_count() - _startup_trace_netsh_start_count
	)
	var counters_snapshot: Dictionary = _startup_trace_counters.duplicate()
	_startup_trace_mutex.unlock()
	print(
		"MCP startup trace | done path=%s total_ms=%d counters=%s"
		% [path, now - _startup_trace_start_ms, str(counters_snapshot)]
	)


func _start_server() -> void:
	## Fire-and-forget: the walk is a coroutine in production (#678). Its
	## completion continuation must NOT live in this method — a reload can
	## free this plugin while the walk is suspended, and resuming a freed
	## Node's coroutine errors out. The manager calls
	## `_finish_startup_trace_after_walk` on walk completion instead,
	## guarded by is_instance_valid.
	_lifecycle.start_server()


## Called by the lifecycle manager when the (possibly suspended) startup
## walk completes — the point where the real startup outcome is known, so
## the trace 'done' line reports the true contended-port path and duration
## instead of a pre-walk placeholder (#682 review).
func _finish_startup_trace_after_walk() -> void:
	var startup_path: String = str(_lifecycle.get_startup_path())
	_startup_trace_finish(startup_path if not startup_path.is_empty() else "loaded")


## Test-fixture shim — characterization tests in test_plugin_lifecycle
## reach for this instance method directly. Delegates to the manager's
## state-owning copy.
func _set_incompatible_server(live: Dictionary, expected_version: String, port: int) -> void:
	_lifecycle._set_incompatible_server(live, expected_version, port)


## Static shim — kept on the plugin class because the characterization
## tests assert against `GodotAiPlugin._incompatible_server_message`.
## Implementation moved to ServerLifecycleManager.
static func _incompatible_server_message(
	live: Dictionary,
	expected_version: String,
	port: int,
	expected_ws_port: int
) -> String:
	return ServerLifecycleManager._incompatible_server_message(
		live, expected_version, port, expected_ws_port
	)


static func _server_version_compatibility(
	actual_version: String, expected_version: String
) -> Dictionary:
	return ServerLifecycleManager._server_version_compatibility(
		actual_version, expected_version
	)


static func _server_status_compatibility(
	actual_version: String,
	expected_version: String,
	actual_ws_port: int,
	expected_ws_port: int,
) -> Dictionary:
	return ServerLifecycleManager._server_status_compatibility(
		actual_version, expected_version, actual_ws_port, expected_ws_port
	)


static func _managed_record_has_version_drift(record_version: String, current_version: String) -> bool:
	return ServerLifecycleManager._managed_record_has_version_drift(record_version, current_version)


static func _probe_live_server_status(port: int, timeout_ms: int = SERVER_STATUS_PROBE_TIMEOUT_MS) -> Dictionary:
	var result := {
		"reachable": false,
		"version": "",
		"name": "",
		"ws_port": 0,
		"status_code": 0,
		"error": "",
	}
	var client := HTTPClient.new()
	var err := client.connect_to_host("127.0.0.1", port)
	if err != OK:
		result["error"] = "connect_%d" % err
		return result
	var deadline := Time.get_ticks_msec() + timeout_ms
	while client.get_status() == HTTPClient.STATUS_RESOLVING or client.get_status() == HTTPClient.STATUS_CONNECTING:
		client.poll()
		if Time.get_ticks_msec() >= deadline:
			result["error"] = "connect_timeout"
			return result
		OS.delay_msec(10)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		result["error"] = "connect_status_%d" % client.get_status()
		return result
	err = client.request(HTTPClient.METHOD_GET, SERVER_STATUS_PATH, ["Accept: application/json"])
	if err != OK:
		result["error"] = "request_%d" % err
		return result
	var body := PackedByteArray()
	while true:
		var status := client.get_status()
		if status == HTTPClient.STATUS_REQUESTING:
			client.poll()
		elif status == HTTPClient.STATUS_BODY:
			client.poll()
			var chunk := client.read_response_body_chunk()
			if chunk.size() > 0:
				body.append_array(chunk)
		elif status == HTTPClient.STATUS_CONNECTED:
			break
		else:
			result["error"] = "response_status_%d" % status
			return result
		if Time.get_ticks_msec() >= deadline:
			result["error"] = "response_timeout"
			return result
		OS.delay_msec(10)
	var response_code := client.get_response_code()
	result["status_code"] = response_code
	if response_code != 200:
		result["error"] = "http_%d" % response_code
		return result
	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary):
		result["error"] = "invalid_json"
		return result
	result["reachable"] = true
	result["name"] = str(parsed.get("name", ""))
	result["version"] = _extract_server_version(parsed)
	result["ws_port"] = int(parsed.get("ws_port", 0))
	## `package_path` was added in v2.4.4 (#416) so the dock's
	## "Incompatible server" banner can name the source of a version
	## skew. Older servers omit it; treat the missing field as "".
	result["package_path"] = str(parsed.get("package_path", ""))
	return result


func _probe_live_server_status_for_port(port: int) -> Dictionary:
	_startup_trace_count("http_status_probe")
	return _probe_live_server_status(port)


static func _extract_server_version(payload: Dictionary) -> String:
	var version := str(payload.get("server_version", ""))
	if version.is_empty():
		version = str(payload.get("version", ""))
	return version


static func _live_status_identifies_godot_ai(live: Dictionary) -> bool:
	return ServerLifecycleManager._live_status_identifies_godot_ai(live)


func _verified_status_version(live: Dictionary) -> String:
	if not ServerLifecycleManager._live_status_identifies_godot_ai(live):
		return ""
	return str(live.get("version", ""))


func _verified_status_ws_port(live: Dictionary) -> int:
	if not ServerLifecycleManager._live_status_identifies_godot_ai(live):
		return 0
	return int(live.get("ws_port", 0))


func _refresh_dock_client_statuses() -> bool:
	if _dock == null:
		return false
	if not _dock.has_method("_refresh_all_client_statuses"):
		return false
	_dock.call("_refresh_all_client_statuses")
	return true


## Test-fixture shim — characterization tests in test_plugin_lifecycle
## still drive the first-writer-wins terminal-diagnosis behaviour through
## this method. Delegates to the manager's `set_terminal_diagnosis`
## (which preserves the same first-writer-wins contract).
func _set_spawn_state(state: int) -> void:
	_lifecycle.set_terminal_diagnosis(state)


## Arm the one-shot connection watcher. Called from `_start_server`'s
## FOREIGN_PORT branch: we flagged the diagnostic preemptively assuming
## the port holder doesn't speak MCP, but if it turns out to be another
## editor's server our WebSocket will open and we need to retract the
## diagnostic.
##
## We intentionally poll `_connection.is_connected` from `_process`
## instead of wiring a new signal on McpConnection. A signal added in the
## same release as a new consumer would be another shape-coupled update:
## old two-phase runners can parse the consumer while the McpConnection
## Script object still reflects v(N). Polling only reads `is_connected`
## (present on every shipped McpConnection), so old-runner upgrade windows
## do not depend on a same-release signal addition.
##
## The watch self-disarms after SPAWN_GRACE_MS so per-frame cost drops
## back to zero if it is ever armed by a legacy adoption path.
func _watch_for_adoption_confirmation() -> void:
	_lifecycle.arm_adoption_watch()
	_update_process_enabled()


func _arm_server_version_check() -> void:
	## `arm_version_check` resolves an empty expected via the plugin
	## version, so we can pass the raw field value through.
	_lifecycle.arm_version_check(_connection, str(_lifecycle._server_expected_version))
	_update_process_enabled()


func _update_process_enabled() -> void:
	if _lifecycle == null:
		set_process(false)
		return
	set_process(
		_lifecycle.get_adoption_watch_deadline_ms() > 0
		or _lifecycle.is_awaiting_server_version()
	)


func _process(_delta: float) -> void:
	## Guard: during script-reload / dual-plugin enable races `_lifecycle`
	## can be null while process is still armed — spam would otherwise flood
	## the Output dock every frame.
	if _lifecycle == null:
		set_process(false)
		return
	var now := Time.get_ticks_msec()
	var version_check = _lifecycle.get_version_check()
	if version_check != null:
		version_check.tick(now)
	_lifecycle.tick_adoption_watch(now)
	_update_process_enabled()


## A WebSocket opening only proves the occupant speaks enough of the editor
## protocol to accept a session. Compatibility is decided by the server
## version in `handshake_ack`, so this only arms that check.
func _on_connection_established() -> void:
	if _lifecycle.get_state() == ServerStateScript.FOREIGN_PORT:
		_arm_server_version_check()


## Test-fixture shim — characterization tests poke the verified path
## directly. Delegates to the version-check seam; the manager resolves
## an empty expected version via `_resolve_expected_version`.
func _on_server_version_verified(version: String) -> void:
	_lifecycle.handle_server_version_verified(
		str(_lifecycle._server_expected_version), version
	)
	_update_process_enabled()


## Test-fixture shim — same shape as `_on_server_version_verified`.
func _on_server_version_unverified() -> void:
	_lifecycle.handle_server_version_unverified(
		str(_lifecycle._server_expected_version)
	)
	_update_process_enabled()


## Start a 1s-tick timer that watches the spawned server for up to
## SERVER_WATCH_MS. If the process dies inside the window we drain the
## captured pipes and mark the server as crashed so the dock can surface
## what went wrong. After the window expires we close the pipes so they
## don't pin file descriptors or fill their kernel buffers. See #146.
func _start_server_watch() -> void:
	_stop_server_watch()
	_server_watch_timer = Timer.new()
	_server_watch_timer.wait_time = 1.0
	_server_watch_timer.one_shot = false
	_server_watch_timer.timeout.connect(_check_server_health)
	add_child(_server_watch_timer)
	_server_watch_timer.start()


func _stop_server_watch() -> void:
	if _server_watch_timer != null:
		_server_watch_timer.stop()
		_server_watch_timer.queue_free()
		_server_watch_timer = null


func _check_server_health() -> void:
	_lifecycle.check_server_health()


## True when the first spawn looks like a stale-uvx-index failure and we
## haven't already retried. Fail signal: launcher process already declared
## dead by the caller, pid-file was never written (Python never got to
## argparse), and we're on the uvx tier (the only tier where `--refresh`
## means anything). Bug #172 — after a fresh PyPI publish, uvx's local
## index metadata keeps saying the new version doesn't exist for ~10 min,
## which cascaded into an infinite reconnect loop pre-#171. Retry-at-spawn
## catches every entry path (Update, Reload Plugin, Reconnect, editor
## restart, crash recovery) — unlike the older Update-only precheck.
func _should_retry_with_refresh() -> bool:
	return _retry_with_refresh_allowed(
		_lifecycle._refresh_retried,
		ClientConfigurator.get_server_launch_mode(),
		_read_pid_file(),
	)


## Pure decision helper — environment-state readers stay in the instance
## method above, the logic lives here so tests can drive the three inputs
## directly without spoofing static caches or pid-files on disk.
static func _retry_with_refresh_allowed(already_retried: bool, launch_mode: String, pid_from_file: int) -> bool:
	return (
		not already_retried
		and launch_mode == "uvx"
		and pid_from_file == 0
	)


func _respawn_with_refresh() -> void:
	_lifecycle.respawn_with_refresh()


## Snapshot of the server-spawn outcome for the dock.
##
## `state` is one of the `McpServerState.*` int constants; the dock owns
## the UI copy per state via its own `_crash_body_for_state`. `exit_ms`
## is only meaningful for `CRASHED`.
func get_server_status() -> Dictionary:
	return _lifecycle.get_status_dict()


func get_resolved_ws_port() -> int:
	return _resolved_ws_port


func _set_resolved_ws_port(port: int) -> void:
	_ws_port_resolution_published = true
	_resolved_ws_port = port
	if _connection != null:
		_connection.ws_port = port


## Pure decision helper — environment-state reads (the published flag, the
## EditorSettings port) stay in `_enter_tree`; the logic lives here so tests
## can drive the three inputs directly without mutating the shared statics.
static func _startup_ws_port_seed(
	resolution_published: bool,
	session_ws_port: int,
	configured_ws_port: int
) -> int:
	return session_ws_port if resolution_published else configured_ws_port


func _resolve_ws_port() -> int:
	return PortResolver.resolve_ws_port(
		ClientConfigurator.ws_port(),
		ClientConfigurator.MAX_PORT,
		_log_buffer,
	)


## Test-compat shim — characterization tests call this static directly.
static func _resolved_ws_port_for_existing_server(
	record_ws_port: int,
	record_version: String,
	current_version: String,
	fresh_resolved: int
) -> int:
	return PortResolver.resolved_ws_port_for_existing_server(
		record_ws_port,
		record_version,
		current_version,
		fresh_resolved,
	)


static func _resolve_ws_port_from_output(
	configured_port: int,
	netsh_output: String,
	span: int = 2048
) -> int:
	return PortResolver.resolve_ws_port_from_output(
		configured_port,
		netsh_output,
		ClientConfigurator.MAX_PORT,
		span,
	)


## Plugin-level shim around the resolver — keeps the startup-trace
## counter wiring and the `_ProofPlugin` override hook on the plugin.
## The scrape takes `_startup_trace_count` directly so the counter names
## track the scraper that actually ran (Windows can fall through netstat
## → PowerShell; the fallback used to hide under the `netstat` count).
func _is_port_in_use(port: int) -> bool:
	if PortResolver.can_bind_local_port(port):
		## POSIX can still have an IPv6 wildcard listener on this port
		## even when an IPv4 loopback bind succeeds. Confirm through
		## lsof so startup and kill-path discovery agree.
		if OS.get_name() != "Windows":
			return PortResolver.is_port_in_use_via_scrape(port, _startup_trace_count)
		return false
	return PortResolver.is_port_in_use_via_scrape(port, _startup_trace_count)


## Pass `_startup_trace_count` so the resolver bumps the right counter
## per scraper that actually ran (Windows can fall through netstat →
## PowerShell — counting both unconditionally would over-report).
func _find_pid_on_port(port: int) -> int:
	return PortResolver.find_pid_on_port(port, _startup_trace_count)


func _find_all_pids_on_port(port: int) -> Array[int]:
	return PortResolver.find_all_pids_on_port(port, _startup_trace_count)


static func _execute_windows_powershell(script: String, output: Array) -> int:
	return PortResolver.execute_windows_powershell(script, output)


static func _windows_listener_pids_from_execute_result(exit_code: int, output: Array) -> Array[int]:
	return PortResolver.windows_listener_pids_from_execute_result(exit_code, output)


static func _windows_listener_execute_result_in_use(exit_code: int, output: Array) -> bool:
	return PortResolver.windows_listener_execute_result_in_use(exit_code, output)


static func _parse_lsof_pids(raw: String) -> Array[int]:
	return PortResolver.parse_lsof_pids(raw)


static func _parse_pid_lines(raw: String) -> Array[int]:
	return PortResolver.parse_pid_lines(raw)


## Find the managed server PID deterministically: prefer the pid-file
## the Python server writes on startup (see runtime_info.py), fall back
## to scraping `netstat -ano` / `lsof` only when the file is missing or
## stale. This is the replacement for raw port-scraping: on Windows the
## uvx launcher PID doesn't cover the Python child, and netstat parsing
## is fragile.
##
## Returns 0 when no server can be identified.
func _find_managed_pid(port: int) -> int:
	var pid := _read_pid_file()
	if pid > 0 and _pid_alive(pid):
		return pid
	return _find_pid_on_port(port)


## `live` is the result of a prior `_probe_live_server_status_for_port`
## call that the caller already has on hand. When non-empty it short-
## circuits the internal probe at the bottom of this helper, so a single
## `_start_server` invocation that probes once at the top can thread the
## same snapshot through compatibility check + recovery without paying
## for a second ~500 ms localhost HTTPClient poll loop. Default `{}`
## preserves the historical behavior for callers outside the spawn flow
## (`can_recover_incompatible_server`, the dock's UI buttons), where a
## fresh probe is the right thing.
## `record_override`: a managed-server record snapshot the caller already
## read. Non-empty skips the internal `_read_managed_server_record()` —
## required when this helper runs on a worker thread (#678), because the
## record lives in EditorSettings, which is main-thread-only. `{}` keeps
## the historical read-it-here behavior for synchronous callers
## (`_read_managed_server_record` never returns a bare `{}`, so the
## sentinel is unambiguous).
func _evaluate_strong_port_occupant_proof(port: int, live: Dictionary = {}, record_override: Dictionary = {}) -> Dictionary:
	var result := {"proof": "", "pids": []}
	var listener_pids := _find_all_pids_on_port(port)
	if listener_pids.is_empty():
		return result

	var record: Dictionary = record_override if not record_override.is_empty() else _read_managed_server_record()
	var record_pid := int(record.get("pid", 0))
	var record_version := str(record.get("version", ""))

	if record_pid > 1 and record_pid != OS.get_process_id():
		## Brand-verify the recorded PID before trusting it as a kill target.
		## A recorded PID can outlive the server it named and be recycled by
		## the kernel for an unrelated process that happens to bind the same
		## port — without the cmdline brand gate (the same one the
		## `pidfile_listener` branch enforces) that process could be killed.
		## See #525.
		if (
			listener_pids.has(record_pid)
			and _pid_alive_for_proof(record_pid)
			and _pid_cmdline_is_godot_ai_for_proof(record_pid)
		):
			return {"proof": "managed_record", "pids": [record_pid]}

	var legacy_targets := _legacy_pidfile_kill_targets(port, listener_pids)
	if not legacy_targets.is_empty():
		return {"proof": "pidfile_listener", "pids": legacy_targets}

	var current_live: Dictionary = live if not live.is_empty() else _probe_live_server_status_for_port(port)
	if (
		_live_status_identifies_godot_ai(current_live)
		and not record_version.is_empty()
		and str(current_live.get("version", "")) == record_version
	):
		## Brand-check every listener before returning it as a kill target
		## (#686): the /godot-ai/status match proves *a* godot-ai server owns
		## the port, but `listener_pids` is a raw scrape that can include an
		## unrelated process sharing the port number (e.g. a ::1-only
		## listener lsof reports alongside our IPv4 one). The other two tiers
		## brand-check every target (#525); this tier feeds the fully
		## automatic start_server drift-kill path, so it must too.
		var branded_listeners: Array[int] = []
		for pid in listener_pids:
			var listener_pid := int(pid)
			if _pid_cmdline_is_godot_ai_for_proof(listener_pid):
				branded_listeners.append(listener_pid)
		if not branded_listeners.is_empty():
			return {"proof": "status_matches_record", "pids": branded_listeners}

	return result


## See `_evaluate_strong_port_occupant_proof` for the `live` and
## `record_override` contracts. Threads both through the strong-proof
## delegate so neither helper probes when the caller already knows the
## port-owner status, and so callers running this on a worker thread
## (#712) can inject the EditorSettings record read on the main thread.
func _evaluate_recovery_port_occupant_proof(
	port: int, live: Dictionary = {}, record_override: Dictionary = {}
) -> Dictionary:
	var proof := _evaluate_strong_port_occupant_proof(port, live, record_override)
	if not str(proof.get("proof", "")).is_empty():
		return proof

	var current_live: Dictionary = live if not live.is_empty() else _probe_live_server_status_for_port(port)
	if _live_status_identifies_godot_ai(current_live):
		return {"proof": "status_name", "pids": _find_all_pids_on_port(port)}

	return {"proof": "", "pids": []}


func _recover_strong_port_occupant(port: int, wait_s: float, pre_kill_live: Dictionary = {}) -> bool:
	## `await` because the manager method is a coroutine in production
	## (#678); with `defer_blocking_work` off it completes synchronously
	## and this await is a pass-through.
	return await _lifecycle.recover_strong_port_occupant(port, wait_s, pre_kill_live)


func _legacy_pidfile_kill_targets(_port: int, listener_pids: Array[int]) -> Array[int]:
	var targets: Array[int] = []
	var pidfile_pid := _read_pid_file_for_proof()
	if pidfile_pid <= 1 or pidfile_pid == OS.get_process_id():
		return targets
	## An alive, branded pid-file PID is sufficient ownership proof. Under
	## `uvicorn --reload` the reloader writes the pid-file but a child worker
	## binds the port, so `listener_pids` never contains the reloader PID.
	## Requiring `listener_pids.has(pidfile_pid)` here used to silently skip
	## the kill path for the entire reload-shaped server family. The branded
	## listener loop below still does the per-PID brand check so we never
	## kill an unrelated process that happens to share the port.
	if not _pid_alive_for_proof(pidfile_pid) or not _pid_cmdline_is_godot_ai_for_proof(pidfile_pid):
		return targets

	for pid in listener_pids:
		if pid <= 1 or pid == OS.get_process_id():
			continue
		## Reuse the brand result already proven above when this listener is
		## the same PID as the pidfile — saves a parent-chain walk and a
		## shell-out (PowerShell on Windows, /proc on Linux, ps on macOS) per
		## startup proof evaluation.
		if pid == pidfile_pid or _pid_cmdline_is_godot_ai_for_proof(pid):
			targets.append(pid)
	## Also kill the reloader/launcher itself when it isn't already a listener.
	## Without this, `--reload` workers would be killed but their parent would
	## immediately respawn a replacement and the port would never free.
	if not targets.has(pidfile_pid):
		targets.append(pidfile_pid)
	return targets


func _read_pid_file_for_proof() -> int:
	return _read_pid_file()


func _pid_alive_for_proof(pid: int) -> bool:
	return _pid_alive(pid)


func _pid_cmdline_is_godot_ai_for_proof(pid: int) -> bool:
	return _pid_cmdline_is_godot_ai(pid)


static func _parse_windows_netstat_pid(stdout: String, port: int) -> int:
	return PortResolver.parse_windows_netstat_pid(stdout, port)


static func _parse_windows_netstat_pids(stdout: String, port: int) -> Array[int]:
	return PortResolver.parse_windows_netstat_pids(stdout, port)


static func _parse_windows_netstat_listening(stdout: String, port: int) -> bool:
	return PortResolver.parse_windows_netstat_listening(stdout, port)


static func _split_on_whitespace(s: String) -> PackedStringArray:
	return PortResolver.split_on_whitespace(s)


static func _read_pid_file() -> int:
	return PortResolver.read_pid_file()


static func _clear_pid_file() -> void:
	PortResolver.clear_pid_file()


func _stop_server() -> void:
	_lifecycle.stop_server()




## Clear the managed-server record and pid-file only if `port` is free.
## Returns true when state was cleared. Extracted from `_stop_server` so
## the "preserve on failed kill" contract is independently testable.
func _finalize_stop_if_port_free(port: int) -> bool:
	if _is_port_in_use(port):
		return false
	_clear_managed_server_record()
	_clear_pid_file()
	return true


## Shared tail of the server CLI: transport, ports, and `--pid-file`. Both
## the initial spawn in `_start_server` and the `--refresh` retry in
## `_respawn_with_refresh` go through here so a new flag added in one place
## can't silently drop out of the other.
static func _build_server_flags(port: int, ws_port: int) -> Array[String]:
	var flags: Array[String] = []
	flags.assign([
		"--transport", "streamable-http",
		"--port", str(port),
		"--ws-port", str(ws_port),
		"--pid-file", ProjectSettings.globalize_path(SERVER_PID_FILE),
	])
	## Append `--exclude-domains` only when the user has actually picked at
	## least one domain to drop. Skipping the empty case keeps spawns
	## compatible with older (pre-1.4.2) servers that don't know the flag —
	## relevant during staggered plugin/server upgrades in user-mode installs.
	var excluded := ClientConfigurator.excluded_domains()
	if not excluded.is_empty():
		flags.append("--exclude-domains")
		flags.append(excluded)
	## LAN opt-in (#507, server core #421): pass `--allow-host` only when the
	## developer-mode Settings tab named at least one CIDR / bare IP. Skipping
	## the empty case keeps the default spawn byte-for-byte identical and
	## compatible with older servers that don't know the flag — same pattern
	## as `--exclude-domains` above.
	var allow_hosts := ClientConfigurator.allow_hosts()
	if not allow_hosts.is_empty():
		flags.append("--allow-host")
		flags.append(allow_hosts)
	return flags


## Returns true only when we can prove `pid`'s command line carries the
## `godot-ai` brand AND a server flag (`--pid-file` / `--transport`). Used by
## automatic kill paths (`_legacy_pidfile_kill_targets`) so a stale pidfile
## whose PID has been recycled by an unrelated listener can't hand us a
## kill target. If the OS lookup fails or returns an empty cmdline we
## conservatively return false — better to surface incompatible-server and
## let the user click Restart than to kill the wrong process.
func _pid_cmdline_is_godot_ai(pid: int) -> bool:
	## Walks up the parent chain so a uvicorn `--reload` worker whose
	## cmdline is just `multiprocessing.spawn` still matches when its
	## parent reloader carries the godot_ai brand. Bound the walk so a
	## hypothetical loop or runaway PPID can't stall the editor.
	var current := pid
	for _i in range(5):
		if current <= 1:
			return false
		var cmd := ""
		if OS.get_name() == "Windows":
			cmd = _windows_pid_commandline(current)
		else:
			cmd = _posix_pid_commandline(current)
		if _commandline_is_godot_ai_server(cmd):
			return true
		current = _pid_parent(current)
	return false


func _pid_parent(pid: int) -> int:
	if pid <= 1:
		return 0
	if OS.get_name() == "Windows":
		var output: Array = []
		var script := (
			"Get-CimInstance Win32_Process -Filter 'ProcessId = %d' | "
			+ "Select-Object -ExpandProperty ParentProcessId"
		) % pid
		_startup_trace_count("powershell")
		if _execute_windows_powershell(script, output) != 0 or output.is_empty():
			return 0
		return int(str(output[0]).strip_edges())
	var output_posix: Array = []
	if OS.execute("ps", ["-o", "ppid=", "-p", str(pid)], output_posix, true) != 0 or output_posix.is_empty():
		return 0
	return int(str(output_posix[0]).strip_edges())


static func _commandline_is_godot_ai_server(cmd: String) -> bool:
	if cmd.is_empty():
		return false
	var lower := cmd.to_lower()
	## The server is invoked with `--pid-file <user>/godot_ai_server.pid`,
	## so the path itself contains "godot_ai". A naive substring brand
	## search would falsely match an unrelated process whose cmdline
	## happens to reference a similarly-named pidfile path. Strip the
	## value (but leave the bare flag for the has_flag check) before
	## brand matching.
	var brand_search := _strip_pidfile_value(lower)
	var has_brand := brand_search.find("godot-ai") >= 0 or brand_search.find("godot_ai") >= 0
	var has_flag := lower.find("--pid-file") >= 0 or lower.find("--transport") >= 0
	return has_brand and has_flag


static func _strip_pidfile_value(cmd: String) -> String:
	var rx := RegEx.new()
	## Match `--pid-file=<token>` and `--pid-file <token>`; keep the bare
	## flag so the flag-presence check still succeeds for a real server.
	if rx.compile("--pid-file(?:=|\\s+)\\S+") != OK:
		return cmd
	return rx.sub(cmd, "--pid-file ", true)


func _windows_pid_commandline(pid: int) -> String:
	var output: Array = []
	var script := (
		"Get-CimInstance Win32_Process -Filter 'ProcessId = %d' | "
		+ "Select-Object -ExpandProperty CommandLine"
	) % pid
	_startup_trace_count("powershell")
	var exit_code := _execute_windows_powershell(script, output)
	if exit_code != 0 or output.is_empty():
		return ""
	return str(output[0])


## POSIX command-line lookup. Linux exposes `/proc/<pid>/cmdline` as
## NUL-separated argv — read it directly so we avoid a `ps` fork on Linux
## and get the full argv rather than the truncated/quoted form some `ps`
## builds emit. Falls back to `ps -ww -p <pid> -o args=` on macOS / *BSD,
## which lack a Linux-style `/proc/<pid>/cmdline`. Returns "" on failure
## so callers conservatively reject the PID rather than killing it blind.
func _posix_pid_commandline(pid: int) -> String:
	var proc_path := "/proc/%d/cmdline" % pid
	if FileAccess.file_exists(proc_path):
		var f := FileAccess.open(proc_path, FileAccess.READ)
		if f != null:
			## procfs pseudo-files report length 0 (the kernel generates
			## content on read). `get_length()` therefore returns 0 and
			## `get_buffer(0)` reads nothing. Read in chunks until EOF
			## instead. Cap at ARG_MAX-class bound so a hypothetically
			## misbehaving file can never stall the editor frame.
			var bytes := PackedByteArray()
			var max_bytes := 1 << 20  # 1 MiB
			while bytes.size() < max_bytes:
				var chunk := f.get_buffer(4096)
				if chunk.is_empty():
					break
				bytes.append_array(chunk)
				if f.eof_reached():
					break
			f.close()
			## /proc cmdline is NUL-separated argv; convert NULs to spaces
			## so the substring fingerprint matches the same way it does on
			## the Windows path. Empty (kernel threads, exited processes)
			## bubbles up as "" via the strip below.
			for i in range(bytes.size()):
				if bytes[i] == 0:
					bytes[i] = 0x20
			return bytes.get_string_from_utf8().strip_edges()
	## `-ww` removes ps's column-width truncation so trailing flags like
	## --pid-file / --transport aren't dropped from the args= field.
	## Both procps (Linux) and BSD ps (macOS / *BSD) accept the
	## double-w form.
	var output: Array = []
	var exit_code := OS.execute("ps", ["-ww", "-p", str(pid), "-o", "args="], output, true)
	if exit_code != 0 or output.is_empty():
		return ""
	return str(output[0]).strip_edges()


## True if the given PID corresponds to a live (non-zombie) process.
## POSIX uses `ps -o stat=` (see inline comment for the zombie rationale);
## Windows uses `tasklist`. Called by `_start_server` to distinguish a live
## managed server that outlived its editor from a stale EditorSettings
## record, and by `_check_server_health` to detect a fast-failing launcher.
static func _pid_alive(pid: int) -> bool:
	return PortResolver.pid_alive(pid)


## Calls `_is_port_in_use` (not `PortResolver.wait_for_port_free`) so
## `_ProofPlugin` overrides keep driving the loop.
func _wait_for_port_free(port: int, timeout_s: float) -> void:
	var deadline := Time.get_ticks_msec() + int(timeout_s * 1000.0)
	while _is_port_in_use(port):
		if Time.get_ticks_msec() >= deadline:
			push_warning("MCP | port %d still in use after %.1fs — proceeding anyway" % [port, timeout_s])
			return
		OS.delay_msec(100)


func _read_managed_server_record() -> Dictionary:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return {"pid": 0, "version": "", "ws_port": 0, "ws_token": ""}
	var pid: int = 0
	if es.has_setting(MANAGED_SERVER_PID_SETTING):
		pid = int(es.get_setting(MANAGED_SERVER_PID_SETTING))
	var version: String = ""
	if es.has_setting(MANAGED_SERVER_VERSION_SETTING):
		version = str(es.get_setting(MANAGED_SERVER_VERSION_SETTING))
	var ws_port: int = 0
	if es.has_setting(MANAGED_SERVER_WS_PORT_SETTING):
		ws_port = int(es.get_setting(MANAGED_SERVER_WS_PORT_SETTING))
	var ws_token: String = ""
	if es.has_setting(MANAGED_SERVER_WS_TOKEN_SETTING):
		ws_token = str(es.get_setting(MANAGED_SERVER_WS_TOKEN_SETTING))
	return {"pid": pid, "version": version, "ws_port": ws_port, "ws_token": ws_token}


func _write_managed_server_record(pid: int, version: String) -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(MANAGED_SERVER_PID_SETTING, pid)
	es.set_setting(MANAGED_SERVER_VERSION_SETTING, version)
	es.set_setting(MANAGED_SERVER_WS_PORT_SETTING, _resolved_ws_port)
	es.set_setting(MANAGED_SERVER_WS_TOKEN_SETTING, _ws_auth_token)


## Keep the in-memory token, the connection's handshake field, and (via the
## next _write_managed_server_record) the persisted record in one place so
## the three can't drift. Empty token = "send no auth_token field".
func _set_ws_auth_token(token: String) -> void:
	_ws_auth_token = token
	if _connection != null:
		_connection.auth_token = token


func _clear_managed_server_record() -> void:
	## Drop the in-memory token together with the persisted one: a cleared
	## record means "no managed server", and a surviving static would make
	## the next handshake send a stale token — the exact present-but-wrong
	## shape a newer spawned server rejects with 4003. (Runs before the
	## es == null early return on purpose: the in-memory scrub must not
	## depend on EditorSettings being available.)
	_set_ws_auth_token("")
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if es.has_setting(MANAGED_SERVER_PID_SETTING):
		es.set_setting(MANAGED_SERVER_PID_SETTING, 0)
	if es.has_setting(MANAGED_SERVER_VERSION_SETTING):
		es.set_setting(MANAGED_SERVER_VERSION_SETTING, "")
	if es.has_setting(MANAGED_SERVER_WS_PORT_SETTING):
		es.set_setting(MANAGED_SERVER_WS_PORT_SETTING, 0)
	if es.has_setting(MANAGED_SERVER_WS_TOKEN_SETTING):
		es.set_setting(MANAGED_SERVER_WS_TOKEN_SETTING, "")


func prepare_for_update_reload() -> void:
	_lifecycle.prepare_for_update_reload()


func _adopt_compatible_server(
	record_version: String,
	current_version: String,
	owner: int,
	record_owns_listener: bool = false
) -> String:
	return _lifecycle.adopt_compatible_server(
		record_version,
		current_version,
		owner,
		record_owns_listener
	)


static func _compatible_adoption_log_message(
	owner_label: String,
	owned_pid: int,
	observed_owner_pid: int,
	live_version: String,
	live_ws_port: int,
	current_version: String
) -> String:
	if owner_label == "managed":
		return "MCP | adopted managed server (PID %d, live v%s, WS %d, plugin v%s)" % [
			owned_pid,
			live_version,
			live_ws_port,
			current_version
		]
	return "MCP | adopted external server owner_pid=%d (live v%s, WS %d, plugin v%s)" % [
		observed_owner_pid,
		live_version,
		live_ws_port,
		current_version
	]


## Hand the self-update over to a tiny runner that is not owned by this
## EditorPlugin. The runner keeps the editor process alive, but disables this
## plugin before extracting/scanning the new scripts so every plugin-owned
## instance tears down on pre-update bytecode and pre-update field storage.
func install_downloaded_update(zip_path: String, temp_dir: String, source_dock: Control) -> void:
	prepare_for_update_reload()

	var detached_dock = null
	if _dock != null and is_instance_valid(_dock):
		detached_dock = _dock
		remove_control_from_docks(_dock)
		_dock = null
	elif source_dock != null and is_instance_valid(source_dock):
		detached_dock = source_dock
		remove_control_from_docks(source_dock)

	var runner = UPDATE_RELOAD_RUNNER_SCRIPT.new()
	var parent: Node = EditorInterface.get_base_control()
	if parent == null:
		parent = get_tree().root
	parent.add_child(runner)
	runner.start(zip_path, temp_dir, detached_dock)


func can_recover_incompatible_server() -> bool:
	return _lifecycle.can_recover_incompatible_server()


func _resume_connection_after_recovery() -> void:
	if _connection == null:
		return
	var state: int = _lifecycle.get_state()
	if (
		_lifecycle.is_connection_blocked()
		or (
			state != ServerStateScript.SPAWNING
			and state != ServerStateScript.READY
		)
	):
		return
	_connection.connect_blocked = false
	_connection.connect_block_reason = ""
	_connection.server_version = ""
	_connection.set_process(true)
	_arm_server_version_check()


func recover_incompatible_server() -> bool:
	## `await` because the manager's recovery is a coroutine in production
	## (#678): `_resume_connection_after_recovery` gates on the post-walk
	## state, so it must not run until the respawn walk has completed. With
	## `defer_blocking_work` off this completes synchronously.
	if not await _lifecycle.recover_incompatible_server():
		return false
	_resume_connection_after_recovery()
	return true


## Kill whichever process is holding `http_port()` right now — by resolving
## the port-owning PID via pid-file / netstat / lsof, independent of whether
## we ever set the manager's `_server_pid` — then clear ownership state
## and respawn via the lifecycle manager. The dock's version-mismatch
## banner wires here when the plugin adopted a foreign server whose
## `server_version` drifts from the current plugin version.
func force_restart_server() -> void:
	_lifecycle.force_restart_server()


## Single entry point for the dock's primary "Restart Dev Server" button.
## The user clicking Restart is explicit consent to take over the HTTP port,
## so this is aggressive: any PID holding the port gets killed (managed,
## branded-dev, or orphan multiprocessing.spawn workers whose parent died
## so brand detection misses them). After the port frees we spawn a fresh
## --reload dev server. Returns true if a kill happened, false if the port
## was already free and we just spawned.
func force_restart_or_start_dev_server() -> bool:
	var port := ClientConfigurator.http_port()
	var killed := false
	if has_managed_server():
		_lifecycle.reset_for_force_restart()
	if _is_port_in_use(port):
		_kill_processes_and_windows_spawn_children(_find_all_pids_on_port(port))
		killed = true
	if killed:
		## OS.kill returns synchronously but uvicorn's listener can take
		## longer to release the port. Without this wait, start_dev_server's
		## fixed 500ms timer races the old shutdown and the new --reload
		## spawn fails to bind.
		_wait_for_port_free(port, 5.0)
	start_dev_server()
	return killed


func start_dev_server() -> void:
	## Start a dev server with --reload that survives plugin reloads.
	## Kills any managed server first, waits for the port to free, then spawns.
	##
	## PYTHONPATH handling: when `res://` sits inside a checkout that owns a
	## `src/godot_ai/` (root repo or a git worktree), prepend that `src/` to
	## PYTHONPATH so `import godot_ai` and uvicorn's `reload_dirs` both pick
	## up *this* tree's source rather than the root repo's editable install.
	## On the root repo the path matches the installed package, so this is a
	## no-op; in a worktree it's what makes `--reload` actually watch the
	## worktree's Python. See #84.
	_stop_server()
	get_tree().create_timer(0.5).timeout.connect(func():
		var server_cmd := ClientConfigurator.get_server_command()
		if server_cmd.is_empty():
			push_warning("MCP | could not find server command for dev server")
			return

		var cmd: String = server_cmd[0]
		_set_resolved_ws_port(_resolve_ws_port())
		var inner_args: Array[String] = []
		inner_args.assign(server_cmd.slice(1))
		inner_args.append_array([
			"--transport", "streamable-http",
			"--port", str(ClientConfigurator.http_port()),
			"--ws-port", str(_resolved_ws_port),
			"--reload",
		])

		var worktree_src := ClientConfigurator.find_worktree_src_dir(ProjectSettings.globalize_path("res://"))
		var prev_pythonpath := OS.get_environment("PYTHONPATH")
		if not worktree_src.is_empty():
			var sep := ";" if OS.get_name() == "Windows" else ":"
			var new_pp := worktree_src if prev_pythonpath.is_empty() else worktree_src + sep + prev_pythonpath
			OS.set_environment("PYTHONPATH", new_pp)

		var injected_telemetry: bool = _lifecycle._inject_telemetry_env()
		var pid := OS.create_process(cmd, inner_args)
		if injected_telemetry:
			OS.unset_environment("GODOT_AI_DISABLE_TELEMETRY")

		## Restore PYTHONPATH immediately — the spawned child has already
		## copied the env, so the editor's own process state returns to
		## baseline. Leaving it set would leak to any later OS.create_process
		## from unrelated paths.
		if not worktree_src.is_empty():
			if prev_pythonpath.is_empty():
				OS.unset_environment("PYTHONPATH")
			else:
				OS.set_environment("PYTHONPATH", prev_pythonpath)

		if pid > 0:
			## Match `server_lifecycle.gd::start_server`'s log wording —
			## "prefix" since we prepended to any pre-existing PYTHONPATH,
			## not replaced it. See #429 review.
			var suffix := " (PYTHONPATH prefix=%s)" % worktree_src if not worktree_src.is_empty() else ""
			print("MCP | started dev server with --reload (PID %d): %s %s%s" % [pid, cmd, " ".join(inner_args), suffix])
		else:
			push_warning("MCP | failed to start dev server")
	)


func stop_dev_server() -> void:
	## Stop any server running on the HTTP port (by port, not PID).
	## Used for dev servers whose PID we don't track across reloads.
	if _lifecycle.get_server_pid() > 0:
		# We have a managed server — use normal stop
		_stop_server()
		return
	## A suspended startup walk holds pre-kill probe results; without this
	## it can resume against the listener we are about to kill and adopt a
	## dead server.
	_lifecycle._invalidate_async_startup()
	var port := ClientConfigurator.http_port()
	var candidates: Array[int] = []
	for pid in _find_all_pids_on_port(port):
		var candidate := int(pid)
		if _pid_cmdline_is_godot_ai(candidate):
			candidates.append(candidate)
	var killed := _kill_processes_and_windows_spawn_children(candidates)
	if not killed.is_empty():
		print("MCP | stopped dev server on port %d" % port)


## `verify_brand`: re-check `pid_alive` + the godot-ai cmdline brand
## immediately before the kill (#686). Pass true when the proof that
## nominated `pids` was evaluated in an earlier scheduling window (e.g.
## `recover_strong_port_occupant`'s proof runs in one `_run_blocking` task
## and the kill in a second, with main-thread frames in between) — a branded
## target that exits in that gap can have its PID recycled to an innocent
## process. Default false preserves the intentionally-unbranded call sites
## (the dock's explicit-consent Restart button, orphan spawn workers whose
## parent died so brand detection misses them).
func _kill_processes_and_windows_spawn_children(pids: Array[int], verify_brand: bool = false) -> Array[int]:
	var unique: Array[int] = []
	for pid in pids:
		if pid <= 0 or unique.has(pid):
			continue
		if verify_brand and not (_pid_alive_for_proof(pid) and _pid_cmdline_is_godot_ai_for_proof(pid)):
			continue
		unique.append(pid)
	if OS.get_name() == "Windows":
		for child_pid in _find_windows_spawn_children(unique):
			if not unique.has(child_pid):
				unique.append(child_pid)
	var killed: Array[int] = []
	for pid in unique:
		if OS.get_name() == "Windows":
			var output: Array = []
			var exit_code := OS.execute("taskkill", ["/PID", str(pid), "/T", "/F"], output, true)
			if exit_code == 0 or not _pid_alive(pid):
				killed.append(pid)
		else:
			## Mirror the Windows branch: only report the PID as killed if
			## the kill succeeded or the process is verifiably gone.
			if OS.kill(pid) == OK or not _pid_alive(pid):
				killed.append(pid)
	return killed


func _find_windows_spawn_children(parent_pids: Array[int]) -> Array[int]:
	if parent_pids.is_empty():
		var empty: Array[int] = []
		return empty
	var found: Array[int] = []
	for parent_pid in parent_pids:
		var output: Array = []
		var script := (
			"Get-CimInstance Win32_Process | "
			+ "Where-Object { $_.CommandLine -like '*spawn_main(parent_pid=%d*' } | "
			+ "ForEach-Object { $_.ProcessId }"
		) % parent_pid
		_startup_trace_count("powershell")
		var exit_code := _execute_windows_powershell(script, output)
		if exit_code != 0 or output.is_empty():
			continue
		for pid in _parse_pid_lines(str(output[0])):
			if not found.has(pid):
				found.append(pid)
	return found


func is_dev_server_running() -> bool:
	## Returns true if a branded dev server is running on the HTTP port
	## that we didn't start as managed.
	if _lifecycle.get_server_pid() > 0:
		return false
	for pid in _find_all_pids_on_port(ClientConfigurator.http_port()):
		if _pid_cmdline_is_godot_ai(int(pid)):
			return true
	return false


func has_managed_server() -> bool:
	## Returns true if the plugin is currently managing a server process it spawned.
	return _lifecycle.has_managed_server()


func can_restart_managed_server() -> bool:
	## Restart is allowed only when we have ownership proof. A live PID
	## means this plugin spawned/adopted a managed server; a non-empty
	## managed record is the cross-session proof used by the drift branch.
	return _lifecycle.can_restart_managed_server()
