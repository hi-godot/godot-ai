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
		## Inline diagnostics — separate function was returning {} in CI
		var diag := {"error": "No test suites found in res://tests/", "total": 0}
		var ddir := DirAccess.open("res://tests")
		diag["dir_open"] = ddir != null
		if ddir != null:
			var dfiles := []
			var dloads := {}
			ddir.list_dir_begin()
			var df := ddir.get_next()
			while not df.is_empty():
				dfiles.append(df)
				if df.begins_with("test_") and df.ends_with(".gd"):
					var dscript = ResourceLoader.load("res://tests/" + df, "", ResourceLoader.CACHE_MODE_IGNORE)
					if dscript == null:
						dloads[df] = "load_null"
					elif dscript.new() is McpTestSuite:
						dloads[df] = "ok"
					else:
						dloads[df] = "not_suite"
				df = ddir.get_next()
			diag["files"] = dfiles
			diag["loads"] = dloads
		return {"data": diag}

	var ctx := {
		"undo_redo": _undo_redo,
		"log_buffer": _log_buffer,
	}

	var results := _runner.run_suites(suites, suite_filter, test_filter, ctx, verbose)
	return {"data": results}


func get_test_results(params: Dictionary) -> Dictionary:
	var verbose: bool = params.get("verbose", false)
	return {"data": _runner.get_results(verbose)}


func _discover_suites() -> Array:
	var suites := []
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
	suites.sort_custom(func(a, b) -> bool:
		return a.suite_name() < b.suite_name()
	)
	return suites


func _diagnose_discovery() -> Dictionary:
	var result := {}
	var dir := DirAccess.open("res://tests")
	result["dir_open"] = dir != null
	if dir == null:
		return result

	var files: Array[String] = []
	var load_results := {}
	dir.list_dir_begin()
	var f := dir.get_next()
	while not f.is_empty():
		files.append(f)
		if f.begins_with("test_") and f.ends_with(".gd"):
			var script = ResourceLoader.load("res://tests/" + f, "", ResourceLoader.CACHE_MODE_IGNORE)
			if script == null:
				load_results[f] = "load_failed"
			else:
				var instance = script.new()
				if instance is McpTestSuite:
					load_results[f] = "ok"
				else:
					load_results[f] = "not_McpTestSuite"
		f = dir.get_next()

	result["files_in_dir"] = files
	result["file_count"] = files.size()
	result["load_results"] = load_results
	return result
