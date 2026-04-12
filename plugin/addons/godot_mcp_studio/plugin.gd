@tool
extends EditorPlugin

var _connection: Connection
var _dispatcher: McpDispatcher
var _log_buffer: McpLogBuffer
var _server_pid := -1
var _handlers: Array = []  # prevent GC of RefCounted handlers


func _enter_tree() -> void:
	_start_server()

	_log_buffer = McpLogBuffer.new()
	_dispatcher = McpDispatcher.new(_log_buffer)

	var editor_handler := EditorHandler.new(_log_buffer)
	var scene_handler := SceneHandler.new()
	var node_handler := NodeHandler.new()
	var client_handler := ClientHandler.new()
	_handlers = [editor_handler, scene_handler, node_handler, client_handler]

	_dispatcher.register("get_editor_state", editor_handler.get_editor_state)
	_dispatcher.register("get_scene_tree", scene_handler.get_scene_tree)
	_dispatcher.register("get_selection", editor_handler.get_selection)
	_dispatcher.register("create_node", node_handler.create_node)
	_dispatcher.register("get_logs", editor_handler.get_logs)
	_dispatcher.register("configure_client", client_handler.configure_client)
	_dispatcher.register("check_client_status", client_handler.check_client_status)

	_connection = Connection.new()
	_connection.log_buffer = _log_buffer
	_connection.dispatcher = _dispatcher
	add_child(_connection)

	_log_buffer.log("plugin loaded")


func _exit_tree() -> void:
	if _connection:
		_connection.disconnect_from_server()
		_connection.queue_free()
		_connection = null
	_stop_server()
	print("MCP | plugin unloaded")


func _start_server() -> void:
	var output: Array = []
	var exit_code := OS.execute("lsof", ["-ti:%d" % McpClientConfigurator.SERVER_WS_PORT], output, true)
	if exit_code == 0 and output.size() > 0 and not output[0].strip_edges().is_empty():
		print("MCP | server already running on port %d" % McpClientConfigurator.SERVER_WS_PORT)
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


func _stop_server() -> void:
	if _server_pid > 0:
		OS.kill(_server_pid)
		print("MCP | stopped server (PID %d)" % _server_pid)
		_server_pid = -1
