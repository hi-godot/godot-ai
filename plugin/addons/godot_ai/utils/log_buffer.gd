@tool
class_name McpLogBuffer
extends RefCounted

## Ring buffer for MCP log lines. Also prints to Godot console.

const MAX_LINES := 500

var _lines: Array[String] = []
var enabled := true


func log(msg: String) -> void:
	var line := "MCP | %s" % msg
	print(line)
	_lines.append(line)
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(-MAX_LINES)


func get_recent(count: int = 50) -> Array[String]:
	var start := maxi(0, _lines.size() - count)
	var result: Array[String] = []
	result.assign(_lines.slice(start))
	return result


func clear() -> void:
	_lines.clear()


func total_count() -> int:
	return _lines.size()
