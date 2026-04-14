@tool
extends EditorPlugin

var _connection: Connection
var _dispatcher: McpDispatcher
var _log_buffer: McpLogBuffer
var _dock: McpDock
var _server_pid := -1
var _handlers: Array = []  # prevent GC of RefCounted handlers


func _enter_tree() -> void:
	_start_server()

	_log_buffer = McpLogBuffer.new()
	_dispatcher = McpDispatcher.new(_log_buffer)

	_connection = Connection.new()
	_connection.log_buffer = _log_buffer

	var editor_handler := EditorHandler.new(_log_buffer, _connection)
	var scene_handler := SceneHandler.new(_connection)
	var node_handler := NodeHandler.new(get_undo_redo())
	var project_handler := ProjectHandler.new()
	var client_handler := ClientHandler.new()
	var script_handler := ScriptHandler.new(get_undo_redo())
	var resource_handler := ResourceHandler.new(get_undo_redo())
	var filesystem_handler := FilesystemHandler.new()
	var signal_handler := SignalHandler.new(get_undo_redo())
	var autoload_handler := AutoloadHandler.new()
	var input_handler := InputHandler.new()
	var test_handler := TestHandler.new(get_undo_redo(), _log_buffer)
	var batch_handler := BatchHandler.new(_dispatcher, get_undo_redo())
	_handlers = [editor_handler, scene_handler, node_handler, project_handler, client_handler, script_handler, resource_handler, filesystem_handler, signal_handler, autoload_handler, input_handler, test_handler, batch_handler]

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

	_connection.dispatcher = _dispatcher
	add_child(_connection)

	# Dock panel
	_dock = McpDock.new()
	_dock.name = "Godot AI"
	_dock.setup(_connection, _log_buffer, self)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, _dock)

	_log_buffer.log("plugin loaded")


func _exit_tree() -> void:
	if _dock:
		remove_control_from_docks(_dock)
		_dock.queue_free()
		_dock = null
	if _connection:
		_connection.disconnect_from_server()
		_connection.queue_free()
		_connection = null
	_stop_server()
	print("MCP | plugin unloaded")


func _start_server() -> void:
	## If a server is already listening on our HTTP port, use it.
	## This covers: CI (external server), another Godot instance, or manual start.
	## NOTE: We only check port 8000 (HTTP), not 9500 (WebSocket). If a foreign
	## process holds 8000, we'll assume it's a valid server. The WebSocket
	## connection will fail and retry if the server isn't actually ours.
	if _is_port_in_use(McpClientConfigurator.SERVER_HTTP_PORT):
		print("MCP | server already running on port %d, using existing" % McpClientConfigurator.SERVER_HTTP_PORT)
		return

	var server_cmd := McpClientConfigurator.get_server_command()
	if server_cmd.is_empty():
		push_warning("MCP | could not find server command")
		return

	var cmd: String = server_cmd[0]
	var args: Array[String] = []
	args.assign(server_cmd.slice(1))
	args.append_array(["--transport", "streamable-http", "--port", str(McpClientConfigurator.SERVER_HTTP_PORT)])

	_server_pid = OS.create_process(cmd, args)
	if _server_pid > 0:
		print("MCP | started server (PID %d): %s %s" % [_server_pid, cmd, " ".join(args)])
	else:
		push_warning("MCP | failed to start server")


func _is_port_in_use(port: int) -> bool:
	var output: Array = []
	if OS.get_name() == "Windows":
		var exit_code := OS.execute("netstat", ["-ano"], output, true)
		if exit_code == 0 and output.size() > 0:
			return output[0].find(":%d " % port) >= 0 and output[0].find("LISTENING") >= 0
	else:
		var exit_code := OS.execute("lsof", ["-ti:%d" % port, "-sTCP:LISTEN"], output, true)
		return exit_code == 0 and output.size() > 0 and not output[0].strip_edges().is_empty()
	return false


func _stop_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		print("MCP | stopped server (PID %d)" % _server_pid)
		_server_pid = -1


func start_dev_server() -> void:
	## Start a dev server with --reload that survives plugin reloads.
	## Kills any managed server first, waits for the port to free, then spawns.
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

		var pid := OS.create_process(cmd, inner_args)
		if pid > 0:
			print("MCP | started dev server with --reload (PID %d): %s %s" % [pid, cmd, " ".join(inner_args)])
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
