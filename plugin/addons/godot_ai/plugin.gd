@tool
extends EditorPlugin

const GAME_HELPER_AUTOLOAD_NAME := "_mcp_game_helper"
const GAME_HELPER_AUTOLOAD_PATH := "res://addons/godot_ai/runtime/game_helper.gd"

## Editor-process Logger subclass — captures parse errors, @tool runtime
## errors, and push_error/push_warning so the LLM can read them via
## `logs_read(source="editor")`.
const EditorLogger := preload("res://addons/godot_ai/runtime/editor_logger.gd")

const UpdateCoordinator := preload("res://addons/godot_ai/utils/update_coordinator.gd")
const UPDATE_TRANSACTION_ENV := "GODOT_AI_UPDATE_TRANSACTION"
const UPDATE_EDITOR_NONCE_ENV := "GODOT_AI_UPDATE_EDITOR_NONCE"
const UPDATE_ACTOR_HANDOFF_ENV := "GODOT_AI_UPDATE_ACTOR_HANDOFF"
## Cross-v4 hot-reload contract: the old actor owns all durable records; the
## swapped GDScript understands only this bounded command/outcome envelope.
const UPDATE_ACTOR_HANDOFF_SCHEMA := 1
const UPDATE_ACTOR_PROTOCOL_VERSION := 1
const UPDATE_ACTOR_COLD_START_TIMEOUT_MS := 120000
const UPDATE_ACTOR_HANDOFF_TIMEOUT_MS := 45000
const UPDATE_ACTOR_COMMAND_TIMEOUT_MS := 60000
const UPDATE_ACTOR_RELEASE_TIMEOUT_MS := 5000
const UPDATE_ACTOR_ERROR_PREFIX := "update transaction refused: "
const MAX_UPDATE_ACTOR_ERROR_BYTES := 1024
const MIN_GODOT_MAJOR := 4
const MIN_GODOT_MINOR := 7
const UNSUPPORTED_GODOT_MESSAGE := \
	"Godot AI v4 requires Godot 4.7 or newer in the 4.x line; plugin remains inactive."

## The lifecycle manager owns the serialized server episode and process
## authority. This root only captures its immutable launch plan and routes
## copied snapshots/results to the connection and Dock.
const ServerLifecycleManager := preload("res://addons/godot_ai/utils/server_lifecycle.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")
const ServerStateScript := preload("res://addons/godot_ai/utils/mcp_server_state.gd")
const TransportCapability := preload("res://addons/godot_ai/utils/transport_capability.gd")

## Plugin-class scripts used by this file. The script-local preload aliases
## are ordinary dependency shorthand and keep construction sites compact.
## They are not the self-update safety boundary. Whole-tree namespace swaps
## happen in an external Python actor while an old, detached coordinator owns
## only disable/scan/enable; no script mutates the tree that contains itself.
const Connection := preload("res://addons/godot_ai/connection.gd")
const Dispatcher := preload("res://addons/godot_ai/dispatcher.gd")
const Telemetry := preload("res://addons/godot_ai/telemetry.gd")
const LogBuffer := preload("res://addons/godot_ai/utils/log_buffer.gd")
const GameLogBuffer := preload("res://addons/godot_ai/utils/game_log_buffer.gd")
const EditorLogBuffer := preload("res://addons/godot_ai/utils/editor_log_buffer.gd")
const SurfacedErrorTracker := preload("res://addons/godot_ai/utils/surfaced_error_tracker.gd")
const Dock := preload("res://addons/godot_ai/mcp_dock.gd")
const DebuggerPlugin := preload("res://addons/godot_ai/debugger/mcp_debugger_plugin.gd")
const VisionRoutingScript := preload("res://addons/godot_ai/vision_routing.gd")
const ExportPlugin := preload("res://addons/godot_ai/export/mcp_export_plugin.gd")
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const CliExec := preload("res://addons/godot_ai/clients/_cli_exec.gd")
const ClientJobOwner := preload("res://addons/godot_ai/utils/client_job_owner.gd")
const UpdateManager := preload("res://addons/godot_ai/utils/update_manager.gd")
const WindowsPortReservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")
const McpToolRegistry := preload("res://addons/godot_ai/custom_tools/mcp_tool_registry.gd")
const McpServiceLocator := preload("res://addons/godot_ai/custom_tools/mcp_service_locator.gd")

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
## self-update safety metric. The transaction actor publishes one exact tree
## before the resource scan, so the root never observes an extracted-over-live
## mixture. In short: preload aliases are not the self-update safety metric.
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
var _vision_routing
var _export_plugin
var _custom_tool_registry
var _custom_tool_service_locator
## Plugin-lifetime owners. The Dock only emits intents and receives copied
## snapshots/outcomes, so replacing the view cannot abandon a live Thread or
## an update transaction.
var _client_jobs
var _update_manager
## Process identity continuity and the immutable terminal outcome cross only
## as values. The coordinator retains neither this plugin nor its objects.
static var _update_editor_nonce := ""
var _post_update_outcome: Dictionary = {}
var _post_update_actor_command = []
var _post_update_actor_version := ""
var _post_update_action := ""
var _normal_start_released := false
var _update_barrier_blocked := false
## One actor worker is sufficient: startup finishes before composition can
## reach migration completion, so two thread owners would encode impossible
## concurrency and double the teardown surface.
var _update_actor_thread
var _update_actor_job := ""
var _update_startup_cancel_mutex := Mutex.new()
var _update_startup_cancelled := false
var _update_actor_termination_unproven := false
## Serialized lifecycle episode owner. Construction is inert; `_enter_tree`
## supplies a copied plan and starts it only after composition completes.
var _lifecycle
static var _resolved_ws_port := ClientConfigurator.DEFAULT_WS_PORT
var _endpoint_policy: Dictionary = {}
var _headless_disabled := false
var _startup_trace_enabled := false
var _startup_trace_start_ms := 0
var _startup_trace_last_ms := 0
var _startup_trace_counters: Dictionary = {}
## Startup-path probes can now run on a worker thread (#678); the trace
## counters they bump are shared with the main thread, so serialize.
var _startup_trace_mutex := Mutex.new()
var _startup_trace_netsh_start_count := 0
var _unsupported_engine := false
var _loaded_plugin_version := ""


func _init() -> void:
	_unsupported_engine = not _supports_godot_version(Engine.get_version_info())
	if _unsupported_engine:
		return
	_lifecycle = ServerLifecycleManager.new()


func _enter_tree() -> void:
	if _unsupported_engine:
		push_error(UNSUPPORTED_GODOT_MESSAGE)
		return
	_startup_trace_begin()
	## Startup actor discovery runs off-main, where env_lookup intentionally
	## refuses live getenv access. Publish only its fixed HOME/PATH-adjacent
	## inputs now; full descriptor/settings warming still belongs at activation.
	ClientConfigurator.warm_update_actor_discovery_env()

	## Keep main-thread result polling off until the vision worker owner exists.
	## Unsupported/headless/barrier-blocked startup therefore has no process
	## callback and constructs no worker-capable object.
	set_process(false)

	## No plugin-owned object, server, or worker is constructed until the
	## external transaction record says this exact tree may start. This also
	## leases headless export/import processes: they execute plugin code and may
	## not straddle a same-install tree swap merely because no server will start.
	_loaded_plugin_version = get_plugin_version()
	## Dev checkouts never offer self-update and commonly mount the add-on by a
	## symlink the transaction actor deliberately rejects. Installed trees must
	## acquire the lease even when this headless launch will return below.
	if not ClientConfigurator.is_dev_checkout():
		_ensure_update_editor_nonce()
		## Export/import processes have no interactive main thread to protect and
		## must register the export filter before continuing, so they run the same
		## bounded command synchronously. An interactive editor returns from
		## _enter_tree immediately and waits on a worker: a cold/offline uvx resolve
		## can delay plugin composition, but can never freeze Godot's UI forever.
		if _mcp_disabled_for_headless_launch():
			if not _run_update_startup_barrier():
				_block_update_startup()
				return
		elif not _start_update_startup_barrier():
			_block_update_startup()
			return
		else:
			return

	_continue_enter_tree_after_update_barrier()


func _continue_enter_tree_after_update_barrier() -> void:

	## Register only after the update barrier, but before the headless guard:
	## `godot --headless --export-*` still needs to strip the game-helper
	## autoload from exported packs. The export plugin is otherwise inert.
	_export_plugin = ExportPlugin.new()
	add_export_plugin(_export_plugin)

	if _mcp_disabled_for_headless_launch():
		_headless_disabled = true
		print("MCP | plugin disabled in headless mode")
		return

	## Register port overrides before spawn so `http_port()` / `ws_port()`
	## return the user's configured values (if any) when `_start_server`
	## builds the CLI args.
	ClientConfigurator.ensure_settings_registered()
	_startup_trace_phase("settings_registered")

	_log_buffer = LogBuffer.new()
	## Apply the persisted dock "Log" toggle before anything logs through the
	## buffer. Without this the choice only took effect after a manual toggle
	## and reset to noisy on every editor restart (#626).
	_log_buffer.enabled = McpSettings.mcp_logging_enabled()

	## Capture desired endpoint settings without probing the OS. WS reservation
	## is an activation effect on Windows (`netsh`), so it runs only after every
	## owner and the Dock have been constructed and wired below.
	_endpoint_policy = ClientConfigurator.capture_endpoint_policy()
	_endpoint_policy["capability_path"] = TransportCapability.path_for_http_port(
		int(_endpoint_policy.http_port)
	)
	_resolved_ws_port = int(_endpoint_policy.ws_port)

	## Construct plugin-lifetime work owners before attaching the replaceable
	## Dock. Constructors are inert; activate() is the single normal-start seam
	## that Phase 6's durable activation barrier will guard.
	_client_jobs = ClientJobOwner.new()
	_client_jobs.snapshot_changed.connect(_on_client_work_snapshot_changed)
	_client_jobs.status_refresh_completed.connect(_on_client_status_refresh_completed)
	_client_jobs.mcp_status_completed.connect(_on_mcp_client_status_completed)
	_client_jobs.mcp_action_completed.connect(_on_mcp_client_action_completed)
	_client_jobs.post_update_repin_completed.connect(_on_post_update_repin_completed)
	_client_jobs.action_completed.connect(_on_client_action_completed)
	_client_jobs.action_timed_out.connect(_on_client_action_timed_out)
	add_child(_client_jobs)
	_update_manager = UpdateManager.new()
	_update_manager.update_check_completed.connect(_on_update_check_completed)
	_update_manager.install_state_changed.connect(_on_update_install_state_changed)
	_update_manager.activation_requested.connect(_on_update_activation_requested)
	add_child(_update_manager)

	_lifecycle.snapshot_changed.connect(_on_lifecycle_snapshot_changed)
	_lifecycle.transport_ready.connect(_on_lifecycle_transport_ready)
	_lifecycle.transport_cleared.connect(_on_lifecycle_transport_cleared)
	_lifecycle.startup_finished.connect(_startup_trace_finish)

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
	_connection.auth_token = ""
	## Pause-depth restore boundary (#712): the dispatcher rebalances any
	## pause_processing level a crashed handler leaked.
	_dispatcher.pause_target = _connection
	_connection.connect_blocked = _lifecycle.is_connection_blocked()
	_connection.connect_block_reason = _lifecycle.get_status_dict().get("message", "")
	## Replay the custom-tool catalog on (re)connect so tools registered
	## before the initial connection or during a disconnect window reach
	## the server — send_event silently drops while _connected is false.
	_connection.connection_state_changed.connect(_on_connection_state_changed)

	_telemetry = Telemetry.new(_connection)

	_debugger_plugin = DebuggerPlugin.new(_log_buffer, _game_log_buffer, _editor_log_buffer, _surfaced_error_tracker)
	_vision_routing = VisionRoutingScript.new()
	_vision_routing.log_buffer = _log_buffer
	set_process(true)
	_debugger_plugin.vision_routing = _vision_routing
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
	_dispatcher.register_lazy_handler("editor", HANDLERS_DIR + "editor_handler.gd", [_log_buffer, _connection, _debugger_plugin, _game_log_buffer, _editor_log_buffer, null, _surfaced_error_tracker, _vision_routing])
	_dispatcher.register_lazy_handler("scene", HANDLERS_DIR + "scene_handler.gd", [_connection])
	_dispatcher.register_lazy_handler("node", HANDLERS_DIR + "node_handler.gd", [undo])
	_dispatcher.register_lazy_handler("project", HANDLERS_DIR + "project_handler.gd", [_connection, _debugger_plugin, _editor_log_buffer])
	_dispatcher.register_lazy_handler(
		"client",
		HANDLERS_DIR + "client_handler.gd",
		[_client_jobs],
	)
	_dispatcher.register_lazy_handler("script", HANDLERS_DIR + "script_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("resource", HANDLERS_DIR + "resource_handler.gd", [undo, _connection])
	_dispatcher.register_lazy_handler("api", HANDLERS_DIR + "api_handler.gd", [])
	_dispatcher.register_lazy_handler("filesystem", HANDLERS_DIR + "filesystem_handler.gd", [_connection])
	_dispatcher.register_lazy_handler("signal", HANDLERS_DIR + "signal_handler.gd", [undo])
	_dispatcher.register_lazy_handler("autoload", HANDLERS_DIR + "autoload_handler.gd", [])
	_dispatcher.register_lazy_handler("input", HANDLERS_DIR + "input_handler.gd", [])
	_dispatcher.register_lazy_handler("test", HANDLERS_DIR + "test_handler.gd", [undo, _log_buffer, _dispatcher, _connection])
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
	_dispatcher.register_lazy_handler("gridmap", HANDLERS_DIR + "gridmap_handler.gd", [undo])
	_dispatcher.register_lazy_handler("csg", HANDLERS_DIR + "csg_handler.gd", [undo])

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
	_dispatcher.register_lazy("set_main_scene", "project", &"set_main_scene")
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
	_dispatcher.register_lazy("gridmap_set_item", "gridmap", &"set_item")
	_dispatcher.register_lazy("gridmap_fill", "gridmap", &"fill")
	_dispatcher.register_lazy("gridmap_clear", "gridmap", &"clear_layer")
	_dispatcher.register_lazy("gridmap_get_used_cells", "gridmap", &"get_used_cells")
	_dispatcher.register_lazy("gridmap_list_library_items", "gridmap", &"list_library_items")
	_dispatcher.register_lazy("csg_create", "csg", &"create")
	_dispatcher.register_lazy("csg_set_operation", "csg", &"set_operation")

	_connection.dispatcher = _dispatcher
	add_child(_connection)
	_startup_trace_phase("handlers_registered")

	# Custom tool registry
	_custom_tool_service_locator = McpServiceLocator.new()
	_custom_tool_service_locator.setup(_connection, _log_buffer)
	_custom_tool_registry = McpToolRegistry.new()
	_custom_tool_registry.setup(_dispatcher, _custom_tool_service_locator)
	_custom_tool_registry.tools_changed.connect(_on_custom_tools_changed)
	_custom_tool_registry.mark_ready()
	_startup_trace_phase("custom_tools_ready")

	# Dock panel
	_dock = Dock.new()
	_dock.vision_routing = _vision_routing
	_dock.name = "Godot AI"
	_dock.update_requested.connect(_on_dock_update_requested)
	_dock.client_action_requested.connect(_on_dock_client_action_requested)
	_dock.client_status_refresh_requested.connect(_on_dock_client_status_refresh_requested)
	_dock.status_snapshot_requested.connect(_on_dock_status_snapshot_requested)
	_dock.live_server_probe_requested.connect(_on_dock_live_server_probe_requested)
	_dock.lifecycle_action_requested.connect(_on_dock_lifecycle_action_requested)
	_dock.dev_server_action_requested.connect(_on_dock_dev_server_action_requested)
	_dock.mcp_logging_changed.connect(_on_dock_mcp_logging_changed)
	_dock.log_snapshot_requested.connect(_on_dock_log_snapshot_requested)
	_dock.plugin_reload_requested.connect(_on_dock_plugin_reload_requested)
	_dock.settings_apply_requested.connect(_on_dock_settings_apply_requested)
	_dock.post_update_action_requested.connect(_on_dock_post_update_action_requested)
	_client_jobs.set_client_health_blocked(_client_health_is_blocked())
	_publish_dock_status_snapshots()
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)
	_dock.present_client_work_snapshot(_client_jobs.snapshot())
	_startup_trace_phase("dock_attached")
	## Activation barrier: no process, socket, or probe effect begins until all
	## owners and the replaceable Dock have been constructed and wired.
	var resolved_policy := _endpoint_policy.duplicate(true)
	resolved_policy["ws_port"] = _resolve_ws_port(int(resolved_policy.ws_port))
	_set_endpoint_policy(resolved_policy)
	## #691: publish every environment/setting value before the first worker.
	ClientConfigurator.warm_env_snapshot(_endpoint_policy)
	_lifecycle.configure(_capture_lifecycle_plan())
	_begin_startup_release()


func _client_health_is_blocked() -> bool:
	return ServerStateScript.blocks_client_health(
		int(_lifecycle.get_status_dict().get("state", ServerStateScript.UNINITIALIZED))
	)


func _on_dock_client_action_requested(client_id: String, action: String) -> void:
	if _client_jobs == null:
		return
	if not _client_jobs.request_action(client_id, action) and _dock != null:
		_dock.present_client_work_snapshot(_client_jobs.snapshot())


func _on_dock_client_status_refresh_requested(client_ids: Array[String], force: bool) -> void:
	if _client_jobs == null:
		return
	_client_jobs.set_client_health_blocked(_client_health_is_blocked())
	_client_jobs.request_status_refresh(client_ids, force)


func _on_client_work_snapshot_changed(snapshot: Dictionary) -> void:
	if _dock != null:
		_dock.present_client_work_snapshot(snapshot)


func _on_client_status_refresh_completed(results: Dictionary) -> void:
	if _dock != null:
		_dock.present_client_status_refresh_results(results)


func _on_mcp_client_status_completed(
	request_ids: Array[String], payload: Dictionary
) -> void:
	if _connection == null:
		return
	for request_id in request_ids:
		_connection.send_deferred_response(request_id, payload)


func _on_mcp_client_action_completed(request_id: String, payload: Dictionary) -> void:
	if _connection != null:
		_connection.send_deferred_response(request_id, payload)


func _on_client_action_completed(
	client_id: String, action: String, result: Dictionary, prewarm: Dictionary
) -> void:
	if _dock != null:
		_dock.present_client_action_result(client_id, action, result, prewarm)


func _on_client_action_timed_out(client_id: String, action: String, detail: String) -> void:
	if _dock != null:
		_dock.present_client_action_timeout(client_id, action, detail)


func _transport_snapshot_for_dock() -> Dictionary:
	if _connection == null:
		return {"connected": false, "server_version": "", "status": {}}
	return {
		"connected": _connection.is_connected,
		"server_version": _connection.server_version,
		"status": _connection.get_transport_status(),
	}


func _lifecycle_snapshot_for_dock() -> Dictionary:
	if _lifecycle == null:
		return {
			"state": ServerStateScript.UNINITIALIZED,
			"server_pid": -1,
			"resolved_ws_port": _resolved_ws_port,
			"can_restart_managed": false,
			"can_recover_incompatible": false,
			"normal_start_released": _normal_start_released,
		}
	var snapshot: Dictionary = _lifecycle.get_status_dict().duplicate(true)
	snapshot["server_pid"] = _lifecycle.get_server_pid()
	snapshot["resolved_ws_port"] = _resolved_ws_port
	snapshot["can_restart_managed"] = (
		_normal_start_released and _lifecycle.can_restart_managed_server()
	)
	snapshot["can_recover_incompatible"] = (
		_normal_start_released and bool(snapshot.get("can_recover_incompatible", false))
	)
	snapshot["normal_start_released"] = _normal_start_released
	return snapshot


func _publish_dock_status_snapshots() -> void:
	if _dock == null:
		return
	_dock.present_transport_snapshot(_transport_snapshot_for_dock())
	_dock.present_lifecycle_snapshot(_lifecycle_snapshot_for_dock())


func _on_dock_status_snapshot_requested() -> void:
	_publish_dock_status_snapshots()


func _on_dock_live_server_probe_requested(port: int) -> void:
	if _dock != null:
		_dock.present_live_server_probe_result(
			ServerLifecycleManager.probe_live_server_status(
				port, ServerLifecycleManager.DEFAULT_PROBE_TIMEOUT_MS,
				str(_endpoint_policy.get("capability_path", ""))
			)
		)


func _on_dock_lifecycle_action_requested(action: int) -> void:
	if not _normal_start_released:
		if _dock != null:
			_dock.present_lifecycle_action_result(false)
		_publish_dock_status_snapshots()
		return
	var accepted := false
	match action:
		Dock.LifecycleAction.RECOVER_INCOMPATIBLE:
			accepted = bool(await recover_incompatible_server())
		Dock.LifecycleAction.RESTART_SERVER:
			accepted = force_restart_server()
	if _dock != null:
		_dock.present_lifecycle_action_result(accepted)
	_publish_dock_status_snapshots()


func _on_dock_dev_server_action_requested(action: int) -> void:
	if action != Dock.DevServerAction.STOP and not _normal_start_released:
		_publish_dock_status_snapshots()
		return
	match action:
		Dock.DevServerAction.START_OR_RESTART:
			if _telemetry != null:
				_telemetry.record_dev_server_toggle("start")
			restart_or_start_managed_server()
		Dock.DevServerAction.STOP:
			if _telemetry != null:
				_telemetry.record_dev_server_toggle("stop")
			stop_managed_server()
	_publish_dock_status_snapshots()


func _on_dock_mcp_logging_changed(enabled: bool) -> void:
	if _dispatcher != null:
		_dispatcher.mcp_logging = enabled
	if _log_buffer != null:
		_log_buffer.enabled = enabled


func _on_dock_log_snapshot_requested(after_sequence: int) -> void:
	if _dock == null or _log_buffer == null:
		return
	var sequence: int = _log_buffer.total_logged()
	var reset: bool = sequence < after_sequence
	var count: int = sequence if reset else maxi(0, sequence - after_sequence)
	_dock.present_log_snapshot({
		"sequence": sequence,
		"reset": reset,
		"lines": _log_buffer.get_recent(count),
	})


func _on_dock_plugin_reload_requested(reason: String) -> void:
	Telemetry.record_pending_plugin_reload(reason)
	_reload_plugin_from_dock.call_deferred()


func _on_dock_settings_apply_requested(changes: Dictionary, reload: bool) -> void:
	var applied := ClientConfigurator.apply_endpoint_settings(changes.duplicate(true))
	if not bool(applied.get("ok", false)):
		push_error("MCP | refused settings change: %s" % str(applied.get("error", "invalid settings")))
		return
	if reload:
		_on_dock_plugin_reload_requested("endpoint_settings")


func _reload_plugin_from_dock() -> void:
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func _on_dock_update_requested() -> void:
	if _update_manager != null and _update_manager.has_install_candidate():
		_update_manager.start_install(_preflight_update())


func _on_update_check_completed(result: Dictionary) -> void:
	if _dock != null:
		_dock.present_update_check(result)


func _on_update_install_state_changed(state: Dictionary) -> void:
	if not bool(state.get("install_in_flight", true)) and _client_jobs != null:
		_client_jobs.resume_after_quiesce()
	if _dock != null:
		_dock.present_update_state(state)


func _on_update_activation_requested(package: Dictionary) -> void:
	install_downloaded_update(package)


## Hold successful activation behind the client-migration barrier. Rollback
## resumes normally after recording its terminal outcome.
func _begin_startup_release() -> void:
	if str(_post_update_outcome.get("outcome", "")) != "success":
		_fan_post_update_outcome()
		_release_normal_startup()
		return
	var started: Dictionary = _client_jobs.begin_post_update_repin(
		str(_post_update_outcome.get("from_version", "")),
		str(_post_update_outcome.get("to_version", "")),
		bool(_post_update_outcome.get(
			"replace_owned_mismatches",
			_post_update_outcome.get("manual_migration", false),
		)),
	)
	if not bool(started.get("ok", false)):
		_present_post_update_barrier_failure(str(started.get("error", "Client migration could not start.")))
		return
	_post_update_action = ""
	if _dock != null:
		_dock.present_update_state({
			"install_in_flight": true,
			"button_text": "Migrating client configuration…",
			"button_disabled": true,
			"label_text": "The server remains stopped until configured clients are repinned.",
			"banner_visible": true,
			"post_update_action": "",
		})


func _on_post_update_repin_completed(result: Dictionary) -> void:
	if str(_post_update_outcome.get("outcome", "")) != "success":
		return
	if not bool(result.get("ok", false)):
		_present_post_update_barrier_failure(str(result.get("error", "Client migration failed.")))
		return
	## A click cannot prove that an external client restarted. The enforceable
	## boundary is the one we own: repin its configuration, durably acknowledge
	## the exact activated tree, then start and authenticate that server. Clients
	## reconnect to the stable endpoint; a stale client can still be restarted as
	## remediation, but it must not hold a healthy installation behind ceremony.
	_complete_post_update_startup()


func _present_post_update_barrier_failure(error: String) -> void:
	_post_update_action = "retry"
	push_error("MCP | post-update client migration blocked startup: %s" % error)
	if _dock != null:
		_dock.present_update_state({
			"install_in_flight": false,
			"button_text": "Retry client migration",
			"button_disabled": false,
			"label_text": "Server startup is blocked: %s" % error,
			"banner_visible": true,
			"post_update_action": "retry",
		})


func _on_dock_post_update_action_requested(action: String) -> void:
	if action != _post_update_action:
		return
	if action == "retry":
		_begin_startup_release()


func _present_post_update_complete() -> void:
	_post_update_action = ""
	if _dock != null:
		_dock.present_update_state({
			"install_in_flight": false,
			"button_text": "Update complete",
			"button_disabled": true,
			"label_text": "",
			"banner_visible": false,
			"post_update_action": "",
			"outcome": "success",
		})


func _complete_post_update_startup() -> void:
	if not _start_post_update_completion():
		_present_post_update_barrier_failure(
			"The transaction actor could not durably complete client migration."
		)
		return
	return


func _start_post_update_completion() -> bool:
	if _update_actor_thread != null:
		return false
	var command: Array[String] = []
	command.assign(_post_update_actor_command)
	var transaction := str(_post_update_outcome.get("transaction", ""))
	if command.is_empty() or transaction.is_empty():
		return false
	var manual := bool(_post_update_outcome.get("manual_migration", false))
	var arguments: Array[String] = [
		"complete-manual-migration" if manual else "complete-migration"
	]
	arguments.append_array(_transaction_identity_arguments())
	if not manual:
		var recovery_root := str(_post_update_outcome.get("recovery_root", ""))
		if recovery_root.is_empty():
			return false
		arguments.append_array([
			"--recovery-root", recovery_root,
			"--transaction", transaction,
		])
	_set_update_startup_cancelled(false)
	_update_actor_thread = Thread.new()
	_update_actor_job = "migration_completion"
	var error := int(_update_actor_thread.start(
		Callable(self, "_run_post_update_completion_job").bind({
			"arguments": arguments,
			"command": command,
			"expected_actor_version": _post_update_actor_version,
			"transaction": transaction,
		}, Callable(self, "_update_startup_cancel_requested"))
	))
	if error != OK:
		_update_actor_thread = null
		_update_actor_job = ""
		return false
	if _dock != null:
		_dock.present_update_state({
			"install_in_flight": true,
			"button_text": "Recording completed migration…",
			"button_disabled": true,
			"label_text": "The server remains stopped until migration completion is durable.",
			"banner_visible": true,
			"post_update_action": "",
		})
	set_process(true)
	return true


static func _run_post_update_completion_job(
	job: Dictionary,
	cancel_check: Callable,
) -> Dictionary:
	var command: Array[String] = []
	command.assign(job.get("command", []))
	var arguments: Array[String] = []
	arguments.assign(job.get("arguments", []))
	var checked := _execute_update_command_value(
		command,
		arguments,
		str(job.get("expected_actor_version", "")),
		UPDATE_ACTOR_COMMAND_TIMEOUT_MS,
		cancel_check,
	)
	if not bool(checked.get("ok", false)):
		return checked
	if not _migration_completion_matches(
		checked.get("data", {}), str(job.get("transaction", ""))
	):
		return {"ok": false, "error": "transaction actor returned an invalid migration completion"}
	return {"ok": true}


static func _migration_completion_matches(data: Variant, transaction: String) -> bool:
	return (
		data is Dictionary
		and not transaction.is_empty()
		and str(data.get("status", "")) == "migration_complete"
		and str(data.get("transaction", "")) == transaction
	)


## Sole release point for ordinary work and the server lifecycle. Keeping
## these effects together makes the post-update legal ordering reviewable.
func _release_normal_startup() -> void:
	if _normal_start_released:
		return
	_normal_start_released = true
	_client_jobs.set_client_health_blocked(_client_health_is_blocked())
	_client_jobs.activate()
	_update_manager.check_for_updates.call_deferred()
	_start_server()
	_startup_trace_phase("server_start")
	_log_buffer.log("plugin loaded")
	if _telemetry != null:
		_telemetry.record_dock_startup()
		_telemetry.flush_pending_plugin_reload()


## Fan one immutable terminal transaction value. It is held only in this
## instance's memory, never EditorSettings, and is cleared exactly once.
func _fan_post_update_outcome() -> void:
	if _post_update_outcome.is_empty():
		return
	var outcome := str(_post_update_outcome.get("outcome", ""))
	var status := "unknown"
	match outcome:
		"success":
			status = "success"
		"rolled_back":
			status = "failed_clean"
		"repair_required", "quarantined":
			status = "failed_mixed"
	var error := "" if outcome == "success" else outcome.replace("_", " ")
	var from_version := str(_post_update_outcome.get("from_version", ""))
	var to_version := str(_post_update_outcome.get("to_version", ""))
	if _telemetry != null and not bool(_post_update_outcome.get("manual_migration", false)):
		_telemetry.record_self_update(status, from_version, to_version, error)
	_post_update_outcome.clear()
	_post_update_actor_command.clear()
	_post_update_actor_version = ""


func _ensure_update_editor_nonce() -> void:
	var inherited := OS.get_environment(UPDATE_EDITOR_NONCE_ENV)
	if _valid_update_nonce(inherited):
		_update_editor_nonce = inherited
	elif not _valid_update_nonce(_update_editor_nonce):
		_update_editor_nonce = Crypto.new().generate_random_bytes(16).hex_encode()


static func _valid_update_nonce(value: String) -> bool:
	if value.length() < 16 or value.length() > 128:
		return false
	for character in value:
		if not "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-".contains(character):
			return false
	return true


static func _update_roots() -> Dictionary:
	return {
		"project": ProjectSettings.globalize_path("res://").trim_suffix("/"),
		"install": ProjectSettings.globalize_path("res://addons/godot_ai"),
	}


func _execute_update_command(
	arguments: Array[String],
	frozen_command: Array[String] = [],
	expected_package_version: String = "",
	timeout_ms: int = UPDATE_ACTOR_COMMAND_TIMEOUT_MS,
) -> Dictionary:
	if _update_actor_termination_unproven:
		return {
			"ok": false,
			"error": "transaction actor termination is unproven; restart Godot before continuing",
			"termination_unproven": true,
		}
	var command := (
		frozen_command.duplicate()
		if not frozen_command.is_empty()
		else ClientConfigurator.get_update_transaction_command()
	)
	if command.is_empty():
		return {"ok": false, "error": "transaction actor is unavailable"}
	var expected := (
		expected_package_version
		if not expected_package_version.is_empty()
		else ClientConfigurator.get_plugin_version()
	)
	var checked := _execute_update_command_value(
		command,
		arguments,
		expected,
		timeout_ms,
		Callable(),
	)
	if bool(checked.get("termination_unproven", false)):
		_update_actor_termination_unproven = true
	return checked


static func _execute_update_command_value(
	command: Array[String],
	arguments: Array[String],
	expected_package_version: String,
	timeout_ms: int,
	cancel_check: Callable,
) -> Dictionary:
	if command.is_empty():
		return {"ok": false, "error": "transaction actor is unavailable"}
	var process_args: Array[String] = []
	process_args.assign(command.slice(1))
	process_args.append_array(arguments)
	var executed := CliExec.run(
		command[0],
		process_args,
		timeout_ms,
		true,
		cancel_check,
		ClientConfigurator.update_actor_requires_uv_environment_isolation(command),
	)
	if bool(executed.get("termination_failed", false)):
		return {
			"ok": false,
			"error": "transaction actor exceeded its deadline and could not be stopped safely",
			"termination_unproven": true,
		}
	if bool(executed.get("timed_out", false)):
		return {"ok": false, "error": "transaction actor timed out"}
	if bool(executed.get("cancelled", false)):
		return {"ok": false, "error": "transaction actor was cancelled"}
	if bool(executed.get("spawn_failed", false)):
		return {"ok": false, "error": "transaction actor could not be started"}
	if int(executed.get("exit_code", -1)) != 0:
		return {
			"ok": false,
			"error": _update_actor_refusal_message(str(executed.get("stderr", ""))),
		}
	var data: Variant = {}
	var raw := str(executed.get("stdout", "")).strip_edges()
	if not raw.is_empty():
		data = JSON.parse_string(raw)
		if not data is Dictionary:
			return {"ok": false, "error": "transaction actor returned invalid JSON"}
	if not _update_actor_identity_matches(data, expected_package_version):
		return {"ok": false, "error": "transaction actor identity is incompatible"}
	return {"ok": true, "data": data, "command": command.duplicate()}


static func _update_actor_refusal_message(stderr_text: String) -> String:
	## uvx/bootstrap diagnostics may echo credential-bearing index URLs. Reflect
	## only the transaction actor's own stable error envelope, never arbitrary
	## process output, and keep even that line bounded/control-free.
	for raw_line in stderr_text.split("\n"):
		var line := raw_line.strip_edges()
		if (
			not line.begins_with(UPDATE_ACTOR_ERROR_PREFIX)
			or line.to_utf8_buffer().size() > MAX_UPDATE_ACTOR_ERROR_BYTES
		):
			continue
		var safe := true
		for index in line.length():
			var code := line.unicode_at(index)
			if code < 0x20 or code == 0x7f:
				safe = false
				break
		if safe:
			return line
	return "transaction actor or exact-package resolver refused"


static func _update_actor_identity_matches(data: Variant, expected_package: String) -> bool:
	return (
		data is Dictionary
		and not expected_package.is_empty()
		and int(data.get("protocol_version", 0)) == UPDATE_ACTOR_PROTOCOL_VERSION
		and str(data.get("package_version", "")) == expected_package
	)


func _transaction_identity_arguments() -> Array[String]:
	var roots := _update_roots()
	return [
		"--project", str(roots.project),
		"--install", str(roots.install),
		"--editor-pid", str(OS.get_process_id()),
		"--editor-nonce", _update_editor_nonce,
	]


func _prepare_update_startup_barrier() -> Dictionary:
	if not _loaded_update_version_matches(
		_loaded_plugin_version, ClientConfigurator.get_plugin_version()
	):
		return {
			"ok": false,
			"error": "loaded plugin version differs from the current add-on tree",
		}
	var transaction := OS.get_environment(UPDATE_TRANSACTION_ENV)
	var handoff := (
		_parse_update_actor_handoff(
			OS.get_environment(UPDATE_ACTOR_HANDOFF_ENV), transaction, _update_editor_nonce
		)
		if not transaction.is_empty()
		else {}
	)
	var command: Array[String] = []
	if not transaction.is_empty():
		command.assign(handoff.get("command", []))
	if not transaction.is_empty() and command.is_empty():
		return {
			"ok": false,
			"error": "frozen transaction actor unavailable; refusing swapped-tree startup",
		}
	var arguments: Array[String] = ["startup"]
	arguments.append_array(_transaction_identity_arguments())
	if not transaction.is_empty():
		arguments.append_array(["--transaction", transaction])
	var expected_actor_version := str(
		handoff.get("package_version", "")
		if not transaction.is_empty()
		else _loaded_plugin_version
	)
	return {
		"ok": true,
		"arguments": arguments,
		"command": command,
		"current_version": _loaded_plugin_version,
		"discover_command": transaction.is_empty(),
		"expected_actor_version": expected_actor_version,
		"timeout_ms": (
			UPDATE_ACTOR_HANDOFF_TIMEOUT_MS
			if not transaction.is_empty()
			else UPDATE_ACTOR_COLD_START_TIMEOUT_MS
		),
		"transaction": transaction,
	}


func _run_update_startup_barrier_job(
	job: Dictionary,
	cancel_check: Callable = Callable(),
) -> Dictionary:
	var command: Array[String] = []
	command.assign(job.get("command", []))
	if command.is_empty() and bool(job.get("discover_command", false)):
		## Discovery may fork bounded login-shell/which probes. Keep it in this
		## worker for interactive startup; the headless/export caller deliberately
		## runs the same job synchronously because it has no editor UI to freeze.
		command = ClientConfigurator.get_update_transaction_command()
	if command.is_empty():
		return {
			"ok": false,
			"error": "transaction actor unavailable; refusing unleased plugin startup",
		}
	var arguments: Array[String] = []
	arguments.assign(job.get("arguments", []))
	var checked := _execute_update_command_value(
		command,
		arguments,
		str(job.get("expected_actor_version", "")),
		int(job.get("timeout_ms", UPDATE_ACTOR_COLD_START_TIMEOUT_MS)),
		cancel_check,
	)
	if not bool(checked.get("ok", false)):
		return checked
	var outcome: Dictionary = checked.get("data", {})
	var transaction := str(job.get("transaction", ""))
	if not _update_outcome_matches_startup(outcome, transaction):
		return {"ok": false, "error": "transaction actor returned an invalid startup outcome"}
	if transaction.is_empty() and str(outcome.get("status", "")) == "none":
		return {"ok": true, "outcome": {}}
	var current := str(job.get("current_version", ""))
	match str(outcome.get("outcome", "")):
		"success":
			if current != str(outcome.get("to_version", "")):
				return {"ok": false, "error": "successful update outcome targets another version"}
		"rolled_back":
			if current != str(outcome.get("from_version", "")):
				return {"ok": false, "error": "rollback outcome targets another version"}
		_:
			return {"ok": false, "error": "transaction outcome is not startable"}
	return {
		"ok": true,
		"actor_command": checked.get("command", []).duplicate(),
		"actor_version": str(job.get("expected_actor_version", "")),
		"outcome": outcome.duplicate(true),
	}


func _accept_update_startup_result(result: Dictionary) -> bool:
	if bool(result.get("termination_unproven", false)):
		_update_actor_termination_unproven = true
	if not bool(result.get("ok", false)):
		push_error("MCP | update startup refused: %s" % str(result.get("error", "")))
		return false
	var outcome: Dictionary = result.get("outcome", {})
	if not outcome.is_empty():
		_post_update_outcome = outcome.duplicate(true)
		_post_update_actor_command.assign(result.get("actor_command", []))
		_post_update_actor_version = str(result.get("actor_version", ""))
	return true


func _run_update_startup_barrier() -> bool:
	var job := _prepare_update_startup_barrier()
	if not bool(job.get("ok", false)):
		push_error("MCP | update startup refused: %s" % str(job.get("error", "")))
		return false
	return _accept_update_startup_result(_run_update_startup_barrier_job(job))


func _start_update_startup_barrier() -> bool:
	var job := _prepare_update_startup_barrier()
	if not bool(job.get("ok", false)):
		push_error("MCP | update startup refused: %s" % str(job.get("error", "")))
		return false
	_set_update_startup_cancelled(false)
	_update_actor_thread = Thread.new()
	_update_actor_job = "startup"
	var error: int = int(_update_actor_thread.start(
		Callable(self, "_run_update_startup_barrier_job").bind(
			job,
			Callable(self, "_update_startup_cancel_requested"),
		)
	))
	if error != OK:
		_update_actor_thread = null
		_update_actor_job = ""
		push_error("MCP | update startup worker could not start")
		return false
	set_process(true)
	print("MCP | checking the bounded update startup barrier in the background")
	return true


func _set_update_startup_cancelled(cancelled: bool) -> void:
	_update_startup_cancel_mutex.lock()
	_update_startup_cancelled = cancelled
	_update_startup_cancel_mutex.unlock()


func _update_startup_cancel_requested() -> bool:
	_update_startup_cancel_mutex.lock()
	var cancelled := _update_startup_cancelled
	_update_startup_cancel_mutex.unlock()
	return cancelled


func _cancel_update_actor_thread() -> void:
	if _update_actor_thread == null:
		return
	_set_update_startup_cancelled(true)
	var result: Variant = _update_actor_thread.wait_to_finish()
	_update_actor_thread = null
	_update_actor_job = ""
	if result is Dictionary and bool(result.get("termination_unproven", false)):
		_update_actor_termination_unproven = true


func _block_update_startup() -> void:
	_update_barrier_blocked = true
	push_error("MCP | update recovery barrier blocked plugin startup")
	_disable_after_update_barrier.call_deferred()


static func _update_outcome_matches_startup(outcome: Dictionary, transaction: String) -> bool:
	if transaction.is_empty():
		var status := str(outcome.get("status", ""))
		return (
			status == "none"
			or (
				status == "migration_pending"
				and not str(outcome.get("transaction", "")).is_empty()
			)
		)
	return (
		str(outcome.get("status", "")) == "claimed"
		and str(outcome.get("transaction", "")) == transaction
	)


static func _loaded_update_version_matches(loaded: String, on_disk: String) -> bool:
	return not loaded.is_empty() and loaded == on_disk


static func _parse_update_actor_handoff(
	raw: String, transaction: String, editor_nonce: String
) -> Dictionary:
	## The old, already-running actor owns the entire durable reducer across a
	## v4 swap. New code only consumes this bounded versioned command envelope,
	## so startup never resolves/downloads the new Python package mid-transaction.
	if raw.is_empty() or raw.length() > 8192:
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	if not parsed is Dictionary or (parsed as Dictionary).size() != 6:
		return {}
	if (
		int(parsed.get("schema_version", 0)) != UPDATE_ACTOR_HANDOFF_SCHEMA
		or int(parsed.get("protocol_version", 0)) != UPDATE_ACTOR_PROTOCOL_VERSION
		or str(parsed.get("package_version", "")).is_empty()
		or str(parsed.get("transaction", "")) != transaction
		or str(parsed.get("editor_nonce", "")) != editor_nonce
	):
		return {}
	var values: Variant = parsed.get("command", [])
	if not values is Array or values.is_empty() or values.size() > 32:
		return {}
	var command: Array[String] = []
	for value in values:
		if not value is String or value.is_empty() or value.length() > 2048:
			return {}
		for index in value.length():
			var code: int = value.unicode_at(index)
			if code < 0x20 or code == 0x7f:
				return {}
		command.append(value)
	if not command[0].is_absolute_path():
		return {}
	return {
		"command": command,
		"package_version": str(parsed.package_version),
		"protocol_version": UPDATE_ACTOR_PROTOCOL_VERSION,
	}


func _disable_after_update_barrier() -> void:
	## An editor without the transaction actor cannot publish a trustworthy
	## cross-editor lease. Remove the blocked shell as well as withholding all
	## owners/update UI, so another editor never swaps beneath an active plugin.
	if _update_barrier_blocked:
		print("MCP | disabling plugin after update barrier refusal")
		EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)


func _preflight_update() -> Dictionary:
	var download_id := "download-" + Crypto.new().generate_random_bytes(16).hex_encode()
	var arguments: Array[String] = ["lease", "preflight"]
	arguments.append_array(_transaction_identity_arguments())
	arguments.append_array(["--download-id", download_id])
	var checked := _execute_update_command(arguments)
	var data: Dictionary = checked.get("data", {})
	var recovery_root := str(data.get("recovery_root", "")).replace("\\", "/").trim_suffix("/")
	var download_root := str(data.get("download_root", "")).replace("\\", "/").trim_suffix("/")
	var expected_root := recovery_root.path_join("downloads").path_join(download_id)
	var accepted := (
		bool(checked.get("ok", false))
		and not recovery_root.is_empty()
		and download_root == expected_root
	)
	return {
		"ok": accepted,
		"error": (
			str(checked.get("error", ""))
			if not bool(checked.get("ok", false))
			else "transaction actor returned an unbound download directory"
		),
		"download_root": download_root if accepted else "",
	}


func _release_update_lease() -> void:
	if (
		_update_editor_nonce.is_empty()
		or _update_actor_termination_unproven
		or not OS.get_environment(UPDATE_TRANSACTION_ENV).is_empty()
	):
		return
	var arguments: Array[String] = ["lease", "release"]
	arguments.append_array(_transaction_identity_arguments())
	_execute_update_command(arguments, [], "", UPDATE_ACTOR_RELEASE_TIMEOUT_MS)


func _exit_tree() -> void:
	if _unsupported_engine:
		return
	_cancel_update_actor_thread()
	set_process(false)
	## Registered before the headless guard in _enter_tree, so it must be
	## removed before the headless early-return here too.
	if _export_plugin != null:
		remove_export_plugin(_export_plugin)
		_export_plugin = null

	if _headless_disabled:
		_release_update_lease()
		_headless_disabled = false
		## Ported from upstream PR #936 at
		## 537a490c865837bedb96042d10ee0fc74673cd99: `_lifecycle` is built in
		## _init(), before the headless guard in _enter_tree() runs, so it exists
		## even on this path — null it here too (full teardown below is skipped).
		_lifecycle = null
		return

	if _update_barrier_blocked:
		_release_update_lease()
		_update_barrier_blocked = false
		_lifecycle = null
		return

	## Client work has plugin lifetime, independent of the Dock. Realize every
	## thread before either owner script can be reloaded or freed.
	if _client_jobs != null:
		_client_jobs.quiesce()

	if _custom_tool_registry != null:
		_custom_tool_registry.clear()
		_custom_tool_registry = null

	_custom_tool_service_locator = null

	## Outer-to-inner teardown. Dispatcher Callables hold RefCounted handlers
	## alive past the point where Godot reloads their class_name scripts — the
	## first post-reload call into a typed-array-holding handler (e.g.
	## McpGameLogBuffer._storage) then SIGSEGVs against a stale class descriptor.
	## See issue #46.

	# Stop inbound work first so _process can't enqueue new commands or
	# null-deref log_buffer on the next tick mid-teardown.
	if _connection:
		_connection.teardown()

	if _vision_routing:
		_vision_routing.shutdown()
		_vision_routing = null
	# Transport is stopped and both worker owners have joined. Release the
	# ordinary plugin-lifetime graph; this is not the stronger hot script-swap
	# authorization (prepare_for_update_reload still requires clear()).
	if _dispatcher:
		_dispatcher.release_after_teardown()

	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _update_manager:
		_update_manager.cancel_install()
		_update_manager.queue_free()
		_update_manager = null
	if _client_jobs:
		_client_jobs.queue_free()
		_client_jobs = null
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

	## Teardown follows the immutable launch plan: keep-on-exit or an active
	## lease detaches; otherwise the exact owned-process grant is stopped.
	_lifecycle.teardown_for_editor_exit()
	_lifecycle = null
	print("MCP | plugin unloaded")
	## Keep the cross-editor lease until every worker is joined, every
	## plugin-script-holding owner is gone, and teardown has emitted its final
	## diagnostic. This must remain the last effect in the normal exit path.
	_release_update_lease()


func _process(_delta: float) -> void:
	if _update_actor_thread != null and not _update_actor_thread.is_alive():
		var result: Variant = _update_actor_thread.wait_to_finish()
		var job := _update_actor_job
		_update_actor_thread = null
		_update_actor_job = ""
		if job == "migration_completion":
			if result is Dictionary and bool(result.get("termination_unproven", false)):
				_update_actor_termination_unproven = true
			if not result is Dictionary or not bool(result.get("ok", false)):
				_present_post_update_barrier_failure(
					str(result.get("error", "Migration completion failed."))
					if result is Dictionary
					else "Migration completion failed."
				)
				return
			print("MCP | client migration durably completed")
			_present_post_update_complete()
			_fan_post_update_outcome()
			_release_normal_startup()
			return
		if job != "startup":
			_block_update_startup()
			return
		set_process(false)
		if not result is Dictionary or not _accept_update_startup_result(result):
			_block_update_startup()
			return
		_continue_enter_tree_after_update_barrier()
		return
	if _vision_routing != null:
		_vision_routing.poll_completed()


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
	if not _normal_start_released:
		push_error("MCP | server start refused before normal startup release")
		return
	_lifecycle.start_server()


func _capture_lifecycle_plan() -> Dictionary:
	var policy := _endpoint_policy.duplicate(true)
	var http_port := int(policy.get("http_port", ClientConfigurator.DEFAULT_HTTP_PORT))
	var worktree_src := ""
	if ClientConfigurator.is_dev_checkout():
		worktree_src = ClientConfigurator.find_worktree_src_dir(
			ProjectSettings.globalize_path("res://")
		)
	return {
		"http_port": http_port,
		"capability_path": str(policy.get("capability_path", "")),
		"ws_port": int(policy.get("ws_port", ClientConfigurator.DEFAULT_WS_PORT)),
		"expected_version": ClientConfigurator.get_plugin_version(),
		"server_command": ClientConfigurator.get_server_command(),
		"pid_file": ProjectSettings.globalize_path(PortResolver.SERVER_PID_FILE),
		"http_port_reserved": WindowsPortReservation.is_port_excluded(http_port),
		"excluded_domains": str(policy.get("excluded_domains", "")),
		"allow_hosts": str(policy.get("allow_hosts", "")),
		"keep_alive": bool(policy.get("keep_alive", false)),
		"worktree_src": worktree_src,
		"ambient_pythonpath": OS.get_environment("PYTHONPATH"),
		"disable_telemetry": not bool(policy.get("telemetry_enabled", true)),
		"automatic_effects": true,
		"defer_effects": true,
	}


static func _supports_godot_version(version_info: Dictionary) -> bool:
	var major := int(version_info.get("major", 0))
	var minor := int(version_info.get("minor", 0))
	return major == MIN_GODOT_MAJOR and minor >= MIN_GODOT_MINOR


func _on_lifecycle_snapshot_changed(snapshot: Dictionary) -> void:
	if _connection != null and bool(snapshot.get("connection_blocked", true)):
		_connection.connect_blocked = true
		_connection.connect_block_reason = str(snapshot.get("message", ""))
	if _client_jobs != null:
		_client_jobs.set_client_health_blocked(
			ServerStateScript.blocks_client_health(
				int(snapshot.get("state", ServerStateScript.UNINITIALIZED))
			)
		)
	_publish_dock_status_snapshots()


func _on_lifecycle_transport_ready(ws_port: int, ws_capability: String) -> void:
	_set_resolved_ws_port(ws_port)
	if _client_jobs != null:
		_client_jobs.set_client_health_blocked(false)
		_client_jobs.request_status_refresh(ClientConfigurator.client_ids(), true)
	if _connection != null:
		_connection.authorize_transport(ws_port, ws_capability)
	_publish_dock_status_snapshots()


func _on_lifecycle_transport_cleared(reason: String) -> void:
	if _connection != null:
		_connection.revoke_transport(reason)
	_publish_dock_status_snapshots()


## Snapshot of the server-spawn outcome for the dock.
##
## `state` is one of the `McpServerState.*` int constants; the dock owns
## the UI copy per state via its own `_crash_body_for_state`. `exit_ms`
## is only meaningful for `CRASHED`.
func get_server_status() -> Dictionary:
	return _lifecycle.get_status_dict()


## Diagnostic accessor for the Dock. Positive means this lifecycle owns an
## exact process grant; adoption always reports -1 and cannot authorize stop.
func get_server_pid() -> int:
	return _lifecycle.get_server_pid()


func get_resolved_ws_port() -> int:
	return _resolved_ws_port


func _set_resolved_ws_port(port: int) -> void:
	var policy := _endpoint_policy.duplicate(true)
	if policy.is_empty():
		policy = ClientConfigurator.capture_endpoint_policy(port)
	policy["ws_port"] = port
	_set_endpoint_policy(policy)
	if _connection != null:
		_connection.ws_port = port


func _set_endpoint_policy(policy: Dictionary) -> void:
	_endpoint_policy = policy.duplicate(true)
	_resolved_ws_port = int(_endpoint_policy.get(
		"ws_port", ClientConfigurator.DEFAULT_WS_PORT
	))
	ClientConfigurator.capture_launch_context(_endpoint_policy)


func _resolve_ws_port(configured_port: int) -> int:
	return PortResolver.resolve_ws_port(
		configured_port,
		ClientConfigurator.MAX_PORT,
		_log_buffer,
	)


func prepare_for_update_reload() -> Dictionary:
	## Refuse while frame-yielding work is still live, before stopping any
	## owner. These probes are non-mutating; retry after the work completes.
	if _dispatcher != null:
		var handlers_ready: Dictionary = _dispatcher.quiesce_for_script_swap()
		if not bool(handlers_ready.get("ok", false)):
			return handlers_ready
	if _debugger_plugin != null:
		var debugger_ready: Dictionary = _debugger_plugin.quiesce_for_script_swap()
		if not bool(debugger_ready.get("ok", false)):
			return debugger_ready
	## Stop the exact managed process only after the non-mutating probes.
	var lifecycle_quiesced: Dictionary = _lifecycle.prepare_for_update_reload()
	if not bool(lifecycle_quiesced.get("ok", false)):
		return lifecycle_quiesced
	if _vision_routing != null:
		_vision_routing.shutdown()
	if _dispatcher != null:
		var quiesced: Dictionary = _dispatcher.quiesce_for_script_swap()
		if not bool(quiesced.get("ok", false)):
			quiesced["reload_required"] = true
			return quiesced
		var cleared: Dictionary = _dispatcher.clear()
		if not bool(cleared.get("ok", false)):
			cleared["reload_required"] = true
			return cleared
	return {"ok": true}


## Authenticate and stage while the old plugin is fully live. Only after that
## succeeds do we quiesce and detach a value-only coordinator. The coordinator
## survives disable because it is parented under the editor, but its already-
## compiled script never reads or writes the tree the Python actor swaps.
func install_downloaded_update(package: Dictionary) -> void:
	_ensure_update_editor_nonce()
	var command := ClientConfigurator.get_update_transaction_command()
	if command.is_empty():
		_on_update_install_state_changed({
			"install_in_flight": false,
			"button_text": "Update blocked — transaction actor unavailable",
			"button_disabled": false,
		})
		return
	var transaction := Crypto.new().generate_random_bytes(16).hex_encode()
	var roots := _update_roots()
	var arguments: Array[String] = [
		"prepare",
		"--archive", str(package.get("archive", "")),
		"--manifest", str(package.get("manifest", "")),
		"--signature", str(package.get("signature", "")),
		"--project", str(roots.project),
		"--install", str(roots.install),
		"--transaction", transaction,
		"--channel", str(package.get("channel", "")),
		"--tag", str(package.get("tag", "")),
		"--version", str(package.get("version", "")),
		"--source", str(package.get("source", "")),
		"--editor-pid", str(OS.get_process_id()),
		"--editor-nonce", _update_editor_nonce,
	]
	var checked := _execute_update_command(arguments, command)
	if _update_manager != null:
		_update_manager.discard_downloads()
	if not bool(checked.get("ok", false)):
		_on_update_install_state_changed({
			"install_in_flight": false,
			"button_text": "Update verification failed",
			"button_disabled": false,
		})
		push_error("MCP | signed update refused: %s" % str(checked.get("error", "")))
		return
	var prepared: Dictionary = checked.get("data", {})
	prepared.merge({
		"project_root": str(roots.project),
		"install_root": str(roots.install),
		"from_version": ClientConfigurator.get_plugin_version(),
		"to_version": str(package.get("version", "")),
	}, true)
	if _client_jobs != null:
		var jobs_quiesced: Dictionary = _client_jobs.quiesce(
			Time.get_ticks_msec() + ClientConfigurator.PREWARM_TIMEOUT_MS
		)
		if not bool(jobs_quiesced.get("ok", false)):
			_abort_prepared_update(prepared, command)
			push_error("MCP | client workers refused update quiescence")
			return
	var script_quiesced := prepare_for_update_reload()
	if not bool(script_quiesced.get("ok", false)):
		_abort_prepared_update(prepared, command)
		if bool(script_quiesced.get("reload_required", false)):
			_reload_plugin_after_failed_update.call_deferred()
		push_error("MCP | command workers refused update quiescence")
		return
	_on_update_install_state_changed({
		"install_in_flight": true,
		"button_text": "Activating verified update…",
		"button_disabled": true,
	})
	var coordinator = UpdateCoordinator.new()
	var parent: Node = EditorInterface.get_base_control()
	if parent == null:
		parent = get_tree().root
	parent.add_child(coordinator)
	coordinator.start(prepared, command, _update_editor_nonce)


func _reload_plugin_after_failed_update() -> void:
	## The signed prepared tree was aborted before mutation. Reconstruct the
	## unchanged old composition if any later quiescence step had already
	## stopped vision or released handler references.
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func _abort_prepared_update(prepared: Dictionary, command: Array[String]) -> bool:
	var arguments: Array[String] = [
		"abort-prepared",
		"--project", str(prepared.project_root),
		"--install", str(prepared.install_root),
		"--recovery-root", str(prepared.recovery_root),
		"--transaction", str(prepared.transaction),
		"--editor-pid", str(OS.get_process_id()),
		"--editor-nonce", _update_editor_nonce,
	]
	var checked := _execute_update_command(arguments, command)
	_on_update_install_state_changed({
		"install_in_flight": false,
		"button_text": (
			"Update cancelled safely"
			if bool(checked.get("ok", false))
			else "Update blocked — cleanup required"
		),
		"button_disabled": false,
	})
	return bool(checked.get("ok", false))


func can_recover_incompatible_server() -> bool:
	return _normal_start_released and _lifecycle.can_recover_incompatible_server()


func recover_incompatible_server(_user_initiated: bool = true, _stale_version: String = "") -> bool:
	## The Dock click is the sole source of replacement authority. The manager
	## binds, spends, and discards one authorization for this exact target.
	if not _normal_start_released:
		return false
	return _lifecycle.request_replacement()


## Managed restart uses the exact owned grant. An unowned incompatible server
## can only reach replacement through the separate explicit Dock intent.
func force_restart_server() -> bool:
	if not _normal_start_released:
		return false
	return _lifecycle.force_restart_server()


## Developer controls use the same lifecycle owner as ordinary startup. The
## plugin may restart only its exact process grant; a compatible external
## server is adopted for transport but remains the launcher's responsibility.
func restart_or_start_managed_server() -> bool:
	if not _normal_start_released:
		return false
	if has_managed_server():
		_lifecycle.force_restart_server()
		return true
	var port := ClientConfigurator.http_port()
	if PortResolver.is_port_in_use(port):
		push_warning(
			"MCP | refusing to restart the unowned server on port %d; stop it from its launcher"
			% port
		)
		return false
	_lifecycle.start_server()
	return true


func stop_managed_server() -> void:
	if has_managed_server():
		_lifecycle.stop_server()


func has_managed_server() -> bool:
	## Returns true if the plugin is currently managing a server process it spawned.
	return _lifecycle.has_managed_server()


func can_restart_managed_server() -> bool:
	## Restart needs an owned grant or a currently replaceable blocked target.
	return _normal_start_released and _lifecycle.can_restart_managed_server()


func _on_custom_tools_changed() -> void:
	if _connection == null:
		push_warning("MCP | connection isn't established")
		return
	var tool_list: Array[Dictionary] = []
	## Send all definitions plus their state: the server hides disabled tools
	## from fresh tools/list responses but retains a callable tombstone so a
	## client using a cached promoted name receives CUSTOM_TOOL_DISABLED.
	for spec in _custom_tool_registry.all():
		tool_list.append({
			"name": spec.name,
			"description": spec.description,
			"params_schema": spec.params_schema,
			"source": spec.source,
			"deferred": spec.deferred,
			"timeout_ms": spec.timeout_ms,
			"requires_writable": spec.requires_writable,
			"undoable": spec.undoable,
			"promoted": spec.promoted,
			"enabled": _custom_tool_registry.is_tool_enabled(spec.name)
		})
	_connection.send_event("custom_tools_changed", {"tools": tool_list})


## On (re)connect, replay the current custom-tool catalog so tools
## registered before the initial connection or during a disconnect
## window reach the server. send_event silently drops while
## _connected is false (connection.gd::_send_json), so without this
## replay those tools only surface on the next registry mutation.
func _on_connection_state_changed(is_open: bool) -> void:
	if is_open:
		_lifecycle.transport_authenticated(_connection.server_version)
		if _custom_tool_registry != null:
			_on_custom_tools_changed()
	else:
		_lifecycle.transport_lost()
