@tool
extends RefCounted

## `dotnet build` for the project's C# assembly, with MSBuild diagnostics
## parsed into the same structured shape the GDScript tools report (#1251).
##
## The script tools treat `.cs` as text only (#908): they never compile .NET,
## so every C# write says `diagnostics_status: "not_checked"`. This is the
## missing half — a build the caller can request explicitly, whose result is
## the compiler's own errors and warnings rather than a guess.
##
## Shape of a run:
##   * `OS.execute_with_pipe(..., false)` starts `dotnet build` and returns at
##     once; a coroutine polls the PID one editor frame at a time, so the main
##     thread never blocks (handlers have a 4ms frame budget).
##   * stdout/stderr are drained every frame with non-blocking reads, so a
##     chatty restore can never fill the pipe and stall the child.
##   * The console logger runs quiet, unaligned and summary-free, so each
##     diagnostic is exactly one canonical MSBuild line.
##   * Concurrent requests join the build already in flight instead of starting
##     a second one against the same output directory; every waiter gets the
##     same result.
##   * A wall-clock timeout kills the `dotnet` process and reports
##     `timed_out: true` with `diagnostics_status: "not_checked"`.
##
## The editor's loaded assembly is not reloaded here. Godot's .NET editor picks
## up a changed assembly on its own (window focus / its Build button); the
## response says so instead of claiming the new code is live.

const ScriptWork := preload("res://addons/godot_ai/utils/script_work.gd")
const PortResolver := preload("res://addons/godot_ai/utils/port_resolver.gd")

const DEFAULT_TIMEOUT_SEC := 180
const MIN_TIMEOUT_SEC := 10
const MAX_TIMEOUT_SEC := 900
const DEFAULT_MAX_DIAGNOSTICS := 200
const MAX_MAX_DIAGNOSTICS := 1000
## Retained output cap. Diagnostics are parsed from the retained text, so the
## cap is generous; it only bounds a pathological build log.
const MAX_OUTPUT_BYTES := 4 * 1024 * 1024
const OUTPUT_TAIL_CHARS := 2000
const _READ_CHUNK := 65536
## Most bytes one drain call reads across stdout + stderr before returning to
## the poll loop (which yields a frame and re-checks the deadline).
const DRAIN_BUDGET_BYTES := 1024 * 1024
## Bounded drain passes after the child exits (covers MAX_OUTPUT_BYTES).
const _FINAL_DRAIN_PASSES := 8
## How long a killed build may take to disappear before the result reports
## `termination_confirmed: false` and the next build is admitted anyway.
const KILL_GRACE_MS := 3000
## Headroom the dispatcher gets over the build's own timeout so the build's
## timed_out result (not DEFERRED_TIMEOUT) reaches the caller.
const DEFERRED_GRACE_MS := 5000

const RELOAD_HINT := (
	"This op builds the assembly; it does not reload it into the editor. "
	+ "Godot's .NET editor loads a rebuilt assembly when its window regains "
	+ "focus or after its own Build button. Attached C# scripts run the new "
	+ "code only after that reload."
)

## One canonical MSBuild diagnostic line:
##   C:\p\Player.cs(12,5): error CS0103: The name 'x' does not exist [C:\p\Game.csproj]
##   C:\p\Player.cs(12,5,12,9): warning CS0168: ...
##   CSC : error CS5001: Program does not contain a static 'Main' method ...
##   MSBUILD : error MSB1009: Project file does not exist.
const _DIAGNOSTIC_PATTERN := (
	"^\\s*(?<origin>.*?)"
	+ "(?:\\((?<line>\\d+)(?:,(?<col>\\d+))?(?:,\\d+,\\d+)?\\))?"
	+ "\\s*:\\s*(?<severity>error|warning)\\s+(?<code>[A-Za-z]+\\d+)\\s*:\\s*"
	+ "(?<message>.*?)"
	+ "(?:\\s+\\[(?<project>[^\\]]+)\\])?\\s*$"
)

## The build in flight, shared by every request that arrives while it runs.
## Empty when idle. Process-wide on purpose: the handler instance is lazily
## created and may be replaced, the build must not be duplicated.
static var _active: Dictionary = {}
static var _regex: RegEx


static func is_building() -> bool:
	return not _active.is_empty()


## The project's C# project file as a res:// path, or "" when there is none.
## Godot names it after `dotnet/project/assembly_name`; fall back to the only
## `.csproj` in the project root for projects that renamed it by hand.
static func find_project_file() -> String:
	var assembly := str(ProjectSettings.get_setting("dotnet/project/assembly_name", ""))
	if not assembly.is_empty():
		var named := "res://%s.csproj" % assembly
		if FileAccess.file_exists(named):
			return named
	var found := list_project_files()
	if found.size() == 1:
		return found[0]
	return ""


## Every `.csproj` in the project root, for the "which one?" error message.
static func list_project_files() -> PackedStringArray:
	var found := PackedStringArray()
	for file in DirAccess.get_files_at("res://"):
		if file.get_extension().to_lower() == "csproj":
			found.append("res://" + file)
	return found


## The `dotnet` host to launch. Prefer an explicit DOTNET_ROOT, then the
## standard install locations (a macOS GUI-launched editor often has no
## /usr/local/share/dotnet on PATH), then plain `dotnet` resolved via PATH.
static func resolve_dotnet_executable() -> String:
	var exe_name := "dotnet.exe" if OS.get_name() == "Windows" else "dotnet"
	var candidates := PackedStringArray()
	var root := OS.get_environment("DOTNET_ROOT")
	if not root.is_empty():
		candidates.append(root.path_join(exe_name))
	match OS.get_name():
		"Windows":
			var program_files := OS.get_environment("ProgramFiles")
			if not program_files.is_empty():
				candidates.append(program_files.path_join("dotnet").path_join(exe_name))
		"macOS":
			candidates.append("/usr/local/share/dotnet/dotnet")
			candidates.append("/opt/homebrew/bin/dotnet")
		_:
			candidates.append("/usr/share/dotnet/dotnet")
			candidates.append("/usr/lib/dotnet/dotnet")
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return "dotnet"


## Arguments for `dotnet build`. Quiet + NoSummary keeps one line per
## diagnostic (no repeated summary block); ForceNoAlign stops MSBuild from
## wrapping long messages at a console width; -tl:off keeps the terminal
## logger's live-updating output out of a redirected pipe; nodeReuse:false
## lets MSBuild worker nodes exit with the build instead of lingering.
static func build_args(project_abs_path: String) -> PackedStringArray:
	return PackedStringArray([
		"build",
		project_abs_path,
		"-c", "Debug",
		"-nologo",
		"-v:q",
		"-tl:off",
		"-nodeReuse:false",
		"-clp:NoSummary;ForceNoAlign",
	])


## Parse MSBuild console output into structured diagnostics.
## Returns {diagnostics, error_count, warning_count, truncated}. Duplicate
## lines (MSBuild repeats a diagnostic once per target framework / pass) are
## collapsed; counts are of unique diagnostics, before truncation.
static func parse_output(
	text: String,
	include_warnings: bool = true,
	max_diagnostics: int = DEFAULT_MAX_DIAGNOSTICS,
) -> Dictionary:
	if _regex == null:
		_regex = RegEx.new()
		_regex.compile(_DIAGNOSTIC_PATTERN)
	var diagnostics: Array = []
	var seen := {}
	var error_count := 0
	var warning_count := 0
	for raw_line in text.replace("\r\n", "\n").split("\n"):
		var line := raw_line.strip_edges()
		if line.is_empty():
			continue
		var m := _regex.search(line)
		if m == null:
			continue
		var severity := m.get_string("severity").to_lower()
		var origin := m.get_string("origin").strip_edges()
		var line_no := int(m.get_string("line")) if not m.get_string("line").is_empty() else 0
		var col := int(m.get_string("col")) if not m.get_string("col").is_empty() else 0
		var code := m.get_string("code")
		var message := m.get_string("message").strip_edges()
		var key := "%s|%d|%d|%s|%s|%s" % [origin, line_no, col, severity, code, message]
		if seen.has(key):
			continue
		seen[key] = true
		if severity == "error":
			error_count += 1
		else:
			warning_count += 1
			if not include_warnings:
				continue
		var diagnostic := {
			"severity": severity,
			"code": code,
			"message": message,
			"path": localize_origin(origin),
			"line": line_no,
			"column": col,
		}
		if diagnostic.path.is_empty() and not origin.is_empty():
			## `CSC`, `MSBUILD`, a tool name: not a file the caller can open.
			diagnostic["origin"] = origin
		diagnostics.append(diagnostic)
	var truncated := diagnostics.size() > max_diagnostics
	if truncated:
		## Errors first, so truncation never hides an error behind warnings.
		var errors := diagnostics.filter(func(d): return d.severity == "error")
		var warnings := diagnostics.filter(func(d): return d.severity != "error")
		diagnostics = (errors + warnings).slice(0, max_diagnostics)
	return {
		"diagnostics": diagnostics,
		"error_count": error_count,
		"warning_count": warning_count,
		"truncated": truncated,
	}


## A diagnostic origin as a path the other tools accept: `res://...` inside
## the project, the absolute path outside it (an SDK .targets file), or ""
## when the origin is a tool name such as `CSC` or `MSBUILD`.
static func localize_origin(origin: String) -> String:
	if origin.is_empty():
		return ""
	var normalized := origin.replace("\\", "/")
	var looks_like_path := (
		normalized.contains("/")
		or (normalized.length() > 1 and normalized[1] == ":")
	)
	if not looks_like_path:
		return ""
	var localized := ProjectSettings.localize_path(normalized)
	if localized.begins_with("res://"):
		return localized
	## localize_path compares case-sensitively; Windows paths may differ in
	## drive-letter case only.
	if OS.get_name() == "Windows":
		var root := ProjectSettings.globalize_path("res://").replace("\\", "/")
		if normalized.to_lower().begins_with(root.to_lower()):
			return "res://" + normalized.substr(root.length())
	return normalized


## Fold a finished (or killed) process into the response payload.
static func build_result(
	project: String,
	exit_code: int,
	timed_out: bool,
	duration_ms: int,
	output: String,
	output_truncated: bool,
	include_warnings: bool,
	max_diagnostics: int,
	termination_confirmed: bool = true,
) -> Dictionary:
	var parsed := parse_output(output, include_warnings, max_diagnostics)
	var succeeded := not timed_out and exit_code == 0
	## "checked" means the compiler's verdict is in the list: a clean build, or
	## a failed one whose errors were parsed. A failure with no parsed error
	## (missing SDK, restore failure, killed by timeout) proves nothing about
	## the source, so it must not read as "checked, no errors".
	## A timed-out build is never "checked", even when it printed an error
	## before it was killed: the list is a partial view of an unfinished run.
	var compiler_verdict: bool = not timed_out and (succeeded or parsed.error_count > 0)
	var data := {
		"project": project,
		"succeeded": succeeded,
		"exit_code": exit_code,
		"timed_out": timed_out,
		"duration_ms": duration_ms,
		"diagnostics_status": "checked" if compiler_verdict else "not_checked",
		"diagnostics_scope": "project",
		"diagnostics": parsed.diagnostics,
		"error_count": parsed.error_count,
		"warning_count": parsed.warning_count,
		"diagnostics_truncated": parsed.truncated,
		"reload_hint": RELOAD_HINT,
	}
	## A failed build with no canonical diagnostic line (restore failure, SDK
	## missing, bad switch) would otherwise be an unexplained `succeeded:
	## false`; hand back the end of the raw output instead.
	if not compiler_verdict:
		data["output_tail"] = output.replace("\r\n", "\n").right(OUTPUT_TAIL_CHARS).strip_edges()
	if output_truncated:
		data["output_truncated"] = true
	if timed_out:
		## Whether the killed build's whole process tree is provably gone. Only
		## Windows `taskkill /T` can prove that; POSIX kills the exact PID, so a
		## descendant may outlive it there.
		data["termination_confirmed"] = termination_confirmed
	return data


## Start a build (or join the one in flight) and reply to `request_id` on
## `connection` when it finishes. Returns {} on start/join, or an error-shaped
## payload when the process could not be launched.
static func start(
	connection: McpConnection,
	request_id: String,
	project: String,
	timeout_sec: int,
	include_warnings: bool,
	max_diagnostics: int,
) -> Dictionary:
	var waiter := {
		"connection": connection,
		"request_id": request_id,
		"include_warnings": include_warnings,
		"max_diagnostics": max_diagnostics,
	}
	if not _active.is_empty():
		## A joiner keeps its own deferred budget. If that budget ends before
		## the running build can finish (its deadline plus the kill grace), the
		## joiner would get DEFERRED_TIMEOUT instead of the shared result, so
		## refuse it up front with the budget it would need.
		var needed_ms := join_budget_needed_ms(int(_active.deadline_ms), Time.get_ticks_msec())
		if timeout_sec * 1000 + DEFERRED_GRACE_MS < needed_ms:
			return {
				"join_refused": true,
				"needed_timeout_sec": maxi(
					MIN_TIMEOUT_SEC, ceili(float(needed_ms - DEFERRED_GRACE_MS) / 1000.0)
				),
			}
		_active.waiters.append(waiter)
		return {"joined": true}
	var exe := resolve_dotnet_executable()
	var args := build_args(ProjectSettings.globalize_path(project))
	PortResolver.lock_process_spawn()
	var info := OS.execute_with_pipe(exe, args, false)
	PortResolver.unlock_process_spawn()
	var pid := int(info.get("pid", -1)) if not info.is_empty() else -1
	if pid <= 0:
		_close_pipes(info)
		return {"spawn_failed": true, "executable": exe}
	_active = {
		"pid": pid,
		"info": info,
		"project": project,
		"started_ms": Time.get_ticks_msec(),
		"deadline_ms": Time.get_ticks_msec() + timeout_sec * 1000,
		"output": PackedByteArray(),
		"output_truncated": false,
		"waiters": [waiter],
	}
	_poll_until_done(connection)
	return {"joined": false}


## How long from `now_ms` until a build with deadline `deadline_ms` has
## replied at the latest (deadline, then the kill grace). A joiner's deferred
## budget (`timeout_sec * 1000 + DEFERRED_GRACE_MS`) must cover it; a joiner
## with the same timeout_sec as the running build always does.
static func join_budget_needed_ms(deadline_ms: int, now_ms: int) -> int:
	return maxi(0, deadline_ms - now_ms) + KILL_GRACE_MS


static func _poll_until_done(connection: McpConnection) -> void:
	var work := ScriptWork.begin("dotnet_build")
	var tree: SceneTree = connection.get_tree() if is_instance_valid(connection) else null
	var timed_out := false
	var termination_confirmed := true
	if tree != null:
		## Let _dispatch() register the deferred request before any reply.
		await tree.process_frame
		while OS.is_process_running(_active.pid):
			_drain(_active)
			if Time.get_ticks_msec() >= _active.deadline_ms:
				timed_out = true
				break
			await tree.process_frame
	else:
		## No tree to yield to (connection already gone): nothing can receive
		## the reply, so stop the child rather than orphan it.
		timed_out = true
	if timed_out:
		termination_confirmed = _kill_build_tree(_active.pid)
		## Keep `_active` held (new requests join or are refused) until the
		## killed tree is gone or the grace expires, so a fresh build never
		## starts while the old one still writes the same output directory.
		var grace_end := Time.get_ticks_msec() + KILL_GRACE_MS
		while PortResolver.pid_alive(_active.pid) and Time.get_ticks_msec() < grace_end:
			if tree == null:
				break
			await tree.process_frame
		if PortResolver.pid_alive(_active.pid):
			termination_confirmed = false
	## The child has exited (or was killed); whatever is still buffered is
	## finite unless a surviving descendant keeps writing, so drain in a few
	## bounded passes rather than until empty.
	for i in _FINAL_DRAIN_PASSES:
		if not _drain(_active):
			break
	var build := _active
	_active = {}
	_close_pipes(build.info)
	var exit_code := -1 if timed_out else OS.get_process_exit_code(build.pid)
	var output: String = build.output.get_string_from_utf8()
	for waiter in build.waiters:
		if not is_instance_valid(waiter.connection):
			continue
		var data := build_result(
			build.project,
			exit_code,
			timed_out,
			Time.get_ticks_msec() - build.started_ms,
			output,
			build.output_truncated,
			waiter.include_warnings,
			waiter.max_diagnostics,
			termination_confirmed,
		)
		if build.waiters.size() > 1:
			data["shared_build"] = true
		waiter.connection.send_deferred_response(waiter.request_id, {"data": data})
	ScriptWork.finish(work)


## Pull whatever the child has written without blocking. stderr is folded
## into the same buffer: MSBuild writes diagnostics to stdout, but the host
## reports its own failures (missing SDK, bad switch) on stderr.
##
## Bounded: one call reads at most DRAIN_BUDGET_BYTES across both streams, so
## a child that keeps its pipe readable cannot hold the editor inside one
## frame — the caller yields and re-checks the deadline between calls. Returns
## true when the budget ran out (more may be waiting).
static func _drain(build: Dictionary) -> bool:
	## Packed arrays are values: mutate a local and store it back.
	var output: PackedByteArray = build.output
	var budget := DRAIN_BUDGET_BYTES
	for key in ["stdio", "stderr"]:
		var pipe: Variant = build.info.get(key, null)
		if pipe == null or not (pipe is FileAccess) or not pipe.is_open():
			continue
		while budget > 0:
			var chunk: PackedByteArray = pipe.get_buffer(mini(_READ_CHUNK, budget))
			if chunk.is_empty():
				break
			budget -= chunk.size()
			var room := MAX_OUTPUT_BYTES - output.size()
			if room <= 0:
				## Past the cap: keep reading (bounded) so the child never
				## blocks on a full pipe, but discard the bytes.
				build.output_truncated = true
				continue
			if chunk.size() > room:
				chunk = chunk.slice(0, room)
				build.output_truncated = true
			output.append_array(chunk)
	build.output = output
	return budget <= 0


## Kill the timed-out build and its descendants. Windows `taskkill /T` (via
## the same exact-identity grant McpCliExec uses) covers the MSBuild nodes and
## compiler server the build launched and reports success only when Windows
## accepted the whole tree; POSIX `OS.kill` reaches only the exact PID.
## Returns true only when the tree kill is proven. Runs once, on timeout, and
## blocks the main thread for the duration of the identity probe and taskkill.
static func _kill_build_tree(pid: int) -> bool:
	var grant := PortResolver.capture_process_kill_grant(pid)
	if not grant.is_empty():
		var grants: Array[Dictionary] = [grant]
		var killed := PortResolver.kill_exact_processes(grants, false, true)
		if killed.has(pid):
			return OS.get_name() == "Windows"
	OS.kill(pid)
	return false


static func _close_pipes(info: Dictionary) -> void:
	for key in ["stdio", "stderr"]:
		var pipe: Variant = info.get(key, null)
		if pipe != null and pipe is FileAccess and pipe.is_open():
			pipe.close()
