@tool
extends McpDebuggerPlugin

## State-machine tests supply synthetic session IDs, not engine-owned debugger
## sessions. Keep the real _setup_session/adoption/capture logic, replacing only
## native signal wiring. Never connect test instances to the editor's debugger UI.
var stopped_connections: Array[int] = []
var break_connections: Array[int] = []


func _connect_session_stopped(session_id: int) -> void:
	stopped_connections.append(session_id)


func _connect_session_break_signals(session_id: int) -> void:
	break_connections.append(session_id)
