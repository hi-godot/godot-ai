@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

## Captures what the editor's Profiler, Visual Profiler and Monitors panels
## show for the running game, and aggregates it into JSON.
##
## Route: the game's built-in profilers are switched on through the public
## EditorDebuggerSession.toggle_profiler(), exactly as the panels' Start
## buttons do. Their frames ("servers:profile_frame", "visual:profile_frame",
## "performance:profile_frame", ...) are parsed by ScriptEditorDebugger's own
## handlers and never reach EditorDebuggerPlugin._capture, so this handler
## listens to ScriptEditorDebugger's bound `debug_data` signal, which
## _parse_message emits for every message before routing it (the signal
## Godot's own Debug Adapter uses). The node is found the same way
## McpDebuggerPlugin finds it for its `breaked` signal: by walking the editor
## UI, since EditorDebuggerSession does not expose it.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const VALID_PROFILERS: Array[String] = ["scripts", "visual", "monitors"]
const VALID_SORT_KEYS: Array[String] = ["self", "total", "calls"]
## The editor clamps its own "max functions per frame" setting to this range.
const MIN_FUNCTIONS := 16
const MAX_FUNCTIONS := 512
const DEFAULT_FUNCTIONS := 128
## Frames kept per stream (10 minutes at 60 fps); later frames are dropped
## and the capture reports truncated=true.
const MAX_FRAMES := 36000
## A frame whose median sits within this band of the frame-rate cap is
## reported as capped: its frame time measures the cap, not the game's cost.
const CAP_BAND_LOW := 0.9
const CAP_BAND_HIGH := 1.1

var _debugger_plugin: EditorDebuggerPlugin
## Testing seam: returns {session, debugger} for the game to profile, or {}.
var _target_finder: Callable
var _debugger: Object = null
var _session: Object = null
var _capturing := false
var _profilers: Array[String] = []
var _started_msec := 0
var _stopped_msec := 0
var _truncated := false
var _game_exited := false
var _dropped_frames := 0

var _signatures := {}
var _script_frames: Array = []
var _visual_frames: Array = []
var _monitor_frames: Array = []
var _custom_monitor_names: Array = []
var _hardware := {}


func _init(debugger_plugin: EditorDebuggerPlugin = null) -> void:
	_debugger_plugin = debugger_plugin
	_target_finder = _find_game_debugger


func profiler_start(params: Dictionary) -> Dictionary:
	var requested: Variant = params.get("profilers", VALID_PROFILERS)
	if not requested is Array:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"profilers must be an array of %s" % [VALID_PROFILERS])
	var profilers: Array[String] = []
	for p in requested:
		if str(p) not in VALID_PROFILERS:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Unknown profiler '%s' — use any of %s" % [p, VALID_PROFILERS])
		if str(p) not in profilers:
			profilers.append(str(p))
	if profilers.is_empty():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"profilers must name at least one of %s" % [VALID_PROFILERS])
	var max_functions := int(params.get("max_functions", DEFAULT_FUNCTIONS))
	if max_functions < MIN_FUNCTIONS or max_functions > MAX_FUNCTIONS:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"max_functions must be %d..%d (got %d)" % [MIN_FUNCTIONS, MAX_FUNCTIONS, max_functions])
	var include_native := bool(params.get("include_native", false))

	## Gate on an attached debugger session, not EditorInterface.is_playing_scene():
	## a game launched outside the editor (--remote-debug with Keep Debug Server
	## Open) has an active session while is_playing_scene() is false.
	var target: Dictionary = _target_finder.call()
	if target.is_empty():
		return _not_running()

	var restarted := _capturing
	if _capturing:
		_toggle(false)
	_disconnect()
	_reset()
	_session = target.session
	_debugger = target.debugger
	_debugger.connect("debug_data", _on_debug_data)
	_session.stopped.connect(_on_session_stopped)
	_profilers = profilers
	_capturing = true
	_started_msec = Time.get_ticks_msec()
	_toggle(true, [max_functions, include_native])
	return {"data": _status_data().merged({"restarted": restarted})}


func profiler_stop(_params: Dictionary) -> Dictionary:
	var was_capturing := _capturing
	if _capturing:
		_toggle(false)
		_finish()
	return {"data": _status_data().merged({"was_capturing": was_capturing})}


func profiler_status(_params: Dictionary) -> Dictionary:
	_check_session()
	return {"data": _status_data()}


func profiler_get(params: Dictionary) -> Dictionary:
	var top_n := int(params.get("top_n", 20))
	var sort_by := str(params.get("sort_by", "self"))
	var last_frames := int(params.get("last_frames", 0))
	var per_frame := bool(params.get("per_frame", false))
	if top_n < 1:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "top_n must be >= 1 (got %d)" % top_n)
	if sort_by not in VALID_SORT_KEYS:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid sort_by '%s' — use one of %s" % [sort_by, VALID_SORT_KEYS])
	if last_frames < 0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "last_frames must be >= 0")
	_check_session()
	var scripts := _tail(_script_frames, last_frames)
	var visual := _tail(_visual_frames, last_frames)
	var data := _status_data()
	data["frame_times"] = summarize_frame_times(scripts)
	data["frame_cap"] = frame_cap(
		ProjectSettings.get_setting("application/run/max_fps", 0),
		ProjectSettings.get_setting("display/window/vsync/vsync_mode", DisplayServer.VSYNC_ENABLED),
		DisplayServer.screen_get_refresh_rate(),
		data.frame_times.frame_ms.get("p50", 0.0))
	data["functions"] = summarize_functions(scripts, _signatures, top_n, sort_by)
	data["servers"] = summarize_servers(scripts)
	data["visual"] = summarize_visual(visual)
	data["monitors"] = summarize_monitors(_monitor_frames, _monitor_names())
	data["hardware"] = _hardware
	if per_frame:
		data["per_frame"] = per_frame_rows(scripts, visual)
	return {"data": data}


# --- capture -----------------------------------------------------------------

func _on_debug_data(msg: String, data: Array) -> void:
	if not _capturing:
		return
	match msg:
		"servers:function_signature":
			if data.size() == 2:
				_signatures[int(data[1])] = str(data[0])
		"servers:profile_frame":
			if "scripts" in _profilers:
				if is_impossible_servers_frame(data):
					_dropped_frames += 1
				else:
					_push(_script_frames, data)
		"visual:profile_frame":
			if "visual" in _profilers:
				_push(_visual_frames, data)
		"visual:hardware_info":
			if data.size() == 2:
				_hardware = {"cpu": str(data[0]), "gpu": str(data[1])}
		"performance:profile_names":
			if data.size() == 2 and data[0] is Array:
				_custom_monitor_names = (data[0] as Array).map(func(n): return str(n))
		"performance:profile_frame":
			if "monitors" in _profilers:
				_push(_monitor_frames, data)


func _push(buffer: Array, data: Array) -> void:
	if buffer.size() >= MAX_FRAMES:
		_truncated = true
		return
	buffer.append(data)


## Mirrors the panels' Start/Stop buttons (ScriptEditorDebugger::_profiler_activate):
## "servers" carries [max_functions, include_native]; "visual" takes no options.
## Performance monitors are always on in a debug game, so they need no toggle.
func _toggle(enable: bool, servers_opts: Array = []) -> void:
	if _session == null or not _session.is_active():
		return
	if "scripts" in _profilers:
		_session.toggle_profiler("servers", enable, servers_opts if enable else [])
	if "visual" in _profilers:
		_session.toggle_profiler("visual", enable)


func _finish() -> void:
	_capturing = false
	_stopped_msec = Time.get_ticks_msec()
	_disconnect()


func _disconnect() -> void:
	if _debugger != null and is_instance_valid(_debugger) and _debugger.is_connected("debug_data", _on_debug_data):
		_debugger.disconnect("debug_data", _on_debug_data)
	_debugger = null
	if _session != null and is_instance_valid(_session) and _session.stopped.is_connected(_on_session_stopped):
		_session.stopped.disconnect(_on_session_stopped)


func _reset() -> void:
	_signatures = {}
	_script_frames = []
	_visual_frames = []
	_monitor_frames = []
	_hardware = {}
	_truncated = false
	_game_exited = false
	_dropped_frames = 0
	_stopped_msec = 0


## The game exiting mid-capture closes the session: end the capture there and
## keep the frames, so a later profiler_get still reads them. The session's
## `stopped` signal ends it on time; the poll covers a missed signal.
func _check_session() -> void:
	if _capturing and (_session == null or not is_instance_valid(_session) or not _session.is_active()):
		_on_session_stopped()


func _on_session_stopped() -> void:
	if _capturing:
		_game_exited = true
		_finish()


func _status_data() -> Dictionary:
	var end_msec := Time.get_ticks_msec() if _capturing else _stopped_msec
	return {
		"capturing": _capturing,
		"profilers": _profilers,
		"duration_s": snappedf(maxf(0.0, (end_msec - _started_msec) / 1000.0), 0.001) if _started_msec > 0 else 0.0,
		"frames": {
			"scripts": _script_frames.size(),
			"visual": _visual_frames.size(),
			"monitors": _monitor_frames.size(),
		},
		"dropped_frames": _dropped_frames,
		"truncated": _truncated,
		"game_exited": _game_exited,
	}


func _not_running() -> Dictionary:
	return ErrorCodes.make_not_ready(
		ErrorCodes.SUB_EDITOR_GAME_NOT_RUNNING,
		"No game is attached to this editor's debugger — start the project first", false,
		"Start the game with project_run, or launch it with --remote-debug to this editor while Debug > Keep Debug Server Open is on, then retry.")


## Find the active game session and the ScriptEditorDebugger behind it. The
## session id is the debugger's tab index (EditorDebuggerNode::plugins_capture).
func _find_game_debugger() -> Dictionary:
	if _debugger_plugin == null:
		return {}
	var session_id := -1
	var sessions := _debugger_plugin.get_sessions()
	for i in sessions.size():
		if sessions[i] != null and sessions[i].is_active():
			session_id = i
			break
	if session_id == -1:
		return {}
	var debuggers: Array[Node] = []
	_collect_debuggers(EditorInterface.get_base_control(), debuggers)
	for dbg in debuggers:
		var parent := dbg.get_parent()
		var index := (parent as TabContainer).get_tab_idx_from_control(dbg) if parent is TabContainer else dbg.get_index()
		if index == session_id or debuggers.size() == 1:
			if dbg.has_signal("debug_data"):
				return {"session": sessions[session_id], "debugger": dbg}
	return {}


static func _collect_debuggers(node: Node, out: Array[Node]) -> void:
	if node == null:
		return
	if node.get_class() == "ScriptEditorDebugger":
		out.append(node)
		return
	for child in node.get_children():
		_collect_debuggers(child, out)


func _monitor_names() -> Array:
	var names := monitor_names()
	names.append_array(_custom_monitor_names)
	return names


static func _tail(frames: Array, count: int) -> Array:
	if count <= 0 or count >= frames.size():
		return frames
	return frames.slice(frames.size() - count)


# --- decoding + aggregation (static: pure functions of the raw messages) -----

## Performance.Monitor names by index, as the engine orders the values in
## "performance:profile_frame" (RemoteDebugger::PerformanceProfiler::tick).
static func monitor_names() -> Array:
	var names := []
	names.resize(Performance.MONITOR_MAX)
	for constant in ClassDB.class_get_enum_constants("Performance", "Monitor"):
		var index := ClassDB.class_get_integer_constant("Performance", constant)
		if index >= 0 and index < Performance.MONITOR_MAX:
			names[index] = str(constant).to_lower()
	return names


## Script time is part of the frame, so a frame that reports more script time
## than frame time is bogus. Seen on a real project: one frame claiming 33 s of
## script time inside a ~50 ms frame, which skewed every average.
static func is_impossible_servers_frame(raw: Array) -> bool:
	return raw.size() >= 7 and float(raw[5]) > float(raw[1])


## ServersDebugger::ServersProfilerFrame::serialize layout: six scalars,
## then a counted list of servers (name, 2*n [function, seconds]), then
## 5*m script functions [sig_id, calls, self_s, total_s, internal_s].
static func decode_servers_frame(raw: Array) -> Dictionary:
	if raw.size() < 7:
		return {}
	var frame := {
		"frame": int(raw[0]),
		"frame_time": float(raw[1]),
		"process_time": float(raw[2]),
		"physics_time": float(raw[3]),
		"script_time": float(raw[5]),
		"servers": {},
		"functions": [],
	}
	var idx := 7
	for _s in int(raw[6]):
		if idx + 2 > raw.size():
			return frame
		var server := str(raw[idx])
		var size := int(raw[idx + 1])
		idx += 2
		var funcs := {}
		for j in int(size / 2.0):
			funcs[str(raw[idx])] = float(raw[idx + 1])
			idx += 2
		frame.servers[server] = funcs
	if idx >= raw.size():
		return frame
	var func_size := int(raw[idx])
	idx += 1
	for _f in int(func_size / 5.0):
		if idx + 5 > raw.size():
			break
		frame.functions.append([int(raw[idx]), int(raw[idx + 1]), float(raw[idx + 2]), float(raw[idx + 3])])
		idx += 5
	return frame


## VisualProfilerFrame layout: frame, 3*n, then [name, cpu_ms, gpu_ms]. The
## times are timestamps: an area lasts until the next one starts, the first
## and last areas bound the frame, ">name" opens a category and "<" closes it
## (EditorVisualProfiler::_update_frame). Each area maps to [cpu, gpu, leaf].
static func decode_visual_frame(raw: Array) -> Dictionary:
	if raw.size() < 2:
		return {}
	var areas := []
	var count := int(int(raw[1]) / 3.0)
	for i in count:
		var at := 2 + i * 3
		if at + 3 > raw.size():
			break
		areas.append([str(raw[at]), float(raw[at + 1]), float(raw[at + 2])])
	var result := {"frame": int(raw[0]), "cpu_ms": 0.0, "gpu_ms": 0.0, "areas": {}}
	if areas.size() < 2:
		return result
	result.cpu_ms = areas[-1][1] - areas[0][1]
	result.gpu_ms = areas[-1][2] - areas[0][2]
	var stack: Array[String] = []
	for i in range(1, areas.size() - 1):
		var name: String = areas[i][0]
		if name.begins_with("<"):
			stack.pop_back()
			continue
		if name.begins_with(">"):
			stack.append(name.substr(1).strip_edges())
			continue
		name = name.strip_edges()
		var cpu: float = areas[i + 1][1] - areas[i][1]
		var gpu: float = areas[i + 1][2] - areas[i][2]
		var path := ""
		for category in stack:
			path += category
			_add_area(result.areas, path, cpu, gpu, false)
			path += "/"
		_add_area(result.areas, path + name, cpu, gpu, true)
	return result


static func _add_area(areas: Dictionary, path: String, cpu: float, gpu: float, leaf: bool) -> void:
	var entry: Array = areas.get(path, [0.0, 0.0, leaf])
	entry[0] += cpu
	entry[1] += gpu
	areas[path] = entry


static func summarize_frame_times(raw_frames: Array) -> Dictionary:
	var series := {"frame_ms": [], "process_ms": [], "physics_ms": [], "script_ms": []}
	for raw in raw_frames:
		var f := decode_servers_frame(raw)
		if f.is_empty():
			continue
		series.frame_ms.append(f.frame_time * 1000.0)
		series.process_ms.append(f.process_time * 1000.0)
		series.physics_ms.append(f.physics_time * 1000.0)
		series.script_ms.append(f.script_time * 1000.0)
	var out := {}
	for key in series:
		out[key] = stats(series[key])
	return out


## Whether frame time is measuring the frame-rate cap rather than the game.
## The cap is the slower of application/run/max_fps and, with vsync on
## (enabled or adaptive), the screen refresh rate the editor sees.
static func frame_cap(max_fps: int, vsync_mode: int, refresh_rate: float, frame_ms_p50: float) -> Dictionary:
	var cap_ms := 0.0
	if max_fps > 0:
		cap_ms = 1000.0 / max_fps
	var vsync_caps := vsync_mode == DisplayServer.VSYNC_ENABLED or vsync_mode == DisplayServer.VSYNC_ADAPTIVE
	if vsync_caps and refresh_rate > 0.0:
		cap_ms = maxf(cap_ms, 1000.0 / refresh_rate)
	var capped := cap_ms > 0.0 and frame_ms_p50 >= cap_ms * CAP_BAND_LOW and frame_ms_p50 <= cap_ms * CAP_BAND_HIGH
	return {
		"max_fps": max_fps,
		"vsync_mode": ["disabled", "enabled", "adaptive", "mailbox"][clampi(vsync_mode, 0, 3)],
		"refresh_rate": snappedf(refresh_rate, 0.01),
		"cap_ms": snappedf(cap_ms, 0.001),
		"capped": capped,
	}


## Per-function totals over the window. Averages divide by every frame in
## the window, so a function absent from a frame counts as zero there; the
## medians are over the frames the function ran in.
static func summarize_functions(raw_frames: Array, signatures: Dictionary, top_n: int, sort_by: String) -> Array:
	var totals := {}
	var frame_count := 0
	for raw in raw_frames:
		var f := decode_servers_frame(raw)
		if f.is_empty():
			continue
		frame_count += 1
		for fn in f.functions:
			var t: Array = totals.get(fn[0], [0, 0.0, 0.0, 0, [], []])
			t[0] += fn[1]
			t[1] += fn[2]
			t[2] += fn[3]
			t[3] += 1
			t[4].append(fn[2])
			t[5].append(fn[3])
			totals[fn[0]] = t
	if frame_count == 0:
		return []
	var rows := []
	for sig_id in totals:
		var t: Array = totals[sig_id]
		var row := _describe_signature(str(signatures.get(sig_id, "")), int(sig_id))
		row["calls"] = t[0]
		row["self_ms"] = snappedf(t[1] * 1000.0, 0.0001)
		row["total_ms"] = snappedf(t[2] * 1000.0, 0.0001)
		row["self_ms_per_frame"] = snappedf(t[1] * 1000.0 / frame_count, 0.0001)
		row["total_ms_per_frame"] = snappedf(t[2] * 1000.0 / frame_count, 0.0001)
		row["self_ms_median"] = snappedf(_median(t[4]) * 1000.0, 0.0001)
		row["total_ms_median"] = snappedf(_median(t[5]) * 1000.0, 0.0001)
		row["calls_per_frame"] = snappedf(float(t[0]) / frame_count, 0.01)
		row["frames_seen"] = t[3]
		rows.append(row)
	var key: String = {"self": "self_ms", "total": "total_ms", "calls": "calls"}[sort_by]
	rows.sort_custom(func(a, b): return a[key] > b[key])
	return rows.slice(0, top_n)


static func _median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[clampi(ceili(0.5 * sorted.size()) - 1, 0, sorted.size() - 1)]


## Signatures read "script::line::function"; built-in scripts carry an extra
## "::" in their path (ScriptEditorDebugger::_msg_servers_profile_common).
static func _describe_signature(signature: String, sig_id: int) -> Dictionary:
	var parts := signature.split("::")
	if parts.size() == 3:
		return {"function": parts[2], "script": parts[0], "line": parts[1].to_int()}
	if parts.size() == 4:
		return {"function": parts[3], "script": parts[0] + "::" + parts[1], "line": parts[2].to_int()}
	if signature.is_empty():
		return {"function": "sig_%d" % sig_id, "script": "", "line": 0}
	return {"function": signature, "script": "", "line": 0}


## Average ms per frame for each server function (physics, navigation, ...).
static func summarize_servers(raw_frames: Array) -> Dictionary:
	var sums := {}
	var frame_count := 0
	for raw in raw_frames:
		var f := decode_servers_frame(raw)
		if f.is_empty():
			continue
		frame_count += 1
		for server in f.servers:
			var funcs: Dictionary = f.servers[server]
			for fn in funcs:
				var key := "%s/%s" % [server, fn]
				sums[key] = sums.get(key, 0.0) + funcs[fn]
	var out := {}
	for key in sums:
		out[key] = snappedf(sums[key] * 1000.0 / frame_count, 0.0001)
	return out


static func summarize_visual(raw_frames: Array) -> Dictionary:
	var cpu := []
	var gpu := []
	var sums := {}
	var frame_count := 0
	for raw in raw_frames:
		var v := decode_visual_frame(raw)
		if v.is_empty():
			continue
		frame_count += 1
		cpu.append(v.cpu_ms)
		gpu.append(v.gpu_ms)
		for path in v.areas:
			var acc: Array = sums.get(path, [0.0, 0.0, v.areas[path][2]])
			acc[0] += v.areas[path][0]
			acc[1] += v.areas[path][1]
			sums[path] = acc
	var areas := []
	for path in sums:
		areas.append({
			"path": path,
			"leaf": sums[path][2],
			"cpu_ms": snappedf(sums[path][0] / frame_count, 0.0001),
			"gpu_ms": snappedf(sums[path][1] / frame_count, 0.0001),
		})
	areas.sort_custom(func(a, b): return a.gpu_ms + a.cpu_ms > b.gpu_ms + b.cpu_ms)
	return {"cpu_ms": stats(cpu), "gpu_ms": stats(gpu), "areas": areas}


static func summarize_monitors(raw_frames: Array, names: Array) -> Dictionary:
	var series := {}
	for raw in raw_frames:
		for i in mini(raw.size(), names.size()):
			if names[i] == null or not (raw[i] is int or raw[i] is float):
				continue
			if not series.has(names[i]):
				series[names[i]] = []
			series[names[i]].append(float(raw[i]))
	var out := {}
	for key in series:
		var values: Array = series[key]
		var s := stats(values)
		s["last"] = values[-1]
		out[key] = s
	return out


## One row per frame number, ascending. Render times are keyed by the
## RenderingServer's profile frame, which can trail the process frame, so a
## frame number may carry only script times or only render times.
static func per_frame_rows(script_frames: Array, visual_frames: Array) -> Array:
	var rows_by_frame := {}
	for raw in script_frames:
		var f := decode_servers_frame(raw)
		if f.is_empty():
			continue
		rows_by_frame[f.frame] = {
			"frame": f.frame,
			"frame_ms": snappedf(f.frame_time * 1000.0, 0.001),
			"process_ms": snappedf(f.process_time * 1000.0, 0.001),
			"physics_ms": snappedf(f.physics_time * 1000.0, 0.001),
			"script_ms": snappedf(f.script_time * 1000.0, 0.001),
		}
	for raw in visual_frames:
		var v := decode_visual_frame(raw)
		if v.is_empty():
			continue
		var row: Dictionary = rows_by_frame.get(v.frame, {"frame": v.frame})
		row["cpu_render_ms"] = snappedf(v.cpu_ms, 0.001)
		row["gpu_render_ms"] = snappedf(v.gpu_ms, 0.001)
		rows_by_frame[v.frame] = row
	var frames := rows_by_frame.keys()
	frames.sort()
	return frames.map(func(n): return rows_by_frame[n])


## avg / min / max and nearest-rank percentiles.
static func stats(values: Array) -> Dictionary:
	if values.is_empty():
		return {"count": 0}
	var sorted := values.duplicate()
	sorted.sort()
	var total := 0.0
	for v in sorted:
		total += v
	var pick := func(p: float) -> float:
		return sorted[clampi(ceili(p * sorted.size()) - 1, 0, sorted.size() - 1)]
	return {
		"count": sorted.size(),
		"avg": snappedf(total / sorted.size(), 0.0001),
		"min": snappedf(sorted[0], 0.0001),
		"p50": snappedf(pick.call(0.5), 0.0001),
		"p90": snappedf(pick.call(0.9), 0.0001),
		"p99": snappedf(pick.call(0.99), 0.0001),
		"max": snappedf(sorted[-1], 0.0001),
	}
