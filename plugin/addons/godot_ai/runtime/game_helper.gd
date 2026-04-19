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
## No-ops in the editor (OS.has_feature("editor")) and when the debugger
## channel is inactive (e.g. exported release builds).

const CAPTURE_PREFIX := "mcp"

var _registered := false


func _ready() -> void:
	## Only run in a game process. Autoloads without @tool shouldn't
	## instantiate in the editor, but belt-and-braces in case a tool-mode
	## addon pulls us in.
	if OS.has_feature("editor"):
		return
	## Register unconditionally. register_message_capture is safe to call
	## before the debugger is active — the capture sits until a message
	## arrives. Don't gate on EngineDebugger.is_active(): at _ready time
	## the debug-channel handshake may not have completed yet, and if we
	## skip registration we'll never notice it later.
	EngineDebugger.register_message_capture(CAPTURE_PREFIX, _on_debug_message)
	_registered = true
	## Print is picked up by Godot's remote-stdout forwarder so it shows
	## up in the editor's Output panel — useful for diagnosing why a
	## capture request timed out.
	print("[godot_ai game_helper] registered mcp capture (debugger active=%s)"
		% EngineDebugger.is_active())
	## Boot beacon so the editor side can confirm the autoload ran even
	## if no screenshot was ever requested.
	if EngineDebugger.is_active():
		EngineDebugger.send_message("mcp:hello", [])


func _exit_tree() -> void:
	if _registered:
		EngineDebugger.unregister_message_capture(CAPTURE_PREFIX)
		_registered = false


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
