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

	var discovery := _discover_suites()
	var suites: Array = discovery.suites
	if suites.is_empty():
		var msg := "No test suites found in res://tests/"
		if not discovery.errors.is_empty():
			msg += " (%d script(s) failed to load: %s)" % [
				discovery.errors.size(),
				", ".join(discovery.errors),
			]
		return {"data": {"error": msg, "total": 0, "load_errors": discovery.errors}}

	var ctx := {
		"undo_redo": _undo_redo,
		"log_buffer": _log_buffer,
	}

	var results := _runner.run_suites(suites, suite_filter, test_filter, ctx, verbose)
	if not discovery.errors.is_empty():
		results["load_errors"] = discovery.errors
	return {"data": results}


func get_test_results(params: Dictionary) -> Dictionary:
	var verbose: bool = params.get("verbose", false)
	return {"data": _runner.get_results(verbose)}


func _discover_suites() -> Dictionary:
	## Returns {"suites": Array, "errors": Array[String]}.
	## Resilient: a broken script doesn't kill discovery of the rest.
	var suites := []
	var errors: Array[String] = []
	var dir := DirAccess.open("res://tests")
	if dir == null:
		return {"suites": suites, "errors": ["DirAccess.open('res://tests') returned null — directory may not exist"]}

	dir.list_dir_begin()
	var file_name := dir.get_next()
	while not file_name.is_empty():
		if file_name.begins_with("test_") and file_name.ends_with(".gd"):
			var path := "res://tests/" + file_name
			var script = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
			if script == null:
				errors.append("%s (load failed — check for parse errors or duplicate methods)" % file_name)
			elif script.can_instantiate():
				var instance = script.new()
				if instance is McpTestSuite:
					suites.append(instance)
				else:
					errors.append("%s (not a McpTestSuite subclass)" % file_name)
			else:
				errors.append("%s (cannot instantiate — abstract or broken)" % file_name)
		file_name = dir.get_next()

	## Sort by suite name for deterministic order.
	suites.sort_custom(func(a, b) -> bool:
		return a.suite_name() < b.suite_name()
	)
	return {"suites": suites, "errors": errors}
