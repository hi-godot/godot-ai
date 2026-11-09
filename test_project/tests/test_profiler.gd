@tool
extends McpTestSuite

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ProfilerHandler := preload("res://addons/godot_ai/handlers/profiler_handler.gd")

## Raw messages in the exact layouts the engine sends (ServersDebugger
## ServersProfilerFrame / VisualProfilerFrame serialize, 4.7-stable).
const SERVERS_FRAME := [
	10, 0.016, 0.010, 0.002, 0.0166, 0.003,
	1, "physics_3d", 2, "step", 0.001,
	10, 0, 2, 0.002, 0.003, 0.0, 1, 1, 0.001, 0.001, 0.0,
]
const VISUAL_FRAME := [
	10, 15,
	"Begin", 0.0, 0.0,
	"> Render", 1.0, 1.5,
	"Pass A", 1.0, 1.5,
	"<", 3.0, 4.0,
	"End", 3.5, 4.5,
]

var _handler


func suite_name() -> String:
	return "profiler"


func setup() -> void:
	_handler = ProfilerHandler.new(null)


func test_decode_servers_frame_reads_engine_layout() -> void:
	var f: Dictionary = ProfilerHandler.decode_servers_frame(SERVERS_FRAME)
	assert_eq(f.frame, 10)
	assert_eq(f.frame_time, 0.016)
	assert_eq(f.servers["physics_3d"]["step"], 0.001)
	assert_eq(f.functions.size(), 2)
	assert_eq(f.functions[0], [0, 2, 0.002, 0.003])


func test_decode_visual_frame_turns_timestamps_into_durations() -> void:
	var v: Dictionary = ProfilerHandler.decode_visual_frame(VISUAL_FRAME)
	assert_eq(v.cpu_ms, 3.5)
	assert_eq(v.gpu_ms, 4.5)
	assert_has_key(v.areas, "Render/Pass A")
	assert_eq(v.areas["Render/Pass A"], [2.0, 2.5])
	assert_eq(v.areas["Render"], [2.0, 2.5], "a category sums the passes inside it")


func test_truncated_frames_decode_without_error() -> void:
	assert_eq(ProfilerHandler.decode_servers_frame([1, 2]), {})
	var partial: Dictionary = ProfilerHandler.decode_servers_frame(SERVERS_FRAME.slice(0, 12))
	assert_eq(partial.functions.size(), 0)
	assert_eq(ProfilerHandler.decode_visual_frame([1]), {})


func test_functions_sorted_and_named_from_signatures() -> void:
	var signatures := {0: "res://a.gd::12::_process", 1: "res://b.gd::4::helper"}
	var rows: Array = ProfilerHandler.summarize_functions(
		[SERVERS_FRAME, SERVERS_FRAME], signatures, 10, "self")
	assert_eq(rows.size(), 2)
	assert_eq(rows[0].function, "_process")
	assert_eq(rows[0].script, "res://a.gd")
	assert_eq(rows[0].line, 12)
	assert_eq(rows[0].calls, 4)
	assert_eq(rows[0].self_ms, 4.0)
	assert_eq(rows[0].self_ms_per_frame, 2.0)
	assert_eq(rows[0].frames_seen, 2)
	var top_one: Array = ProfilerHandler.summarize_functions([SERVERS_FRAME], signatures, 1, "calls")
	assert_eq(top_one.size(), 1)
	assert_eq(top_one[0].function, "_process")


func test_stats_percentiles_use_nearest_rank() -> void:
	var values := []
	for i in range(1, 101):
		values.append(float(i))
	var s: Dictionary = ProfilerHandler.stats(values)
	assert_eq(s.count, 100)
	assert_eq(s.avg, 50.5)
	assert_eq(s.p50, 50.0)
	assert_eq(s.p99, 99.0)
	assert_eq(s.max, 100.0)
	assert_eq(ProfilerHandler.stats([]), {"count": 0})


func test_monitor_names_follow_performance_enum() -> void:
	var names: Array = ProfilerHandler.monitor_names()
	assert_eq(names.size(), Performance.MONITOR_MAX)
	assert_eq(names[Performance.TIME_FPS], "time_fps")
	assert_eq(names[Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME], "render_total_draw_calls_in_frame")


func test_debug_data_feeds_profiler_get() -> void:
	_handler._capturing = true
	_handler._profilers.assign(["scripts", "visual", "monitors"])
	_handler._on_debug_data("servers:function_signature", ["res://a.gd::12::_process", 0])
	_handler._on_debug_data("servers:profile_frame", SERVERS_FRAME)
	_handler._on_debug_data("visual:profile_frame", VISUAL_FRAME)
	var monitors := []
	monitors.resize(Performance.MONITOR_MAX)
	monitors.fill(0)
	monitors[Performance.TIME_FPS] = 60
	_handler._on_debug_data("performance:profile_frame", monitors)
	_handler._on_debug_data("scene:unrelated", [1])
	_handler._capturing = false

	var result: Dictionary = _handler.profiler_get({"top_n": 5, "per_frame": true})
	assert_has_key(result, "data")
	var data: Dictionary = result.data
	assert_eq(data.frames, {"scripts": 1, "visual": 1, "monitors": 1})
	assert_eq(data.functions[0].function, "_process")
	assert_eq(data.functions[1].function, "sig_1", "an unseen signature keeps its id")
	assert_eq(data.frame_times.frame_ms.avg, 16.0)
	assert_eq(data.servers["physics_3d/step"], 1.0)
	assert_eq(data.visual.gpu_ms.avg, 4.5)
	assert_eq(data.monitors.time_fps.last, 60.0)
	assert_eq(data.per_frame[0].frame, 10)
	assert_eq(data.per_frame[0].gpu_render_ms, 4.5)


func test_frames_ignored_while_not_capturing() -> void:
	_handler._profilers.assign(["scripts"])
	_handler._on_debug_data("servers:profile_frame", SERVERS_FRAME)
	var data: Dictionary = _handler.profiler_status({}).data
	assert_eq(data.frames.scripts, 0)
	assert_false(data.capturing)


func test_last_frames_limits_window() -> void:
	_handler._capturing = true
	_handler._profilers.assign(["scripts"])
	var slow := SERVERS_FRAME.duplicate()
	slow[1] = 0.1
	_handler._on_debug_data("servers:profile_frame", slow)
	_handler._on_debug_data("servers:profile_frame", SERVERS_FRAME)
	_handler._capturing = false
	var data: Dictionary = _handler.profiler_get({"last_frames": 1}).data
	assert_eq(data.frame_times.frame_ms.count, 1)
	assert_eq(data.frame_times.frame_ms.max, 16.0)


func test_start_rejects_bad_params() -> void:
	assert_is_error(_handler.profiler_start({"profilers": ["gpu"]}), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(_handler.profiler_start({"profilers": "scripts"}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.profiler_start({"profilers": []}), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(_handler.profiler_start({"max_functions": 8}), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(_handler.profiler_get({"top_n": 0}), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(_handler.profiler_get({"sort_by": "fast"}), ErrorCodes.VALUE_OUT_OF_RANGE)


func test_start_without_running_game_is_not_ready() -> void:
	if EditorInterface.is_playing_scene():
		skip("A game is running in this editor")
		return
	var result: Dictionary = _handler.profiler_start({})
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(result.error.data.sub_code, ErrorCodes.SUB_EDITOR_GAME_NOT_RUNNING)


func test_stop_without_capture_is_idempotent() -> void:
	var data: Dictionary = _handler.profiler_stop({}).data
	assert_false(data.was_capturing)
	assert_false(data.capturing)


func test_game_exit_ends_capture_and_keeps_frames() -> void:
	_handler._capturing = true
	_handler._started_msec = Time.get_ticks_msec()
	_handler._profilers.assign(["scripts"])
	_handler._on_debug_data("servers:profile_frame", SERVERS_FRAME)
	_handler._on_session_stopped()
	var data: Dictionary = _handler.profiler_status({}).data
	assert_false(data.capturing)
	assert_true(data.game_exited)
	assert_eq(data.frames.scripts, 1)
