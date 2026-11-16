@tool
extends McpTestSuite

## Tests for script_manage(op="build") (#1251): the MSBuild diagnostic parser,
## the result payload, the `dotnet build` argument contract, and the handler's
## refusals. The parser and payload tests run on any editor; the process path
## itself needs a .NET editor plus the .NET SDK and is covered by a live smoke.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const DotnetBuild := preload("res://addons/godot_ai/utils/dotnet_build.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")

var _handler: ScriptHandler


func suite_name() -> String:
	return "dotnet_build"


func suite_setup(_ctx: Dictionary) -> void:
	_handler = ScriptHandler.new(null)


func _project_file(rel: String) -> String:
	## Absolute path the way MSBuild prints it on this OS.
	var abs_path := ProjectSettings.globalize_path("res://" + rel)
	if OS.get_name() == "Windows":
		abs_path = abs_path.replace("/", "\\")
	return abs_path


# --- parse_output -----------------------------------------------------------

func test_parse_canonical_error_maps_to_res_path() -> void:
	var line := "%s(12,5): error CS0103: The name 'speed' does not exist in the current context [%s]" % [
		_project_file("scripts/Player.cs"), _project_file("Game.csproj")]
	var parsed := DotnetBuild.parse_output(line)
	assert_eq(parsed.error_count, 1)
	assert_eq(parsed.warning_count, 0)
	assert_eq(parsed.diagnostics.size(), 1)
	var d: Dictionary = parsed.diagnostics[0]
	assert_eq(d.severity, "error")
	assert_eq(d.code, "CS0103")
	assert_eq(d.path, "res://scripts/Player.cs")
	assert_eq(d.line, 12)
	assert_eq(d.column, 5)
	assert_eq(d.message, "The name 'speed' does not exist in the current context",
		"the trailing [project] tag must not leak into the message")
	assert_false(d.has("origin"), "a file diagnostic needs no origin")


func test_parse_range_form_and_warning() -> void:
	var line := "%s(3,9,3,14): warning CS0168: The variable 'e' is declared but never used" % \
		_project_file("Enemy.cs")
	var parsed := DotnetBuild.parse_output(line)
	assert_eq(parsed.warning_count, 1)
	var d: Dictionary = parsed.diagnostics[0]
	assert_eq(d.severity, "warning")
	assert_eq(d.path, "res://Enemy.cs")
	assert_eq(d.line, 3)
	assert_eq(d.column, 9)


func test_parse_tool_origin_has_no_path() -> void:
	var parsed := DotnetBuild.parse_output(
		"CSC : error CS5001: Program does not contain a static 'Main' method suitable for an entry point")
	assert_eq(parsed.error_count, 1)
	var d: Dictionary = parsed.diagnostics[0]
	assert_eq(d.path, "")
	assert_eq(d.origin, "CSC")
	assert_eq(d.code, "CS5001")
	assert_eq(d.line, 0)


func test_parse_keeps_outside_paths_absolute() -> void:
	var outside := "C:\\Program Files\\dotnet\\sdk\\8.0.400\\Microsoft.Common.CurrentVersion.targets" \
		if OS.get_name() == "Windows" else "/usr/share/dotnet/sdk/8.0.400/Microsoft.Common.CurrentVersion.targets"
	var parsed := DotnetBuild.parse_output(
		"%s(2401,5): warning MSB3277: Found conflicts between different versions" % outside)
	var d: Dictionary = parsed.diagnostics[0]
	assert_false(d.path.begins_with("res://"), "SDK files are outside the project")
	assert_contains(d.path, "Microsoft.Common.CurrentVersion.targets")
	assert_eq(d.code, "MSB3277")


func test_parse_ignores_non_diagnostic_lines() -> void:
	var text := "\n".join([
		"  Determining projects to restore...",
		"  All projects are up-to-date for restore.",
		"Build FAILED.",
		"Time Elapsed 00:00:01.23",
		"",
	])
	var parsed := DotnetBuild.parse_output(text)
	assert_eq(parsed.diagnostics.size(), 0)
	assert_eq(parsed.error_count, 0)


func test_parse_collapses_duplicate_lines() -> void:
	var line := "%s(1,1): error CS1002: ; expected" % _project_file("A.cs")
	var parsed := DotnetBuild.parse_output("%s\r\n%s\n%s" % [line, line, line])
	assert_eq(parsed.error_count, 1, "MSBuild repeats diagnostics; count unique ones")
	assert_eq(parsed.diagnostics.size(), 1)


func test_parse_without_warnings_still_counts_them() -> void:
	var text := "\n".join([
		"%s(1,1): warning CS0168: unused" % _project_file("A.cs"),
		"%s(2,1): error CS1002: ; expected" % _project_file("A.cs"),
	])
	var parsed := DotnetBuild.parse_output(text, false)
	assert_eq(parsed.warning_count, 1)
	assert_eq(parsed.error_count, 1)
	assert_eq(parsed.diagnostics.size(), 1)
	assert_eq(parsed.diagnostics[0].severity, "error")


func test_parse_truncation_keeps_errors_first() -> void:
	var lines := PackedStringArray()
	for i in 5:
		lines.append("%s(%d,1): warning CS0168: unused %d" % [_project_file("A.cs"), i + 1, i])
	lines.append("%s(99,1): error CS1002: ; expected" % _project_file("A.cs"))
	var parsed := DotnetBuild.parse_output("\n".join(lines), true, 2)
	assert_true(parsed.truncated)
	assert_eq(parsed.diagnostics.size(), 2)
	assert_eq(parsed.diagnostics[0].severity, "error",
		"an error listed after many warnings must survive truncation")
	assert_eq(parsed.warning_count, 5, "counts are taken before truncation")


# --- build_result -----------------------------------------------------------

func test_build_result_success() -> void:
	var data := DotnetBuild.build_result("res://Game.csproj", 0, false, 1234, "", false, true, 200)
	assert_true(data.succeeded)
	assert_eq(data.exit_code, 0)
	assert_eq(data.diagnostics_status, "checked")
	assert_eq(data.diagnostics_scope, "project")
	assert_eq(data.error_count, 0)
	assert_eq(data.project, "res://Game.csproj")
	assert_contains(data.reload_hint, "does not reload")
	assert_false(data.has("output_tail"), "a clean build has nothing to explain")


func test_build_result_compile_error() -> void:
	var out := "%s(4,13): error CS0029: Cannot implicitly convert type 'string' to 'int' [x]" % \
		_project_file("Player.cs")
	var data := DotnetBuild.build_result("res://Game.csproj", 1, false, 900, out, false, true, 200)
	assert_false(data.succeeded)
	assert_eq(data.diagnostics_status, "checked")
	assert_eq(data.error_count, 1)
	assert_eq(data.diagnostics[0].path, "res://Player.cs")
	assert_false(data.has("output_tail"), "parsed errors already explain the failure")


func test_build_result_failure_without_diagnostics_has_output_tail() -> void:
	var data := DotnetBuild.build_result(
		"res://Game.csproj", 145, false, 50,
		"The command could not be loaded, possibly because:\n  * You intended to execute a .NET SDK command:\n      No .NET SDKs were found.",
		false, true, 200)
	assert_false(data.succeeded)
	assert_eq(data.diagnostics_status, "not_checked",
		"the compiler never ran, so an empty list must not read as clean")
	assert_has_key(data, "output_tail")
	assert_contains(data.output_tail, "No .NET SDKs were found")


func test_build_result_timeout_is_not_checked() -> void:
	var data := DotnetBuild.build_result("res://Game.csproj", -1, true, 10000, "", false, true, 200)
	assert_false(data.succeeded)
	assert_true(data.timed_out)
	assert_eq(data.diagnostics_status, "not_checked",
		"a killed build proves nothing about the source")


# --- build_args / project discovery ----------------------------------------

func test_build_args_contract() -> void:
	var args := DotnetBuild.build_args("/p/Game.csproj")
	assert_eq(args[0], "build")
	assert_eq(args[1], "/p/Game.csproj")
	for flag in ["-nologo", "-v:q", "-tl:off", "-nodeReuse:false", "-clp:NoSummary;ForceNoAlign"]:
		assert_true(flag in args, "missing %s" % flag)
	var c := args.find("-c")
	assert_true(c >= 0 and args[c + 1] == "Debug", "editor builds use the Debug configuration")


func test_find_project_file_none_in_test_project() -> void:
	if not DotnetBuild.list_project_files().is_empty():
		skip("test_project has a .csproj on this machine")
		return
	assert_eq(DotnetBuild.find_project_file(), "")


# --- handler refusals -------------------------------------------------------

func test_build_rejects_out_of_range_timeout() -> void:
	var result := _handler.build_csharp({"timeout_sec": 1, "_request_id": "r1"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "timeout_sec")


func test_build_rejects_out_of_range_max_diagnostics() -> void:
	var result := _handler.build_csharp({"max_diagnostics": 0, "_request_id": "r1"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, "max_diagnostics")


func test_build_without_dotnet_editor_reports_clear_error() -> void:
	if ScriptHandler.editor_has_dotnet():
		skip("this editor has .NET; the refusal only applies to standard builds")
		return
	var result := _handler.build_csharp({"_request_id": "r1"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_contains(result.error.message, ".NET")
	assert_false(DotnetBuild.is_building(), "a refused request must not start a process")


func test_build_without_csproj_reports_not_found() -> void:
	if not ScriptHandler.editor_has_dotnet():
		skip("needs a .NET editor to reach project discovery")
		return
	if not DotnetBuild.list_project_files().is_empty():
		skip("test_project has a .csproj on this machine")
		return
	var result := _handler.build_csharp({"_request_id": "r1"})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)
	assert_contains(result.error.message, ".csproj")
