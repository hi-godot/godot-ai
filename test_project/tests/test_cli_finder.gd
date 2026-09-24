@tool
extends McpTestSuite

## Tests for McpCliFinder, focused on the Windows path-picking rule that
## stops `OS.execute_with_pipe` from surfacing "Could not create child
## process" against npm-installed POSIX shims (#251).
##
## `find()` end-to-end depends on the host's PATH and well-known dirs, so
## the routing logic is covered indirectly through `test_clients.gd`. Here
## we pin the pure helper (`_pick_best_path`) on every platform so the rule
## doesn't quietly regress on a CI runner that lacks any npm-installed CLI.


func suite_name() -> String:
	return "cli_finder"


func test_pick_best_path_prefers_cmd_over_extensionless() -> void:
	## The npm-on-Windows reproducer: `where claude` lists the bash shim
	## first (no extension) and the `.cmd` wrapper after. Picking the
	## extensionless one is what produces
	## `ERROR: Could not create child process: "...\claude" mcp list`.
	var lines := PackedStringArray([
		"C:\\Program Files\\nodejs\\claude",
		"C:\\Program Files\\nodejs\\claude.cmd",
		"C:\\Program Files\\nodejs\\claude.ps1",
	])
	var picked: String = McpCliFinder._pick_best_path(lines)
	assert_eq(picked, "C:\\Program Files\\nodejs\\claude.cmd",
		"Must skip the extensionless POSIX shim and pick the .cmd wrapper")


func test_pick_best_path_prefers_exe_over_cmd() -> void:
	## Native `.exe` is always preferable to a `.cmd` shell wrapper — same
	## work, one fewer process. Order is independent of where the entries
	## appear in `where` output, since the helper scans every line before
	## falling back.
	var lines := PackedStringArray([
		"C:\\Users\\u\\AppData\\Local\\npm\\tool.cmd",
		"C:\\Users\\u\\AppData\\Local\\npm\\tool.exe",
	])
	var picked: String = McpCliFinder._pick_best_path(lines)
	assert_eq(picked, "C:\\Users\\u\\AppData\\Local\\npm\\tool.exe",
		"`.exe` should win over `.cmd` when both are listed")


func test_pick_best_path_strips_carriage_returns() -> void:
	## `where` on Windows emits CRLF line endings — `strip_edges()` has to
	## eat the `\r` before the extension check or every line looks like it
	## ends in `\r` and falls through to the fallback branch.
	var lines := PackedStringArray([
		"C:\\Program Files\\nodejs\\claude\r",
		"C:\\Program Files\\nodejs\\claude.cmd\r",
	])
	var picked: String = McpCliFinder._pick_best_path(lines)
	assert_eq(picked, "C:\\Program Files\\nodejs\\claude.cmd",
		"CRLF line endings must not defeat the extension check")


func test_pick_best_path_falls_back_when_nothing_qualifies() -> void:
	## If `where` somehow returned only extensionless or unrecognised
	## entries, return *something* rather than empty — the caller can still
	## try to spawn it and surface a clearer error than "no CLI found".
	var lines := PackedStringArray([
		"C:\\custom\\bin\\tool",
		"C:\\other\\tool.weird",
	])
	var picked: String = McpCliFinder._pick_best_path(lines)
	assert_eq(picked, "C:\\custom\\bin\\tool",
		"With no recognised extension, fall back to the first non-empty line")


func test_pick_best_path_skips_blank_lines() -> void:
	## `where` sometimes leaves a trailing blank line in its output;
	## splitting by "\n" surfaces it as an empty entry. The helper must
	## skip blanks for both the fallback and the extension scan.
	var lines := PackedStringArray([
		"",
		"   ",
		"C:\\bin\\tool.cmd",
	])
	var picked: String = McpCliFinder._pick_best_path(lines)
	assert_eq(picked, "C:\\bin\\tool.cmd",
		"Blank entries must not be returned as the fallback")


func test_pick_best_path_empty_input_returns_empty() -> void:
	var picked: String = McpCliFinder._pick_best_path(PackedStringArray())
	assert_eq(picked, "",
		"No input lines must yield an empty string, not a synthetic path")


func test_lookup_failure_distinguishes_absence_from_failed_observation() -> void:
	assert_eq(McpCliFinder._lookup_failure({"exit_code": 1}, true), "not_found")
	assert_eq(McpCliFinder._lookup_failure({"exit_code": 1}, false), "nonzero_exit")
	assert_eq(McpCliFinder._lookup_failure({"exit_code": 2}, true), "nonzero_exit")
	assert_eq(McpCliFinder._lookup_failure({"exit_code": 0, "stdout": " \r\n"}, true), "empty_output")
	assert_eq(McpCliFinder._lookup_failure({"exit_code": 0, "stdout": "private/path"}, false), "unusable_output")
	for flag in ["timed_out", "spawn_failed", "cancelled", "termination_failed"]:
		assert_eq(McpCliFinder._lookup_failure({"exit_code": 1, flag: true}, true), flag)


func test_lookup_trace_excludes_raw_result_fields() -> void:
	var records: Array = []
	var sink := func(record: Dictionary) -> void: records.append(record)
	var private_result := {
		"exit_code": -1, "timed_out": true,
		"stdout": "PRIVATE_LOOKUP_CANARY", "stderr": "PRIVATE_LOOKUP_CANARY",
		"output": "PRIVATE_LOOKUP_CANARY", "command": "PRIVATE_LOOKUP_CANARY",
	}
	McpCliFinder._trace_lookup(Callable(), "inherited_path", "timed_out", 0, private_result)
	assert_eq(records.size(), 0, "No sink must stay silent")
	McpCliFinder._trace_lookup(sink, "inherited_path", "timed_out", Time.get_ticks_msec(), private_result)
	assert_eq(records.size(), 1)
	assert_eq(records[0].status, "timed_out")
	assert_eq(records[0].exit_code, -1)
	assert_true(records[0].timed_out)
	assert_false(records[0].cache_hit)
	assert_true(records[0].elapsed_ms >= 0)
	assert_false(JSON.stringify(records).contains("PRIVATE_LOOKUP_CANARY"))
	assert_eq(records[0].size(), 9, "Only the fixed diagnostic schema leaves the finder")


func test_lookup_trace_preserves_cached_miss_and_hit() -> void:
	var key := "godot-ai-finder-private-canary"
	var records: Array = []
	var sink := func(record: Dictionary) -> void: records.append(record)
	McpCliFinder._mutex.lock()
	McpCliFinder._cache[key] = ""
	McpCliFinder._searched[key] = true
	McpCliFinder._mutex.unlock()
	assert_eq(McpCliFinder.find([key], sink), "")
	assert_eq(McpCliFinder.find([key]), "", "Tracing must not invalidate a miss")
	assert_eq(records.size(), 1)
	assert_eq(records[0].status, "cached_miss")
	assert_true(records[0].cache_hit)
	McpCliFinder._mutex.lock()
	McpCliFinder._cache[key] = "PRIVATE_LOOKUP_CANARY"
	McpCliFinder._mutex.unlock()
	assert_eq(McpCliFinder.find([key], sink), "PRIVATE_LOOKUP_CANARY")
	assert_eq(records[1].status, "resolved")
	assert_true(records[1].cache_hit)
	assert_false(JSON.stringify(records).contains("PRIVATE_LOOKUP_CANARY"))
	assert_false(JSON.stringify(records).contains(key))
	McpCliFinder.invalidate(key)
