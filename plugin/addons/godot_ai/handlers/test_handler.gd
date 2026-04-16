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
		# Inline diagnostic: try loading one script and report what happens
		var dbg := {}
		var test_file := "test_connection.gd"
		var path := "res://tests/" + test_file
		dbg["load_path"] = path
		var scr = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
		if scr == null:
			dbg["load_result"] = "null"
			dbg["file_exists"] = FileAccess.file_exists(path)
		else:
			dbg["load_result"] = "ok"
			dbg["script_class"] = scr.get_class()
			var inst = scr.new()
			dbg["instance_class"] = inst.get_class() if inst else "null"
			dbg["is_test_suite"] = inst is McpTestSuite if inst else false
			if inst and not (inst is McpTestSuite):
				dbg["base_script"] = inst.get_script().get_base_script().resource_path if inst.get_script() and inst.get_script().get_base_script() else "none"
		return {"data": {"error": "No test suites found in res://tests/", "total": 0, "debug": dbg}}

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
		print("MCP | test discovery: DirAccess.open('res://tests') returned null, error: ", DirAccess.get_open_error())
		return suites

	print("MCP | test discovery: scanning res://tests/")
	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			var script := ResourceLoader.load("res://tests/" + file_name, "", ResourceLoader.CACHE_MODE_IGNORE)
			if script:
				var instance = script.new()
				if instance is McpTestSuite:
					suites.append(instance)
				else:
					print("MCP | test discovery: ", file_name, " instance is NOT McpTestSuite (type: ", typeof(instance), ")")
			else:
				print("MCP | test discovery: failed to load ", file_name)
		file_name = dir.get_next()

	## Sort by suite name for deterministic order
	suites.sort_custom(func(a: McpTestSuite, b: McpTestSuite) -> bool:
		return a.suite_name() < b.suite_name()
	)
	return suites
