@tool
extends EditorPlugin

const CONNECTION = preload("res://addons/godot_mcp_studio/connection.gd")
const CONFIGURATOR = preload("res://addons/godot_mcp_studio/client_configurator.gd")

var _connection: Connection
var _server_pid := -1


func _enter_tree() -> void:
	_start_server()
	_connection = CONNECTION.new()
	add_child(_connection)
	print("MCP | plugin loaded")
	_auto_configure_clients.call_deferred()


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


func _auto_configure_clients() -> void:
	for client_type in [
		McpClientConfigurator.ClientType.CLAUDE_CODE,
		McpClientConfigurator.ClientType.ANTIGRAVITY,
	]:
		var display_name: String = McpClientConfigurator.ClientType.keys()[client_type]

		var status := McpClientConfigurator.check_status(client_type)
		if status == McpClientConfigurator.ConfigStatus.CONFIGURED:
			print("MCP | %s: already configured" % display_name)
			continue

		print("MCP | %s: not configured, setting up..." % display_name)
		var result := McpClientConfigurator.configure(client_type)
		if result.get("status") == "ok":
			print("MCP | %s: %s" % [display_name, result.get("message", "configured")])
		else:
			print("MCP | %s: setup failed - %s" % [display_name, result.get("message", "unknown error")])
