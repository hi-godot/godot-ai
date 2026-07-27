@tool
extends McpTestSuite

const GameHelper := preload("res://addons/godot_ai/runtime/game_helper.gd")

const ROOT_NAME := "McpUiElementsRoot"


class PropertyProbe:
	extends Object

	static var property_list_calls := 0

	func _get_property_list() -> Array[Dictionary]:
		property_list_calls += 1
		return [{
			"name": "probe_value",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
		}]


class AlphaProbe:
	extends Object

	func _get_property_list() -> Array[Dictionary]:
		return [{
			"name": "alpha_value",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
		}]


class BetaProbe:
	extends Object

	func _get_property_list() -> Array[Dictionary]:
		return [{
			"name": "beta_value",
			"type": TYPE_STRING,
			"usage": PROPERTY_USAGE_DEFAULT,
		}]


var _helper: Node
var _root: Node


func suite_name() -> String:
	return "game_helper"


func suite_setup(_ctx: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		fail_setup("current_scene required")
		return
	_helper = GameHelper.new()
	scene_root.add_child(_helper)
	_root = CanvasLayer.new()
	_root.name = ROOT_NAME
	scene_root.add_child(_root)


func suite_teardown() -> void:
	if _root != null:
		_root.queue_free()
		_root = null
	if _helper != null:
		_helper.queue_free()
		_helper = null


func setup() -> void:
	## Reset input_sequence test state here (not just at each test's end) so a
	## mid-test assertion failure can't leak a registered/pressed _SEQ_ACTION
	## into a later test.
	_clear_seq_action()
	if _root == null:
		return
	for child in _root.get_children():
		_root.remove_child(child)
		child.free()


func test_object_has_property_caches_property_lists_by_script() -> void:
	_helper._property_name_cache.clear()
	PropertyProbe.property_list_calls = 0
	var probe := PropertyProbe.new()

	assert_true(_helper.call("_object_has_property", probe, "probe_value"))
	assert_true(_helper.call("_object_has_property", probe, "probe_value"))
	assert_eq(PropertyProbe.property_list_calls, 1)

	assert_true(_helper.call("_object_has_property", AlphaProbe.new(), "alpha_value"))
	assert_false(_helper.call("_object_has_property", AlphaProbe.new(), "beta_value"))
	assert_true(_helper.call("_object_has_property", BetaProbe.new(), "beta_value"))
	assert_false(_helper.call("_object_has_property", BetaProbe.new(), "alpha_value"))


func test_get_ui_elements_returns_controls_with_text_and_rects() -> void:
	assert_true(_helper.has_method("_game_get_ui_elements"),
		"game helper should expose get_ui_elements")
	var container := Node.new()
	container.name = "Container"
	_root.add_child(container)

	var title := Label.new()
	title.name = "Title"
	title.text = "Score: 10"
	title.position = Vector2(10, 20)
	title.size = Vector2(120, 30)
	container.add_child(title)

	var button := Button.new()
	button.name = "StartButton"
	button.text = "Start"
	button.disabled = true
	button.position = Vector2(20, 60)
	button.size = Vector2(90, 40)
	container.add_child(button)

	var result = _helper.call("_game_get_ui_elements", {
		"root_path": "/Main/%s" % ROOT_NAME,
		"include_hidden": true,
		"max_depth": 4,
	})

	assert_true(result is Dictionary, "get_ui_elements should return a Dictionary")
	assert_eq(result.root, "/Main/%s" % ROOT_NAME)
	assert_eq(result.total_count, 2)
	assert_eq(result.elements[0].name, "Title")
	assert_eq(result.elements[0].type, "Label")
	assert_eq(result.elements[0].text, "Score: 10")
	assert_has_key(result.elements[0], "visible")
	assert_eq(result.elements[0].disabled, false)
	assert_eq(result.elements[0].rect.position.x, 10.0)
	assert_eq(result.elements[0].rect.size.y, 30.0)
	assert_eq(result.elements[1].name, "StartButton")
	assert_eq(result.elements[1].disabled, true)
	assert_eq(result.elements[1].text, "Start")


func test_get_ui_elements_can_filter_disabled_and_include_hidden() -> void:
	assert_true(_helper.has_method("_game_get_ui_elements"),
		"game helper should expose get_ui_elements")
	var visible_enabled := LineEdit.new()
	visible_enabled.name = "NameInput"
	visible_enabled.text = "Ada"
	_root.add_child(visible_enabled)

	var disabled_button := Button.new()
	disabled_button.name = "DisabledButton"
	disabled_button.disabled = true
	_root.add_child(disabled_button)

	var hidden_label := Label.new()
	hidden_label.name = "HiddenButIncluded"
	hidden_label.text = "Hidden"
	hidden_label.visible = false
	_root.add_child(hidden_label)

	var result = _helper.call("_game_get_ui_elements", {
		"root_path": "/Main/%s" % ROOT_NAME,
		"include_hidden": true,
		"include_disabled": false,
		"max_depth": 1,
	})

	assert_true(result is Dictionary, "get_ui_elements should return a Dictionary")
	assert_eq(result.total_count, 2)
	var names := [result.elements[0].name, result.elements[1].name]
	assert_true(names.has("NameInput"), "enabled control should be included")
	assert_true(names.has("HiddenButIncluded"), "hidden control should be included when requested")
	assert_false(names.has("DisabledButton"), "disabled control should be filtered when requested")


# ----- input_mouse position resolution (#635) -----

func test_input_mouse_position_dict() -> void:
	var r: Dictionary = _helper.call("_resolve_mouse_position", {"x": 12.0, "y": 34.0})
	assert_false(r.has("error"), "valid dict must not error")
	assert_eq(r.position, Vector2(12, 34))


func test_input_mouse_position_array_coerces() -> void:
	## Arrays [x, y] are accepted as a coercion, matching the dict-or-array
	## flexibility elsewhere in the tool surface.
	var r: Dictionary = _helper.call("_resolve_mouse_position", [56.0, 78.0])
	assert_false(r.has("error"), "2-element array must not error")
	assert_eq(r.position, Vector2(56, 78))


func test_input_mouse_position_absent_falls_back() -> void:
	## Omitting position (null) is a deliberate default: use the live cursor.
	var r: Dictionary = _helper.call("_resolve_mouse_position", null)
	assert_false(r.has("error"), "absent position must fall back, not error")
	assert_true(r.has("position"))


func test_input_mouse_position_malformed_array_rejected() -> void:
	var r: Dictionary = _helper.call("_resolve_mouse_position", [1.0, 2.0, 3.0])
	assert_true(r.has("error"), "3-element array must be rejected, not silently substituted")
	## A rejection must NOT also hand back a fallback position — otherwise a
	## regression could silently substitute cursor coords despite the error.
	assert_false(r.has("position"), "rejected input must not carry a fallback position")


func test_input_mouse_position_wrong_type_rejected() -> void:
	## #635: a present but wrong-shaped position (here a bare number) must be
	## rejected instead of silently falling back to the cursor, which hid
	## caller bugs.
	var r: Dictionary = _helper.call("_resolve_mouse_position", 42.0)
	assert_true(r.has("error"), "scalar position must be rejected")
	assert_false(r.has("position"), "rejected input must not carry a fallback position")


func test_input_mouse_position_empty_dict_falls_back() -> void:
	## An empty {} is treated as "unspecified" (like absent) and falls back.
	var r: Dictionary = _helper.call("_resolve_mouse_position", {})
	assert_false(r.has("error"), "empty dict must fall back, not error")
	assert_true(r.has("position"))


func test_input_mouse_position_dict_without_xy_rejected() -> void:
	## Copilot review: a NON-empty dict carrying neither coordinate (e.g.
	## {"foo": 1}) is a caller mistake, not a request for the default — reject
	## it instead of silently substituting the cursor.
	var r: Dictionary = _helper.call("_resolve_mouse_position", {"foo": 1})
	assert_true(r.has("error"), "non-empty dict without x/y must be rejected")
	assert_false(r.has("position"))


func test_input_mouse_position_non_numeric_rejected() -> void:
	## Copilot review: non-numeric coordinates must be rejected rather than
	## coerced through float() (which would silently produce 0.0).
	var r_dict: Dictionary = _helper.call("_resolve_mouse_position", {"x": "left", "y": 5})
	assert_true(r_dict.has("error"), "non-numeric dict x must be rejected")
	assert_false(r_dict.has("position"))
	var r_arr: Dictionary = _helper.call("_resolve_mouse_position", ["a", "b"])
	assert_true(r_arr.has("error"), "non-numeric array elements must be rejected")
	assert_false(r_arr.has("position"))


func test_input_mouse_position_partial_dict_uses_number() -> void:
	## A partial dict with one numeric coordinate is still valid — the missing
	## axis defaults to the current cursor. (x present and numeric here.)
	var r: Dictionary = _helper.call("_resolve_mouse_position", {"x": 7})
	assert_false(r.has("error"), "partial numeric dict must not error")
	assert_eq(r.position.x, 7.0)


# ----- #777: stalled-main-loop synchronous screenshot fallback -----

func test_should_capture_stale_sync_requires_stall_plus_real_frame() -> void:
	## The sync stale capture only commits when awaiting can't produce a fresh
	## frame (frozen loop OR suppressed rendering) AND the viewport plausibly
	## holds a real frame.
	assert_true(GameHelper._should_capture_stale_sync(true, false, true, 5),
		"stalled loop + scene in tree + drawn frames commits the sync capture")
	assert_true(GameHelper._should_capture_stale_sync(false, true, true, 5),
		"stalled rendering with an alive loop (Windows minimize) also commits it")
	assert_false(GameHelper._should_capture_stale_sync(false, false, true, 5),
		"an alive, presenting game must take the fresh-frame await path")
	assert_false(GameHelper._should_capture_stale_sync(true, true, false, 5),
		"no current_scene (booting / custom main loop) has no trustworthy frame")
	assert_false(GameHelper._should_capture_stale_sync(true, true, true, 0),
		"zero frames drawn means the texture is the boot clear color, not a frame")


func test_main_loop_appears_stalled_before_first_tick() -> void:
	var helper: Node = GameHelper.new()
	assert_true(helper._main_loop_appears_stalled(),
		"the -1 sentinel (no _process tick yet) reads as stalled")
	helper.free()


func test_main_loop_appears_stalled_uses_threshold() -> void:
	var helper: Node = GameHelper.new()
	helper._last_loop_tick_msec = Time.get_ticks_msec()
	assert_false(helper._main_loop_appears_stalled(),
		"a just-ticked loop is alive")
	helper._last_loop_tick_msec = Time.get_ticks_msec() - (GameHelper.MAIN_LOOP_STALL_MSEC + 500)
	assert_true(helper._main_loop_appears_stalled(),
		"a loop silent past MAIN_LOOP_STALL_MSEC reads as stalled")
	helper.free()


func test_rendering_appears_stalled_false_before_first_advance() -> void:
	## A game that has never presented (booting, render-less) has no
	## trustworthy frame — the -1 sentinel must read as NOT render-stalled so
	## the await path's texture/image error replies stay in charge.
	var helper: Node = GameHelper.new()
	assert_false(helper._rendering_appears_stalled(),
		"no observed frame advance yet must not read as render-stalled")
	helper.free()


func test_rendering_appears_stalled_uses_threshold() -> void:
	## Windows minimize freezes presentation but not _process (#794 smoke,
	## 1b): frames_drawn stagnation past RENDER_STALL_MSEC is the freeze
	## signal there, independent of the loop beacon.
	var helper: Node = GameHelper.new()
	helper._last_frames_advance_msec = Time.get_ticks_msec()
	assert_false(helper._rendering_appears_stalled(),
		"a recent frame advance reads as rendering alive")
	helper._last_frames_advance_msec = (
		Time.get_ticks_msec() - (GameHelper.RENDER_STALL_MSEC + 500)
	)
	assert_true(helper._rendering_appears_stalled(),
		"frames_drawn flat past RENDER_STALL_MSEC reads as render-stalled")
	helper.free()


func test_process_records_frame_advance_beacon() -> void:
	## _process must update the rendering beacon only when frames_drawn
	## actually moves, so stagnation ages honestly between presents.
	var helper: Node = GameHelper.new()
	helper._last_frames_drawn_seen = Engine.get_frames_drawn() - 1
	helper._process(0.016)
	assert_eq(helper._last_frames_drawn_seen, Engine.get_frames_drawn(),
		"an observed frames_drawn change must be recorded")
	assert_eq(helper._last_frames_advance_msec, helper._last_loop_tick_msec,
		"the advance timestamp must match the tick that observed it")
	var stamped: int = helper._last_frames_advance_msec - 5000
	helper._last_frames_advance_msec = stamped
	helper._process(0.016)
	assert_eq(helper._last_frames_advance_msec, stamped,
		"no frames_drawn change must leave the advance timestamp untouched")
	helper.free()


func test_capture_and_reply_flags_stale_when_no_new_frame() -> void:
	## frames_at_request == current frames_drawn is exactly the frozen-loop
	## case: nothing can render between receipt and this synchronous capture,
	## so the reply must carry stale=true plus the frames_drawn diagnostic.
	## The editor 3D viewport stands in for the game root viewport.
	var viewport := EditorInterface.get_editor_viewport_3d()
	if viewport == null:
		skip("No editor 3D viewport available")
		return
	var helper: Node = GameHelper.new()
	helper._capture_and_reply("rid-stale", viewport, 64, Engine.get_frames_drawn())
	var reply: Dictionary = helper._last_screenshot_reply
	helper.free()
	if str(reply.get("kind")) == "error":
		skip("Viewport readback unavailable in this environment: %s" % str(reply.get("message")))
		return
	assert_eq(reply.get("request_id"), "rid-stale")
	assert_true(bool(reply.get("stale")), "no frame drawn after receipt -> stale flag set")
	assert_gt(int(reply.get("frames_drawn")), 0, "frames_drawn rides with the reply")


func test_capture_and_reply_fresh_when_frame_advanced() -> void:
	## frames_at_request one below the current count models the await path
	## having seen a fresh present: the reply must NOT be flagged stale.
	var viewport := EditorInterface.get_editor_viewport_3d()
	if viewport == null:
		skip("No editor 3D viewport available")
		return
	var helper: Node = GameHelper.new()
	helper._capture_and_reply("rid-fresh", viewport, 64, Engine.get_frames_drawn() - 1)
	var reply: Dictionary = helper._last_screenshot_reply
	helper.free()
	if str(reply.get("kind")) == "error":
		skip("Viewport readback unavailable in this environment: %s" % str(reply.get("message")))
		return
	assert_false(bool(reply.get("stale")), "a frame drawn after receipt -> not stale")


func test_screenshot_reply_error_records_seam() -> void:
	## The error paths stay synchronous and record through the same testing
	## seam (EngineDebugger is inactive in the editor harness).
	var helper: Node = GameHelper.new()
	helper._reply_error("rid-err", "No game root viewport available")
	assert_eq(helper._last_screenshot_reply.get("kind"), "error")
	assert_eq(helper._last_screenshot_reply.get("request_id"), "rid-err")
	assert_contains(str(helper._last_screenshot_reply.get("message")), "No game root viewport")
	helper.free()


# ----- input_sequence: pure plan validation (#814) -----

func test_plan_input_sequence_normalizes_defaults() -> void:
	var plan: Dictionary = _helper.call(
		"_plan_input_sequence", {"steps": [{"at_frame": 0, "action": "jump"}]})
	assert_false(plan.has("error"), "valid plan must not error")
	assert_eq(plan.end_frame, 0)
	var step: Dictionary = plan.steps[0]
	assert_eq(step.pressed, true, "pressed defaults to true")
	assert_eq(step.strength, 1.0, "strength defaults to 1.0")


func test_plan_input_sequence_end_frame_includes_settle() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence", {
		"steps": [{"at_frame": 6, "action": "jump"}],
		"settle_frames": 5,
	})
	assert_eq(plan.end_frame, 11, "end_frame is last at_frame + settle_frames")


func test_plan_input_sequence_rejects_empty() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence", {"steps": []})
	assert_true(plan.has("error"), "empty steps must be rejected")


func test_plan_input_sequence_rejects_out_of_order() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence", {"steps": [
		{"at_frame": 10, "action": "a"},
		{"at_frame": 5, "action": "b"},
	]})
	assert_true(plan.has("error"), "descending at_frame must be rejected")
	assert_contains(plan.error, "ordered")


func test_plan_input_sequence_allows_equal_frames() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence", {"steps": [
		{"at_frame": 3, "action": "a"},
		{"at_frame": 3, "action": "b"},
	]})
	assert_false(plan.has("error"), "equal at_frame (a combo) is valid")


func test_plan_input_sequence_rejects_negative_frame() -> void:
	var plan: Dictionary = _helper.call(
		"_plan_input_sequence", {"steps": [{"at_frame": -1, "action": "a"}]})
	assert_true(plan.has("error"), "negative at_frame must be rejected")


func test_plan_input_sequence_rejects_over_frame_cap() -> void:
	var cap: int = GameHelper.MAX_SEQUENCE_FRAMES
	var plan: Dictionary = _helper.call("_plan_input_sequence", {
		"steps": [{"at_frame": cap, "action": "a"}],
		"settle_frames": 1,
	})
	assert_true(plan.has("error"), "spanning past the frame cap must be rejected")


func test_plan_input_sequence_rejects_over_step_cap() -> void:
	var steps: Array = []
	for i in GameHelper.MAX_SEQUENCE_STEPS + 1:
		steps.append({"at_frame": 0, "action": "a"})
	var plan: Dictionary = _helper.call("_plan_input_sequence", {"steps": steps})
	assert_true(plan.has("error"), "exceeding the step cap must be rejected")


# The planner validates field *kinds* rather than coercing (matches the
# server-side validator), so a malformed direct message can't silently change
# meaning (pressed="false" -> true, at_frame="oops" -> 0).

func test_plan_input_sequence_rejects_non_bool_pressed() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence",
		{"steps": [{"at_frame": 0, "action": "a", "pressed": "false"}]})
	assert_true(plan.has("error"), "string pressed must be rejected, not coerced to true")


func test_plan_input_sequence_rejects_non_number_at_frame() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence",
		{"steps": [{"at_frame": "oops", "action": "a"}]})
	assert_true(plan.has("error"), "non-numeric at_frame must be rejected, not coerced to 0")


func test_plan_input_sequence_rejects_non_number_strength() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence",
		{"steps": [{"at_frame": 0, "action": "a", "strength": "hard"}]})
	assert_true(plan.has("error"), "non-numeric strength must be rejected")


func test_plan_input_sequence_rejects_non_number_settle() -> void:
	var plan: Dictionary = _helper.call("_plan_input_sequence",
		{"steps": [{"at_frame": 0, "action": "a"}], "settle_frames": "nope"})
	assert_true(plan.has("error"), "non-numeric settle_frames must be rejected")


func test_plan_input_sequence_accepts_float_frames_from_json() -> void:
	## JSON round-trips whole numbers as float; the kind-check must still accept
	## them (it validates number-ness, not strictly int).
	var plan: Dictionary = _helper.call("_plan_input_sequence",
		{"steps": [{"at_frame": 2.0, "action": "a"}], "settle_frames": 1.0})
	assert_false(plan.has("error"), "float at_frame/settle from JSON must be accepted")
	assert_eq(plan.end_frame, 3)


# ----- input_sequence: async frame-stepping (#814) -----

const _SEQ_ACTION := "mcp_test_seq_action"


func _register_seq_action() -> void:
	if not InputMap.has_action(_SEQ_ACTION):
		InputMap.add_action(_SEQ_ACTION)


func _clear_seq_action() -> void:
	Input.action_release(_SEQ_ACTION)
	if InputMap.has_action(_SEQ_ACTION):
		InputMap.erase_action(_SEQ_ACTION)


func test_run_input_sequence_applies_steps_across_frames() -> void:
	## The editor test runner calls tests synchronously and never pumps
	## `process_frame` (test_runner.gd::_run_one_test), so a real frame-await
	## would suspend and record 0 assertions. Inject a synchronous frame-waiter
	## so the multi-frame loop runs to completion in one call — the per-step
	## timing (one frame each) is engine-guaranteed; what we assert here is the
	## scheduling/application layered on top: steps fire on their scheduled
	## frame, settle is counted, and the reply shape is right.
	_register_seq_action()
	var helper: GameHelper = _helper
	helper._frame_waiter = func() -> void: pass
	await helper._run_input_sequence("req-seq-1", {
		"steps": [
			{"at_frame": 0, "action": _SEQ_ACTION, "pressed": true},
			{"at_frame": 2, "action": _SEQ_ACTION, "pressed": false},
		],
		"settle_frames": 1,
	})
	helper._frame_waiter = Callable()
	var reply: Dictionary = helper._last_game_command_reply
	assert_eq(reply.kind, "response", "a valid sequence replies with a response")
	var result: Dictionary = reply.result
	assert_eq(result.completed, true)
	assert_eq(result.steps_applied, 2, "both steps applied across frames")
	assert_eq(result.frames_elapsed, 3, "2 (last step) + 1 settle")
	assert_eq(result.applied[0].at_frame, 0)
	assert_eq(result.applied[1].at_frame, 2, "second step fires on its scheduled frame")
	assert_false(Input.is_action_pressed(_SEQ_ACTION),
		"the release step must have run, leaving the action up")
	assert_eq(result.actions_pressed_at_end, [], "nothing left held")
	# cleanup is fail-safe in setup(), so no per-test _clear_seq_action() here


func test_run_input_sequence_reports_actions_left_pressed() -> void:
	_register_seq_action()
	var helper: GameHelper = _helper
	# press with no matching release — caller must be told it's still held
	await helper._run_input_sequence("req-seq-2", {
		"steps": [{"at_frame": 0, "action": _SEQ_ACTION, "pressed": true}],
	})
	var result: Dictionary = helper._last_game_command_reply.result
	assert_eq(result.actions_pressed_at_end, [_SEQ_ACTION])
	assert_true(Input.is_action_pressed(_SEQ_ACTION))


func test_run_input_sequence_unknown_action_fails_fast() -> void:
	var helper: GameHelper = _helper
	var absent := "mcp_definitely_not_an_action"
	assert_false(InputMap.has_action(absent), "precondition: action must not exist")
	await helper._run_input_sequence("req-seq-3", {
		"steps": [{"at_frame": 0, "action": absent, "pressed": true}],
	})
	var reply: Dictionary = helper._last_game_command_reply
	assert_eq(reply.kind, "error", "an unknown action must error, not apply partially")
	assert_contains(reply.message, absent)
	assert_false(Input.is_action_pressed(absent))


func test_run_input_sequence_invalid_plan_replies_error() -> void:
	var helper: GameHelper = _helper
	await helper._run_input_sequence("req-seq-4", {"steps": []})
	assert_eq(helper._last_game_command_reply.kind, "error",
		"a plan error must surface as a game_command error")
