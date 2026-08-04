@tool
extends RefCounted

## Vision Routing - route screenshot-tool images through Groq's free vision API.
##
## Models without image support (e.g. DeepSeek) cannot read the image blocks the
## screenshot tool returns. When routing is enabled, every capture is sent to
## Groq's free vision model on a worker thread and the resulting text
## description is returned to the AI instead:
##
##   - Editor (non-game) screenshots are captured normally by
##     editor_handler.gd, then described on a worker thread; the reply is
##     deferred until the description is ready.
##   - Game screenshots are intercepted in mcp_debugger_plugin.gd the same way.
##   - On success the response keeps a valid but tiny 2x2 placeholder image and
##     carries the description as text metadata (`vision_description` plus a
##     `note`, which the server forwards to the model).
##   - On failure (missing key, network, API error) the original image payload
##     passes through unchanged, so the screenshot tool never breaks.
##
## Settings live in Editor Settings (`vision_routing/enabled` and
## `vision_routing/api_key_enc`); the API key is stored encrypted (AES-256-CBC,
## key derived from this machine) rather than in plain text, and the
## GROQ_API_KEY environment variable takes priority over the stored key.
##
## UI: "Vision Routing" tab in Clients & Tools (after Settings) plus a quick
## toggle in the dock right under Developer mode.

const MODEL_ID := "qwen/qwen3.6-27b"
const GROQ_HOST := "api.groq.com"
const GROQ_PORT := 443
const GROQ_PATH := "/openai/v1/chat/completions"

const SETTING_ENABLED := "vision_routing/enabled"
const SETTING_API_KEY_ENC := "vision_routing/api_key_enc"
const TAB_NAME := "Vision Routing"
const ROW_NAME := "VisionRoutingToggleRow"

const MAX_IMAGE_EDGE := 1024
const CONNECT_TIMEOUT_MS := 4000
const REQUEST_TIMEOUT_MS := 8000

const _ENC_PREFIX := "v1"
const _SALT := "vision_routing::v1::godot-ai"
const _PLACEHOLDER_PNG := "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAALSURBVBhXY2BABwAAEgABp3qZbgAAAABJRU5ErkJggg=="

## Plugin log buffer (McpLogBuffer), set by plugin.gd; null-safe.
var log_buffer: Object = null

var _active := true
var _route_done: Callable
var _pending: Dictionary = {}   # request_id -> {payload, data, connection}
var _threads: Dictionary = {}   # request_id -> Thread ("_test" = ping thread)
var _error_notes: Dictionary = {}  # request_id -> last Groq error detail
var _key_loading := false

# UI references, kept in sync by _sync_ui_states().
var _tab_enable: CheckButton = null
var _tab_key_edit: LineEdit = null
var _tab_status: Label = null
var _row_toggle: CheckButton = null


func _init() -> void:
	_route_done = Callable(self, "_on_route_complete")


## Plugin teardown: stop workers and join in-flight threads so Godot never
## destroys a Thread mid-execution during a plugin reload.
func shutdown() -> void:
	_active = false
	## Workers poll _active between HTTP polls, so this returns within one
	## poll interval (~50ms) unless a request is mid-flight in the OS; worst
	## case is a connect/request timeout.
	for rid in _threads:
		var thread: Thread = _threads[rid]
		if thread != null and thread.is_started() and thread.is_alive():
			thread.wait_to_finish()
	_threads.clear()
	_pending.clear()
	_error_notes.clear()
	_tab_enable = null
	_tab_key_edit = null
	_tab_status = null
	_row_toggle = null


# --- routing ------------------------------------------------------------------

## Entry point called from editor_handler.take_screenshot when routing is
## enabled. Runs the real capture (via `original`), then routes the image
## through Groq on a worker thread. Returns the deferred-response sentinel
## when the worker owns the reply, otherwise the capture result unchanged.
func route_editor_screenshot(params: Dictionary, original: Callable, connection: Object) -> Dictionary:
	var rid := str(params.get("_request_id", ""))
	if rid.is_empty():
		## No deferred channel (e.g. batch_execute / dispatch_direct) - keep
		## the original synchronous result untouched.
		return original.call(params)
	var result := original.call(params)
	if not (result is Dictionary) or not result.has("data"):
		return result
	var data: Variant = result["data"]
	if not (data is Dictionary) or not data.has("image_base64"):
		return result
	if _start_route(rid, str(params.get("source", "viewport")), result, data, connection, params):
		return {"_deferred": true, "_deferred_timeout_ms": 30000}
	return result


## Entry point called from McpDebuggerPlugin._on_screenshot_response before
## the frame is sent. Returns true when a worker owns the reply (the caller
## must NOT send the payload itself); false means pass through unchanged.
func route_game_payload(connection: Object, rid: String, payload: Dictionary) -> bool:
	var data: Variant = payload.get("data")
	if not (data is Dictionary) or not data.has("image_base64"):
		return false
	return _start_route(rid, "game", payload, data, connection, {})


## Returns true when a worker owns the reply; false means the caller should
## pass the original payload through unchanged.
func _start_route(rid: String, source: String, payload: Dictionary, data: Dictionary, connection: Object, params: Dictionary) -> bool:
	var api_key := _resolved_api_key()
	if api_key.is_empty():
		_log("vision routing: no Groq API key - screenshot %s passed through" % rid)
		return false
	_pending[rid] = {"payload": payload, "data": data, "connection": connection}
	var prompt := _build_prompt(params)
	var thread := Thread.new()
	_threads[rid] = thread
	thread.start(_groq_worker.bind(str(data.get("image_base64", "")), prompt, api_key, rid))
	_log("vision routing: routing %s screenshot %s (%d b64 chars) via %s" % [source, rid, str(data.get("image_base64", "")).length(), MODEL_ID])
	return true


func _on_route_complete(rid: String, description: Variant) -> void:
	_join_thread(rid)
	if not _active:
		_pending.erase(rid)
		return
	var entry: Dictionary = _pending.get(rid, {})
	_pending.erase(rid)
	if entry.is_empty():
		return
	var connection: Object = entry.get("connection")
	if connection == null or not is_instance_valid(connection):
		return
	var payload: Dictionary = entry.get("payload", {})
	var description_str := str(description) if description != null else ""
	if description_str.is_empty():
		_log("vision routing: Groq failed for %s (%s) - returning original image" % [rid, _error_notes.get(rid, "unknown error")])
		_error_notes.erase(rid)
		_pass_through(connection, rid, payload)
		return
	_error_notes.erase(rid)
	var data: Dictionary = entry.get("data", {}).duplicate()
	## The server forwards a fixed whitelist of metadata keys into the text
	## result; `note` is the free-form one, so the description rides there
	## (plus an explicit `vision_description` key) so text-only models can
	## read it. The original image is replaced by a valid 2x2 placeholder so
	## the payload stays well-formed.
	data.erase("image_base64")
	data["vision_description"] = description_str
	data["routed_via"] = MODEL_ID
	var original_note := str(data.get("note", ""))
	data["note"] = (original_note + " | " if not original_note.is_empty() else "") + description_str
	data["image_base64"] = _PLACEHOLDER_PNG
	data["format"] = "png"
	_log("vision routing: description ready for %s (%d chars)" % [rid, description_str.length()])
	_pass_through(connection, rid, {"data": data})


func _pass_through(connection: Object, rid: String, payload: Dictionary) -> void:
	if connection != null and is_instance_valid(connection):
		connection.send_deferred_response(rid, payload)


func _build_prompt(params: Dictionary) -> String:
	var lines := PackedStringArray([
		"You are the vision module of a text-only AI agent driving the Godot editor through MCP.",
		"Describe this screenshot so the agent can act without seeing it. Report:",
		"- What is shown: Godot editor viewport, game window, 2D/3D scene, UI panel, dialog, or other.",
		"- Objects/nodes: what they are, position, color, size, and any labels or text (quote text exactly).",
		"- UI text: menus, buttons, error dialogs, console output, warnings, line numbers.",
		"- State: selected node outlines, gizmos, play/stop status, panels that are open.",
		"- Problems: errors, red highlights, missing textures, black screens, glitches, stretching.",
		"Be concise (under 200 words), factual, and use exact quotes instead of paraphrase. Do not give advice.",
	])
	var user_prompt := str(params.get("_user_prompt", ""))
	if user_prompt.is_empty():
		user_prompt = str(params.get("user_prompt", ""))
	if not user_prompt.is_empty():
		lines.append("Context from the agent that requested this screenshot: %s" % user_prompt)
	return "\n".join(lines)


# --- Groq worker (thread) -----------------------------------------------------

func _groq_worker(image_b64: String, prompt: String, api_key: String, rid: String) -> void:
	var description := _groq_describe_blocking(image_b64, prompt, api_key, rid)
	_route_done.call_deferred(rid, description)


func _groq_describe_blocking(image_b64: String, prompt: String, api_key: String, rid: String) -> String:
	var b64 := _downscale_image_if_needed(image_b64)
	var body := JSON.stringify({
		"model": MODEL_ID,
		"messages": [{
			"role": "user",
			"content": [
				{"type": "text", "text": prompt},
				{"type": "image_url", "image_url": {"url": "data:image/png;base64," + b64}},
			],
		}],
		"max_tokens": 512,
		"temperature": 0.2,
		"reasoning_effort": "none",
	})
	var response := _http_post_json(api_key, body)
	var code: int = int(response.get("code", 0))
	if code == 0:
		_error_notes[rid] = str(response.get("error", "HTTP request failed"))
		return ""
	if code != 200:
		_error_notes[rid] = "Groq HTTP %d: %s" % [code, _body_snippet(str(response.get("text", "")))]
		return ""
	var parsed: Variant = JSON.parse_string(str(response.get("text", "")))
	if not (parsed is Dictionary):
		_error_notes[rid] = "Groq response was not JSON: %s" % _body_snippet(str(response.get("text", "")))
		return ""
	var choices: Variant = parsed.get("choices")
	if not (choices is Array) or choices.is_empty():
		_error_notes[rid] = "Groq response had no choices: %s" % _body_snippet(str(response.get("text", "")))
		return ""
	if not (choices[0] is Dictionary):
		_error_notes[rid] = "Groq response choice was not an object: %s" % _body_snippet(str(response.get("text", "")))
		return ""
	var message: Variant = choices[0].get("message", {})
	if not (message is Dictionary):
		_error_notes[rid] = "Groq response message was not an object: %s" % _body_snippet(str(response.get("text", "")))
		return ""
	var content: Variant = message.get("content", "")
	if content == null:
		_error_notes[rid] = "Groq response content was null: %s" % _body_snippet(str(response.get("text", "")))
		return ""
	var text := str(content).strip_edges()
	## Qwen3 reasoning may wrap its answer in <think>...</think> blocks.
	var think_end := text.rfind("</think>")
	if think_end != -1:
		text = text.substr(think_end + "</think>".length()).strip_edges()
	return text


## Minimal text-only call used by the "Test connection" button.
func _groq_ping_blocking(api_key: String) -> Dictionary:
	var body := JSON.stringify({
		"model": MODEL_ID,
		"messages": [{"role": "user", "content": "Reply with exactly: OK"}],
		"max_tokens": 5,
	})
	var response := _http_post_json(api_key, body)
	var code: int = int(response.get("code", 0))
	if code == 200:
		return {"ok": true, "error": ""}
	if code == 0:
		return {"ok": false, "error": str(response.get("error", "request failed"))}
	return {"ok": false, "error": "Groq HTTP %d: %s" % [code, _body_snippet(str(response.get("text", "")))]}


func _http_post_json(api_key: String, body: String) -> Dictionary:
	if api_key.is_empty():
		return {"code": 0, "error": "empty API key"}
	var http := HTTPClient.new()
	var connect_err := http.connect_to_host(GROQ_HOST, GROQ_PORT, TLSOptions.client())
	if connect_err != OK:
		http.close()
		return {"code": 0, "error": "connect_to_host failed: %s" % error_string(connect_err)}
	var deadline := Time.get_ticks_msec() + CONNECT_TIMEOUT_MS
	var first_poll := true
	var connected := false
	var last_status := -1
	while Time.get_ticks_msec() < deadline:
		if not _active:
			http.close()
			return {"code": 0, "error": "aborted (plugin teardown)"}
		http.poll()
		var status := http.get_status()
		last_status = status
		if status == HTTPClient.STATUS_CONNECTED:
			connected = true
			break
		if status == HTTPClient.STATUS_DISCONNECTED and not first_poll:
			break
		first_poll = false
		OS.delay_msec(50)
	if not connected:
		http.close()
		return {"code": 0, "error": "could not connect (status %d)" % last_status}
	var headers := PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key,
	])
	if http.request(HTTPClient.METHOD_POST, GROQ_PATH, headers, body) != OK:
		http.close()
		return {"code": 0, "error": "request() failed"}
	deadline = Time.get_ticks_msec() + REQUEST_TIMEOUT_MS
	var timed_out := false
	var status_at_timeout := -1
	while http.get_status() == HTTPClient.STATUS_REQUESTING:
		if not _active:
			http.close()
			return {"code": 0, "error": "aborted (plugin teardown)"}
		http.poll()
		if Time.get_ticks_msec() > deadline:
			timed_out = true
			status_at_timeout = http.get_status()
			break
		OS.delay_msec(50)
	if timed_out:
		http.close()
		return {"code": 0, "error": "request timed out (status %d)" % status_at_timeout}
	if not http.has_response():
		var st := http.get_status()
		http.close()
		return {"code": 0, "error": "no HTTP response (status %d)" % st}
	var code := http.get_response_code()
	var chunks := PackedByteArray()
	var body_deadline := Time.get_ticks_msec() + REQUEST_TIMEOUT_MS
	while http.get_status() == HTTPClient.STATUS_BODY:
		chunks.append_array(http.read_response_body_chunk())
		http.poll()
		if Time.get_ticks_msec() > body_deadline:
			break
		OS.delay_msec(10)
	http.close()
	return {"code": code, "text": chunks.get_string_from_utf8()}


func _body_snippet(text: String) -> String:
	if text.is_empty():
		return "(empty body)"
	if text.length() > 300:
		return text.substr(0, 300) + "..."
	return text


func _join_thread(rid: String) -> void:
	## Join the worker before dropping the Thread reference, otherwise Godot
	## warns "Thread object destroyed without completion".
	var thread: Thread = _threads.get(rid)
	if thread != null and thread.is_started():
		thread.wait_to_finish()
	_threads.erase(rid)


func _downscale_image_if_needed(image_b64: String) -> String:
	if image_b64.is_empty():
		return image_b64
	var raw := Marshalls.base64_to_raw(image_b64)
	if raw.is_empty():
		return image_b64
	var image := Image.new()
	if image.load_png_from_buffer(raw) != OK:
		return image_b64
	var width := image.get_width()
	var height := image.get_height()
	if width <= MAX_IMAGE_EDGE and height <= MAX_IMAGE_EDGE:
		return image_b64
	if width >= height:
		height = maxi(1, int(round(height * MAX_IMAGE_EDGE / float(width))))
		width = MAX_IMAGE_EDGE
	else:
		width = maxi(1, int(round(width * MAX_IMAGE_EDGE / float(height))))
		height = MAX_IMAGE_EDGE
	image.resize(width, height, Image.INTERPOLATE_BILINEAR)
	var out := image.save_png_to_buffer()
	if out.is_empty():
		return image_b64
	return Marshalls.raw_to_base64(out)


func _groq_ping_worker(api_key: String, status_label: Label) -> void:
	var result := _groq_ping_blocking(api_key)
	Callable(self, "_on_ping_done").call_deferred(result, status_label)


func _on_ping_done(result: Dictionary, status_label: Label) -> void:
	_join_thread("_test")
	if status_label != null and is_instance_valid(status_label):
		status_label.text = "OK - Groq responded." if result.get("ok", false) else "FAILED - %s" % result.get("error", "unknown error")
		_log("vision routing: ping result: %s" % status_label.text)


# --- settings / key storage ---------------------------------------------------

func _settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()


func is_routing_enabled() -> bool:
	var es := _settings()
	if es == null:
		return false
	var value = es.get_setting(SETTING_ENABLED)
	return value != null and value


func _resolved_api_key() -> String:
	## Environment variable takes priority over the stored (encrypted) key.
	var env_key := OS.get_environment("GROQ_API_KEY")
	if not env_key.is_empty():
		return env_key
	var es := _settings()
	if es == null:
		return ""
	var blob := str(es.get_setting(SETTING_API_KEY_ENC))
	if blob.is_empty():
		return ""
	return _decrypt(blob)


func _decrypted_key() -> String:
	var es := _settings()
	if es == null:
		return ""
	return _decrypt(str(es.get_setting(SETTING_API_KEY_ENC)))


func set_api_key(plain: String) -> void:
	var es := _settings()
	if es == null:
		return
	if plain.is_empty():
		es.set_setting(SETTING_API_KEY_ENC, "")
		return
	es.set_setting(SETTING_API_KEY_ENC, _encrypt(plain))


## Machine-derived key: not a password, but enough that a casually-opened
## editor_settings-4.tres does not reveal the key in plain text.
func _derive_key() -> PackedByteArray:
	var parts := PackedStringArray([
		OS.get_unique_id(),
		OS.get_environment("USERNAME"),
		OS.get_environment("USERPROFILE"),
		OS.get_name(),
		_SALT,
	])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("|".join(parts)).to_utf8_buffer())
	return ctx.finish()


func _encrypt(plain: String) -> String:
	var key := _derive_key()
	var iv := Crypto.new().generate_random_bytes(16)
	var raw := plain.to_utf8_buffer()
	## PKCS7 padding.
	var pad := 16 - (raw.size() % 16)
	var padded := raw.duplicate()
	for i in pad:
		padded.append(pad)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, key, iv)
	var cipher := aes.update(padded)
	aes.finish()
	var hmac := HMACContext.new()
	hmac.start(HashingContext.HASH_SHA256, key)
	hmac.update(cipher)
	var mac := hmac.finish()
	return "%s:%s:%s:%s" % [_ENC_PREFIX, Marshalls.raw_to_base64(iv), Marshalls.raw_to_base64(mac), Marshalls.raw_to_base64(cipher)]


func _decrypt(blob: String) -> String:
	var parts := blob.split(":")
	if parts.size() != 4 or parts[0] != _ENC_PREFIX:
		return ""
	var iv := Marshalls.base64_to_raw(parts[1])
	var mac := Marshalls.base64_to_raw(parts[2])
	var cipher := Marshalls.base64_to_raw(parts[3])
	if iv.size() != 16 or cipher.is_empty() or cipher.size() % 16 != 0:
		return ""
	var key := _derive_key()
	var hmac := HMACContext.new()
	hmac.start(HashingContext.HASH_SHA256, key)
	hmac.update(cipher)
	var expected := hmac.finish()
	if expected != mac:
		return ""
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, key, iv)
	var padded := aes.update(cipher)
	aes.finish()
	if padded.is_empty():
		return ""
	var pad := int(padded[padded.size() - 1])
	if pad < 1 or pad > 16 or pad > padded.size():
		return ""
	var raw := padded.slice(0, padded.size() - pad)
	return raw.get_string_from_utf8()


# --- UI: tab in Clients & Tools -------------------------------------------------

## Builds the "Vision Routing" tab. Called by mcp_dock._build_ui right after
## the Settings tab is built, so it appears directly after Settings.
func build_tab(tabs: TabContainer) -> void:
	var margin := MarginContainer.new()
	margin.name = TAB_NAME
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		margin.add_theme_constant_override(side, 12)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)
	tabs.add_child(margin)

	var header := Label.new()
	header.text = "Vision Routing"
	header.add_theme_font_size_override("font_size", 18)
	box.add_child(header)

	var enable_row := HBoxContainer.new()
	var enable_label := Label.new()
	enable_label.text = "Enable routing"
	enable_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enable_row.add_child(enable_label)
	_tab_enable = CheckButton.new()
	_tab_enable.button_pressed = is_routing_enabled()
	_tab_enable.toggled.connect(_on_enable_toggled)
	enable_row.add_child(_tab_enable)
	box.add_child(enable_row)

	var description := Label.new()
	description.text = (
		"When enabled, every screenshot the AI model takes through the godot-ai "
		+ "screenshot tool is sent to Groq's free vision model (qwen/"
		+ "qwen3.6-27b) for a text description. The description "
		+ "is returned to the AI instead of the raw image, so models without image "
		+ "support (e.g. DeepSeek) can still \"see\" the editor and game. When the "
		+ "connected model analyzes images itself, switch this off (or use the quick "
		+ "toggle under Developer mode in the Godot AI dock) so screenshots pass "
		+ "through unchanged."
	)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(description)

	var key_label := Label.new()
	key_label.text = "Groq API key (free tier: console.groq.com)"
	box.add_child(key_label)

	var key_row := HBoxContainer.new()
	_tab_key_edit = LineEdit.new()
	_tab_key_edit.placeholder_text = "gsk_..."
	_tab_key_edit.secret = true
	_tab_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_key_edit.text_changed.connect(_on_key_text_changed)
	key_row.add_child(_tab_key_edit)
	var show_button := CheckButton.new()
	show_button.tooltip_text = "Show / hide key"
	show_button.toggled.connect(func(show: bool) -> void: _tab_key_edit.secret = not show)
	key_row.add_child(show_button)
	box.add_child(key_row)
	_key_loading = true
	_tab_key_edit.text = _decrypted_key()
	_key_loading = false

	var key_hint := Label.new()
	key_hint.text = (
		"Stored encrypted (AES-256, key derived from this machine) in Editor Settings "
		+ "- not plain text, but local obfuscation only. You can also set the "
		+ "GROQ_API_KEY environment variable; it takes priority over this field."
	)
	key_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	key_hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	box.add_child(key_hint)

	var test_row := HBoxContainer.new()
	var test_button := Button.new()
	test_button.text = "Test connection"
	test_button.pressed.connect(_on_test_connection)
	test_row.add_child(test_button)
	_tab_status = Label.new()
	_tab_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_status.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	test_row.add_child(_tab_status)
	box.add_child(test_row)


func _on_key_text_changed(_new_text: String) -> void:
	if _key_loading:
		return
	set_api_key(_tab_key_edit.text)


func _on_test_connection() -> void:
	if _tab_status == null:
		return
	var api_key := _resolved_api_key()
	if api_key.is_empty():
		_tab_status.text = "No key set - add one below or set GROQ_API_KEY."
		return
	_tab_status.text = "Testing..."
	var thread := Thread.new()
	_threads["_test"] = thread
	thread.start(_groq_ping_worker.bind(api_key, _tab_status))


# --- UI: quick toggle in the dock ----------------------------------------------

## Builds the "Vision Routing" quick toggle. Called by mcp_dock._build_ui
## right after the Developer mode row, so it sits directly under it.
func build_toggle_row(body: VBoxContainer) -> void:
	var row := HBoxContainer.new()
	row.name = ROW_NAME
	var label := Label.new()
	label.text = "Vision Routing"
	label.tooltip_text = "Route screenshot-tool images through Groq's free vision API (see the Vision Routing tab in Clients & Tools)."
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(label)
	_row_toggle = CheckButton.new()
	_row_toggle.button_pressed = is_routing_enabled()
	_row_toggle.toggled.connect(_on_enable_toggled)
	row.add_child(_row_toggle)
	body.add_child(row)


func _on_enable_toggled(enabled: bool) -> void:
	var es := _settings()
	if es != null:
		es.set_setting(SETTING_ENABLED, enabled)
	_sync_ui_states()


func _sync_ui_states() -> void:
	var enabled := is_routing_enabled()
	if _tab_enable != null and is_instance_valid(_tab_enable) and _tab_enable.button_pressed != enabled:
		_tab_enable.button_pressed = enabled
	if _row_toggle != null and is_instance_valid(_row_toggle) and _row_toggle.button_pressed != enabled:
		_row_toggle.button_pressed = enabled


# --- logging --------------------------------------------------------------------

func _log(message: String) -> void:
	if log_buffer != null and is_instance_valid(log_buffer) and log_buffer.has_method("log"):
		log_buffer.log(message, false)