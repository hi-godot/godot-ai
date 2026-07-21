@tool
extends RefCounted

## Discovers and runs McpTestSuite scripts from res://tests/.
## Exposes run_tests and get_test_results as MCP commands.

var _runner: McpTestRunner
var _undo_redo: EditorUndoRedoManager
var _log_buffer: McpLogBuffer
## Live plugin dispatcher, exposed to suites via ctx so tests can prove the
## lazy handler registrations (#736) materialize with their real ctor args.
## Optional third arg keeps old two-arg fixtures working; untyped because
## the dispatcher constructs this handler (avoids a load-time type cycle).
var _dispatcher


func _init(undo_redo: EditorUndoRedoManager, log_buffer: McpLogBuffer, dispatcher = null) -> void:
	_runner = McpTestRunner.new()
	_undo_redo = undo_redo
	_log_buffer = log_buffer
	_dispatcher = dispatcher


func run_tests(params: Dictionary) -> Dictionary:
	var suite_filter: String = params.get("suite", "")
	var test_filter: String = params.get("test_name", "")
	var exclude_test_filter: String = params.get("exclude_test_name", "")
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
		var no_suites := {"error": msg, "total": 0, "load_errors": discovery.errors}
		## Keep the edited_scene annotation on the no-suites error payload too,
		## so the response contract is consistent across every return path.
		_annotate_edited_scene(no_suites)
		return {"data": no_suites}

	var ctx := {
		"undo_redo": _undo_redo,
		"log_buffer": _log_buffer,
		"dispatcher": _dispatcher,
	}

	var results := _runner.run_suites(suites, suite_filter, test_filter, ctx, verbose, exclude_test_filter)
	if not discovery.errors.is_empty():
		results["load_errors"] = discovery.errors
	_annotate_edited_scene(results)
	return {"data": results}


## Many suites assume the project's main scene is the edited scene (they read
## /Main/... nodes directly). Running with another scene open produces a flood
## of phantom failures that look like real regressions. Surface the edited
## scene and a warning when it differs from run/main_scene so the failures are
## attributable at a glance instead of costing a debugging round (#635).
func _annotate_edited_scene(results: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	var edited := scene_root.scene_file_path if scene_root else ""
	results["edited_scene"] = edited
	var main_scene := str(ProjectSettings.get_setting("application/run/main_scene", ""))
	if main_scene.is_empty() or edited == main_scene:
		return
	if int(results.get("failed", 0)) <= 0:
		return
	results["scene_warning"] = (
		"Edited scene is '%s' but the project main scene is '%s'. Many suites "
		% [edited if not edited.is_empty() else "<none>", main_scene]
		+ "assume the main scene is open and will report phantom failures "
		+ "otherwise. If these failures are unexpected, scene_open('%s') and re-run." % main_scene
	)


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
