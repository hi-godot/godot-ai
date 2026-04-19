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
## Entries drained from the logger but not yet sent over the debugger
## channel. Holds the tail of one drain() so we can bleed it out across
## frames at FLUSH_BATCH_LIMIT per frame rather than blasting the whole
## queue in a single _process tick.
var _pending_outbound: Array = []


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
