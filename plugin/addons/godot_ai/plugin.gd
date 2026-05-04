@tool
extends EditorPlugin

const GAME_HELPER_AUTOLOAD_NAME := "_mcp_game_helper"
const GAME_HELPER_AUTOLOAD_PATH := "res://addons/godot_ai/runtime/game_helper.gd"

## Editor-process Logger subclass — captures parse errors, @tool runtime
## errors, and push_error/push_warning so the LLM can read them via
## `logs_read(source="editor")`. Loaded dynamically because
## `extends Logger` requires Godot 4.5+; gating on ClassDB at registration
## time keeps the plugin loadable on 4.4. See issue #231.
const EDITOR_LOGGER_PATH := "res://addons/godot_ai/runtime/editor_logger.gd"

## EditorSettings keys used to remember which server process the plugin
## spawned — survives editor restarts, lets a later editor session adopt
## and manage a server it didn't spawn itself. See #135.
const MANAGED_SERVER_PID_SETTING := "godot_ai/managed_server_pid"
const MANAGED_SERVER_VERSION_SETTING := "godot_ai/managed_server_version"
const MANAGED_SERVER_WS_PORT_SETTING := "godot_ai/managed_server_ws_port"
const UPDATE_RELOAD_RUNNER_SCRIPT := preload("res://addons/godot_ai/update_reload_runner.gd")

## Preloaded so `_stop_server` / `force_restart_server` can reference the
## sweep without depending on the editor's `class_name` scan running first.
## See utils/uv_cache_cleanup.gd for what this does and why it lives next
## to the server-stop hot path.
const UvCacheCleanup := preload("res://addons/godot_ai/utils/uv_cache_cleanup.gd")

## Server lifecycle + port discovery — extracted to dedicated classes in
## #297 / PR 5. plugin.gd keeps thin shims so the public surface (the
## dock + characterization tests) is unchanged. See server_lifecycle.gd's
## `_host` rationale comment for why the manager talks back to the plugin.
const ServerLifecycleManager := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")

## Plugin-class scripts — preloaded so `plugin.gd`'s parse and instantiation
## sites resolve via the script path, not via the global `class_name`
## registry. See the self-update parse-hazard policy near the field
## declarations below for why every `Mcp*` plugin-class reference in this
## file goes through one of these consts. Naming follows the existing
## `UvCacheCleanup := preload(...)` convention (script-local const aliasing
## a class whose registered `class_name` is `Mcp*`).
const Connection := preload("res://addons/godot_ai/connection.gd")
const Dispatcher := preload("res://addons/godot_ai/dispatcher.gd")
const LogBuffer := preload("res://addons/godot_ai/utils/log_buffer.gd")
const GameLogBuffer := preload("res://addons/godot_ai/utils/game_log_buffer.gd")
const EditorLogBuffer := preload("res://addons/godot_ai/utils/editor_log_buffer.gd")
const Dock := preload("res://addons/godot_ai/mcp_dock.gd")
const DebuggerPlugin := preload("res://addons/godot_ai/debugger/mcp_debugger_plugin.gd")

## Handlers — preloaded as consts instead of registered via `class_name` so
## they don't pollute the project-wide global scope. A user project that
## happens to define its own `InputHandler`, `SceneHandler`, etc. would
## otherwise hard-error on plugin enable.
const EditorHandler := preload("res://addons/godot_ai/handlers/editor_handler.gd")
const SceneHandler := preload("res://addons/godot_ai/handlers/scene_handler.gd")
const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")
const ProjectHandler := preload("res://addons/godot_ai/handlers/project_handler.gd")
const ClientHandler := preload("res://addons/godot_ai/handlers/client_handler.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")
const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const FilesystemHandler := preload("res://addons/godot_ai/handlers/filesystem_handler.gd")
const SignalHandler := preload("res://addons/godot_ai/handlers/signal_handler.gd")
const AutoloadHandler := preload("res://addons/godot_ai/handlers/autoload_handler.gd")
const InputHandler := preload("res://addons/godot_ai/handlers/input_handler.gd")
const TestHandler := preload("res://addons/godot_ai/handlers/test_handler.gd")
const BatchHandler := preload("res://addons/godot_ai/handlers/batch_handler.gd")
const UiHandler := preload("res://addons/godot_ai/handlers/ui_handler.gd")
const ThemeHandler := preload("res://addons/godot_ai/handlers/theme_handler.gd")
const AnimationHandler := preload("res://addons/godot_ai/handlers/animation_handler.gd")
const MaterialHandler := preload("res://addons/godot_ai/handlers/material_handler.gd")
const ParticleHandler := preload("res://addons/godot_ai/handlers/particle_handler.gd")
const CameraHandler := preload("res://addons/godot_ai/handlers/camera_handler.gd")
const AudioHandler := preload("res://addons/godot_ai/handlers/audio_handler.gd")
const PhysicsShapeHandler := preload("res://addons/godot_ai/handlers/physics_shape_handler.gd")
const EnvironmentHandler := preload("res://addons/godot_ai/handlers/environment_handler.gd")
const TextureHandler := preload("res://addons/godot_ai/handlers/texture_handler.gd")
const CurveHandler := preload("res://addons/godot_ai/handlers/curve_handler.gd")
const ControlDrawRecipeHandler := preload("res://addons/godot_ai/handlers/control_draw_recipe_handler.gd")

## The Python server writes its own PID here on startup (passed as
## `--pid-file`) and unlinks on clean exit. Deterministic replacement
## for scraping `netstat -ano` to find the port owner — especially on
## Windows where `OS.kill` on the uvx launcher doesn't take the Python
## child with it, and the scrape was the only path to the real PID.
## See issue for #154-era Windows update friction.
const SERVER_PID_FILE := "user://godot_ai_server.pid"

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
const SERVER_HANDSHAKE_VERSION_TIMEOUT_MS := 5 * 1000
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
## Self-update parse-hazard policy: `plugin.gd` MUST NOT reference any
## plugin-defined `class_name` (`Mcp*`) by name — neither as a type
## annotation (`var x: McpFoo`) nor as a constructor (`McpFoo.new()`).
## Both forms resolve through Godot's global class_name registry at parse
## time. During an in-place self-update, `set_plugin_enabled(false)` re-
## parses `plugin.gd` against the freshly-extracted addon tree before the
## registry has scanned the new files; a reference to a class whose
## inheritance or class_name siblings changed in the new release fails to
## resolve, the plugin enters a degraded state, and the follow-up
## `_exit_tree` cascade crashes (see #242, #244).
##
## The mitigation is two-part:
##   (1) Field declarations are untyped (this block).
##   (2) Constructor sites use script-local `const X := preload("res://...")`
##       aliases declared at the top of the file (e.g. `Connection`,
##       `Dispatcher`, `LogBuffer`, …). `preload(...)` resolves the script
##       by path at script-load, never consulting the global registry, so
##       the parse stays clean across releases regardless of how the
##       referenced class's `extends` chain or sibling class_names change.
##
## `tests/unit/test_plugin_self_update_safety.py` locks both halves in.
##
## `_editor_logger` was already untyped because its script extends Godot
## 4.5+'s Logger class and is loaded via `load()` so the plugin still parses
## on 4.4. Null on Godot < 4.5 or before `_attach_editor_logger` runs;
## "attached" state IS exactly "non-null".
var _connection
var _dispatcher
var _log_buffer
var _game_log_buffer
var _editor_log_buffer
var _editor_logger
var _dock
var _server_pid := -1
var _handlers: Array = []  # prevent GC of RefCounted handlers
var _debugger_plugin
## ServerLifecycleManager instance — owns the spawn / stop / respawn /
## adopt orchestration. Untyped to honor the parse-hazard policy above.
## Allocated in `_init` so `_ProofPlugin extends GodotAiPlugin` test
## fixtures (which never enter the tree) can still drive `_start_server`.
var _lifecycle
static var _server_started_this_session := false  # guard against re-entrant spawns
static var _resolved_ws_port := McpClientConfigurator.DEFAULT_WS_PORT

## Captured state for server-spawn supervision (see _start_server_watch).
## Populated only when WE spawn the process — adopt / foreign-server
## branches leave these at their defaults.
var _server_spawn_ms: int = 0
var _server_exit_ms: int = 0
var _server_watch_timer: Timer = null
## Outcome of the most recent `_start_server` attempt. One of the
## `McpSpawnState.*` string constants; the dock switches on this to
## decide which diagnostic panel to render. Default `OK` covers both
## happy paths (spawned fresh / adopted existing). Failure states are
## set at the exact point of failure and never cleared during the
## plugin session — reload the plugin to retry.
var _spawn_state: String = McpSpawnState.OK
## One-shot guard for the stale-uvx-index recovery (see
## `_should_retry_with_refresh`). Reset at the top of `_start_server` so
## each fresh spawn attempt gets its own refresh budget; set to true the
## moment we respawn with `--refresh` so a second failure falls through
## to CRASHED instead of looping.
var _refresh_retried: bool = false
## Bounded deadline for `_watch_for_adoption_confirmation`. Zero when
## disarmed. See that function's docstring.
var _adoption_watch_deadline_ms: int = 0
var _server_expected_version := ""
var _server_actual_version := ""
var _server_actual_name := ""
var _server_status_message := ""
var _server_dev_version_mismatch_allowed := false
var _can_recover_incompatible := false
var _connection_blocked := false
var _awaiting_server_version := false
var _server_version_deadline_ms: int = 0
var _headless_disabled := false
var _startup_trace_enabled := false
var _startup_trace_start_ms := 0
var _startup_trace_last_ms := 0
var _startup_trace_counters: Dictionary = {}
var _startup_trace_netsh_start_count := 0
var _startup_path := ""


func _init() -> void:
	## RefCounted bag holding the lifecycle methods. Instantiated here so
	## test fixtures that construct GodotAiPlugin without entering the
	## tree (`_ProofPlugin.new()` in test_plugin_lifecycle.gd) still get a
	## live manager when they call `_start_server`. No editor side-effects.
	_lifecycle = ServerLifecycleManager.new(self)


func _enter_tree() -> void:
	_startup_trace_begin()

	## `_process` is only used by the adoption-confirmation watcher; keep
	## it off until `_watch_for_adoption_confirmation` arms it, so the
	## plugin has zero per-frame cost in the common case.
	set_process(false)

	if _mcp_disabled_for_headless_launch():
		_headless_disabled = true
		print("MCP | plugin disabled in headless mode")
		return

	## Register port overrides before spawn so `http_port()` / `ws_port()`
	## return the user's configured values (if any) when `_start_server`
	## builds the CLI args.
	McpClientConfigurator.ensure_settings_registered()
	_startup_trace_phase("settings_registered")

	_log_buffer = LogBuffer.new()
	_start_server()
	_startup_trace_phase("server_start")

	_game_log_buffer = GameLogBuffer.new()
	_editor_log_buffer = EditorLogBuffer.new()
	_attach_editor_logger()
	_dispatcher = Dispatcher.new(_log_buffer)
	_startup_trace_phase("core_objects")

	_connection = Connection.new()
	_connection.log_buffer = _log_buffer
	_connection.ws_port = _resolved_ws_port
	_connection.connect_blocked = _connection_blocked
	_connection.connect_block_reason = _server_status_message
	if not _connection_blocked and _spawn_state == McpSpawnState.OK:
		_arm_server_version_check()

	_debugger_plugin = DebuggerPlugin.new(_log_buffer, _game_log_buffer)
	add_debugger_plugin(_debugger_plugin)
	_ensure_game_helper_autoload()

	var editor_handler := EditorHandler.new(_log_buffer, _connection, _debugger_plugin, _game_log_buffer, _editor_log_buffer)
	var scene_handler := SceneHandler.new(_connection)
	var node_handler := NodeHandler.new(get_undo_redo())
	var project_handler := ProjectHandler.new(_connection)
	var client_handler := ClientHandler.new()
	var script_handler := ScriptHandler.new(get_undo_redo(), _connection)
	var resource_handler := ResourceHandler.new(get_undo_redo(), _connection)
	var filesystem_handler := FilesystemHandler.new()
	var signal_handler := SignalHandler.new(get_undo_redo())
	var autoload_handler := AutoloadHandler.new()
	var input_handler := InputHandler.new()
	var test_handler := TestHandler.new(get_undo_redo(), _log_buffer)
	var batch_handler := BatchHandler.new(_dispatcher, get_undo_redo())
	var ui_handler := UiHandler.new(get_undo_redo())
	var theme_handler := ThemeHandler.new(get_undo_redo())
	var animation_handler := AnimationHandler.new(get_undo_redo())
	var material_handler := MaterialHandler.new(get_undo_redo())
	var particle_handler := ParticleHandler.new(get_undo_redo())
	var camera_handler := CameraHandler.new(get_undo_redo())
	var audio_handler := AudioHandler.new(get_undo_redo())
	var physics_shape_handler := PhysicsShapeHandler.new(get_undo_redo())
	var environment_handler := EnvironmentHandler.new(get_undo_redo(), _connection)
	var texture_handler := TextureHandler.new(get_undo_redo(), _connection)
	var curve_handler := CurveHandler.new(get_undo_redo(), _connection)
	var control_draw_recipe_handler := ControlDrawRecipeHandler.new(get_undo_redo())
	_handlers = [editor_handler, scene_handler, node_handler, project_handler, client_handler, script_handler, resource_handler, filesystem_handler, signal_handler, autoload_handler, input_handler, test_handler, batch_handler, ui_handler, theme_handler, animation_handler, material_handler, particle_handler, camera_handler, audio_handler, physics_shape_handler, environment_handler, texture_handler, curve_handler, control_draw_recipe_handler]

	_dispatcher.register("get_editor_state", editor_handler.get_editor_state)
	_dispatcher.register("get_scene_tree", scene_handler.get_scene_tree)
	_dispatcher.register("get_open_scenes", scene_handler.get_open_scenes)
	_dispatcher.register("find_nodes", scene_handler.find_nodes)
	_dispatcher.register("create_scene", scene_handler.create_scene)
	_dispatcher.register("open_scene", scene_handler.open_scene)
	_dispatcher.register("save_scene", scene_handler.save_scene)
	_dispatcher.register("save_scene_as", scene_handler.save_scene_as)
	_dispatcher.register("get_selection", editor_handler.get_selection)
	_dispatcher.register("create_node", node_handler.create_node)
	_dispatcher.register("delete_node", node_handler.delete_node)
	_dispatcher.register("reparent_node", node_handler.reparent_node)
	_dispatcher.register("set_property", node_handler.set_property)
	_dispatcher.register("rename_node", node_handler.rename_node)
	_dispatcher.register("duplicate_node", node_handler.duplicate_node)
	_dispatcher.register("move_node", node_handler.move_node)
	_dispatcher.register("add_to_group", node_handler.add_to_group)
	_dispatcher.register("remove_from_group", node_handler.remove_from_group)
	_dispatcher.register("set_selection", node_handler.set_selection)
	_dispatcher.register("get_node_properties", node_handler.get_node_properties)
	_dispatcher.register("get_children", node_handler.get_children)
	_dispatcher.register("get_groups", node_handler.get_groups)
	_dispatcher.register("get_logs", editor_handler.get_logs)
	_dispatcher.register("clear_logs", editor_handler.clear_logs)
	_dispatcher.register("take_screenshot", editor_handler.take_screenshot)
	_dispatcher.register("get_performance_monitors", editor_handler.get_performance_monitors)
	_dispatcher.register("reload_plugin", editor_handler.reload_plugin)
	_dispatcher.register("quit_editor", editor_handler.quit_editor)
	_dispatcher.register("get_project_setting", project_handler.get_project_setting)
	_dispatcher.register("set_project_setting", project_handler.set_project_setting)
	_dispatcher.register("run_project", project_handler.run_project)
	_dispatcher.register("stop_project", project_handler.stop_project)
	_dispatcher.register("search_filesystem", project_handler.search_filesystem)
	_dispatcher.register("configure_client", client_handler.configure_client)
	_dispatcher.register("remove_client", client_handler.remove_client)
	_dispatcher.register("check_client_status", client_handler.check_client_status)
	_dispatcher.register("create_script", script_handler.create_script)
	_dispatcher.register("patch_script", script_handler.patch_script)
	_dispatcher.register("read_script", script_handler.read_script)
	_dispatcher.register("attach_script", script_handler.attach_script)
	_dispatcher.register("detach_script", script_handler.detach_script)
	_dispatcher.register("find_symbols", script_handler.find_symbols)
	_dispatcher.register("search_resources", resource_handler.search_resources)
	_dispatcher.register("load_resource", resource_handler.load_resource)
	_dispatcher.register("assign_resource", resource_handler.assign_resource)
	_dispatcher.register("create_resource", resource_handler.create_resource)
	_dispatcher.register("get_resource_info", resource_handler.get_resource_info)
	_dispatcher.register("read_file", filesystem_handler.read_file)
	_dispatcher.register("write_file", filesystem_handler.write_file)
	_dispatcher.register("reimport", filesystem_handler.reimport)
	_dispatcher.register("list_signals", signal_handler.list_signals)
	_dispatcher.register("connect_signal", signal_handler.connect_signal)
	_dispatcher.register("disconnect_signal", signal_handler.disconnect_signal)
	_dispatcher.register("list_autoloads", autoload_handler.list_autoloads)
	_dispatcher.register("add_autoload", autoload_handler.add_autoload)
	_dispatcher.register("remove_autoload", autoload_handler.remove_autoload)
	_dispatcher.register("list_actions", input_handler.list_actions)
	_dispatcher.register("add_action", input_handler.add_action)
	_dispatcher.register("remove_action", input_handler.remove_action)
	_dispatcher.register("bind_event", input_handler.bind_event)
	_dispatcher.register("run_tests", test_handler.run_tests)
	_dispatcher.register("get_test_results", test_handler.get_test_results)
	_dispatcher.register("batch_execute", batch_handler.batch_execute)
	_dispatcher.register("set_anchor_preset", ui_handler.set_anchor_preset)
	_dispatcher.register("set_text", ui_handler.set_text)
	_dispatcher.register("build_layout", ui_handler.build_layout)
	_dispatcher.register("create_theme", theme_handler.create_theme)
	_dispatcher.register("theme_set_color", theme_handler.set_color)
	_dispatcher.register("theme_set_constant", theme_handler.set_constant)
	_dispatcher.register("theme_set_font_size", theme_handler.set_font_size)
	_dispatcher.register("theme_set_stylebox_flat", theme_handler.set_stylebox_flat)
	_dispatcher.register("apply_theme", theme_handler.apply_theme)
	_dispatcher.register("animation_player_create", animation_handler.create_player)
	_dispatcher.register("animation_create", animation_handler.create_animation)
	_dispatcher.register("animation_add_property_track", animation_handler.add_property_track)
	_dispatcher.register("animation_add_method_track", animation_handler.add_method_track)
	_dispatcher.register("animation_set_autoplay", animation_handler.set_autoplay)
	_dispatcher.register("animation_play", animation_handler.play)
	_dispatcher.register("animation_stop", animation_handler.stop)
	_dispatcher.register("animation_list", animation_handler.list_animations)
	_dispatcher.register("animation_get", animation_handler.get_animation)
	_dispatcher.register("animation_create_simple", animation_handler.create_simple)
	_dispatcher.register("animation_delete", animation_handler.delete_animation)
	_dispatcher.register("animation_validate", animation_handler.validate_animation)
	_dispatcher.register("animation_preset_fade", animation_handler.preset_fade)
	_dispatcher.register("animation_preset_slide", animation_handler.preset_slide)
	_dispatcher.register("animation_preset_shake", animation_handler.preset_shake)
	_dispatcher.register("animation_preset_pulse", animation_handler.preset_pulse)
	_dispatcher.register("material_create", material_handler.create_material)
	_dispatcher.register("material_set_param", material_handler.set_param)
	_dispatcher.register("material_set_shader_param", material_handler.set_shader_param)
	_dispatcher.register("material_get", material_handler.get_material)
	_dispatcher.register("material_list", material_handler.list_materials)
	_dispatcher.register("material_assign", material_handler.assign_material)
	_dispatcher.register("material_apply_to_node", material_handler.apply_to_node)
	_dispatcher.register("material_apply_preset", material_handler.apply_preset)
	_dispatcher.register("particle_create", particle_handler.create_particle)
	_dispatcher.register("particle_set_main", particle_handler.set_main)
	_dispatcher.register("particle_set_process", particle_handler.set_process)
	_dispatcher.register("particle_set_draw_pass", particle_handler.set_draw_pass)
	_dispatcher.register("particle_restart", particle_handler.restart_particle)
	_dispatcher.register("particle_get", particle_handler.get_particle)
	_dispatcher.register("particle_apply_preset", particle_handler.apply_preset)
	_dispatcher.register("camera_create", camera_handler.create_camera)
	_dispatcher.register("camera_configure", camera_handler.configure)
	_dispatcher.register("camera_set_limits_2d", camera_handler.set_limits_2d)
	_dispatcher.register("camera_set_damping_2d", camera_handler.set_damping_2d)
	_dispatcher.register("camera_follow_2d", camera_handler.follow_2d)
	_dispatcher.register("camera_get", camera_handler.get_camera)
	_dispatcher.register("camera_list", camera_handler.list_cameras)
	_dispatcher.register("camera_apply_preset", camera_handler.apply_preset)
	_dispatcher.register("audio_player_create", audio_handler.create_player)
	_dispatcher.register("audio_player_set_stream", audio_handler.set_stream)
	_dispatcher.register("audio_player_set_playback", audio_handler.set_playback)
	_dispatcher.register("audio_play", audio_handler.play)
	_dispatcher.register("audio_stop", audio_handler.stop)
	_dispatcher.register("audio_list", audio_handler.list_streams)
	_dispatcher.register("physics_shape_autofit", physics_shape_handler.autofit)
	_dispatcher.register("environment_create", environment_handler.create_environment)
	_dispatcher.register("gradient_texture_create", texture_handler.create_gradient_texture)
	_dispatcher.register("noise_texture_create", texture_handler.create_noise_texture)
	_dispatcher.register("curve_set_points", curve_handler.set_points)
	_dispatcher.register(
		"control_draw_recipe", control_draw_recipe_handler.control_draw_recipe
	)

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
	_startup_trace_finish(_startup_path if not _startup_path.is_empty() else "loaded")


func _exit_tree() -> void:
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

	# Break the Callable -> handler ref chain before dropping _handlers, so the
	# array clear actually decrefs the handler RefCounteds to zero.
	if _dispatcher:
		_dispatcher.clear()

	# Handler destructors run here, while their class_name scripts are still loaded.
	_handlers.clear()

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
## logs_read(source="editor"). Logger subclassing is 4.5+ only; the
## ClassDB gate keeps the plugin loadable on 4.4 with no-op editor logs
## (the buffer stays empty, logs_read returns no entries).
##
## Limitation called out in the issue: parse errors fired *before* the
## plugin's _enter_tree (e.g. during the editor's initial filesystem
## scan, or for scripts that fail on first project open) happen before
## add_logger is called and are not captured. There's no public API to
## drain the editor's already-emitted error history; rescanning the
## file would re-emit them but at the cost of disrupting the user's
## editing state, so we accept the gap.
func _attach_editor_logger() -> void:
	if not (ClassDB.class_exists("Logger") and OS.has_method("add_logger")):
		return
	var logger_script := load(EDITOR_LOGGER_PATH)
	if logger_script == null:
		return
	_editor_logger = logger_script.new(_editor_log_buffer)
	OS.call("add_logger", _editor_logger)


func _detach_editor_logger() -> void:
	if _editor_logger != null and OS.has_method("remove_logger"):
		OS.call("remove_logger", _editor_logger)
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
	if _env_truthy(allow_value):
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


static func _env_truthy(value: String) -> bool:
	match value.strip_edges().to_lower():
		"1", "true", "yes", "on":
			return true
		_:
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
	_startup_trace_enabled = McpClientConfigurator.startup_trace_enabled()
	if not _startup_trace_enabled:
		return
	_startup_trace_start_ms = Time.get_ticks_msec()
	_startup_trace_last_ms = _startup_trace_start_ms
	_startup_trace_netsh_start_count = McpWindowsPortReservation.netsh_query_count()
	_startup_trace_counters.clear()
	for counter in STARTUP_TRACE_COUNTER_NAMES:
		_startup_trace_counters[counter] = 0
	print(
		"MCP startup trace | begin platform=%s http_port=%d ws_port=%d"
		% [
			OS.get_name(),
			McpClientConfigurator.http_port(),
			McpClientConfigurator.ws_port(),
		]
	)


func _startup_trace_count(counter: String, amount: int = 1) -> void:
	if not _startup_trace_enabled:
		return
	_startup_trace_counters[counter] = int(_startup_trace_counters.get(counter, 0)) + amount


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
	_startup_trace_counters["netsh"] = (
		McpWindowsPortReservation.netsh_query_count() - _startup_trace_netsh_start_count
	)
	print(
		"MCP startup trace | done path=%s total_ms=%d counters=%s"
		% [path, now - _startup_trace_start_ms, str(_startup_trace_counters)]
	)


## Spawn the managed server, or adopt / recover whatever is on the port.
## Implementation in McpServerLifecycleManager.start_server (#297 PR 5).
func _start_server() -> void:
	_lifecycle.start_server()


func _set_incompatible_server(live: Dictionary, expected_version: String, port: int) -> void:
	_spawn_state = McpSpawnState.INCOMPATIBLE_SERVER
	_connection_blocked = true
	_server_expected_version = expected_version
	_server_actual_name = str(live.get("name", ""))
	_server_actual_version = _live_version_for_message(live)
	_server_dev_version_mismatch_allowed = false
	_server_status_message = _incompatible_server_message(live, expected_version, port, _resolved_ws_port)
	## `live` is the caller's most-current snapshot — pass it through to
	## the recovery proof helper so it doesn't fire another probe of the
	## same port. The `_set_incompatible_server` contract is "use exactly
	## this live", so threading it down keeps the proof determination
	## consistent with the diagnostic message we just built.
	var proof := _evaluate_recovery_port_occupant_proof(port, live)
	var proof_name := str(proof.get("proof", ""))
	_can_recover_incompatible = not proof_name.is_empty()
	print("MCP | proof: %s" % (proof_name if _can_recover_incompatible else "(none)"))
	_refresh_dock_client_statuses()


static func _incompatible_server_message(
	live: Dictionary,
	expected_version: String,
	port: int,
	expected_ws_port: int
) -> String:
	var version := _live_version_for_message(live)
	var actual_ws_port := _live_ws_port_for_message(live)
	if not version.is_empty():
		if actual_ws_port > 0 and actual_ws_port != expected_ws_port:
			return (
				"Port %d is occupied by godot-ai server v%s using WS port %d; "
				+ "plugin expects v%s with WS port %d. Stop the old server or "
				+ "change both HTTP and WS ports."
			) % [port, version, actual_ws_port, expected_version, expected_ws_port]
		return (
			"Port %d is occupied by godot-ai server v%s; plugin expects v%s. "
			+ "Stop the old server or change both HTTP and WS ports."
		) % [port, version, expected_version]
	var status_code := int(live.get("status_code", 0))
	if status_code > 0:
		return (
			"Port %d is occupied by an unverified server (status endpoint returned HTTP %d); "
			+ "plugin expects godot-ai v%s. Stop the other server or change both HTTP and WS ports."
		) % [port, status_code, expected_version]
	return (
		"Port %d is occupied by another process; plugin expects godot-ai v%s. "
		+ "Stop the other process or change both HTTP and WS ports."
	) % [port, expected_version]


static func _server_version_compatibility(actual_version: String, expected_version: String, is_dev_checkout: bool) -> Dictionary:
	if actual_version.is_empty():
		return {"compatible": false, "reason": "unknown", "dev_mismatch_allowed": false}
	if actual_version == expected_version:
		return {"compatible": true, "reason": "exact", "dev_mismatch_allowed": false}
	if is_dev_checkout:
		return {"compatible": true, "reason": "dev_mismatch", "dev_mismatch_allowed": true}
	return {"compatible": false, "reason": "version_mismatch", "dev_mismatch_allowed": false}


static func _server_status_compatibility(
	actual_version: String,
	expected_version: String,
	actual_ws_port: int,
	expected_ws_port: int,
	is_dev_checkout: bool,
) -> Dictionary:
	var version_result := _server_version_compatibility(
		actual_version,
		expected_version,
		is_dev_checkout
	)
	if not bool(version_result.get("compatible", false)):
		return version_result
	if actual_ws_port != expected_ws_port:
		return {"compatible": false, "reason": "ws_port_mismatch", "dev_mismatch_allowed": false}
	return version_result


static func _managed_record_has_version_drift(record_version: String, current_version: String) -> bool:
	return not record_version.is_empty() and record_version != current_version


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
	return str(live.get("name", "")) == "godot-ai"


static func _verified_status_version(live: Dictionary) -> String:
	if not _live_status_identifies_godot_ai(live):
		return ""
	return str(live.get("version", ""))


static func _verified_status_ws_port(live: Dictionary) -> int:
	if not _live_status_identifies_godot_ai(live):
		return 0
	return int(live.get("ws_port", 0))


static func _live_version_for_message(live: Dictionary) -> String:
	if live.has("name") and str(live.get("name", "")) != "godot-ai":
		return ""
	return str(live.get("version", ""))


static func _live_ws_port_for_message(live: Dictionary) -> int:
	if live.has("name") and str(live.get("name", "")) != "godot-ai":
		return 0
	return int(live.get("ws_port", 0))


func _refresh_dock_client_statuses() -> bool:
	if _dock == null:
		return false
	if not _dock.has_method("_refresh_all_client_statuses"):
		return false
	_dock.call("_refresh_all_client_statuses")
	return true


## Record a non-OK spawn outcome. First writer wins: once a specific
## diagnosis lands (e.g. PORT_EXCLUDED during the proactive check),
## later fallback paths (e.g. CRASHED from the watch loop) don't
## overwrite the more actionable state.
func _set_spawn_state(state: String) -> void:
	if _spawn_state != McpSpawnState.OK:
		return
	_spawn_state = state


## Arm the one-shot connection watcher. Called from `_start_server`'s
## FOREIGN_PORT branch: we flagged the diagnostic preemptively assuming
## the port holder doesn't speak MCP, but if it turns out to be another
## editor's server our WebSocket will open and we need to retract the
## diagnostic.
##
## We intentionally poll `_connection.is_connected` from `_process`
## instead of wiring a new signal on McpConnection — signals would be
## cleaner, but `class_name McpConnection` is cached by the editor across
## plugin disable/enable, and a self-update that added a new signal
## crashes `_enter_tree` with "invalid access to property" until the
## user restarts Godot. Polling only reads `is_connected` (present on
## every shipped McpConnection), so upgrades stay hot-reloadable.
##
## The watch self-disarms after SPAWN_GRACE_MS so per-frame cost drops
## back to zero if it is ever armed by a legacy adoption path.
func _watch_for_adoption_confirmation() -> void:
	_adoption_watch_deadline_ms = Time.get_ticks_msec() + SPAWN_GRACE_MS
	_update_process_enabled()


func _arm_server_version_check() -> void:
	_awaiting_server_version = true
	_server_version_deadline_ms = 0
	_update_process_enabled()


func _update_process_enabled() -> void:
	set_process(_adoption_watch_deadline_ms > 0 or _awaiting_server_version)


func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	if _awaiting_server_version:
		if _connection != null and _connection.is_connected:
			if _server_version_deadline_ms == 0:
				_server_version_deadline_ms = now + SERVER_HANDSHAKE_VERSION_TIMEOUT_MS
			if not _connection.server_version.is_empty():
				_on_server_version_verified(_connection.server_version)
			elif now >= _server_version_deadline_ms:
				_on_server_version_unverified()
	if _adoption_watch_deadline_ms > 0 and now >= _adoption_watch_deadline_ms:
		_adoption_watch_deadline_ms = 0
	_update_process_enabled()


## A WebSocket opening only proves the occupant speaks enough of the editor
## protocol to accept a session. Compatibility is decided by the server
## version in `handshake_ack`, so this only arms that check.
func _on_connection_established() -> void:
	if _spawn_state == McpSpawnState.FOREIGN_PORT:
		_arm_server_version_check()


func _on_server_version_verified(version: String) -> void:
	_awaiting_server_version = false
	_server_version_deadline_ms = 0
	_server_actual_name = "godot-ai"
	_server_actual_version = version
	var expected := _server_expected_version
	if expected.is_empty():
		expected = McpClientConfigurator.get_plugin_version()
		_server_expected_version = expected
	var compatibility := _server_version_compatibility(
		version,
		expected,
		McpClientConfigurator.is_dev_checkout()
	)
	if compatibility.get("compatible", false):
		_can_recover_incompatible = false
		_server_dev_version_mismatch_allowed = bool(compatibility.get("dev_mismatch_allowed", false))
		if _server_dev_version_mismatch_allowed:
			_server_status_message = (
				"Using dev server v%s with plugin v%s (dev checkout version mismatch allowed)."
				% [version, expected]
			)
		if _spawn_state == McpSpawnState.FOREIGN_PORT:
			_spawn_state = McpSpawnState.OK
		_update_process_enabled()
		return
	var live := {"version": version, "status_code": 200, "name": "godot-ai"}
	_set_incompatible_server(live, expected, McpClientConfigurator.http_port())
	if _connection != null:
		_connection.connect_blocked = true
		_connection.connect_block_reason = _server_status_message
		_connection.disconnect_from_server()
	_update_process_enabled()


func _on_server_version_unverified() -> void:
	_awaiting_server_version = false
	_server_version_deadline_ms = 0
	var expected := _server_expected_version
	if expected.is_empty():
		expected = McpClientConfigurator.get_plugin_version()
		_server_expected_version = expected
	var live := {"version": "", "status_code": 0, "error": "missing_handshake_ack"}
	_set_incompatible_server(live, expected, McpClientConfigurator.http_port())
	if _connection != null:
		_connection.connect_blocked = true
		_connection.connect_block_reason = _server_status_message
		_connection.disconnect_from_server()
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


## Watch-loop callback. Implementation in McpServerLifecycleManager.
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
		_refresh_retried,
		McpClientConfigurator.get_server_launch_mode(),
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


## Retry the spawn with `--refresh` (uvx PyPI-index workaround).
## Implementation in McpServerLifecycleManager.respawn_with_refresh.
func _respawn_with_refresh() -> void:
	_lifecycle.respawn_with_refresh()


## Snapshot of the server-spawn outcome for the dock.
##
## `state` is one of the `McpSpawnState.*` constants; the dock owns the
## UI copy per state via its own `_crash_body_for_state`. `exit_ms` is
## only meaningful for `CRASHED`.
func get_server_status() -> Dictionary:
	return {
		"state": _spawn_state,
		"exit_ms": _server_exit_ms,
		"actual_name": _server_actual_name,
		"actual_version": _server_actual_version,
		"expected_version": _server_expected_version,
		"message": _server_status_message,
		"dev_version_mismatch_allowed": _server_dev_version_mismatch_allowed,
		"can_recover_incompatible": _can_recover_incompatible,
		"connection_blocked": _connection_blocked,
	}


func get_resolved_ws_port() -> int:
	return _resolved_ws_port


func _set_resolved_ws_port(port: int) -> void:
	_resolved_ws_port = port
	if _connection != null:
		_connection.ws_port = port


func _resolve_ws_port() -> int:
	return PortResolver.resolve_ws_port(
		McpClientConfigurator.ws_port(),
		McpClientConfigurator.MAX_PORT,
		_log_buffer,
	)


## Forwarding shim — McpPortResolver owns the implementation. Kept on
## the plugin so existing characterization tests calling
## `GodotAiPlugin._resolved_ws_port_for_existing_server(...)` keep working.
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
		McpClientConfigurator.MAX_PORT,
		span,
	)


static func _can_bind_local_port(port: int) -> bool:
	return PortResolver.can_bind_local_port(port)


## Instance shim — McpPortResolver owns the OS scraping. The wrapper
## stays on the plugin so the cold-start trace counter still increments
## for each scrape, and so `_ProofPlugin extends GodotAiPlugin` test
## fixtures can override port queries by overriding this method.
func _is_port_in_use(port: int) -> bool:
	if PortResolver.can_bind_local_port(port):
		return false
	if OS.get_name() == "Windows":
		_startup_trace_count("netstat")
	else:
		_startup_trace_count("lsof")
	return PortResolver.is_port_in_use_via_scrape(port)


## Forwarding shim — McpPortResolver owns the implementation. See
## `_is_port_in_use` for the trace-counter / test-override rationale.
func _find_pid_on_port(port: int) -> int:
	if OS.get_name() == "Windows":
		_startup_trace_count("netstat")
		_startup_trace_count("powershell")
	else:
		_startup_trace_count("lsof")
	return PortResolver.find_pid_on_port(port)


func _find_all_pids_on_port(port: int) -> Array[int]:
	if OS.get_name() == "Windows":
		_startup_trace_count("netstat")
		_startup_trace_count("powershell")
	else:
		_startup_trace_count("lsof")
	return PortResolver.find_all_pids_on_port(port)


static func _find_listener_pids_windows(port: int) -> Array[int]:
	return PortResolver.find_listener_pids_windows(port)


static func _execute_windows_powershell(script: String, output: Array) -> int:
	return PortResolver.execute_windows_powershell(script, output)


static func _windows_powershell_candidates() -> Array[String]:
	return PortResolver.windows_powershell_candidates()


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
func _evaluate_strong_port_occupant_proof(port: int, live: Dictionary = {}) -> Dictionary:
	var result := {"proof": "", "pids": []}
	var listener_pids := _find_all_pids_on_port(port)
	if listener_pids.is_empty():
		return result

	var record := _read_managed_server_record()
	var record_pid := int(record.get("pid", 0))
	var record_version := str(record.get("version", ""))

	if record_pid > 1 and record_pid != OS.get_process_id():
		if listener_pids.has(record_pid) and _pid_alive_for_proof(record_pid):
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
		return {"proof": "status_matches_record", "pids": listener_pids}

	return result


## See `_evaluate_strong_port_occupant_proof` for the `live` contract.
## Threads `live` through the strong-proof delegate so neither helper
## probes when the caller already knows the port-owner status.
func _evaluate_recovery_port_occupant_proof(port: int, live: Dictionary = {}) -> Dictionary:
	var proof := _evaluate_strong_port_occupant_proof(port, live)
	if not str(proof.get("proof", "")).is_empty():
		return proof

	var current_live: Dictionary = live if not live.is_empty() else _probe_live_server_status_for_port(port)
	if _live_status_identifies_godot_ai(current_live):
		return {"proof": "status_name", "pids": _find_all_pids_on_port(port)}

	return {"proof": "", "pids": []}


## See McpServerLifecycleManager.recover_strong_port_occupant.
func _recover_strong_port_occupant(port: int, wait_s: float, pre_kill_live: Dictionary = {}) -> bool:
	return _lifecycle.recover_strong_port_occupant(port, wait_s, pre_kill_live)


func _legacy_pidfile_kill_targets(_port: int, listener_pids: Array[int]) -> Array[int]:
	var targets: Array[int] = []
	var pidfile_pid := _read_pid_file_for_proof()
	var pidfile_alive := _pid_alive_for_proof(pidfile_pid)
	var pidfile_branded := _pid_cmdline_is_godot_ai_for_proof(pidfile_pid)
	if pidfile_pid <= 1 or pidfile_pid == OS.get_process_id():
		return targets
	if not listener_pids.has(pidfile_pid) or not pidfile_alive:
		return targets
	if not pidfile_branded:
		return targets

	for pid in listener_pids:
		if pid > 1 and pid != OS.get_process_id() and _pid_cmdline_is_godot_ai_for_proof(pid):
			targets.append(pid)
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


## Stop the managed server. Implementation in McpServerLifecycleManager.
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
	var excluded := McpClientConfigurator.excluded_domains()
	if not excluded.is_empty():
		flags.append("--exclude-domains")
		flags.append(excluded)
	return flags


## Returns true only when we can prove `pid`'s command line carries the
## `godot-ai` brand AND a server flag (`--pid-file` / `--transport`). Used by
## automatic kill paths (`_legacy_pidfile_kill_targets`) so a stale pidfile
## whose PID has been recycled by an unrelated listener can't hand us a
## kill target. If the OS lookup fails or returns an empty cmdline we
## conservatively return false — better to surface incompatible-server and
## let the user click Restart than to kill the wrong process.
func _pid_cmdline_is_godot_ai(pid: int) -> bool:
	if pid <= 1:
		return false
	var cmd := ""
	if OS.get_name() == "Windows":
		cmd = _windows_pid_commandline(pid)
	else:
		cmd = _posix_pid_commandline(pid)
	return _commandline_is_godot_ai_server(cmd)


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


## Instance shim — delegates to `_is_port_in_use` so test fixtures that
## override port queries still drive the wait loop. McpPortResolver has
## an equivalent static helper, but it talks to `is_port_in_use` directly
## and would bypass the override.
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
		return {"pid": 0, "version": "", "ws_port": 0}
	var pid: int = 0
	if es.has_setting(MANAGED_SERVER_PID_SETTING):
		pid = int(es.get_setting(MANAGED_SERVER_PID_SETTING))
	var version: String = ""
	if es.has_setting(MANAGED_SERVER_VERSION_SETTING):
		version = str(es.get_setting(MANAGED_SERVER_VERSION_SETTING))
	var ws_port: int = 0
	if es.has_setting(MANAGED_SERVER_WS_PORT_SETTING):
		ws_port = int(es.get_setting(MANAGED_SERVER_WS_PORT_SETTING))
	return {"pid": pid, "version": version, "ws_port": ws_port}


func _write_managed_server_record(pid: int, version: String) -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(MANAGED_SERVER_PID_SETTING, pid)
	es.set_setting(MANAGED_SERVER_VERSION_SETTING, version)
	es.set_setting(MANAGED_SERVER_WS_PORT_SETTING, _resolved_ws_port)


func _clear_managed_server_record() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if es.has_setting(MANAGED_SERVER_PID_SETTING):
		es.set_setting(MANAGED_SERVER_PID_SETTING, 0)
	if es.has_setting(MANAGED_SERVER_VERSION_SETTING):
		es.set_setting(MANAGED_SERVER_VERSION_SETTING, "")
	if es.has_setting(MANAGED_SERVER_WS_PORT_SETTING):
		es.set_setting(MANAGED_SERVER_WS_PORT_SETTING, 0)


## Public entry point for the self-update reload handoff.
## Implementation in McpServerLifecycleManager.prepare_for_update_reload.
func prepare_for_update_reload() -> void:
	_lifecycle.prepare_for_update_reload()


## See McpServerLifecycleManager.adopt_compatible_server.
func _adopt_compatible_server(record_version: String, current_version: String, owner: int) -> String:
	return _lifecycle.adopt_compatible_server(record_version, current_version, owner)


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
	if _spawn_state != McpSpawnState.INCOMPATIBLE_SERVER:
		return false
	var port := McpClientConfigurator.http_port()
	if not _is_port_in_use(port):
		return false
	var proof := _evaluate_recovery_port_occupant_proof(port)
	return not str(proof.get("proof", "")).is_empty()


func _resume_connection_after_recovery() -> void:
	if _connection == null:
		return
	if _spawn_state != McpSpawnState.OK or _connection_blocked:
		return
	_connection.connect_blocked = false
	_connection.connect_block_reason = ""
	_connection.server_version = ""
	_connection.set_process(true)
	_arm_server_version_check()


func recover_incompatible_server() -> bool:
	if _spawn_state != McpSpawnState.INCOMPATIBLE_SERVER:
		return false

	var port := McpClientConfigurator.http_port()
	var proof := _evaluate_recovery_port_occupant_proof(port)
	var targets: Array[int] = []
	targets.assign(proof.get("pids", []))
	if targets.is_empty():
		return false
	print("MCP | proof: %s" % str(proof.get("proof", "")))

	var killed := _kill_processes_and_windows_spawn_children(targets)
	if not killed.is_empty():
		print("MCP | killed pids %s on port %d" % [str(killed), port])
	_wait_for_port_free(port, 5.0)
	if _is_port_in_use(port):
		return false

	UvCacheCleanup.purge_stale_builds()
	_clear_managed_server_record()
	_clear_pid_file()
	_spawn_state = McpSpawnState.OK
	_connection_blocked = false
	_server_status_message = ""
	_server_actual_version = ""
	_server_actual_name = ""
	_can_recover_incompatible = false
	_server_started_this_session = false
	_server_pid = -1
	_start_server()
	_resume_connection_after_recovery()
	return true


## Kill whichever process is holding `http_port()` right now — by resolving
## the port-owning PID via pid-file / netstat / lsof, independent of whether
## we ever set `_server_pid` — then clear ownership state and respawn via
## `_start_server`. The dock's version-mismatch banner wires here when the
## plugin adopted a foreign server (no managed record, `_server_pid == -1`)
## whose `server_version` drifts from the current plugin version. Without
## this, `_stop_server` early-returns on `_server_pid <= 0` and the old
## server outlives every plugin reload.
func force_restart_server() -> void:
	if not can_restart_managed_server():
		push_warning("MCP | refusing to kill server on port %d without managed-server ownership proof"
			% McpClientConfigurator.http_port())
		return
	var port := McpClientConfigurator.http_port()
	## Kill every LISTENER on the port, not just the first one. A dev
	## server run via `uvicorn --reload` owns port 8000 through both a
	## reloader parent AND a worker child — killing only one (or zero,
	## if the single-pid parse fell over on multi-line lsof output) leaves
	## the other holding the port past `_wait_for_port_free`'s window.
	_kill_processes_and_windows_spawn_children(_find_all_pids_on_port(port))
	_wait_for_port_free(port, 5.0)
	if _is_port_in_use(port):
		_set_incompatible_server(
			_probe_live_server_status_for_port(port),
			McpClientConfigurator.get_plugin_version(),
			port
		)
		return
	## Same rationale as `_stop_server`: the server child python just
	## released its `pydantic_core` mapping, so this is the only window in
	## which the hard-linked copies under `builds-v0\.tmp*` are deletable.
	## Sweep before respawning so the upcoming `uvx mcp-proxy` build doesn't
	## inherit the same cleanup-failure path that triggered the restart.
	UvCacheCleanup.purge_stale_builds()
	_clear_managed_server_record()
	_clear_pid_file()
	_server_started_this_session = false
	_server_pid = -1
	_start_server()


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
		var server_cmd := McpClientConfigurator.get_server_command()
		if server_cmd.is_empty():
			push_warning("MCP | could not find server command for dev server")
			return

		var cmd: String = server_cmd[0]
		_set_resolved_ws_port(_resolve_ws_port())
		var inner_args: Array[String] = []
		inner_args.assign(server_cmd.slice(1))
		inner_args.append_array([
			"--transport", "streamable-http",
			"--port", str(McpClientConfigurator.http_port()),
			"--ws-port", str(_resolved_ws_port),
			"--reload",
		])

		var worktree_src := McpClientConfigurator.find_worktree_src_dir(ProjectSettings.globalize_path("res://"))
		var prev_pythonpath := OS.get_environment("PYTHONPATH")
		if not worktree_src.is_empty():
			var sep := ";" if OS.get_name() == "Windows" else ":"
			var new_pp := worktree_src if prev_pythonpath.is_empty() else worktree_src + sep + prev_pythonpath
			OS.set_environment("PYTHONPATH", new_pp)

		var pid := OS.create_process(cmd, inner_args)

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
			var suffix := " (PYTHONPATH=%s)" % worktree_src if not worktree_src.is_empty() else ""
			print("MCP | started dev server with --reload (PID %d): %s %s%s" % [pid, cmd, " ".join(inner_args), suffix])
		else:
			push_warning("MCP | failed to start dev server")
	)


func stop_dev_server() -> void:
	## Stop any server running on the HTTP port (by port, not PID).
	## Used for dev servers whose PID we don't track across reloads.
	if _server_pid > 0:
		# We have a managed server — use normal stop
		_stop_server()
		return
	var output: Array = []
	var port := McpClientConfigurator.http_port()
	if OS.get_name() == "Windows":
		var killed := _kill_processes_and_windows_spawn_children(_find_all_pids_on_port(port))
		if not killed.is_empty():
			print("MCP | stopped dev server on port %d" % port)
	else:
		var exit_code := OS.execute("bash", ["-c", "lsof -ti:%d -sTCP:LISTEN | xargs kill 2>/dev/null" % port], output, true)
		if exit_code == 0:
			print("MCP | stopped dev server on port %d" % port)


func _kill_processes_and_windows_spawn_children(pids: Array[int]) -> Array[int]:
	var unique: Array[int] = []
	for pid in pids:
		if pid > 0 and not unique.has(pid):
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
			OS.kill(pid)
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
	## Returns true if a server is running on the HTTP port that we didn't start as managed.
	return _server_pid <= 0 and _is_port_in_use(McpClientConfigurator.http_port())


func has_managed_server() -> bool:
	## Returns true if the plugin is currently managing a server process it spawned.
	return _server_pid > 0


func can_restart_managed_server() -> bool:
	## Restart is allowed only when we have ownership proof. A live PID
	## means this plugin spawned/adopted a managed server; a non-empty
	## managed record is the cross-session proof used by the drift branch.
	if _server_pid > 0:
		return true
	var record := _read_managed_server_record()
	return not str(record.get("version", "")).is_empty()
