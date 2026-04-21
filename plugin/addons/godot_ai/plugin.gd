@tool
extends EditorPlugin

const GAME_HELPER_AUTOLOAD_NAME := "_mcp_game_helper"
const GAME_HELPER_AUTOLOAD_PATH := "res://addons/godot_ai/runtime/game_helper.gd"

## EditorSettings keys used to remember which server process the plugin
## spawned — survives editor restarts, lets a later editor session adopt
## and manage a server it didn't spawn itself. See #135.
const MANAGED_SERVER_PID_SETTING := "godot_ai/managed_server_pid"
const MANAGED_SERVER_VERSION_SETTING := "godot_ai/managed_server_version"

## The Python server writes its own PID here on startup (passed as
## `--pid-file`) and unlinks on clean exit. Deterministic replacement
## for scraping `netstat -ano` to find the port owner — especially on
## Windows where `OS.kill` on the uvx launcher doesn't take the Python
## child with it, and the scrape was the only path to the real PID.
## See issue for #154-era Windows update friction.
const SERVER_PID_FILE := "user://godot_ai_server.pid"

## How long we keep the spawned server's stdout/stderr pipes open and poll
## for early exit. If the process is still alive when this expires, we
## stop watching and close pipes. Crashes after this point get caught by
## the usual disconnect flow.
const SERVER_WATCH_MS := 30 * 1000
## Only keep the last N captured lines — more than enough for a Python
## traceback, small enough to render comfortably in the dock.
const SERVER_OUTPUT_MAX_LINES := 40

var _connection: Connection
var _dispatcher: McpDispatcher
var _log_buffer: McpLogBuffer
var _game_log_buffer: GameLogBuffer
var _dock: McpDock
var _server_pid := -1
var _handlers: Array = []  # prevent GC of RefCounted handlers
var _debugger_plugin: McpDebuggerPlugin
static var _server_started_this_session := false  # guard against re-entrant spawns

## Captured state for server-spawn supervision (see _start_server_watch).
## Populated only when WE spawn the process — adopt / foreign-server
## branches leave these empty.
var _server_stdio: FileAccess = null
var _server_stderr: FileAccess = null
var _server_spawn_ms: int = 0
var _server_output: PackedStringArray = PackedStringArray()
var _server_crashed: bool = false
var _server_exit_ms: int = 0
var _server_watch_timer: Timer = null
## True when the spawn path detected Windows had excluded our port BEFORE
## we tried to bind. Dock surfaces a pointed hint in this case rather
## than waiting for the inevitable WinError 10013.
var _server_port_excluded: bool = false


func _enter_tree() -> void:
	_start_server()

	_log_buffer = McpLogBuffer.new()
	_game_log_buffer = GameLogBuffer.new()
	_dispatcher = McpDispatcher.new(_log_buffer)

	_connection = Connection.new()
	_connection.log_buffer = _log_buffer

	_debugger_plugin = McpDebuggerPlugin.new(_log_buffer, _game_log_buffer)
	add_debugger_plugin(_debugger_plugin)
	_ensure_game_helper_autoload()

	var editor_handler := EditorHandler.new(_log_buffer, _connection, _debugger_plugin, _game_log_buffer)
	var scene_handler := SceneHandler.new(_connection)
	var node_handler := NodeHandler.new(get_undo_redo())
	var project_handler := ProjectHandler.new(_connection)
	var client_handler := ClientHandler.new()
	var script_handler := ScriptHandler.new(get_undo_redo())
	var resource_handler := ResourceHandler.new(get_undo_redo())
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
	var environment_handler := EnvironmentHandler.new(get_undo_redo())
	var texture_handler := TextureHandler.new(get_undo_redo())
	var curve_handler := CurveHandler.new(get_undo_redo())
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

	# Dock panel
	_dock = McpDock.new()
	_dock.name = "Godot AI"
	_dock.setup(_connection, _log_buffer, self)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)

	_log_buffer.log("plugin loaded")


func _exit_tree() -> void:
	## Outer-to-inner teardown. Dispatcher Callables hold RefCounted handlers
	## alive past the point where Godot reloads their class_name scripts — the
	## first post-reload call into a typed-array-holding handler (e.g.
	## GameLogBuffer._storage) then SIGSEGVs against a stale class descriptor.
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

	_dispatcher = null
	_log_buffer = null
	_game_log_buffer = null

	_stop_server()
	## Symmetric with prepare_for_update_reload: the static guard persists
	## across disable/enable within a single editor session, so the re-enabled
	## plugin instance's _start_server would short-circuit and never respawn.
	## Pre-#159 this was masked — the old kill path usually left Python alive
	## and the new instance adopted it on port 8000. Now that _stop_server is
	## deterministic, nothing is left to adopt and the reload hangs.
	_server_started_this_session = false
	print("MCP | plugin unloaded")


## Register the game-side autoload on plugin enable. Runs the helper inside
## the game process so the editor-side debugger plugin can request
## framebuffer captures over EngineDebugger messages. Removed on
## _disable_plugin so disabling the plugin leaves project.godot clean.
func _enable_plugin() -> void:
	_ensure_game_helper_autoload()


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


func _start_server() -> void:
	## Branch on port state + EditorSettings record. The record lets a
	## later editor session recognize and manage a server it didn't spawn
	## itself; treating the stored `version` (not `pid`) as the "is this
	## ours?" signal handles the uvx tier, where the recorded PID is a
	## launcher that has long since exited. See #135 and #137.
	##
	##   port free                            -> spawn fresh, record PID
	##   port in use, record.version matches  -> adopt the port owner
	##                                              (self-heals stale PID)
	##   port in use, record.version drifts   -> kill port owner + respawn
	##                                              (fixes cold-start drift
	##                                              from manual file replace)
	##   port in use, no matching record      -> foreign server, leave alone
	if _server_started_this_session:
		## Guard against re-entrant spawns (e.g. plugin reload during update).
		## The static flag persists across disable/enable cycles within the
		## same editor session, preventing cascading server process creation.
		return

	var port := McpClientConfigurator.SERVER_HTTP_PORT
	var current_version := McpClientConfigurator.get_plugin_version()

	if _is_port_in_use(port):
		var record := _read_managed_server_record()
		if record.version == current_version:
			## Version matches — this port is owned by a server we spawned
			## at some point. Adopt the live port owner, ignoring any stale
			## launcher PID that may still be in the record. Self-heal the
			## record so next session's adopt can fast-path.
			var owner := _find_managed_pid(port)
			if owner > 0:
				_server_pid = owner
				_write_managed_server_record(owner, current_version)
			_server_started_this_session = true
			print("MCP | adopted managed server (PID %d, v%s)" % [_server_pid, current_version])
			return
		if not record.version.is_empty():
			## Version drift — our server but the plugin moved on. Kill
			## the port owner (not the stale launcher PID) and respawn
			## to match the current plugin version.
			print("MCP | managed server v%s does not match plugin v%s, restarting"
				% [record.version, current_version])
			var owner := _find_managed_pid(port)
			if owner > 0:
				OS.kill(owner)
			_clear_managed_server_record()
			_clear_pid_file()
			_wait_for_port_free(port, 3.0)
			## Fall through to spawn.
		else:
			## No record claiming this port — foreign process. Don't touch;
			## the WebSocket handshake will fail if it isn't actually ours
			## and the reconnect loop will surface that.
			_server_started_this_session = true
			print("MCP | foreign server already running on port %d, using existing" % port)
			return

	var server_cmd := McpClientConfigurator.get_server_command()
	if server_cmd.is_empty():
		push_warning("MCP | could not find server command")
		return

	var cmd: String = server_cmd[0]
	var args: Array[String] = []
	args.assign(server_cmd.slice(1))
	args.append_array([
		"--transport", "streamable-http",
		"--port", str(port),
		"--pid-file", ProjectSettings.globalize_path(SERVER_PID_FILE),
	])

	## Wipe any stale pid-file before spawning so a failed launch can't
	## leave last session's PID sitting there for _find_managed_pid to
	## read and act on.
	_clear_pid_file()

	## Proactive Windows port-reservation check. WinError 10013 surfaces as
	## an otherwise-silent spawn-then-exit because nothing owns the port;
	## netstat shows nothing and the dock's reconnect spinner climbs
	## forever. Catch it before we even try. See issue #146.
	_server_port_excluded = WindowsPortReservation.is_port_excluded(port)
	if _server_port_excluded:
		push_warning("MCP | port %d is reserved by Windows (Hyper-V / WSL2 / Docker)" % port)

	## execute_with_pipe captures stdout+stderr so early-exit crashes
	## surface in the dock instead of vanishing into /dev/null. If the
	## process survives the startup grace window we close the pipes in
	## _stop_server_watch() — the typical case.
	var result := OS.execute_with_pipe(cmd, args)
	_server_pid = int(result.get("pid", 0)) if result is Dictionary else 0
	if _server_pid > 0:
		_server_stdio = result.get("stdio") as FileAccess
		_server_stderr = result.get("stderr") as FileAccess
		_server_spawn_ms = Time.get_ticks_msec()
		_server_crashed = false
		_server_exit_ms = 0
		_server_output = PackedStringArray()
		_server_started_this_session = true
		## Record the launcher PID immediately so a same-session
		## prepare_for_update_reload has something to kill. On the next
		## editor start, _start_server's adopt branch self-heals the PID
		## to the actual port owner (uvx's child).
		_write_managed_server_record(_server_pid, current_version)
		print("MCP | started server (PID %d, v%s): %s %s" % [_server_pid, current_version, cmd, " ".join(args)])
		_start_server_watch()
	else:
		push_warning("MCP | failed to start server")


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
	_server_stdio = null
	_server_stderr = null


func _check_server_health() -> void:
	if _server_pid <= 0:
		_stop_server_watch()
		return
	if not _pid_alive(_server_pid) and not _server_crashed:
		_server_crashed = true
		_server_exit_ms = Time.get_ticks_msec() - _server_spawn_ms
		_drain_server_output()
		_log_buffer.log("server exited after %dms" % _server_exit_ms)
		for line in _server_output:
			_log_buffer.log("  | %s" % line)
		_stop_server_watch()
		return
	if Time.get_ticks_msec() - _server_spawn_ms >= SERVER_WATCH_MS:
		## Server survived startup — stop watching and release the pipes
		## so the kernel can reclaim the FDs. Mid-session crashes after
		## this point surface via the WebSocket disconnect path instead.
		_stop_server_watch()


## Drain captured stdout+stderr into _server_output. Only safe to call
## once the child has exited — get_as_text blocks until EOF. Keeps the
## last SERVER_OUTPUT_MAX_LINES lines so the dock can render without
## overflowing.
func _drain_server_output() -> void:
	var lines := PackedStringArray()
	var pipes: Array[FileAccess] = [_server_stdio, _server_stderr]
	for f in pipes:
		if f == null:
			continue
		var text: String = f.get_as_text()
		for line in text.split("\n"):
			var trimmed: String = line.strip_edges(false, true)
			if not trimmed.is_empty():
				lines.append(trimmed)
	if lines.size() > SERVER_OUTPUT_MAX_LINES:
		lines = lines.slice(lines.size() - SERVER_OUTPUT_MAX_LINES)
	_server_output = lines


## Snapshot of spawn-supervision state for the dock. Returns an empty
## Dictionary-shaped payload in the adopt / foreign-server branches
## where we didn't spawn anything ourselves.
func get_server_status() -> Dictionary:
	var port := McpClientConfigurator.SERVER_HTTP_PORT
	var hint := ""
	if _server_port_excluded:
		hint = WindowsPortReservation.port_excluded_hint(port)
	elif _server_crashed:
		hint = WindowsPortReservation.hint_from_output(_server_output, port)
	return {
		"crashed": _server_crashed,
		"output": _server_output,
		"exit_ms": _server_exit_ms,
		"port_excluded": _server_port_excluded,
		"hint": hint,
	}


func _is_port_in_use(port: int) -> bool:
	var output: Array = []
	if OS.get_name() == "Windows":
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code == 0 and output.size() > 0:
			return _parse_windows_netstat_listening(str(output[0]), port)
	else:
		var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
		return exit_code == 0 and output.size() > 0 and not output[0].strip_edges().is_empty()
	return false


## Return the PID currently listening on the given TCP port, or 0 if
## the port is free. Netstat/lsof fallback; callers should prefer
## `_find_managed_pid` which consults the Python-written pid-file first.
##
## Use when the pid-file is missing (pre-#154 server, or the server was
## SIGKILL'd before writing it) to recover the port owner. On Windows
## this parses `netstat -ano` line-by-line — Godot's `OS.execute` pushes
## the whole stdout into `output[0]` as a single string, so an earlier
## implementation that iterated `output` as if each element were a line
## returned a garbage PID (the last whitespace-separated token in the
## entire dump). See parser tests in tests/test_netstat_parser.gd.
func _find_pid_on_port(port: int) -> int:
	var output: Array = []
	if OS.get_name() == "Windows":
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code != 0 or output.is_empty():
			return 0
		return _parse_windows_netstat_pid(str(output[0]), port)
	## POSIX: `lsof -ti:<port> -sTCP:LISTEN` returns only the PID.
	var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
	if exit_code != 0 or output.is_empty():
		return 0
	var pid_str := str(output[0]).strip_edges()
	if pid_str.is_empty() or not pid_str.is_valid_int():
		return 0
	return int(pid_str)


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


## Parse the LISTENING line for `port` in a Windows `netstat -ano`
## dump and return its PID, or 0 if no matching line is found.
##
## netstat prints rows like:
##   TCP    0.0.0.0:8000    0.0.0.0:0    LISTENING    57865
## (whitespace-separated, possibly with leading whitespace). Only rows
## whose local address ends with `:<port>` AND state is `LISTENING`
## qualify — substring-matching `:<port> ` against the whole dump was
## the earlier bug; a remote address happening to include `:8000` would
## false-positive.
static func _parse_windows_netstat_pid(stdout: String, port: int) -> int:
	var port_suffix := ":%d" % port
	for line in stdout.split("\n"):
		var s := line.strip_edges()
		if s.is_empty():
			continue
		var fields := _split_on_whitespace(s)
		## Minimum columns: proto, local, remote, state, pid
		if fields.size() < 5:
			continue
		if fields[3] != "LISTENING":
			continue
		if not fields[1].ends_with(port_suffix):
			continue
		var pid_str := fields[fields.size() - 1]
		if pid_str.is_valid_int():
			return int(pid_str)
	return 0


## True if any row in a Windows `netstat -ano` dump is a LISTENING
## entry for `port`. See `_parse_windows_netstat_pid` for the row
## schema and why substring-matching the whole dump is wrong.
static func _parse_windows_netstat_listening(stdout: String, port: int) -> bool:
	return _parse_windows_netstat_pid(stdout, port) > 0


static func _split_on_whitespace(s: String) -> PackedStringArray:
	## `String.split(" ", false)` only splits on single spaces; netstat
	## columns are separated by runs of spaces (and sometimes tabs).
	## Collapse whitespace manually so PID-column extraction is robust.
	var out: PackedStringArray = []
	var cur := ""
	for i in s.length():
		var c := s.substr(i, 1)
		if c == " " or c == "\t":
			if not cur.is_empty():
				out.append(cur)
				cur = ""
		else:
			cur += c
	if not cur.is_empty():
		out.append(cur)
	return out


## Read the integer PID from SERVER_PID_FILE, or 0 if the file is
## missing/empty/malformed. The file is written by the Python server
## at startup (see --pid-file flag, plumbed in _start_server).
static func _read_pid_file() -> int:
	if not FileAccess.file_exists(SERVER_PID_FILE):
		return 0
	var f := FileAccess.open(SERVER_PID_FILE, FileAccess.READ)
	if f == null:
		return 0
	var content := f.get_as_text().strip_edges()
	f.close()
	if content.is_empty() or not content.is_valid_int():
		return 0
	var pid := int(content)
	return pid if pid > 0 else 0


static func _clear_pid_file() -> void:
	if FileAccess.file_exists(SERVER_PID_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SERVER_PID_FILE))


func _stop_server() -> void:
	_stop_server_watch()
	if _server_pid <= 0:
		return
	## Kill both the process we tracked and the real Python PID if they
	## differ. For direct-spawn tiers (.venv, system CLI) these match
	## and we kill once. For the uvx tier `_server_pid` is the launcher
	## — may be dead (adopted), still installing, or done spawning; on
	## Windows, `OS.kill` is `TerminateProcess` and does NOT walk the
	## child tree, so without an independent read of the real PID the
	## Python child survives and port 8000 stays held. `_find_managed_pid`
	## reads the pid-file the server wrote at startup (deterministic),
	## falling back to netstat/lsof if the file is missing.
	var port := McpClientConfigurator.SERVER_HTTP_PORT
	var killed: Array[int] = []
	if _pid_alive(_server_pid):
		OS.kill(_server_pid)
		killed.append(_server_pid)
	var real_pid := _find_managed_pid(port)
	if real_pid > 0 and not killed.has(real_pid):
		OS.kill(real_pid)
		killed.append(real_pid)
	if not killed.is_empty():
		print("MCP | stopped server (PID %s)" % str(killed))
	_server_pid = -1
	## Brief wait so a follow-up spawn doesn't race a still-closing socket.
	_wait_for_port_free(port, 2.0)
	## Only forget this server if the port is actually free. If the kill
	## failed — e.g. a previous plugin version's buggy netstat parser
	## targeted a bogus PID during the first v1.2.8 → v1.2.9 Update — then
	## clearing the record would route the next _start_server down the
	## "foreign server" branch, which leaves the zombie alone. Preserving
	## the record keeps the next _start_server in the drift branch, which
	## retries the kill with the current (fixed) parser. See issue filed
	## as follow-up to PR #159.
	_finalize_stop_if_port_free(port)


## Clear the managed-server record and pid-file only if `port` is free.
## Returns true when state was cleared. Extracted from `_stop_server` so
## the "preserve on failed kill" contract is independently testable.
func _finalize_stop_if_port_free(port: int) -> bool:
	if _is_port_in_use(port):
		return false
	_clear_managed_server_record()
	_clear_pid_file()
	return true


## True if the given PID corresponds to a live process. Uses POSIX `kill -0`
## (doesn't actually kill — just probes whether the process exists) or the
## Windows tasklist equivalent. Used by _start_server to distinguish a live
## managed server that outlived its editor from a stale EditorSettings
## record pointing at a PID that no longer exists.
func _pid_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if OS.get_name() == "Windows":
		var output: Array = []
		var exit_code := OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"], output, true)
		if exit_code != 0 or output.is_empty():
			return false
		## tasklist returns "INFO: No tasks ..." when the PID doesn't exist,
		## otherwise a CSV row containing the PID. Match on the PID appearing
		## as its own field rather than INFO-string substring.
		for line in output:
			if str(line).find("\"%d\"" % pid) >= 0:
				return true
		return false
	var exit_code := OS.execute("kill", ["-0", str(pid)], [], true)
	return exit_code == 0


## Poll until the given port is no longer bound, or the timeout elapses.
## Used after `OS.kill` in the update-flow restart branch so we don't race
## the port-in-use check when we try to rebind.
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
		return {"pid": 0, "version": ""}
	var pid: int = 0
	if es.has_setting(MANAGED_SERVER_PID_SETTING):
		pid = int(es.get_setting(MANAGED_SERVER_PID_SETTING))
	var version: String = ""
	if es.has_setting(MANAGED_SERVER_VERSION_SETTING):
		version = str(es.get_setting(MANAGED_SERVER_VERSION_SETTING))
	return {"pid": pid, "version": version}


func _write_managed_server_record(pid: int, version: String) -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	es.set_setting(MANAGED_SERVER_PID_SETTING, pid)
	es.set_setting(MANAGED_SERVER_VERSION_SETTING, version)


func _clear_managed_server_record() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if es.has_setting(MANAGED_SERVER_PID_SETTING):
		es.set_setting(MANAGED_SERVER_PID_SETTING, 0)
	if es.has_setting(MANAGED_SERVER_VERSION_SETTING):
		es.set_setting(MANAGED_SERVER_VERSION_SETTING, "")


## Prepare for a plugin-self-update reload cycle: kill the server process
## and reset the re-entrancy guard so the re-enabled plugin spawns a fresh
## server. Without the reset, `_start_server` short-circuits on the static
## flag after the reload — even though we just freed the port — and the
## new plugin ends up talking to whatever process inherited port 8000
## (or, if none exists, the server never starts at all). See #132.
func prepare_for_update_reload() -> void:
	_stop_server()
	_server_started_this_session = false


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
		var inner_args: Array[String] = []
		inner_args.assign(server_cmd.slice(1))
		inner_args.append_array([
			"--transport", "streamable-http",
			"--port", str(McpClientConfigurator.SERVER_HTTP_PORT),
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
	var port := McpClientConfigurator.SERVER_HTTP_PORT
	if OS.get_name() == "Windows":
		# Find PID listening on port, then kill
		var exit_code := OS.execute("cmd", ["/c", "for /f \"tokens=5\" %%a in ('netstat -ano ^| findstr :%d ^| findstr LISTENING') do taskkill /PID %%a /F" % port], output, true)
		if exit_code == 0:
			print("MCP | stopped dev server on port %d" % port)
	else:
		var exit_code := OS.execute("bash", ["-c", "lsof -ti:%d -sTCP:LISTEN | xargs kill 2>/dev/null" % port], output, true)
		if exit_code == 0:
			print("MCP | stopped dev server on port %d" % port)


func is_dev_server_running() -> bool:
	## Returns true if a server is running on the HTTP port that we didn't start as managed.
	return _server_pid <= 0 and _is_port_in_use(McpClientConfigurator.SERVER_HTTP_PORT)


func has_managed_server() -> bool:
	## Returns true if the plugin is currently managing a server process it spawned.
	return _server_pid > 0
