@tool
class_name TestHandler
extends RefCounted

## Discovers and runs McpTestSuite scripts from res://tests/.
## Exposes run_tests and get_test_results as MCP commands.

var _runner: McpTestRunner
var _undo_redo: EditorUndoRedoManager
var _log_buffer: McpLogBuffer


func _init(undo_redo: EditorUndoRedoManager, log_buffer: McpLogBuffer) -> void:
	_runner = McpTestRunner.new()
	_undo_redo = undo_redo
	_log_buffer = log_buffer


func run_tests(params: Dictionary) -> Dictionary:
	var suite_filter: String = params.get("suite", "")
	var test_filter: String = params.get("test_name", "")
	var verbose: bool = params.get("verbose", false)

	var suites := _discover_suites()
	if suites.is_empty():
		return {"data": {"error": "No test suites found in res://tests/", "total": 0}}

	var ctx := {
		"undo_redo": _undo_redo,
		"log_buffer": _log_buffer,
	}

	var results := _runner.run_suites(suites, suite_filter, test_filter, ctx, verbose)
	return {"data": results}


func get_test_results(params: Dictionary) -> Dictionary:
	var verbose: bool = params.get("verbose", false)
	return {"data": _runner.get_results(verbose)}


func _discover_suites() -> Array[McpTestSuite]:
	var suites: Array[McpTestSuite] = []
	var dir := DirAccess.open("res://tests")
	if dir == null:
		return suites

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			var script := ResourceLoader.load("res://tests/" + file_name, "", ResourceLoader.CACHE_MODE_IGNORE)
			if script:
				var instance = script.new()
				if instance is McpTestSuite:
					suites.append(instance)
		file_name = dir.get_next()

	## Sort by suite name for deterministic order
	suites.sort_custom(func(a: McpTestSuite, b: McpTestSuite) -> bool:
		return a.suite_name() < b.suite_name()
	)
	return suites
