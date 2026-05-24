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

const GAME_LOGGER_PATH := "res://addons/godot_ai/runtime/game_logger.gd"

var _registered := false
## Untyped because the McpGameLogger script is loaded dynamically (it
## extends Logger, which only exists in Godot 4.5+).
var _logger
var _logger_attached := false
var _debug_draw_node: Node3D
var _debug_meshes: Array = []
## Entries drained from the logger but not yet sent over the debugger
## channel. Holds the tail of one drain() so we can bleed it out across
## frames at FLUSH_BATCH_LIMIT per frame rather than blasting the whole
## queue in a single _process tick.
var _pending_outbound: Array = []

## Key name → keycode map for game_key_press (ported from godot-mcp)
const _KEY_MAP := {
	"A": KEY_A, "B": KEY_B, "C": KEY_C, "D": KEY_D, "E": KEY_E, "F": KEY_F,
	"G": KEY_G, "H": KEY_H, "I": KEY_I, "J": KEY_J, "K": KEY_K, "L": KEY_L,
	"M": KEY_M, "N": KEY_N, "O": KEY_O, "P": KEY_P, "Q": KEY_Q, "R": KEY_R,
	"S": KEY_S, "T": KEY_T, "U": KEY_U, "V": KEY_V, "W": KEY_W, "X": KEY_X,
	"Y": KEY_Y, "Z": KEY_Z,
	"0": KEY_0, "1": KEY_1, "2": KEY_2, "3": KEY_3, "4": KEY_4,
	"5": KEY_5, "6": KEY_6, "7": KEY_7, "8": KEY_8, "9": KEY_9,
	"SPACE": KEY_SPACE, "ENTER": KEY_ENTER, "RETURN": KEY_ENTER,
	"ESCAPE": KEY_ESCAPE, "ESC": KEY_ESCAPE,
	"TAB": KEY_TAB, "BACKSPACE": KEY_BACKSPACE,
	"DELETE": KEY_DELETE, "HOME": KEY_HOME, "END": KEY_END,
	"PAGEUP": KEY_PAGEUP, "PAGEDOWN": KEY_PAGEDOWN,
	"UP": KEY_UP, "DOWN": KEY_DOWN, "LEFT": KEY_LEFT, "RIGHT": KEY_RIGHT,
	"SHIFT": KEY_SHIFT, "CTRL": KEY_CTRL, "ALT": KEY_ALT,
	"F1": KEY_F1, "F2": KEY_F2, "F3": KEY_F3, "F4": KEY_F4,
	"F5": KEY_F5, "F6": KEY_F6, "F7": KEY_F7, "F8": KEY_F8,
	"F9": KEY_F9, "F10": KEY_F10, "F11": KEY_F11, "F12": KEY_F12,
}


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
	## ClassDB so the rest of the helper still loads on 4.4 (the logger
	## script never gets parsed because we only load() it inside this
	## branch).
	if ClassDB.class_exists("Logger") and OS.has_method("add_logger"):
		var logger_script := load(GAME_LOGGER_PATH)
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
		"get_property":
			_handle_get_property(data)
			return true
		"set_property":
			_handle_set_property(data)
			return true
		"call_method":
			_handle_call_method(data)
			return true
		"click":
			_handle_click(data)
			return true
		"key_press":
			_handle_key_press(data)
			return true
		"mouse_move":
			_handle_mouse_move(data)
			return true
		"key_hold":
			_handle_key_hold(data)
			return true
		"key_release":
			_handle_key_release(data)
			return true
		"instantiate_scene":
			_handle_instantiate_scene(data)
			return true
		"scroll":
			_handle_scroll(data)
			return true
		"get_performance":
			_handle_get_performance(data)
			return true
		"get_ui_elements":
			_handle_get_ui_elements(data)
			return true
		"get_nodes_in_group":
			_handle_get_nodes_in_group(data)
			return true
		"find_nodes_by_class":
			_handle_find_nodes_by_class(data)
			return true
		"get_camera":
			_handle_get_camera(data)
			return true
		"set_camera":
			_handle_set_camera(data)
			return true
		"raycast":
			_handle_raycast(data)
			return true
		"play_animation":
			_handle_play_animation(data)
			return true
		"serialize_state":
			_handle_serialize_state(data)
			return true
		"get_audio":
			_handle_get_audio(data)
			return true
		"audio_play":
			_handle_audio_play(data)
			return true
		"audio_bus":
			_handle_audio_bus(data)
			return true
		"environment":
			_handle_environment(data)
			return true
		"physics_body":
			_handle_physics_body(data)
			return true
		"light_3d":
			_handle_light_3d(data)
			return true
		"mesh_instance":
			_handle_mesh_instance(data)
			return true
		"navigate_path":
			_handle_navigate_path(data)
			return true
		"navigation_3d":
			_handle_navigation_3d(data)
			return true
		"animation_tree":
			_handle_animation_tree(data)
			return true
		"create_animation":
			_handle_create_animation(data)
			return true
		"skeleton_ik":
			_handle_skeleton_ik(data)
			return true
		"time_scale":
			_handle_time_scale(data)
			return true
		"window":
			_handle_window(data)
			return true
		"gamepad":
			_handle_gamepad(data)
			return true
		"mouse_drag":
			_handle_mouse_drag(data)
			return true
		"ui_debug":
			_handle_ui_debug(data)
			return true
		"debug_draw":
			_handle_debug_draw(data)
			return true
		"input_state":
			_handle_input_state(data)
			return true
		"create_timer":
			_handle_create_timer(data)
			return true
		"tween_property":
			_handle_tween_property(data)
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


## --- game_eval: execute arbitrary GDScript in the running game ---

func _handle_eval(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var code: String = data[1] if data.size() > 1 else ""

	if code.is_empty():
		EngineDebugger.send_message("mcp:eval_error", [request_id, "No code provided"])
		return

	## Wrap user code so we can capture a return value.
	## Uses await so user code can use `await` internally.
	var script_source := (
		"extends Node\n"
		+ "func execute():\n"
		+ "\tvar __result = null\n"
		+ "\t__result = await _run()\n"
		+ "\treturn __result\n\n"
		+ "func _run():\n"
		+ _indent_eval_code(code)
	)

	var script: GDScript = GDScript.new()
	script.source_code = script_source
	var err: int = script.reload()
	if err != OK:
		EngineDebugger.send_message("mcp:eval_error",
			[request_id, "Failed to compile GDScript (error %d). Check syntax." % err])
		return

	var temp_node := Node.new()
	temp_node.set_script(script)
	temp_node.process_mode = Node.PROCESS_MODE_ALWAYS
	add_child(temp_node)

	var result = null
	if temp_node.has_method("execute"):
		result = await temp_node.execute()

	temp_node.queue_free()
	EngineDebugger.send_message("mcp:eval_response",
		[request_id, JSON.stringify(_variant_to_json(result))])


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


## --- game_get_property / game_set_property ---

func _handle_get_property(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var property: String = data[2] if data.size() > 2 else ""

	if node_path.is_empty() or property.is_empty():
		EngineDebugger.send_message("mcp:get_property_error",
			[request_id, "node_path and property are required"])
		return

	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:get_property_error",
			[request_id, "Node not found: %s" % node_path])
		return

	var value = node.get(property)
	EngineDebugger.send_message("mcp:get_property_response",
		[request_id, JSON.stringify(_variant_to_json(value))])


func _handle_set_property(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var property: String = data[2] if data.size() > 2 else ""
	var value_json: String = data[3] if data.size() > 3 else "null"

	if node_path.is_empty() or property.is_empty():
		EngineDebugger.send_message("mcp:set_property_error",
			[request_id, "node_path and property are required"])
		return

	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:set_property_error",
			[request_id, "Node not found: %s" % node_path])
		return

	var parsed = JSON.parse_string(value_json)
	var value = _json_to_variant_for_property(node, property, parsed)
	node.set(property, value)
	EngineDebugger.send_message("mcp:set_property_response",
		[request_id, JSON.stringify(_variant_to_json(node.get(property)))])


## Convert JSON dictionary/primitive to a Godot Variant.
## Inverse of _variant_to_json. Ported from godot-mcp.
func _json_to_variant(value: Variant, type_hint: String = "") -> Variant:
	if value == null:
		return null
	if value is Dictionary:
		var dict: Dictionary = value
		match type_hint:
			"Vector2":
				return Vector2(float(dict.get("x", 0)), float(dict.get("y", 0)))
			"Vector2i":
				return Vector2i(int(dict.get("x", 0)), int(dict.get("y", 0)))
			"Vector3":
				return Vector3(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)))
			"Vector3i":
				return Vector3i(int(dict.get("x", 0)), int(dict.get("y", 0)), int(dict.get("z", 0)))
			"Color":
				return Color(float(dict.get("r", 0)), float(dict.get("g", 0)), float(dict.get("b", 0)), float(dict.get("a", 1)))
			"Quaternion":
				return Quaternion(float(dict.get("x", 0)), float(dict.get("y", 0)), float(dict.get("z", 0)), float(dict.get("w", 1)))
			"Rect2":
				var rp: Dictionary = dict.get("position", {"x": 0, "y": 0})
				var rs: Dictionary = dict.get("size", {"x": 0, "y": 0})
				return Rect2(float(rp.get("x", 0)), float(rp.get("y", 0)), float(rs.get("x", 0)), float(rs.get("y", 0)))
			"AABB":
				var ap: Dictionary = dict.get("position", {"x": 0, "y": 0, "z": 0})
				var as_: Dictionary = dict.get("size", {"x": 0, "y": 0, "z": 0})
				return AABB(Vector3(float(ap.x), float(ap.y), float(ap.z)), Vector3(float(as_.x), float(as_.y), float(as_.z)))
			"Basis":
				var bx: Dictionary = dict.get("x", {"x": 1, "y": 0, "z": 0})
				var by: Dictionary = dict.get("y", {"x": 0, "y": 1, "z": 0})
				var bz: Dictionary = dict.get("z", {"x": 0, "y": 0, "z": 1})
				return Basis(Vector3(bx.x, bx.y, bx.z), Vector3(by.x, by.y, by.z), Vector3(bz.x, bz.y, bz.z))
			"Transform3D":
				var bd: Dictionary = dict.get("basis", {})
				var od: Dictionary = dict.get("origin", {"x": 0, "y": 0, "z": 0})
				var basis: Basis = _json_to_variant(bd, "Basis") if bd.size() > 0 else Basis.IDENTITY
				return Transform3D(basis, Vector3(float(od.x), float(od.y), float(od.z)))
			"Transform2D":
				var t2x: Dictionary = dict.get("x", {"x": 1, "y": 0})
				var t2y: Dictionary = dict.get("y", {"x": 0, "y": 1})
				var t2o: Dictionary = dict.get("origin", {"x": 0, "y": 0})
				return Transform2D(Vector2(t2x.x, t2x.y), Vector2(t2y.x, t2y.y), Vector2(t2o.x, t2o.y))
		# Auto-detect from dict keys
		if dict.has("basis") and dict.has("origin"):
			return _json_to_variant(dict, "Transform3D")
		if dict.has("r") and dict.has("g") and dict.has("b"):
			return Color(dict.r, dict.g, dict.b, dict.get("a", 1.0))
		if dict.has("x") and dict.has("y") and dict.has("z") and dict.has("w"):
			return Quaternion(dict.x, dict.y, dict.z, dict.w)
		if dict.has("position") and dict.has("size"):
			var pd: Dictionary = dict["position"]
			if pd.has("z") or dict["size"].has("z"):
				return _json_to_variant(dict, "AABB")
			return _json_to_variant(dict, "Rect2")
		if dict.has("x") and dict.has("y") and dict.has("z"):
			return Vector3(float(dict.x), float(dict.y), float(dict.z))
		if dict.has("x") and dict.has("y") and dict.size() == 2:
			return Vector2(float(dict.x), float(dict.y))
		return value
	return value


func _json_to_variant_for_property(node: Node, property: String, value: Variant) -> Variant:
	for prop in node.get_property_list():
		if prop["name"] == property:
			var tid: int = prop.get("type", 0)
			match tid:
				TYPE_VECTOR2:    return _json_to_variant(value, "Vector2")
				TYPE_VECTOR2I:   return _json_to_variant(value, "Vector2i")
				TYPE_VECTOR3:    return _json_to_variant(value, "Vector3")
				TYPE_VECTOR3I:   return _json_to_variant(value, "Vector3i")
				TYPE_COLOR:      return _json_to_variant(value, "Color")
				TYPE_QUATERNION: return _json_to_variant(value, "Quaternion")
				TYPE_RECT2:      return _json_to_variant(value, "Rect2")
				TYPE_AABB:       return _json_to_variant(value, "AABB")
				TYPE_BASIS:      return _json_to_variant(value, "Basis")
				TYPE_TRANSFORM3D: return _json_to_variant(value, "Transform3D")
				TYPE_TRANSFORM2D: return _json_to_variant(value, "Transform2D")
				TYPE_BOOL:
					if value is String: return value.to_lower() == "true"
					return bool(value)
				TYPE_INT:   return int(value)
				TYPE_FLOAT: return float(value)
			break
	return _json_to_variant(value)


## --- game_call_method ---

func _handle_call_method(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var method_name: String = data[2] if data.size() > 2 else ""
	var args_json: String = data[3] if data.size() > 3 else "[]"

	if node_path.is_empty() or method_name.is_empty():
		EngineDebugger.send_message("mcp:call_method_error",
			[request_id, "node_path and method are required"])
		return

	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:call_method_error",
			[request_id, "Node not found: %s" % node_path])
		return

	if not node.has_method(method_name):
		EngineDebugger.send_message("mcp:call_method_error",
			[request_id, "Method not found: %s on node %s" % [method_name, node_path]])
		return

	var args_parsed = JSON.parse_string(args_json)
	var args: Array = args_parsed if args_parsed is Array else []
	var result = node.callv(method_name, args)
	EngineDebugger.send_message("mcp:call_method_response",
		[request_id, JSON.stringify(_variant_to_json(result))])


## --- Input simulation ---

func _str_to_keycode(key_str: String) -> int:
	var upper := key_str.to_upper()
	if _KEY_MAP.has(upper):
		return _KEY_MAP[upper]
	if key_str.length() == 1:
		return key_str.unicode_at(0)
	return KEY_NONE


func _handle_click(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var x: float = float(data[1]) if data.size() > 1 else 0.0
	var y: float = float(data[2]) if data.size() > 2 else 0.0
	var button: int = int(data[3]) if data.size() > 3 else MOUSE_BUTTON_LEFT

	var pos := Vector2(x, y)
	var press := InputEventMouseButton.new()
	press.position = pos; press.global_position = pos
	press.button_index = button as MouseButton; press.pressed = true
	Input.parse_input_event(press)

	await get_tree().process_frame

	var release := InputEventMouseButton.new()
	release.position = pos; release.global_position = pos
	release.button_index = button as MouseButton; release.pressed = false
	Input.parse_input_event(release)

	EngineDebugger.send_message("mcp:click_response",
		[request_id, JSON.stringify({"x": x, "y": y, "button": button})])


func _handle_key_press(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var key: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else ""
	var pressed: bool = data[3] if data.size() > 3 else true

	if not action.is_empty():
		if pressed: Input.action_press(action)
		else: Input.action_release(action)
		EngineDebugger.send_message("mcp:key_press_response",
			[request_id, JSON.stringify({"action": action, "pressed": pressed})])
		return

	if key.is_empty():
		EngineDebugger.send_message("mcp:key_press_error",
			[request_id, "Must provide 'key' or 'action' parameter"])
		return

	var keycode := _str_to_keycode(key)
	if keycode == KEY_NONE:
		EngineDebugger.send_message("mcp:key_press_error",
			[request_id, "Unknown key: %s" % key])
		return

	var event := InputEventKey.new()
	event.keycode = keycode as Key; event.physical_keycode = keycode as Key
	event.pressed = pressed
	Input.parse_input_event(event)

	if pressed:
		await get_tree().process_frame
		event.pressed = false
		Input.parse_input_event(event)

	EngineDebugger.send_message("mcp:key_press_response",
		[request_id, JSON.stringify({"key": key, "pressed": pressed})])


func _handle_mouse_move(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var x: float = float(data[1]) if data.size() > 1 else 0.0
	var y: float = float(data[2]) if data.size() > 2 else 0.0
	var rel_x: float = float(data[3]) if data.size() > 3 else 0.0
	var rel_y: float = float(data[4]) if data.size() > 4 else 0.0

	var event := InputEventMouseMotion.new()
	event.position = Vector2(x, y); event.global_position = Vector2(x, y)
	event.relative = Vector2(rel_x, rel_y)
	Input.parse_input_event(event)

	EngineDebugger.send_message("mcp:mouse_move_response",
		[request_id, JSON.stringify({"x": x, "y": y})])


func _handle_key_hold(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var key: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else ""

	if not action.is_empty():
		Input.action_press(action)
		EngineDebugger.send_message("mcp:key_hold_response", [request_id, JSON.stringify({"held": action, "type": "action"})])
		return

	if key.is_empty():
		EngineDebugger.send_message("mcp:key_hold_error", [request_id, "Must provide 'key' or 'action'"])
		return

	var keycode := _str_to_keycode(key)
	if keycode == KEY_NONE:
		EngineDebugger.send_message("mcp:key_hold_error", [request_id, "Unknown key: %s" % key])
		return

	var event := InputEventKey.new()
	event.keycode = keycode as Key; event.physical_keycode = keycode as Key; event.pressed = true
	Input.parse_input_event(event)
	EngineDebugger.send_message("mcp:key_hold_response", [request_id, JSON.stringify({"held": key, "type": "key"})])


func _handle_key_release(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var key: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else ""

	if not action.is_empty():
		Input.action_release(action)
		EngineDebugger.send_message("mcp:key_release_response", [request_id, JSON.stringify({"released": action, "type": "action"})])
		return

	if key.is_empty():
		EngineDebugger.send_message("mcp:key_release_error", [request_id, "Must provide 'key' or 'action'"])
		return

	var keycode := _str_to_keycode(key)
	if keycode == KEY_NONE:
		EngineDebugger.send_message("mcp:key_release_error", [request_id, "Unknown key: %s" % key])
		return

	var event := InputEventKey.new()
	event.keycode = keycode as Key; event.physical_keycode = keycode as Key; event.pressed = false
	Input.parse_input_event(event)
	EngineDebugger.send_message("mcp:key_release_response", [request_id, JSON.stringify({"released": key, "type": "key"})])


func _handle_scroll(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var x: float = float(data[1]) if data.size() > 1 else 0.0
	var y: float = float(data[2]) if data.size() > 2 else 0.0

	var event := InputEventMouseButton.new()
	event.button_index = MOUSE_BUTTON_WHEEL_UP if y > 0 else MOUSE_BUTTON_WHEEL_DOWN
	event.factor = abs(y)
	event.pressed = true
	Input.parse_input_event(event)
	EngineDebugger.send_message("mcp:scroll_response", [request_id, JSON.stringify({"x": x, "y": y})])

func _handle_list_signals(data: Array) -> void:
	var request_id := ""
	if data.size() > 0:
		request_id = data[0]
	var node_path := ""
	if data.size() > 1:
		node_path = data[1]
	if node_path.is_empty():
		EngineDebugger.send_message("mcp:list_signals_error", [request_id, "node_path is required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:list_signals_error", [request_id, "Node not found: %s" % node_path])
		return
	var signals: Array = []
	for sig in node.get_signal_list():
		var connections: Array = []
		for conn in node.get_signal_connection_list(sig["name"]):
			connections.append({"callable": str(conn["callable"]), "flags": conn["flags"]})
		signals.append({"name": sig["name"], "args": str(sig["args"]), "connections": connections})
	EngineDebugger.send_message("mcp:list_signals_response", [request_id, JSON.stringify(signals)])


func _handle_connect_signal(data: Array) -> void:
	var request_id := ""; var node_path := ""; var signal_name := ""; var target_path := ""; var method_name := ""
	if data.size() > 0: request_id = data[0]
	if data.size() > 1: node_path = data[1]
	if data.size() > 2: signal_name = data[2]
	if data.size() > 3: target_path = data[3]
	if data.size() > 4: method_name = data[4]
	if node_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		EngineDebugger.send_message("mcp:connect_signal_error", [request_id, "node_path, signal_name, target_path, and method are required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:connect_signal_error", [request_id, "Source node not found: %s" % node_path])
		return
	var target := get_node_or_null(target_path)
	if target == null:
		EngineDebugger.send_message("mcp:connect_signal_error", [request_id, "Target node not found: %s" % target_path])
		return
	if not node.has_signal(signal_name):
		EngineDebugger.send_message("mcp:connect_signal_error", [request_id, "Signal '%s' not found on %s" % [signal_name, node_path]])
		return
	if not target.has_method(method_name):
		EngineDebugger.send_message("mcp:connect_signal_error", [request_id, "Method '%s' not found on %s" % [method_name, target_path]])
		return
	var cb := Callable(target, method_name)
	if node.is_connected(signal_name, cb):
		EngineDebugger.send_message("mcp:connect_signal_error", [request_id, "Signal already connected"])
		return
	node.connect(signal_name, cb)
	EngineDebugger.send_message("mcp:connect_signal_response", [request_id, JSON.stringify({"signal": signal_name, "from": node_path, "to": target_path, "method": method_name})])


func _handle_disconnect_signal(data: Array) -> void:
	var request_id := ""; var node_path := ""; var signal_name := ""; var target_path := ""; var method_name := ""
	if data.size() > 0: request_id = data[0]
	if data.size() > 1: node_path = data[1]
	if data.size() > 2: signal_name = data[2]
	if data.size() > 3: target_path = data[3]
	if data.size() > 4: method_name = data[4]
	if node_path.is_empty() or signal_name.is_empty() or target_path.is_empty() or method_name.is_empty():
		EngineDebugger.send_message("mcp:disconnect_signal_error", [request_id, "node_path, signal_name, target_path, and method are required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:disconnect_signal_error", [request_id, "Source node not found: %s" % node_path])
		return
	var target := get_node_or_null(target_path)
	if target == null:
		EngineDebugger.send_message("mcp:disconnect_signal_error", [request_id, "Target node not found: %s" % target_path])
		return
	var cb := Callable(target, method_name)
	if not node.is_connected(signal_name, cb):
		EngineDebugger.send_message("mcp:disconnect_signal_error", [request_id, "Signal not connected"])
		return
	node.disconnect(signal_name, cb)
	EngineDebugger.send_message("mcp:disconnect_signal_response", [request_id, JSON.stringify({"disconnected": signal_name, "from": node_path, "to": target_path, "method": method_name})])


func _handle_emit_signal(data: Array) -> void:
	var request_id := ""
	if data.size() > 0: request_id = data[0]
	var node_path := ""
	if data.size() > 1: node_path = data[1]
	var signal_name := ""
	if data.size() > 2: signal_name = data[2]
	var args_json := "[]"
	if data.size() > 3: args_json = data[3]
	if node_path.is_empty() or signal_name.is_empty():
		EngineDebugger.send_message("mcp:emit_signal_error", [request_id, "node_path and signal_name are required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:emit_signal_error", [request_id, "Node not found: %s" % node_path])
		return
	if not node.has_signal(signal_name):
		EngineDebugger.send_message("mcp:emit_signal_error", [request_id, "Signal '%s' not found on %s" % [signal_name, node_path]])
		return
	var args_parsed = JSON.parse_string(args_json)
	var call_args: Array = [signal_name]
	if args_parsed is Array:
		call_args.append_array(args_parsed)
	node.callv("emit_signal", call_args)
	EngineDebugger.send_message("mcp:emit_signal_response", [request_id, JSON.stringify({"emitted": signal_name, "node": node_path})])


func _handle_pause(data: Array) -> void:
	var request_id := ""
	if data.size() > 0: request_id = data[0]
	var paused := true
	if data.size() > 1: paused = data[1]
	get_tree().paused = paused
	EngineDebugger.send_message("mcp:pause_response", [request_id, JSON.stringify({"paused": paused})])


func _build_tree_node(node: Node) -> Dictionary:
	var info: Dictionary = {"name": node.name, "type": node.get_class()}
	var children_arr: Array = []
	for child in node.get_children():
		children_arr.append(_build_tree_node(child))
	if children_arr.size() > 0:
		info["children"] = children_arr
	return info


func _handle_get_scene_tree(data: Array) -> void:
	var request_id := ""
	if data.size() > 0: request_id = data[0]
	var tree: Dictionary = _build_tree_node(get_tree().root)
	EngineDebugger.send_message("mcp:get_scene_tree_response", [request_id, JSON.stringify(tree)])


func _handle_get_node_info(data: Array) -> void:
	var request_id := ""; var node_path := ""
	if data.size() > 0: request_id = data[0]
	if data.size() > 1: node_path = data[1]
	if node_path.is_empty():
		EngineDebugger.send_message("mcp:get_node_info_error", [request_id, "node_path is required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:get_node_info_error", [request_id, "Node not found: %s" % node_path])
		return
	var properties: Array = []
	for prop in node.get_property_list():
		var prop_dict: Dictionary = prop
		if prop_dict.get("usage", 0) & PROPERTY_USAGE_EDITOR:
			properties.append({"name": prop_dict.get("name", ""), "type": prop_dict.get("type", 0), "value": _variant_to_json(node.get(prop_dict.get("name", "")))})
	var signals: Array = []
	for sig in node.get_signal_list():
		signals.append(sig.get("name", ""))
	var methods: Array = []
	for m in node.get_method_list():
		var m_dict: Dictionary = m
		var m_name: String = m_dict.get("name", "")
		if not m_name.begins_with("_"):
			methods.append(m_name)
	var children: Array = []
	for child in node.get_children():
		children.append({"name": child.name, "type": child.get_class(), "path": str(child.get_path())})
	EngineDebugger.send_message("mcp:get_node_info_response", [request_id, JSON.stringify({
		"class": node.get_class(), "name": node.name, "path": str(node.get_path()),
		"properties": properties, "signals": signals, "methods": methods, "children": children
	})])


func _handle_spawn_node(data: Array) -> void:
	var request_id := ""; var type_name := ""; var node_name := ""; var parent_path := "/root"
	if data.size() > 0: request_id = data[0]
	if data.size() > 1: type_name = data[1]
	if data.size() > 2: node_name = data[2]
	if data.size() > 3: parent_path = data[3]
	if type_name.is_empty():
		EngineDebugger.send_message("mcp:spawn_node_error", [request_id, "type is required"])
		return
	if not ClassDB.class_exists(type_name):
		EngineDebugger.send_message("mcp:spawn_node_error", [request_id, "Unknown class: %s" % type_name])
		return
	if not ClassDB.is_parent_class(type_name, "Node") and type_name != "Node":
		EngineDebugger.send_message("mcp:spawn_node_error", [request_id, "Class '%s' is not a Node type" % type_name])
		return
	var parent := get_node_or_null(parent_path)
	if parent == null:
		EngineDebugger.send_message("mcp:spawn_node_error", [request_id, "Parent node not found: %s" % parent_path])
		return
	var instance := ClassDB.instantiate(type_name) as Node
	if instance == null:
		EngineDebugger.send_message("mcp:spawn_node_error", [request_id, "Failed to instantiate: %s" % type_name])
		return
	if node_name.length() > 0:
		instance.name = node_name
	var properties_json := "{}"
	if data.size() > 4: properties_json = data[4]
	var properties = JSON.parse_string(properties_json)
	if properties is Dictionary:
		for prop_name in properties:
			var raw_value = properties[prop_name]
			var value = _json_to_variant_for_property(instance, prop_name, raw_value)
			instance.set(prop_name, value)
	parent.add_child(instance)
	EngineDebugger.send_message("mcp:spawn_node_response", [request_id, JSON.stringify({"name": instance.name, "type": type_name, "path": str(instance.get_path())})])


func _handle_remove_node(data: Array) -> void:
	var request_id := ""; var node_path := ""
	if data.size() > 0: request_id = data[0]
	if data.size() > 1: node_path = data[1]
	if node_path.is_empty():
		EngineDebugger.send_message("mcp:remove_node_error", [request_id, "node_path is required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:remove_node_error", [request_id, "Node not found: %s" % node_path])
		return
	var node_name: String = node.name
	node.queue_free()
	EngineDebugger.send_message("mcp:remove_node_response", [request_id, JSON.stringify({"removed": node_name, "path": node_path})])


func _handle_instantiate_scene(data: Array) -> void:
	var request_id := ""; var scene_path := ""; var parent_path := "/root"
	if data.size() > 0: request_id = data[0]
	if data.size() > 1: scene_path = data[1]
	if data.size() > 2: parent_path = data[2]
	if scene_path.is_empty():
		EngineDebugger.send_message("mcp:instantiate_scene_error", [request_id, "scene_path is required"])
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		EngineDebugger.send_message("mcp:instantiate_scene_error", [request_id, "Failed to load scene: %s" % scene_path])
		return
	var parent := get_node_or_null(parent_path)
	if parent == null:
		EngineDebugger.send_message("mcp:instantiate_scene_error", [request_id, "Parent node not found: %s" % parent_path])
		return
	var instance := packed.instantiate()
	parent.add_child(instance)
	EngineDebugger.send_message("mcp:instantiate_scene_response", [request_id, JSON.stringify({"name": instance.name, "path": str(instance.get_path())})])


func _handle_get_performance(data: Array) -> void:
	var request_id := ""
	if data.size() > 0:
		request_id = data[0]
	EngineDebugger.send_message("mcp:get_performance_response", [request_id, JSON.stringify({
		"fps": Performance.get_monitor(Performance.TIME_FPS),
		"frame_time": Performance.get_monitor(Performance.TIME_PROCESS),
		"physics_frame_time": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS),
		"memory_static": Performance.get_monitor(Performance.MEMORY_STATIC),
		"memory_static_max": Performance.get_monitor(Performance.MEMORY_STATIC_MAX),
		"object_count": Performance.get_monitor(Performance.OBJECT_COUNT),
		"object_node_count": Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		"render_total_objects": Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		"render_total_draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	})])


func _handle_get_nodes_in_group(data: Array) -> void:
	var request_id := ""
	if data.size() > 0:
		request_id = data[0]
	var group_name := ""
	if data.size() > 1:
		group_name = data[1]
	if group_name.is_empty():
		EngineDebugger.send_message("mcp:get_nodes_in_group_error", [request_id, "group is required"])
		return
	var nodes: Array = get_tree().get_nodes_in_group(group_name)
	var result: Array = []
	for node in nodes:
		result.append({"name": node.name, "type": node.get_class(), "path": str(node.get_path())})
	EngineDebugger.send_message("mcp:get_nodes_in_group_response", [request_id, JSON.stringify({"group": group_name, "count": result.size(), "nodes": result})])


func _handle_get_ui_elements(data: Array) -> void:
	var request_id := ""
	if data.size() > 0:
		request_id = data[0]
	var elements: Array = []
	_collect_ui_elements(get_tree().root, elements)
	EngineDebugger.send_message("mcp:get_ui_elements_response", [request_id, JSON.stringify(elements)])


func _collect_ui_elements(node: Node, elements: Array) -> void:
	if node is Control:
		var ctrl := node as Control
		if ctrl.visible and ctrl.get_global_rect().size.x > 0:
			var info: Dictionary = {
				"name": ctrl.name, "type": ctrl.get_class(), "path": str(ctrl.get_path()),
				"position": {"x": ctrl.global_position.x, "y": ctrl.global_position.y},
				"size": {"width": ctrl.size.x, "height": ctrl.size.y},
			}
			if ctrl is Label:
				info["text"] = (ctrl as Label).text
			elif ctrl is Button:
				info["text"] = (ctrl as Button).text
			elif ctrl is LineEdit:
				info["text"] = (ctrl as LineEdit).text
			elif ctrl is RichTextLabel:
				info["text"] = (ctrl as RichTextLabel).get_parsed_text()
			elements.append(info)
	for child in node.get_children():
		_collect_ui_elements(child, elements)


func _handle_find_nodes_by_class(data: Array) -> void:
	var request_id := ""
	if data.size() > 0:
		request_id = data[0]
	var cls := ""
	if data.size() > 1:
		cls = data[1]
	var rp := "/root"
	if data.size() > 2:
		rp = data[2]
	if cls.is_empty():
		EngineDebugger.send_message("mcp:find_nodes_by_class_error", [request_id, "class_name is required"])
		return
	var root_node := get_node_or_null(rp)
	if root_node == null:
		EngineDebugger.send_message("mcp:find_nodes_by_class_error", [request_id, "Root node not found: %s" % rp])
		return
	var found: Array = []
	_find_by_cls(root_node, cls, found)
	EngineDebugger.send_message("mcp:find_nodes_by_class_response", [request_id, JSON.stringify({"class_name": cls, "count": found.size(), "nodes": found})])


func _find_by_cls(node: Node, cls: String, results: Array) -> void:
	if node.get_class() == cls or node.is_class(cls):
		results.append({"name": node.name, "type": node.get_class(), "path": str(node.get_path())})
	for child in node.get_children():
		_find_by_cls(child, cls, results)


func _handle_get_camera(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var result: Dictionary = {}
	var cam2d: Camera2D = get_viewport().get_camera_2d()
	if cam2d != null:
		result["camera_2d"] = {
			"position": {"x": cam2d.global_position.x, "y": cam2d.global_position.y},
			"rotation": cam2d.global_rotation,
			"zoom": {"x": cam2d.zoom.x, "y": cam2d.zoom.y},
			"path": str(cam2d.get_path())
		}
	var cam3d: Camera3D = get_viewport().get_camera_3d()
	if cam3d != null:
		result["camera_3d"] = {
			"position": {"x": cam3d.global_position.x, "y": cam3d.global_position.y, "z": cam3d.global_position.z},
			"rotation": {"x": rad_to_deg(cam3d.global_rotation.x), "y": rad_to_deg(cam3d.global_rotation.y), "z": rad_to_deg(cam3d.global_rotation.z)},
			"fov": cam3d.fov,
			"path": str(cam3d.get_path())
		}
	EngineDebugger.send_message("mcp:get_camera_response", [request_id, JSON.stringify(result)])


func _handle_set_camera(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var params_json: String = data[1] if data.size() > 1 else "{}"
	var params = JSON.parse_string(params_json)
	if params == null:
		EngineDebugger.send_message("mcp:set_camera_error", [request_id, "Invalid params JSON"])
		return
	var cam2d: Camera2D = get_viewport().get_camera_2d()
	var cam3d: Camera3D = get_viewport().get_camera_3d()
	if cam2d == null and cam3d == null:
		EngineDebugger.send_message("mcp:set_camera_error", [request_id, "No active camera found"])
		return
	if cam2d != null:
		if params.has("position"):
			var pos: Dictionary = params["position"]
			cam2d.global_position = Vector2(float(pos.get("x", cam2d.global_position.x)), float(pos.get("y", cam2d.global_position.y)))
		if params.has("rotation"):
			cam2d.global_rotation = deg_to_rad(float(params["rotation"]))
		if params.has("zoom"):
			var z: Dictionary = params["zoom"]
			cam2d.zoom = Vector2(float(z.get("x", cam2d.zoom.x)), float(z.get("y", cam2d.zoom.y)))
		EngineDebugger.send_message("mcp:set_camera_response", [request_id, JSON.stringify({"camera": "2d"})])
		return
	if cam3d != null:
		if params.has("position"):
			var pos: Dictionary = params["position"]
			cam3d.global_position = Vector3(float(pos.get("x", cam3d.global_position.x)), float(pos.get("y", cam3d.global_position.y)), float(pos.get("z", cam3d.global_position.z)))
		if params.has("rotation"):
			var rot: Dictionary = params["rotation"]
			cam3d.global_rotation = Vector3(deg_to_rad(float(rot.get("x", rad_to_deg(cam3d.global_rotation.x)))), deg_to_rad(float(rot.get("y", rad_to_deg(cam3d.global_rotation.y)))), deg_to_rad(float(rot.get("z", rad_to_deg(cam3d.global_rotation.z)))))
		if params.has("fov"):
			cam3d.fov = float(params["fov"])
		EngineDebugger.send_message("mcp:set_camera_response", [request_id, JSON.stringify({"camera": "3d"})])
		return


func _handle_raycast(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var params_json: String = data[1] if data.size() > 1 else "{}"
	var params = JSON.parse_string(params_json)
	if params == null:
		EngineDebugger.send_message("mcp:raycast_error", [request_id, "Invalid params JSON"])
		return
	var from_dict: Dictionary = params.get("from", {})
	var to_dict: Dictionary = params.get("to", {})
	var collision_mask: int = int(params.get("collision_mask", 0xFFFFFFFF))
	var is_3d: bool = from_dict.has("z") or to_dict.has("z")
	if is_3d:
		var from_pos: Vector3 = Vector3(float(from_dict.get("x", 0)), float(from_dict.get("y", 0)), float(from_dict.get("z", 0)))
		var to_pos: Vector3 = Vector3(float(to_dict.get("x", 0)), float(to_dict.get("y", 0)), float(to_dict.get("z", 0)))
		var space_state: PhysicsDirectSpaceState3D = get_viewport().world_3d.direct_space_state
		var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(from_pos, to_pos, collision_mask)
		var result: Dictionary = space_state.intersect_ray(query)
		if result.is_empty():
			EngineDebugger.send_message("mcp:raycast_response", [request_id, JSON.stringify({"hit": false, "mode": "3d"})])
		else:
			EngineDebugger.send_message("mcp:raycast_response", [request_id, JSON.stringify({
				"hit": true, "mode": "3d",
				"position": _variant_to_json(result["position"]),
				"normal": _variant_to_json(result["normal"]),
				"collider_path": str(result["collider"].get_path()) if result.has("collider") and result["collider"] is Node else "",
				"collider_class": result["collider"].get_class() if result.has("collider") else "",
			})])
	else:
		var from_pos: Vector2 = Vector2(float(from_dict.get("x", 0)), float(from_dict.get("y", 0)))
		var to_pos: Vector2 = Vector2(float(to_dict.get("x", 0)), float(to_dict.get("y", 0)))
		var space_state: PhysicsDirectSpaceState2D = get_viewport().world_2d.direct_space_state
		var query: PhysicsRayQueryParameters2D = PhysicsRayQueryParameters2D.create(from_pos, to_pos, collision_mask)
		var result: Dictionary = space_state.intersect_ray(query)
		if result.is_empty():
			EngineDebugger.send_message("mcp:raycast_response", [request_id, JSON.stringify({"hit": false, "mode": "2d"})])
		else:
			EngineDebugger.send_message("mcp:raycast_response", [request_id, JSON.stringify({
				"hit": true, "mode": "2d",
				"position": _variant_to_json(result["position"]),
				"normal": _variant_to_json(result["normal"]),
				"collider_path": str(result["collider"].get_path()) if result.has("collider") and result["collider"] is Node else "",
				"collider_class": result["collider"].get_class() if result.has("collider") else "",
			})])


func _handle_play_animation(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else "play"
	if node_path.is_empty():
		EngineDebugger.send_message("mcp:play_animation_error", [request_id, "node_path is required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:play_animation_error", [request_id, "Node not found: %s" % node_path])
		return
	if not node is AnimationPlayer:
		EngineDebugger.send_message("mcp:play_animation_error", [request_id, "Node is not an AnimationPlayer"])
		return
	var anim_player: AnimationPlayer = node as AnimationPlayer
	if action == "play":
		var anim: String = data[3] if data.size() > 3 else ""
		if anim.is_empty():
			EngineDebugger.send_message("mcp:play_animation_error", [request_id, "animation name is required"])
			return
		if not anim_player.has_animation(anim):
			EngineDebugger.send_message("mcp:play_animation_error", [request_id, "Animation '%s' not found" % anim])
			return
		anim_player.play(anim)
		EngineDebugger.send_message("mcp:play_animation_response", [request_id, JSON.stringify({"action": "play", "animation": anim})])
	elif action == "stop":
		anim_player.stop()
		EngineDebugger.send_message("mcp:play_animation_response", [request_id, JSON.stringify({"action": "stop"})])
	elif action == "pause":
		anim_player.pause()
		EngineDebugger.send_message("mcp:play_animation_response", [request_id, JSON.stringify({"action": "pause"})])
	elif action == "list":
		var anims: Array = []
		for anim_name in anim_player.get_animation_list():
			anims.append(str(anim_name))
		EngineDebugger.send_message("mcp:play_animation_response", [request_id, JSON.stringify({"action": "list", "animations": anims, "current": anim_player.current_animation, "playing": anim_player.is_playing()})])


func _handle_serialize_state(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else "/root"
	var action: String = data[2] if data.size() > 2 else "save"
	var max_depth: int = int(data[3]) if data.size() > 3 else 5
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:serialize_state_error", [request_id, "Node not found: %s" % node_path])
		return
	if action == "save":
		var state: Dictionary = _serialize_node(node, max_depth, 0)
		EngineDebugger.send_message("mcp:serialize_state_response", [request_id, JSON.stringify({"action": "save", "state": state})])
	elif action == "load":
		var load_json: String = data[4] if data.size() > 4 else "{}"
		var load_data = JSON.parse_string(load_json)
		if load_data == null:
			EngineDebugger.send_message("mcp:serialize_state_error", [request_id, "Invalid data JSON"])
			return
		var count: int = _deserialize_node(node, load_data)
		EngineDebugger.send_message("mcp:serialize_state_response", [request_id, JSON.stringify({"action": "load", "restored_count": count})])


func _serialize_node(node: Node, max_depth: int, depth: int) -> Dictionary:
	var result: Dictionary = {"class": node.get_class(), "name": node.name, "path": str(node.get_path())}
	var props: Dictionary = {}
	for prop in node.get_property_list():
		var prop_dict: Dictionary = prop
		if prop_dict.get("usage", 0) & PROPERTY_USAGE_STORAGE:
			var prop_name: String = prop_dict.get("name", "")
			if not prop_name.is_empty() and not prop_name.begins_with("_"):
				props[prop_name] = _variant_to_json(node.get(prop_name))
	result["properties"] = props
	if depth < max_depth:
		var children: Array = []
		for child in node.get_children():
			children.append(_serialize_node(child, max_depth, depth + 1))
		if children.size() > 0:
			result["children"] = children
	return result


func _deserialize_node(node: Node, data: Dictionary) -> int:
	var count: int = 0
	var props: Dictionary = data.get("properties", {})
	for prop_name in props:
		var value = _json_to_variant_for_property(node, prop_name, props[prop_name])
		node.set(prop_name, value)
		count += 1
	var children_data: Array = data.get("children", [])
	for child_data in children_data:
		var child_name: String = child_data.get("name", "")
		var child: Node = null
		for c in node.get_children():
			if c.name == child_name:
				child = c
				break
		if child != null:
			count += _deserialize_node(child, child_data)
	return count


func _handle_get_audio(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var buses: Array = []
	for i in AudioServer.bus_count:
		buses.append({
			"name": AudioServer.get_bus_name(i),
			"volume_db": AudioServer.get_bus_volume_db(i),
			"mute": AudioServer.is_bus_mute(i),
			"solo": AudioServer.is_bus_solo(i),
		})
	var players: Array = []
	_find_audio_players(get_tree().root, players)
	EngineDebugger.send_message("mcp:get_audio_response", [request_id, JSON.stringify({"buses": buses, "players": players})])


func _find_audio_players(node: Node, results: Array) -> void:
	if node is AudioStreamPlayer:
		var p: AudioStreamPlayer = node as AudioStreamPlayer
		results.append({"path": str(p.get_path()), "type": "AudioStreamPlayer", "playing": p.playing, "bus": p.bus})
	elif node is AudioStreamPlayer2D:
		var p: AudioStreamPlayer2D = node as AudioStreamPlayer2D
		results.append({"path": str(p.get_path()), "type": "AudioStreamPlayer2D", "playing": p.playing, "bus": p.bus})
	elif node is AudioStreamPlayer3D:
		var p: AudioStreamPlayer3D = node as AudioStreamPlayer3D
		results.append({"path": str(p.get_path()), "type": "AudioStreamPlayer3D", "playing": p.playing, "bus": p.bus})
	for child in node.get_children():
		_find_audio_players(child, results)


func _handle_audio_play(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else "play"
	if node_path.is_empty():
		EngineDebugger.send_message("mcp:audio_play_error", [request_id, "node_path is required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:audio_play_error", [request_id, "Node not found: %s" % node_path])
		return
	if not (node is AudioStreamPlayer or node is AudioStreamPlayer2D or node is AudioStreamPlayer3D):
		EngineDebugger.send_message("mcp:audio_play_error", [request_id, "Node is not an AudioStreamPlayer"])
		return
	var params_json: String = data[3] if data.size() > 3 else "{}"
	var params = JSON.parse_string(params_json)
	if params != null:
		if params.has("stream"):
			var stream := load(params["stream"]) as AudioStream
			if stream != null:
				node.set("stream", stream)
		if params.has("volume"):
			node.set("volume_db", linear_to_db(clampf(float(params["volume"]), 0.0, 1.0)))
		if params.has("pitch"):
			node.set("pitch_scale", float(params["pitch"]))
		if params.has("bus"):
			node.set("bus", params["bus"])
	if action == "play":
		var from_pos: float = float(params.get("from_position", 0.0)) if params != null else 0.0
		node.call("play", from_pos)
		EngineDebugger.send_message("mcp:audio_play_response", [request_id, JSON.stringify({"action": "play", "node_path": node_path})])
	elif action == "stop":
		node.call("stop")
		EngineDebugger.send_message("mcp:audio_play_response", [request_id, JSON.stringify({"action": "stop", "node_path": node_path})])
	elif action == "pause":
		node.set("stream_paused", true)
		EngineDebugger.send_message("mcp:audio_play_response", [request_id, JSON.stringify({"action": "pause", "node_path": node_path})])
	elif action == "resume":
		node.set("stream_paused", false)
		EngineDebugger.send_message("mcp:audio_play_response", [request_id, JSON.stringify({"action": "resume", "node_path": node_path})])


func _handle_audio_bus(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var bus_name: String = data[1] if data.size() > 1 else "Master"
	var bus_idx: int = AudioServer.get_bus_index(bus_name)
	if bus_idx == -1:
		EngineDebugger.send_message("mcp:audio_bus_error", [request_id, "Audio bus not found: %s" % bus_name])
		return
	var params_json: String = data[2] if data.size() > 2 else "{}"
	var params = JSON.parse_string(params_json)
	if params != null:
		if params.has("volume"):
			AudioServer.set_bus_volume_db(bus_idx, linear_to_db(clampf(float(params["volume"]), 0.0, 1.0)))
		if params.has("mute"):
			AudioServer.set_bus_mute(bus_idx, bool(params["mute"]))
		if params.has("solo"):
			AudioServer.set_bus_solo(bus_idx, bool(params["solo"]))
	EngineDebugger.send_message("mcp:audio_bus_response", [request_id, JSON.stringify({
		"bus_name": bus_name,
		"volume_db": AudioServer.get_bus_volume_db(bus_idx),
		"mute": AudioServer.is_bus_mute(bus_idx),
		"solo": AudioServer.is_bus_solo(bus_idx)
	})])


func _get_or_create_environment() -> Environment:
	var cam: Camera3D = get_viewport().get_camera_3d()
	if cam != null and cam.get_environment() != null:
		return cam.get_environment()
	for child in get_tree().root.get_children():
		if child is WorldEnvironment:
			return (child as WorldEnvironment).environment
	var we: WorldEnvironment = WorldEnvironment.new()
	we.environment = Environment.new()
	get_tree().root.add_child(we)
	return we.environment


func _handle_environment(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var action: String = data[1] if data.size() > 1 else "get"
	var params_json: String = data[2] if data.size() > 2 else "{}"
	var params = JSON.parse_string(params_json)
	if action == "get":
		var env: Environment = _get_or_create_environment()
		if env == null:
			EngineDebugger.send_message("mcp:environment_error", [request_id, "No Environment found"])
			return
		EngineDebugger.send_message("mcp:environment_response", [request_id, JSON.stringify({
			"background_mode": env.background_mode,
			"background_color": _variant_to_json(env.background_color),
			"ambient_light_color": _variant_to_json(env.ambient_light_color),
			"ambient_light_energy": env.ambient_light_energy,
			"fog_enabled": env.fog_enabled,
			"fog_density": env.fog_density,
			"glow_enabled": env.glow_enabled,
			"glow_intensity": env.glow_intensity,
			"ssao_enabled": env.ssao_enabled,
		})])
		return
	if action == "set" or action == "sky":
		var env: Environment = _get_or_create_environment()
		if action == "set":
			if params.has("background_color"):
				var c: Dictionary = params["background_color"]
				env.background_color = Color(float(c.get("r", 0)), float(c.get("g", 0)), float(c.get("b", 0)), float(c.get("a", 1)))
			if params.has("ambient_light_color"):
				var c: Dictionary = params["ambient_light_color"]
				env.ambient_light_color = Color(float(c.get("r", 0)), float(c.get("g", 0)), float(c.get("b", 0)), float(c.get("a", 1)))
			if params.has("ambient_light_energy"):
				env.ambient_light_energy = float(params["ambient_light_energy"])
			if params.has("fog_enabled"):
				env.fog_enabled = bool(params["fog_enabled"])
			if params.has("fog_density"):
				env.fog_density = float(params["fog_density"])
			if params.has("glow_enabled"):
				env.glow_enabled = bool(params["glow_enabled"])
			if params.has("glow_intensity"):
				env.glow_intensity = float(params["glow_intensity"])
			if params.has("ssao_enabled"):
				env.ssao_enabled = bool(params["ssao_enabled"])
			if params.has("ssao_radius"):
				env.ssao_radius = float(params["ssao_radius"])
			if params.has("brightness"):
				env.adjustment_enabled = true
				env.adjustment_brightness = float(params["brightness"])
			if params.has("contrast"):
				env.adjustment_enabled = true
				env.adjustment_contrast = float(params["contrast"])
			EngineDebugger.send_message("mcp:environment_response", [request_id, JSON.stringify({"action": "set"})])
			return
		if action == "sky":
			env.sky = Sky.new()
			env.background_mode = Environment.BG_SKY
			var sky_mat: ProceduralSkyMaterial = ProceduralSkyMaterial.new()
			if params.has("top_color"):
				var c: Dictionary = params["top_color"]
				sky_mat.sky_top_color = Color(float(c.get("r", 0.4)), float(c.get("g", 0.6)), float(c.get("b", 1.0)))
			if params.has("horizon_color"):
				var c: Dictionary = params["horizon_color"]
				sky_mat.sky_horizon_color = Color(float(c.get("r", 0.7)), float(c.get("g", 0.8)), float(c.get("b", 0.9)))
			if params.has("ground_color"):
				var c: Dictionary = params["ground_color"]
				sky_mat.ground_bottom_color = Color(float(c.get("r", 0.1)), float(c.get("g", 0.1)), float(c.get("b", 0.1)))
			if params.has("sun_energy"):
				sky_mat.sun_curve = float(params["sun_energy"])
			env.sky.sky_material = sky_mat
			EngineDebugger.send_message("mcp:environment_response", [request_id, JSON.stringify({"action": "sky"})])
			return


func _handle_physics_body(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	if node_path.is_empty():
		EngineDebugger.send_message("mcp:physics_body_error", [request_id, "node_path is required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:physics_body_error", [request_id, "Node not found: %s" % node_path])
		return
	if not (node is PhysicsBody2D or node is PhysicsBody3D):
		EngineDebugger.send_message("mcp:physics_body_error", [request_id, "Node is not a PhysicsBody"])
		return
	var params_json: String = data[2] if data.size() > 2 else "{}"
	var params = JSON.parse_string(params_json)
	if params != null:
		if params.has("gravity_scale"):
			node.set("gravity_scale", float(params["gravity_scale"]))
		if params.has("mass"):
			node.set("mass", float(params["mass"]))
		if params.has("freeze"):
			node.set("freeze", bool(params["freeze"]))
		if params.has("sleeping"):
			node.set("sleeping", bool(params["sleeping"]))
		if params.has("linear_damp"):
			node.set("linear_damp", float(params["linear_damp"]))
		if params.has("angular_damp"):
			node.set("angular_damp", float(params["angular_damp"]))
		if params.has("linear_velocity"):
			var lv: Dictionary = params["linear_velocity"]
			if node is PhysicsBody3D:
				node.set("linear_velocity", Vector3(float(lv.get("x", 0)), float(lv.get("y", 0)), float(lv.get("z", 0))))
			else:
				node.set("linear_velocity", Vector2(float(lv.get("x", 0)), float(lv.get("y", 0))))
		if params.has("angular_velocity"):
			var av = params["angular_velocity"]
			if node is PhysicsBody3D and av is Dictionary:
				node.set("angular_velocity", Vector3(float(av.get("x", 0)), float(av.get("y", 0)), float(av.get("z", 0))))
			else:
				node.set("angular_velocity", float(av))
		if params.has("friction"):
			var phys_mat: PhysicsMaterial = node.get("physics_material_override") as PhysicsMaterial
			if phys_mat == null:
				phys_mat = PhysicsMaterial.new()
				node.set("physics_material_override", phys_mat)
			phys_mat.friction = float(params["friction"])
		if params.has("bounce"):
			var phys_mat: PhysicsMaterial = node.get("physics_material_override") as PhysicsMaterial
			if phys_mat == null:
				phys_mat = PhysicsMaterial.new()
				node.set("physics_material_override", phys_mat)
			phys_mat.bounce = float(params["bounce"])
	var result: Dictionary = {"node_path": node_path, "class": node.get_class()}
	if node.get("mass") != null:
		result["mass"] = node.get("mass")
	if node.get("gravity_scale") != null:
		result["gravity_scale"] = node.get("gravity_scale")
	EngineDebugger.send_message("mcp:physics_body_response", [request_id, JSON.stringify(result)])


func _handle_light_3d(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var action: String = data[1] if data.size() > 1 else "create"
	var params_json: String = data[2] if data.size() > 2 else "{}"
	var params = JSON.parse_string(params_json)
	if action == "create":
		var parent_path: String = params.get("parent_path", "/root")
		var parent := get_node_or_null(parent_path)
		if parent == null:
			EngineDebugger.send_message("mcp:light_3d_error", [request_id, "Parent not found: %s" % parent_path])
			return
		var light_type: String = params.get("light_type", "omni")
		var light: Light3D
		if light_type == "directional": light = DirectionalLight3D.new()
		elif light_type == "spot": light = SpotLight3D.new()
		else: light = OmniLight3D.new()
		if params.has("color"):
			var c: Dictionary = params["color"]
			light.light_color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)))
		if params.has("energy"):
			light.light_energy = float(params["energy"])
		if params.has("shadows"):
			light.shadow_enabled = bool(params["shadows"])
		if light is OmniLight3D and params.has("range"):
			(light as OmniLight3D).omni_range = float(params["range"])
		if light is SpotLight3D:
			if params.has("range"):
				(light as SpotLight3D).spot_range = float(params["range"])
			if params.has("spot_angle"):
				(light as SpotLight3D).spot_angle = float(params["spot_angle"])
		if params.has("name") and not str(params["name"]).is_empty():
			light.name = params["name"]
		parent.add_child(light)
		EngineDebugger.send_message("mcp:light_3d_response", [request_id, JSON.stringify({"action": "create", "path": str(light.get_path()), "type": light_type})])
	elif action == "configure":
		var node_path: String = params.get("node_path", "")
		var node := get_node_or_null(node_path)
		if node == null or not node is Light3D:
			EngineDebugger.send_message("mcp:light_3d_error", [request_id, "Light3D not found"])
			return
		var light: Light3D = node as Light3D
		if params.has("color"):
			var c: Dictionary = params["color"]
			light.light_color = Color(float(c.get("r", 1)), float(c.get("g", 1)), float(c.get("b", 1)))
		if params.has("energy"):
			light.light_energy = float(params["energy"])
		if params.has("shadows"):
			light.shadow_enabled = bool(params["shadows"])
		EngineDebugger.send_message("mcp:light_3d_response", [request_id, JSON.stringify({"action": "configure"})])


func _handle_mesh_instance(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var params_json: String = data[1] if data.size() > 1 else "{}"
	var params = JSON.parse_string(params_json)
	var parent_path: String = params.get("parent_path", "/root")
	var parent := get_node_or_null(parent_path)
	if parent == null:
		EngineDebugger.send_message("mcp:mesh_instance_error", [request_id, "Parent not found: %s" % parent_path])
		return
	var mesh_type: String = params.get("mesh_type", "box")
	var mesh: Mesh
	if mesh_type == "sphere": mesh = SphereMesh.new()
	elif mesh_type == "cylinder": mesh = CylinderMesh.new()
	elif mesh_type == "capsule": mesh = CapsuleMesh.new()
	elif mesh_type == "plane": mesh = PlaneMesh.new()
	elif mesh_type == "quad": mesh = QuadMesh.new()
	else: mesh = BoxMesh.new()
	if params.has("size") and mesh is BoxMesh:
		var s: Dictionary = params["size"]
		(mesh as BoxMesh).size = Vector3(float(s.get("x", 1)), float(s.get("y", 1)), float(s.get("z", 1)))
	if params.has("radius"):
		if mesh is SphereMesh: (mesh as SphereMesh).radius = float(params["radius"])
		elif mesh is CylinderMesh: (mesh as CylinderMesh).top_radius = float(params["radius"])
		elif mesh is CapsuleMesh: (mesh as CapsuleMesh).radius = float(params["radius"])
	if params.has("height"):
		if mesh is CylinderMesh: (mesh as CylinderMesh).height = float(params["height"])
		elif mesh is CapsuleMesh: (mesh as CapsuleMesh).height = float(params["height"])
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	if params.has("material") and params["material"] is String:
		var mat: StandardMaterial3D = StandardMaterial3D.new()
		var hex: String = params["material"]
		if hex.begins_with("#") or hex.length() == 6 or hex.length() == 8:
			mat.albedo_color = Color.from_string(hex, Color.WHITE)
		mi.material_override = mat
	if params.has("name") and not str(params["name"]).is_empty():
		mi.name = params["name"]
	parent.add_child(mi)
	EngineDebugger.send_message("mcp:mesh_instance_response", [request_id, JSON.stringify({"path": str(mi.get_path()), "mesh_type": mesh_type})])


func _handle_navigate_path(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var params_json: String = data[1] if data.size() > 1 else "{}"
	var params = JSON.parse_string(params_json)
	if params == null:
		EngineDebugger.send_message("mcp:navigate_path_error", [request_id, "Invalid params"])
		return
	var start_dict: Dictionary = params.get("start", {})
	var end_dict: Dictionary = params.get("end", {})
	var optimize: bool = params.get("optimize", true)
	if start_dict.is_empty() or end_dict.is_empty():
		EngineDebugger.send_message("mcp:navigate_path_error", [request_id, "start and end are required"])
		return
	var is_3d: bool = start_dict.has("z") or end_dict.has("z")
	if is_3d:
		var start_pos: Vector3 = Vector3(float(start_dict.get("x", 0)), float(start_dict.get("y", 0)), float(start_dict.get("z", 0)))
		var end_pos: Vector3 = Vector3(float(end_dict.get("x", 0)), float(end_dict.get("y", 0)), float(end_dict.get("z", 0)))
		var map_rid: RID = get_tree().root.get_world_3d().get_navigation_map()
		var path_arr: PackedVector3Array = NavigationServer3D.map_get_path(map_rid, start_pos, end_pos, optimize)
		var total_length: float = 0.0
		for i in range(1, path_arr.size()):
			total_length += path_arr[i - 1].distance_to(path_arr[i])
		EngineDebugger.send_message("mcp:navigate_path_response", [request_id, JSON.stringify({"mode": "3d", "path": _variant_to_json(path_arr), "point_count": path_arr.size(), "total_length": total_length})])
	else:
		var start_pos: Vector2 = Vector2(float(start_dict.get("x", 0)), float(start_dict.get("y", 0)))
		var end_pos: Vector2 = Vector2(float(end_dict.get("x", 0)), float(end_dict.get("y", 0)))
		var map_rid: RID = get_tree().root.get_world_2d().get_navigation_map()
		var path_arr: PackedVector2Array = NavigationServer2D.map_get_path(map_rid, start_pos, end_pos, optimize)
		var total_length: float = 0.0
		for i in range(1, path_arr.size()):
			total_length += path_arr[i - 1].distance_to(path_arr[i])
		EngineDebugger.send_message("mcp:navigate_path_response", [request_id, JSON.stringify({"mode": "2d", "path": _variant_to_json(path_arr), "point_count": path_arr.size(), "total_length": total_length})])


func _handle_navigation_3d(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var action: String = data[1] if data.size() > 1 else "create"
	var params_json: String = data[2] if data.size() > 2 else "{}"
	var params = JSON.parse_string(params_json)
	if action == "create":
		var parent_path: String = params.get("parent_path", "/root")
		var parent := get_node_or_null(parent_path)
		if parent == null:
			EngineDebugger.send_message("mcp:navigation_3d_error", [request_id, "Parent not found: %s" % parent_path])
			return
		var region: NavigationRegion3D = NavigationRegion3D.new()
		region.navigation_mesh = NavigationMesh.new()
		if params.has("cell_size"):
			region.navigation_mesh.cell_size = float(params["cell_size"])
		if params.has("agent_radius"):
			region.navigation_mesh.agent_radius = float(params["agent_radius"])
		if params.has("agent_height"):
			region.navigation_mesh.agent_height = float(params["agent_height"])
		if params.has("name") and not str(params["name"]).is_empty():
			region.name = params["name"]
		parent.add_child(region)
		EngineDebugger.send_message("mcp:navigation_3d_response", [request_id, JSON.stringify({"action": "create", "path": str(region.get_path())})])
	elif action == "bake":
		var node_path: String = params.get("node_path", "")
		var node := get_node_or_null(node_path)
		if node == null or not node is NavigationRegion3D:
			EngineDebugger.send_message("mcp:navigation_3d_error", [request_id, "NavigationRegion3D not found"])
			return
		(node as NavigationRegion3D).bake_navigation_mesh()
		EngineDebugger.send_message("mcp:navigation_3d_response", [request_id, JSON.stringify({"action": "bake"})])


func _handle_animation_tree(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else "get_state"
	var node := get_node_or_null(node_path)
	if node == null or not node is AnimationTree:
		EngineDebugger.send_message("mcp:animation_tree_error", [request_id, "AnimationTree not found"])
		return
	var tree: AnimationTree = node as AnimationTree
	if action == "travel":
		var state_name: String = data[3] if data.size() > 3 else ""
		var playback = tree.get("parameters/playback")
		if playback != null:
			playback.travel(state_name)
		EngineDebugger.send_message("mcp:animation_tree_response", [request_id, JSON.stringify({"action": "travel", "state": state_name})])
	elif action == "set_param":
		var param_name: String = data[3] if data.size() > 3 else ""
		var param_value = data[4] if data.size() > 4 else 0
		tree.set("parameters/" + param_name, param_value)
		EngineDebugger.send_message("mcp:animation_tree_response", [request_id, JSON.stringify({"action": "set_param", "param": param_name})])
	else:
		var playback = tree.get("parameters/playback")
		var current: String = ""
		if playback != null:
			current = playback.get_current_node()
		EngineDebugger.send_message("mcp:animation_tree_response", [request_id, JSON.stringify({"action": "get_state", "current": current})])


func _handle_create_animation(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var params_json: String = data[1] if data.size() > 1 else "{}"
	var params = JSON.parse_string(params_json)
	if params == null:
		EngineDebugger.send_message("mcp:create_animation_error", [request_id, "Invalid params"])
		return
	var node_path: String = params.get("node_path", "")
	var anim_name: String = params.get("animation_name", "")
	if node_path.is_empty() or anim_name.is_empty():
		EngineDebugger.send_message("mcp:create_animation_error", [request_id, "node_path and animation_name are required"])
		return
	var node := get_node_or_null(node_path)
	if node == null or not node is AnimationPlayer:
		EngineDebugger.send_message("mcp:create_animation_error", [request_id, "AnimationPlayer not found"])
		return
	var anim_player: AnimationPlayer = node as AnimationPlayer
	var anim: Animation = Animation.new()
	anim.length = float(params.get("length", 1.0))
	var loop_mode: int = int(params.get("loop_mode", 0))
	anim.loop_mode = loop_mode
	var tracks: Array = params.get("tracks", [])
	var track_count: int = 0
	for track_data in tracks:
		var track_type_str: String = track_data.get("type", "value")
		var track_path: String = track_data.get("path", "")
		if track_path.is_empty():
			continue
		var idx: int = anim.add_track(Animation.TYPE_VALUE)
		anim.track_set_path(idx, NodePath(track_path))
		var keys: Array = track_data.get("keys", [])
		for key_data in keys:
			var time: float = float(key_data.get("time", 0.0))
			var value = _json_to_variant(key_data.get("value", null), key_data.get("type_hint", ""))
			anim.track_insert_key(idx, time, value)
		track_count += 1
	var lib_name: String = params.get("library", "")
	var lib: AnimationLibrary
	if anim_player.has_animation_library(lib_name):
		lib = anim_player.get_animation_library(lib_name)
	else:
		lib = AnimationLibrary.new()
		anim_player.add_animation_library(lib_name, lib)
	lib.add_animation(anim_name, anim)
	EngineDebugger.send_message("mcp:create_animation_response", [request_id, JSON.stringify({"animation_name": anim_name, "length": anim.length, "track_count": track_count})])


func _handle_skeleton_ik(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else "start"
	var node := get_node_or_null(node_path)
	if node == null or not node is SkeletonIK3D:
		EngineDebugger.send_message("mcp:skeleton_ik_error", [request_id, "SkeletonIK3D not found"])
		return
	var ik: SkeletonIK3D = node as SkeletonIK3D
	if action == "start":
		ik.start()
		EngineDebugger.send_message("mcp:skeleton_ik_response", [request_id, JSON.stringify({"action": "start"})])
	elif action == "stop":
		ik.stop()
		EngineDebugger.send_message("mcp:skeleton_ik_response", [request_id, JSON.stringify({"action": "stop"})])
	elif action == "set_target":
		var params_json: String = data[3] if data.size() > 3 else "{}"
		var params = JSON.parse_string(params_json)
		var target_tf: Transform3D = Transform3D.IDENTITY
		target_tf.origin = Vector3(float(params.get("x", 0)), float(params.get("y", 0)), float(params.get("z", 0)))
		ik.target = target_tf
		EngineDebugger.send_message("mcp:skeleton_ik_response", [request_id, JSON.stringify({"action": "set_target"})])


func _handle_time_scale(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var action: String = data[1] if data.size() > 1 else "get"
	if action == "set" and data.size() > 2:
		Engine.time_scale = float(data[2])
	EngineDebugger.send_message("mcp:time_scale_response", [request_id, JSON.stringify({"time_scale": Engine.time_scale, "fps": Engine.get_frames_per_second()})])


func _handle_window(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var action: String = data[1] if data.size() > 1 else "get"
	var win: Window = get_tree().root
	var params_json: String = data[2] if data.size() > 2 else "{}"
	var params = JSON.parse_string(params_json)
	if action == "get":
		EngineDebugger.send_message("mcp:window_response", [request_id, JSON.stringify({"size": {"x": win.size.x, "y": win.size.y}, "title": win.title})])
		return
	if params != null:
		if params.has("width") and params.has("height"):
			win.size = Vector2i(int(params["width"]), int(params["height"]))
		if params.has("title"):
			win.title = str(params["title"])
	EngineDebugger.send_message("mcp:window_response", [request_id, JSON.stringify({"action": "set"})])


func _handle_gamepad(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var input_type: String = data[1] if data.size() > 1 else "button"
	var index: int = int(data[2]) if data.size() > 2 else 0
	var value: float = float(data[3]) if data.size() > 3 else 0
	var device: int = int(data[4]) if data.size() > 4 else 0
	if input_type == "button":
		var event: InputEventJoypadButton = InputEventJoypadButton.new()
		event.device = device
		event.button_index = index
		event.pressed = value > 0.5
		event.pressure = value
		Input.parse_input_event(event)
		EngineDebugger.send_message("mcp:gamepad_response", [request_id, JSON.stringify({"type": "button", "index": index, "pressed": event.pressed})])
	else:
		var event: InputEventJoypadMotion = InputEventJoypadMotion.new()
		event.device = device
		event.axis = index
		event.axis_value = value
		Input.parse_input_event(event)
		EngineDebugger.send_message("mcp:gamepad_response", [request_id, JSON.stringify({"type": "axis", "index": index, "value": value})])


func _handle_mouse_drag(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var from_x: float = float(data[1]) if data.size() > 1 else 0
	var from_y: float = float(data[2]) if data.size() > 2 else 0
	var to_x: float = float(data[3]) if data.size() > 3 else 0
	var to_y: float = float(data[4]) if data.size() > 4 else 0
	var button: int = int(data[5]) if data.size() > 5 else MOUSE_BUTTON_LEFT
	var from_pos: Vector2 = Vector2(from_x, from_y)
	var to_pos: Vector2 = Vector2(to_x, to_y)
	var pe: InputEventMouseButton = InputEventMouseButton.new()
	pe.position = from_pos
	pe.button_index = button
	pe.pressed = true
	Input.parse_input_event(pe)
	var me: InputEventMouseMotion = InputEventMouseMotion.new()
	me.position = to_pos
	me.relative = to_pos - from_pos
	me.button_mask = MOUSE_BUTTON_MASK_LEFT
	Input.parse_input_event(me)
	var re: InputEventMouseButton = InputEventMouseButton.new()
	re.position = to_pos
	re.button_index = button
	re.pressed = false
	Input.parse_input_event(re)
	EngineDebugger.send_message("mcp:mouse_drag_response", [request_id, JSON.stringify({"from": {"x": from_x, "y": from_y}, "to": {"x": to_x, "y": to_y}})])


func _handle_ui_debug(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var node_path: String = data[1] if data.size() > 1 else ""
	var action: String = data[2] if data.size() > 2 else "get"
	if node_path.is_empty():
		EngineDebugger.send_message("mcp:ui_debug_error", [request_id, "node_path is required"])
		return
	var node := get_node_or_null(node_path)
	if node == null or not node is Control:
		EngineDebugger.send_message("mcp:ui_debug_error", [request_id, "Control node not found"])
		return
	var ctrl: Control = node as Control
	if action == "get":
		var text: String = ""
		if ctrl is Label: text = (ctrl as Label).text
		elif ctrl is Button: text = (ctrl as Button).text
		elif ctrl is LineEdit: text = (ctrl as LineEdit).text
		EngineDebugger.send_message("mcp:ui_debug_response", [request_id, JSON.stringify({
			"visible": ctrl.visible, "position": {"x": ctrl.position.x, "y": ctrl.position.y},
			"size": {"w": ctrl.size.x, "h": ctrl.size.y}, "text": text, "class": ctrl.get_class()
		})])
	elif action == "set":
		var params_json: String = data[3] if data.size() > 3 else "{}"
		var params = JSON.parse_string(params_json)
		if params != null:
			if params.has("visible"): ctrl.visible = bool(params["visible"])
			if params.has("position"):
				var p: Dictionary = params["position"]
				ctrl.position = Vector2(float(p.get("x", ctrl.position.x)), float(p.get("y", ctrl.position.y)))
			if params.has("size"):
				var s: Dictionary = params["size"]
				ctrl.size = Vector2(float(s.get("w", ctrl.size.x)), float(s.get("h", ctrl.size.y)))
		EngineDebugger.send_message("mcp:ui_debug_response", [request_id, JSON.stringify({"action": "set"})])
	elif action == "text":
		var text: String = data[3] if data.size() > 3 else ""
		if ctrl is Label: (ctrl as Label).text = text
		elif ctrl is Button: (ctrl as Button).text = text
		elif ctrl is LineEdit: (ctrl as LineEdit).text = text
		EngineDebugger.send_message("mcp:ui_debug_response", [request_id, JSON.stringify({"action": "text"})])


func _handle_debug_draw(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var action: String = data[1] if data.size() > 1 else "line"
	var params_json: String = data[2] if data.size() > 2 else "{}"
	var params = JSON.parse_string(params_json)
	if action == "clear":
		for entry in _debug_meshes:
			if is_instance_valid(entry["node"]):
				entry["node"].queue_free()
		_debug_meshes.clear()
		if _debug_draw_node != null and is_instance_valid(_debug_draw_node):
			_debug_draw_node.queue_free()
			_debug_draw_node = null
		EngineDebugger.send_message("mcp:debug_draw_response", [request_id, JSON.stringify({"action": "clear"})])
		return
	if _debug_draw_node == null or not is_instance_valid(_debug_draw_node):
		_debug_draw_node = Node3D.new()
		_debug_draw_node.name = "_McpDebugDraw"
		get_tree().root.add_child(_debug_draw_node)
	var color_dict: Dictionary = params.get("color", {})
	var color: Color = Color(float(color_dict.get("r", 1)), float(color_dict.get("g", 0)), float(color_dict.get("b", 0)), float(color_dict.get("a", 1)))
	var duration: int = int(params.get("duration", 0))
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = true
	if action == "line":
		var from_dict: Dictionary = params.get("from", {})
		var to_dict: Dictionary = params.get("to", {})
		var from_pos: Vector3 = Vector3(float(from_dict.get("x", 0)), float(from_dict.get("y", 0)), float(from_dict.get("z", 0)))
		var to_pos: Vector3 = Vector3(float(to_dict.get("x", 0)), float(to_dict.get("y", 0)), float(to_dict.get("z", 0)))
		var im: ImmediateMesh = ImmediateMesh.new()
		im.surface_begin(Mesh.PRIMITIVE_LINES, mat)
		im.surface_add_vertex(from_pos)
		im.surface_add_vertex(to_pos)
		im.surface_end()
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = im
		_debug_draw_node.add_child(mi)
		_debug_meshes.append({"node": mi, "frames_left": duration})
		EngineDebugger.send_message("mcp:debug_draw_response", [request_id, JSON.stringify({"action": "line"})])
	elif action == "sphere":
		var center_dict: Dictionary = params.get("center", {})
		var center: Vector3 = Vector3(float(center_dict.get("x", 0)), float(center_dict.get("y", 0)), float(center_dict.get("z", 0)))
		var radius: float = float(params.get("radius", 0.5))
		var sm: SphereMesh = SphereMesh.new()
		sm.radius = radius
		sm.height = radius * 2.0
		sm.material = mat
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = sm
		mi.global_position = center
		_debug_draw_node.add_child(mi)
		_debug_meshes.append({"node": mi, "frames_left": duration})
		EngineDebugger.send_message("mcp:debug_draw_response", [request_id, JSON.stringify({"action": "sphere"})])
	elif action == "box":
		var center_dict: Dictionary = params.get("center", {})
		var center: Vector3 = Vector3(float(center_dict.get("x", 0)), float(center_dict.get("y", 0)), float(center_dict.get("z", 0)))
		var size_dict: Dictionary = params.get("size", {})
		var box_size: Vector3 = Vector3(float(size_dict.get("x", 1)), float(size_dict.get("y", 1)), float(size_dict.get("z", 1)))
		var bm: BoxMesh = BoxMesh.new()
		bm.size = box_size
		bm.material = mat
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = bm
		mi.global_position = center
		_debug_draw_node.add_child(mi)
		_debug_meshes.append({"node": mi, "frames_left": duration})
		EngineDebugger.send_message("mcp:debug_draw_response", [request_id, JSON.stringify({"action": "box"})])


func _handle_input_state(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var action: String = data[1] if data.size() > 1 else "query"
	if action == "query":
		var mouse_pos: Vector2 = get_viewport().get_mouse_position()
		EngineDebugger.send_message("mcp:input_state_response", [request_id, JSON.stringify({"mouse_position": {"x": mouse_pos.x, "y": mouse_pos.y}})])
	elif action == "warp_mouse":
		var params_json: String = data[2] if data.size() > 2 else "{}"
		var params = JSON.parse_string(params_json)
		Input.warp_mouse(Vector2(float(params.get("x", 0)), float(params.get("y", 0))))
		EngineDebugger.send_message("mcp:input_state_response", [request_id, JSON.stringify({"action": "warp_mouse"})])
	elif action == "mouse_mode":
		var mode_str: String = data[2] if data.size() > 2 else "visible"
		if mode_str == "hidden": Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		elif mode_str == "captured": Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		else: Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		EngineDebugger.send_message("mcp:input_state_response", [request_id, JSON.stringify({"action": "mouse_mode", "mode": mode_str})])


func _handle_create_timer(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var params_json: String = data[1] if data.size() > 1 else "{}"
	var params = JSON.parse_string(params_json)
	var parent_path: String = params.get("parent_path", "/root")
	var wait_time: float = float(params.get("wait_time", 1.0))
	var one_shot: bool = params.get("one_shot", false)
	var autostart: bool = params.get("autostart", false)
	var parent := get_node_or_null(parent_path)
	if parent == null:
		EngineDebugger.send_message("mcp:create_timer_error", [request_id, "Parent not found: %s" % parent_path])
		return
	var timer: Timer = Timer.new()
	timer.wait_time = wait_time
	timer.one_shot = one_shot
	timer.autostart = autostart
	if params.has("name") and not str(params["name"]).is_empty():
		timer.name = params["name"]
	parent.add_child(timer)
	if autostart:
		timer.start()
	EngineDebugger.send_message("mcp:create_timer_response", [request_id, JSON.stringify({"path": str(timer.get_path()), "wait_time": timer.wait_time, "one_shot": timer.one_shot})])


func _handle_tween_property(data: Array) -> void:
	var request_id: String = data[0] if data.size() > 0 else ""
	var params_json: String = data[1] if data.size() > 1 else "{}"
	var params = JSON.parse_string(params_json)
	var node_path: String = params.get("node_path", "")
	var property: String = params.get("property", "")
	if node_path.is_empty() or property.is_empty():
		EngineDebugger.send_message("mcp:tween_property_error", [request_id, "node_path and property are required"])
		return
	var node := get_node_or_null(node_path)
	if node == null:
		EngineDebugger.send_message("mcp:tween_property_error", [request_id, "Node not found"])
		return
	var final_value = _json_to_variant_for_property(node, property, params.get("final_value", null))
	var duration: float = float(params.get("duration", 1.0))
	var trans_type: int = int(params.get("trans_type", 0))
	var ease_type: int = int(params.get("ease_type", 2))
	var tween: Tween = create_tween()
	tween.tween_property(node, property, final_value, duration)
	EngineDebugger.send_message("mcp:tween_property_response", [request_id, JSON.stringify({"node": node_path, "property": property, "duration": duration})])
