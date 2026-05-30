extends Node

## Godot AI MCP — game-process helper.
##
## Registered as an autoload by plugin.gd when the Godot AI plugin is enabled.
## Runs in the running game process (separate from the editor) so the plugin
## can request the game's framebuffer over the editor-debugger channel.
##
## The editor never has direct access to the game's pixels: even when "Embed
## Game Mode" is on, the game is still a separate OS child process whose
## window is reparented into the editor via Win32 SetParent / X11
## XReparentWindow / macOS remote layer (Godot PR godotengine/godot#99010).
## So viewport-texture capture on the editor side never contains game pixels.
## This autoload solves that by replying to "mcp:take_screenshot" debug
## messages with a PNG of Viewport.get_texture() from inside the game.
##
## No-ops in the editor (Engine.is_editor_hint) and silently sits idle
## when the debugger channel is inactive (e.g. exported release builds)
## — register_message_capture is safe to call either way, it's
## send_message that requires an active channel.

const CAPTURE_PREFIX := "mcp"
## Cap per-frame flush so a runaway print loop can't blow the debugger's
## packet budget in a single send. Surplus stays queued for the next frame.
const FLUSH_BATCH_LIMIT := 200

const LoggerLoader := preload("res://addons/godot_ai/runtime/logger_loader.gd")

var _registered := false
## Untyped because the McpGameLogger script is loaded dynamically (it
## extends Logger, which only exists in Godot 4.5+).
var _logger
var _logger_attached := false
## Entries drained from the logger but not yet sent over the debugger
## channel. Holds the tail of one drain() so we can bleed it out across
## frames at FLUSH_BATCH_LIMIT per frame rather than blasting the whole
## queue in a single _process tick.
var _pending_outbound: Array = []
## #490: in-flight evals, keyed by request_id (multiple deferred game_evals
## can run at once). Each entry: {node:Node, token:String, baseline:int}.
## `token` names this eval's unique wrapper function so a runtime error is
## attributed only to the eval that actually raised it — not an unrelated
## background game error, and not a sibling overlapping eval. `baseline` is the
## logger's script-error seq just before this eval ran. The editor's eval_check
## probe (and #488's in-flight poll loop, when the game is focused) consult
## these to report a runtime error that aborted execute() before the reply.
var _inflight_evals: Dictionary = {}
var _eval_token_counter: int = 0


func _ready() -> void:
	## Only run in the game process, not in the editor. Use is_editor_hint
	## — NOT OS.has_feature("editor"), which is a BUILD-config check
	## (TOOLS_ENABLED) and returns true in the game subprocess too because
	## the game is spawned with the same editor binary. is_editor_hint is
	## the runtime-context check: true only inside the editor GUI, false
	## in play-from-editor. The earlier has_feature check was causing us
	## to skip registration in the game and time out every capture.
	if Engine.is_editor_hint():
		return
	## register_message_capture is safe to call before the debugger
	## handshake completes; the capture sits until a message arrives.
	EngineDebugger.register_message_capture(CAPTURE_PREFIX, _on_debug_message)
	_registered = true
	## Capture print() / printerr() / push_error() / push_warning() and
	## ferry them to the editor in mcp:log_batch messages flushed from
	## _process. Logger subclassing was added in Godot 4.5 — gate on
	## ClassDB so the rest of the helper still loads on older engines.
	## game_logger.gd lives in the `.gdignore`'d runtime/loggers/ folder so
	## it never parse-errors during a < 4.5 editor scan; LoggerLoader
	## compiles it from source at runtime, only past this gate.
	if ClassDB.class_exists("Logger") and OS.has_method("add_logger"):
		var logger_script := LoggerLoader.build(LoggerLoader.GAME_LOGGER_PATH)
		if logger_script != null:
			_logger = logger_script.new()
			OS.call("add_logger", _logger)
			_logger_attached = true
	## Routed to the editor's Output panel via Godot's remote-stdout
	## forwarder — handy when diagnosing why capture timed out.
	print("[godot_ai game_helper] registered mcp capture (debugger active=%s, logger=%s)"
		% [EngineDebugger.is_active(), _logger_attached])
	## Boot beacon so the editor side can confirm the autoload ran even
	## if no screenshot was ever requested.
	if EngineDebugger.is_active():
		EngineDebugger.send_message("mcp:hello", [])


func _process(_delta: float) -> void:
	## Drain the logger queue on the main thread (Logger virtuals can fire
	## from any thread; EngineDebugger.send_message is only safe from main).
	## Send at most one FLUSH_BATCH_LIMIT-sized batch per frame so a runaway
	## print loop can't stall the game by shoving thousands of entries
	## through the debugger packet path in a single tick. Surplus stays in
	## `_pending_outbound` and bleeds out across subsequent frames.
	if not _logger_attached or _logger == null:
		return
	if not EngineDebugger.is_active():
		return
	if _pending_outbound.is_empty():
		if not _logger.has_pending():
			return
		_pending_outbound = _logger.drain()
	var batch := _pending_outbound.slice(0, FLUSH_BATCH_LIMIT)
	_pending_outbound = _pending_outbound.slice(FLUSH_BATCH_LIMIT)
	EngineDebugger.send_message("mcp:log_batch", [batch])


func _exit_tree() -> void:
	if _registered:
		EngineDebugger.unregister_message_capture(CAPTURE_PREFIX)
		_registered = false
	if _logger_attached and _logger != null and OS.has_method("remove_logger"):
		OS.call("remove_logger", _logger)
		_logger_attached = false
		_logger = null


## Dispatched for messages prefixed "mcp:" on the debugger channel.
## Different Godot versions pass either the tail ("take_screenshot") or the
## full message ("mcp:take_screenshot") to the capture callable — accept
## both forms so this works across 4.2/4.3/4.4/4.5.
func _on_debug_message(message: String, data: Array) -> bool:
	var action := message.trim_prefix("mcp:")
	match action:
		"take_screenshot":
			_handle_take_screenshot(data)
			return true
		"eval":
			_handle_eval(data)
			return true
		"eval_check":
			_handle_eval_check(data)
			return true
		"game_command":
			_handle_game_command(data)
			return true
	return false


func _handle_take_screenshot(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var max_resolution: int = int(data[1]) if data.size() > 1 else 0

	var viewport := get_tree().root
	if viewport == null:
		_reply_error(request_id, "No game root viewport available")
		return

	var texture := viewport.get_texture()
	if texture == null:
		_reply_error(request_id, "Root viewport has no texture (headless?)")
		return

	var image := texture.get_image()
	if image == null or image.is_empty():
		_reply_error(request_id, "Captured an empty image from game viewport")
		return

	var original_width := image.get_width()
	var original_height := image.get_height()

	if max_resolution > 0:
		var longest := maxi(original_width, original_height)
		if longest > max_resolution:
			var scale := float(max_resolution) / float(longest)
			var new_w := maxi(1, int(original_width * scale))
			var new_h := maxi(1, int(original_height * scale))
			image.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)

	var png := image.save_png_to_buffer()
	var b64 := Marshalls.raw_to_base64(png)

	EngineDebugger.send_message("mcp:screenshot_response", [
		request_id,
		b64,
		image.get_width(),
		image.get_height(),
		original_width,
		original_height,
	])


func _reply_error(request_id: String, message: String) -> void:
	EngineDebugger.send_message("mcp:screenshot_error", [request_id, message])


## --- game_command: curated runtime inspection and input ---

func _handle_game_command(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var op: String = data[1] if data.size() > 1 else ""
	var params_json: String = data[2] if data.size() > 2 else "{}"

	if request_id.is_empty():
		return
	if op.is_empty():
		_reply_game_command_error(request_id, "No op provided")
		return

	var json := JSON.new()
	var parse_err := json.parse(params_json)
	if parse_err != OK or not (json.data is Dictionary):
		_reply_game_command_error(request_id, "Invalid params JSON")
		return

	var result: Dictionary
	match op:
		"get_scene_tree":
			result = _game_get_scene_tree(json.data)
		"get_node_info":
			result = _game_get_node_info(json.data)
		"get_ui_elements":
			result = _game_get_ui_elements(json.data)
		"input_key":
			result = _game_input_key(json.data)
		"input_mouse":
			result = _game_input_mouse(json.data)
		"input_gamepad":
			result = _game_input_gamepad(json.data)
		"input_state":
			result = _game_input_state(json.data)
		_:
			_reply_game_command_error(request_id, "Unknown game op: %s" % op)
			return

	result["source"] = "game"
	result["op"] = op
	EngineDebugger.send_message("mcp:game_command_response",
		[request_id, JSON.stringify(_variant_to_json(result))])


func _reply_game_command_error(request_id: String, message: String) -> void:
	EngineDebugger.send_message("mcp:game_command_error", [request_id, message])


func _game_get_scene_tree(params: Dictionary) -> Dictionary:
	var depth := maxi(0, int(params.get("depth", 10)))
	var root := _resolve_runtime_node(str(params.get("root_path", "")))
	if root == null:
		return {"root": "", "nodes": [], "total_count": 0, "not_found": params.get("root_path", "")}

	var nodes: Array[Dictionary] = []
	_collect_runtime_nodes(root, 0, depth, nodes)
	return {
		"root": _runtime_path(root),
		"nodes": nodes,
		"total_count": nodes.size(),
	}


func _collect_runtime_nodes(node: Node, current_depth: int, max_depth: int, out: Array[Dictionary]) -> void:
	out.append({
		"name": node.name,
		"type": node.get_class(),
		"path": _runtime_path(node),
		"children_count": node.get_child_count(),
	})
	if current_depth >= max_depth:
		return
	for child in node.get_children():
		if child is Node:
			_collect_runtime_nodes(child, current_depth + 1, max_depth, out)


func _game_get_node_info(params: Dictionary) -> Dictionary:
	var path := str(params.get("path", ""))
	var node := _resolve_runtime_node(path)
	if node == null:
		return {"path": path, "found": false}

	var info := {
		"path": _runtime_path(node),
		"name": node.name,
		"type": node.get_class(),
		"children_count": node.get_child_count(),
		"groups": node.get_groups(),
		"found": true,
	}
	if bool(params.get("include_properties", true)):
		info["properties"] = _runtime_node_properties(node)
	return info


func _game_get_ui_elements(params: Dictionary) -> Dictionary:
	var max_depth := maxi(0, int(params.get("max_depth", 10)))
	var include_hidden := bool(params.get("include_hidden", false))
	var include_disabled := bool(params.get("include_disabled", true))
	var root_path := str(params.get("root_path", ""))
	var root := _resolve_runtime_node(root_path)
	if root == null:
		return {"root": "", "elements": [], "total_count": 0, "not_found": root_path}

	var elements: Array[Dictionary] = []
	_collect_ui_elements(root, 0, max_depth, include_hidden, include_disabled, elements)
	return {
		"root": _runtime_path(root),
		"elements": elements,
		"total_count": elements.size(),
	}


func _collect_ui_elements(
	node: Node,
	current_depth: int,
	max_depth: int,
	include_hidden: bool,
	include_disabled: bool,
	out: Array[Dictionary]
) -> void:
	if node is Control:
		var control := node as Control
		var visible := _control_visible_in_tree(control)
		var disabled := _control_disabled(control)
		if (include_hidden or visible) and (include_disabled or not disabled):
			out.append(_ui_element_info(control, visible, disabled))

	if current_depth >= max_depth:
		return
	for child in node.get_children():
		if child is Node:
			_collect_ui_elements(
				child,
				current_depth + 1,
				max_depth,
				include_hidden,
				include_disabled,
				out
			)


func _ui_element_info(control: Control, visible: bool, disabled: bool) -> Dictionary:
	var info := {
		"path": _runtime_path(control),
		"name": control.name,
		"type": control.get_class(),
		"visible": visible,
		"disabled": disabled,
		"rect": _variant_to_json(control.get_rect()),
		"global_rect": _variant_to_json(control.get_global_rect()),
	}
	if _object_has_property(control, "text"):
		info["text"] = str(control.get("text"))
	return info


func _control_disabled(control: Control) -> bool:
	if _object_has_property(control, "disabled"):
		return bool(control.get("disabled"))
	return false


func _control_visible_in_tree(control: Control) -> bool:
	if not control.visible:
		return false
	var parent := control.get_parent()
	while parent != null:
		if parent is CanvasItem and not (parent as CanvasItem).visible:
			return false
		parent = parent.get_parent()
	if Engine.is_editor_hint():
		return true
	return control.is_visible_in_tree()


static var _property_name_cache: Dictionary = {}


func _object_has_property(obj: Object, property_name: String) -> bool:
	var key := _property_cache_key(obj)
	if not _property_name_cache.has(key):
		var names := {}
		for prop in obj.get_property_list():
			names[str(prop.get("name", ""))] = true
		_property_name_cache[key] = names
	return (_property_name_cache[key] as Dictionary).has(property_name)


func _property_cache_key(obj: Object) -> String:
	var script = obj.get_script()
	if script == null:
		return obj.get_class()
	var script_id := str(script.get_instance_id())
	if not script.resource_path.is_empty():
		script_id = script.resource_path
	return "%s:%s" % [obj.get_class(), script_id]


func _runtime_node_properties(node: Node) -> Dictionary:
	var props := {}
	for p in node.get_property_list():
		var name := str(p.get("name", ""))
		var usage := int(p.get("usage", 0))
		if name.is_empty() or (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		props[name] = _variant_to_json(node.get(name))
	return props


func _resolve_runtime_node(path: String) -> Node:
	var scene_root := _current_scene_root()
	if scene_root == null:
		return null
	if path.is_empty() or path == "/":
		return scene_root

	if path.begins_with("/root/"):
		return get_tree().root.get_node_or_null(path.trim_prefix("/root/"))

	var scene_path := path.trim_prefix("/")
	if scene_path == str(scene_root.name):
		return scene_root
	var prefix := str(scene_root.name) + "/"
	if scene_path.begins_with(prefix):
		scene_path = scene_path.substr(prefix.length())
	return scene_root.get_node_or_null(scene_path)


func _runtime_path(node: Node) -> String:
	var scene_root := _current_scene_root()
	if scene_root == null:
		return str(node.get_path())
	if node == scene_root:
		return "/" + str(scene_root.name)
	return "/" + str(scene_root.name) + "/" + str(scene_root.get_path_to(node))


func _current_scene_root() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	var scene_root := tree.current_scene
	if scene_root == null and Engine.is_editor_hint():
		scene_root = EditorInterface.get_edited_scene_root()
	return scene_root


func _game_input_key(params: Dictionary) -> Dictionary:
	var key_name := str(params.get("key", ""))
	var keycode := OS.find_keycode_from_string(key_name)
	if keycode == KEY_NONE:
		return {"sent": false, "error": "Unknown key: %s" % key_name}
	var ev := InputEventKey.new()
	ev.keycode = keycode
	ev.physical_keycode = keycode
	ev.pressed = bool(params.get("pressed", true))
	ev.echo = bool(params.get("echo", false))
	Input.parse_input_event(ev)
	return {"sent": true, "key": key_name, "pressed": ev.pressed}


func _game_input_mouse(params: Dictionary) -> Dictionary:
	var event := str(params.get("event", "button"))
	var pos := _dict_to_vector2(params.get("position", {}))
	match event:
		"motion":
			var motion := InputEventMouseMotion.new()
			motion.position = pos
			motion.global_position = pos
			Input.parse_input_event(motion)
			return {"sent": true, "event": "motion", "position": _variant_to_json(pos)}
		"button":
			var button_event := InputEventMouseButton.new()
			button_event.position = pos
			button_event.global_position = pos
			button_event.button_index = _mouse_button_index(str(params.get("button", "left")))
			button_event.pressed = bool(params.get("pressed", true))
			Input.parse_input_event(button_event)
			return {
				"sent": true,
				"event": "button",
				"button": params.get("button", "left"),
				"pressed": button_event.pressed,
				"position": _variant_to_json(pos),
			}
	return {"sent": false, "error": "Invalid mouse event: %s" % event}


func _game_input_gamepad(params: Dictionary) -> Dictionary:
	var device := int(params.get("device", 0))
	var control := str(params.get("control", "button"))
	match control:
		"button":
			var button := InputEventJoypadButton.new()
			button.device = device
			button.button_index = int(params.get("index", 0))
			button.pressed = bool(params.get("pressed", true))
			Input.parse_input_event(button)
			return {"sent": true, "control": "button", "device": device, "index": button.button_index, "pressed": button.pressed}
		"axis":
			var axis := InputEventJoypadMotion.new()
			axis.device = device
			axis.axis = int(params.get("index", 0))
			axis.axis_value = float(params.get("value", 0.0))
			Input.parse_input_event(axis)
			return {"sent": true, "control": "axis", "device": device, "index": axis.axis, "value": axis.axis_value}
	return {"sent": false, "error": "Invalid gamepad control: %s" % control}


func _game_input_state(params: Dictionary) -> Dictionary:
	var actions: Array = params.get("actions", [])
	if actions.is_empty():
		actions = InputMap.get_actions()
	var states := {}
	for action in actions:
		var name := str(action)
		states[name] = Input.is_action_pressed(name)
	return {"actions": states}


func _dict_to_vector2(value: Variant) -> Vector2:
	var viewport := get_viewport()
	var fallback := viewport.get_mouse_position() if viewport != null else Vector2.ZERO
	if value is Dictionary:
		if value.is_empty() or (not value.has("x") and not value.has("y")):
			return fallback
		return Vector2(float(value.get("x", fallback.x)), float(value.get("y", fallback.y)))
	return fallback


func _mouse_button_index(name: String) -> int:
	match name:
		"right":
			return MOUSE_BUTTON_RIGHT
		"middle":
			return MOUSE_BUTTON_MIDDLE
		"wheel_up":
			return MOUSE_BUTTON_WHEEL_UP
		"wheel_down":
			return MOUSE_BUTTON_WHEEL_DOWN
	return MOUSE_BUTTON_LEFT


## --- game_eval: execute arbitrary GDScript in the running game ---

## Wall-clock ceiling for a single game_eval. Evaluated code that awaits
## something which never completes (a signal that never fires, a timer on a
## paused tree) would otherwise pin the request open until the dispatcher's
## 15s deferred budget / the server's 15s command timeout fires it as an
## opaque INTERNAL_ERROR — with the temp eval Node leaked into the tree.
## Bounding it here lets us free the node and reply with an actionable
## message instead. See hi-godot/godot-ai#487.
##
## TIMEOUT ORDERING — load-bearing across three files: this value MUST stay
## below the editor-side fallback timer in
## `debugger/mcp_debugger_plugin.gd::request_game_eval` (`timeout_sec`,
## default 10.0), which in turn stays below the dispatcher's `game_eval`
## budget in `dispatcher.gd` (15000 ms). So: game 8s < editor 10s <
## dispatcher 15s. Only this game-side guard emits the actionable
## "Eval exceeded 8s" message; the editor timer emits a *generic* "Game eval
## timed out" message. Raise this at/above the editor timer (or drop that
## timer below this) and the generic message wins the race, silently losing
## the diagnostic this fix exists to provide. Nothing enforces the order —
## change one, re-check the other two.
##
## NOTE: this catches a hung `await`, not a CPU-bound loop with no `await` —
## a tight `while true:` with no yield blocks the main thread, so nothing
## (including this poll) runs until it yields. That case is out of scope.
const EVAL_TIMEOUT_SEC := 8.0


func _handle_eval(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var code: String = data[1] if data.size() > 1 else ""

	if code.is_empty():
		_reply_eval_error(request_id, "No code provided")
		return

	## Wrap user code in an execute() coroutine (so it can `await` internally)
	## whose inner function is uniquely named per eval. A runtime error's
	## backtrace then carries `_mcp_run_<token>`, letting us attribute it to
	## THIS eval — not an unrelated background game error, and not a sibling
	## overlapping eval. (#490)
	_eval_token_counter += 1
	var token := str(_eval_token_counter)
	var run_fn := "_mcp_run_%s" % token
	var script_source := (
		"extends Node\n"
		+ "func execute():\n"
		+ "\treturn await %s()\n\n" % run_fn
		+ "func %s():\n" % run_fn
		+ _indent_eval_code(code)
	)

	## Snapshot the logger's script-error seq BEFORE running so we only attribute
	## errors raised by this eval. In a debug build a parse error aborts reload()
	## and a runtime error aborts execute() — either way this function may never
	## reach its reply: the editor infers a compile error from the missing
	## mcp:eval_compiled beacon, and a runtime error is reported (via the
	## eval_check probe / the in-flight poll loop) once a logged error past this
	## baseline carries this eval's token.
	var baseline: int = _logger.script_error_seq() if _logger != null else 0

	var script: GDScript = GDScript.new()
	script.source_code = script_source
	## #490: ack BEFORE reload(). A parse error aborts this function at reload()
	## without a return code in a debug build, so this is our only chance to tell
	## the editor "received + about to compile." The editor uses that to tell a
	## real parse error (acked, never compiled) apart from a message it simply
	## hasn't serviced yet (never acked); see mcp_debugger_plugin._on_eval_grace.
	EngineDebugger.send_message("mcp:eval_ack", [request_id])
	## reload() ABORTS this function on a parse error in a debug build (it does
	## not return a non-OK code there), so the lines below only run when the
	## source compiled. Keep reload() INLINE — moving it behind a timer/await
	## poisons subsequent evals (#490). The err branch still matters for the
	## editor process (handler unit tests), where reload() does return.
	var err: int = script.reload()
	if err != OK:
		_reply_eval_error(request_id,
			"Failed to compile GDScript (error %d). Check syntax." % err)
		return

	## Compiled OK — tell the editor so its grace timer doesn't flag a compile
	## error and so it begins probing for a runtime error.
	EngineDebugger.send_message("mcp:eval_compiled", [request_id])

	var temp_node := Node.new()
	temp_node.set_script(script)
	temp_node.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(temp_node)

	if not temp_node.has_method("execute"):
		temp_node.queue_free()
		_reply_eval_error(request_id, "Internal error: eval wrapper is missing execute().")
		return

	## Register in-flight BEFORE running: a runtime error aborts execute() (and
	## may unwind this function) before we could record it afterward, and the
	## editor probe / poll loop need the entry to attribute and report the error.
	_inflight_evals[request_id] = {"node": temp_node, "token": token, "baseline": baseline}

	## Drive execute() as a fire-and-forget coroutine that records its outcome
	## into `holder`, then poll frames until it finishes or the deadline passes
	## (#488's hung-await guard). A plain `await temp_node.execute()` has no
	## escape hatch: if user code never returns, we never reach the reply/cleanup
	## below and the request hangs with the node leaked.
	var holder := {"done": false, "value": null, "abandoned": false}
	_drive_eval(temp_node, holder)

	var tree := get_tree()
	var deadline_ms := int(EVAL_TIMEOUT_SEC * 1000.0)
	var start_ms := Time.get_ticks_msec()
	while not holder["done"] and (Time.get_ticks_msec() - start_ms) < deadline_ms:
		## #490 focused fast path: a runtime error aborts _drive_eval (holder
		## never completes), so check each frame whether THIS eval's token now
		## appears in a logged error and report it immediately. (Backgrounded,
		## this loop is frozen and the editor probe does the same job.)
		if _try_report_eval_runtime_error(request_id):
			holder["abandoned"] = true
			return
		await tree.process_frame

	if not holder["done"]:
		## Past the 8s deadline. Disambiguate a runtime error (its token is in a
		## logged error) from a genuine hung await before the generic timeout.
		holder["abandoned"] = true
		if _try_report_eval_runtime_error(request_id):
			return
		_inflight_evals.erase(request_id)
		if is_instance_valid(temp_node):
			remove_child(temp_node)
		_reply_eval_error(request_id,
			("Eval exceeded %ds and was aborted — the code likely awaits "
				+ "something that never completes (a signal that never fires, a timer on "
				+ "a paused tree) or loops forever. Check logs_read(source='game').")
				% int(EVAL_TIMEOUT_SEC))
		return

	## Clean finish.
	_inflight_evals.erase(request_id)
	temp_node.queue_free()
	_reply_eval_response(request_id, holder["value"])


## Run the compiled eval node's execute() and stash the result. Kept
## separate from _handle_eval so the latter can race it against a deadline
## via frame polling. If the eval was abandoned (timed out) before this
## resumes, drop the result and free the now-detached node — _handle_eval
## has already replied.
##
## RESIDUAL LEAK (accepted): if the awaited thing *never* fires, this
## coroutine never resumes, so the `node` it holds is detached (via
## _handle_eval's remove_child) but never freed — one orphaned Node per such
## timeout, for the game-process lifetime. GDScript has no way to cancel a
## suspended coroutine, so this is the best achievable in-process. It is still
## strictly better than the pre-#487 behavior, where the node leaked *into*
## the live tree and the request hung to the 15s ceiling.
func _drive_eval(node: Node, holder: Dictionary) -> void:
	var value = await node.execute()
	if holder.get("abandoned", false):
		if is_instance_valid(node):
			node.queue_free()
		return
	holder["value"] = value
	holder["done"] = true


func _reply_eval_error(request_id: String, message: String) -> void:
	EngineDebugger.send_message("mcp:eval_error", [request_id, message])


func _reply_eval_response(request_id: String, value: Variant) -> void:
	EngineDebugger.send_message("mcp:eval_response",
		[request_id, JSON.stringify(_variant_to_json(value))])


## #490: if a logged script error past THIS eval's baseline carries its unique
## wrapper-function token, a runtime error aborted it before it could reply —
## report it with the real text + line. Returns true if it reported. Called
## from the editor's eval_check probe (the reliable path when a backgrounded
## game's idle loop is frozen — the debugger capture callback still runs) and
## from _handle_eval's poll loop (the focused fast path). Token + baseline
## matching means an unrelated background error, or a sibling overlapping
## eval's error, can never fail this request.
func _try_report_eval_runtime_error(request_id: String) -> bool:
	if _logger == null:
		return false
	var entry = _inflight_evals.get(request_id)
	if entry == null:
		return false
	var text: String = _logger.find_script_error_since(
		int(entry["baseline"]), "_mcp_run_%s" % str(entry["token"]))
	if text.is_empty():
		return false
	_inflight_evals.erase(request_id)
	var node: Node = entry["node"]
	if node != null and is_instance_valid(node):
		node.queue_free()
	if EngineDebugger.is_active():
		EngineDebugger.send_message("mcp:eval_runtime_error", [request_id, text])
	return true


## #490: answer an editor eval_check probe. The editor polls this once the
## eval has compiled but not yet replied. This runs in the debugger capture
## callback, which stays live even when the backgrounded game's _process is
## frozen — so it's the reliable channel for reporting a runtime error that
## aborted the eval. Report if one is detected for this request, else stay
## silent (the editor keeps polling until the real reply or the hang timeout).
func _handle_eval_check(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	if request_id.is_empty():
		return
	_try_report_eval_runtime_error(request_id)


func _indent_eval_code(code: String) -> String:
	var lines: PackedStringArray = code.split("\n")
	var out := ""
	for line in lines:
		out += "\t" + line + "\n"
	return out


## Serialize any Godot Variant to a JSON-safe dictionary/array/primitive.
## Ported from godot-mcp's mcp_interaction_server.gd.
func _variant_to_json(value: Variant) -> Variant:
	if value == null:
		return null
	if value is bool or value is int or value is float or value is String:
		return value
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Vector3:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector4:
		return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
	if value is Vector2i:
		return {"x": value.x, "y": value.y}
	if value is Vector3i:
		return {"x": value.x, "y": value.y, "z": value.z}
	if value is Vector4i:
		return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
	if value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is Quaternion:
		return {"x": value.x, "y": value.y, "z": value.z, "w": value.w}
	if value is Basis:
		return {
			"x": _variant_to_json(value.x),
			"y": _variant_to_json(value.y),
			"z": _variant_to_json(value.z),
		}
	if value is Transform3D:
		return {
			"basis": _variant_to_json(value.basis),
			"origin": _variant_to_json(value.origin),
		}
	if value is Transform2D:
		return {
			"x": _variant_to_json(value.x),
			"y": _variant_to_json(value.y),
			"origin": _variant_to_json(value.origin),
		}
	if value is Rect2:
		return {
			"position": _variant_to_json(value.position),
			"size": _variant_to_json(value.size),
		}
	if value is Rect2i:
		return {
			"position": _variant_to_json(value.position),
			"size": _variant_to_json(value.size),
		}
	if value is AABB:
		return {
			"position": _variant_to_json(value.position),
			"size": _variant_to_json(value.size),
		}
	if value is NodePath or value is StringName:
		return str(value)
	if value is Plane:
		return {
			"normal": _variant_to_json(value.normal),
			"d": value.d,
		}
	if value is Projection:
		return {
			"x": _variant_to_json(value.x),
			"y": _variant_to_json(value.y),
			"z": _variant_to_json(value.z),
			"w": _variant_to_json(value.w),
		}
	## Packed arrays
	if value is PackedByteArray:
		var arr: Array = []
		for item in value: arr.append(item)
		return arr
	if value is PackedInt32Array or value is PackedInt64Array:
		var arr: Array = []
		for item in value: arr.append(item)
		return arr
	if value is PackedFloat32Array or value is PackedFloat64Array:
		var arr: Array = []
		for item in value: arr.append(item)
		return arr
	if value is PackedStringArray:
		var arr: Array = []
		for item in value: arr.append(item)
		return arr
	if value is PackedVector2Array:
		var arr: Array = []
		for item in value: arr.append({"x": item.x, "y": item.y})
		return arr
	if value is PackedVector3Array:
		var arr: Array = []
		for item in value: arr.append({"x": item.x, "y": item.y, "z": item.z})
		return arr
	if value is PackedVector4Array:
		var arr: Array = []
		for item in value: arr.append({"x": item.x, "y": item.y, "z": item.z, "w": item.w})
		return arr
	if value is PackedColorArray:
		var arr: Array = []
		for item in value: arr.append({"r": item.r, "g": item.g, "b": item.b, "a": item.a})
		return arr
	## Generic arrays and dictionaries — recurse
	if value is Array:
		var arr: Array = []
		for item in value:
			arr.append(_variant_to_json(item))
		return arr
	if value is Dictionary:
		var dict: Dictionary = {}
		for key in value.keys():
			dict[str(key)] = _variant_to_json(value[key])
		return dict
	## Fallback: string representation
	return str(value)
