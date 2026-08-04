@tool
extends RefCounted

## Vision Routing - route screenshot-tool images through a curated vision API.
##
## Models without image support (e.g. DeepSeek) cannot read the image blocks the
## screenshot tool returns. When routing is enabled, every single-image capture is sent to a
## vision model on a worker thread and the resulting text description is
## returned to the AI instead:
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
## Providers are curated: label, API dialect, endpoint shape, environment
## variable and encrypted key slot are fixed in the PROVIDERS table. The model
## id is NOT - it is required per provider and entered by the user (stored in
## Editor Settings next to the key), because third-party model ids retire and
## only the account holder gets notified. Switching providers switches to that
## provider's entered model, so the software never guesses a model name:
##   - Groq          (free tier)                - OpenAI chat-completions
##   - Google Gemini (free tier, AI Studio key) - generateContent REST
##   - xAI Grok      (paid)                     - OpenAI chat-completions
## Both dialects are handled in this file.
##
## Settings live in Editor Settings (`vision_routing/enabled`,
## `vision_routing/provider`, plus one encrypted key slot and one model-id
## slot per provider). Keys are stored encrypted (AES-256-CBC, key derived
## from this machine) rather than in plain text, and each provider's
## environment variable (GROQ_API_KEY / GOOGLE_API_KEY / XAI_API_KEY) takes
## priority over the stored key.
##
## UI: a "Vision Routing" section inside the Clients & Tools Settings tab.

## Curated providers: label, dialect, endpoint shape, env var and key/model
## setting slots are fixed here. The model id itself is user-entered per
## provider (see `_resolved_model`), so provider rows carry a `model_setting`
## slot and a `model_placeholder` suggestion instead of a baked-in id -
## third-party model ids retire, and only the account holder gets notified
## when one does.
const PROVIDERS := {
	"groq": {
		"label": "Groq",
		"dialect": "openai",
		"model_setting": "vision_routing/groq_model",
		"model_placeholder": "qwen/qwen3.6-27b",
		"host": "api.groq.com",
		"port": 443,
		"path": "/openai/v1/chat/completions",
		"env": "GROQ_API_KEY",
		"setting": "vision_routing/api_key_enc",
		"placeholder": "gsk_...",
		"key_label": "Groq API key (free tier: console.groq.com)",
		"reasoning_effort": "none",
	},
	"google": {
		"label": "Google Gemini",
		"dialect": "gemini",
		"host": "generativelanguage.googleapis.com",
		"port": 443,
		"path": "/v1beta/models/{model}:generateContent",
		"model_setting": "vision_routing/google_model",
		"model_placeholder": "gemini-flash-latest",
		"env": "GOOGLE_API_KEY",
		"setting": "vision_routing/google_api_key_enc",
		"placeholder": "AIza...",
		"key_label": "Google AI Studio API key (free tier: aistudio.google.com)",
	},
	"grok": {
		"label": "xAI Grok",
		"dialect": "openai",
		"model_setting": "vision_routing/grok_model",
		"model_placeholder": "grok-4.5",
		"host": "api.x.ai",
		"port": 443,
		"path": "/v1/chat/completions",
		"env": "XAI_API_KEY",
		"setting": "vision_routing/grok_api_key_enc",
		"placeholder": "xai-...",
		"key_label": "xAI API key (api.x.ai)",
	},
}
const PROVIDER_ORDER := ["groq", "google", "grok"]

const SETTING_ENABLED := "vision_routing/enabled"
const SETTING_PROVIDER := "vision_routing/provider"
const SETTING_API_KEY_ENC := "vision_routing/api_key_enc"
const TAB_NAME := "Vision Routing"

const MAX_IMAGE_EDGE := 1024
const CONNECT_TIMEOUT_MS := 4000
const REQUEST_TIMEOUT_MS := 8000
## Total budget for the whole provider exchange (connect + request + body).
## Kept under the server's 15s editor_screenshot window so the fallback
## pass-through always lands before the server gives up on slow providers.
const TOTAL_ROUTE_BUDGET_MS := 10000
## Response body cap: the deadline bounds time but not bytes, and the socket
## talks to third-party hosts - a faulty or hostile provider must not be able
## to stream an unbounded body inside the window.
const MAX_RESPONSE_BODY_BYTES := 1048576

const _ENC_PREFIX := "v1"
const _SALT := "vision_routing::v1::godot-ai"
const _PLACEHOLDER_PNG := "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAALSURBVBhXY2BABwAAEgABp3qZbgAAAABJRU5ErkJggg=="

## Plugin log buffer (McpLogBuffer), set by plugin.gd; null-safe.
var log_buffer: Object = null

var _active := true
var _route_done: Callable
var _pending: Dictionary = {}   # request_id -> {payload, data, connection, provider_id, provider, params}
var _threads: Dictionary = {}   # request_id -> Thread ("_test" = ping thread)
var _ui_loading := false

# UI references, kept in sync by _sync_ui_states().
var _tab_provider: OptionButton = null
var _tab_enable: CheckButton = null
var _tab_key_label: Label = null
var _tab_key_hint: Label = null
var _tab_key_edit: LineEdit = null
var _tab_model_label: Label = null
var _tab_model_hint: Label = null
var _tab_model_edit: LineEdit = null
var _tab_status: Label = null
var _tab_test_button: Button = null


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
		if thread != null and thread.is_started():
			thread.wait_to_finish()
	_threads.clear()
	_pending.clear()
	_tab_provider = null
	_tab_enable = null
	_tab_key_label = null
	_tab_key_hint = null
	_tab_key_edit = null
	_tab_status = null
	_tab_test_button = null
	_tab_model_label = null
	_tab_model_hint = null
	_tab_model_edit = null


# --- routing ------------------------------------------------------------------

## Entry point called from editor_handler.take_screenshot when routing is
## enabled. Runs the real capture (via `original`), then routes the image
## through the selected provider's vision API on a worker thread. Returns the deferred-response sentinel
## when the worker owns the reply, otherwise the capture result unchanged.
func route_editor_screenshot(params: Dictionary, original: Callable, connection: Object) -> Dictionary:
	var rid := str(params.get("_request_id", ""))
	if rid.is_empty():
		## No deferred channel (e.g. batch_execute / dispatch_direct) - keep
		## the original synchronous result untouched.
		return original.call(params)
	var result := original.call(params)
	if not (result is Dictionary) or not result.has("data"):
		## Deferred capture (source="game"): the frame arrives later through
		## route_game_payload. Stash the caller params (e.g. user_prompt) by
		## request id so the routed description keeps the agent's context.
		if result is Dictionary and result.get("_deferred", false):
			_pending[rid] = {"params": params}
		return result
	var data: Variant = result["data"]
	if not (data is Dictionary) or not data.has("image_base64"):
		return result
	if _start_route(rid, str(params.get("source", "viewport")), result, data, connection, params):
		## Keep the deferred ledger inside the server's 15s editor_screenshot
		## window (the worker itself is capped at TOTAL_ROUTE_BUDGET_MS), so
		## a hung provider surfaces as a clean plugin timeout, not a
		## server-side abort.
		return {"_deferred": true, "_deferred_timeout_ms": 13000}
	return result


## Entry point called from McpDebuggerPlugin._on_screenshot_response before
## the frame is sent. Returns true when a worker owns the reply (the caller
## must NOT send the payload itself); false means pass through unchanged.
func route_game_payload(connection: Object, rid: String, payload: Dictionary) -> bool:
	var data: Variant = payload.get("data")
	if not (data is Dictionary) or not data.has("image_base64"):
		## Not a routeable frame - drop any params stashed by
		## route_editor_screenshot for this request id.
		_pending.erase(rid)
		return false
	## The editor handler stashed the caller params (user_prompt etc.) by
	## request id when it deferred the capture; hand them to the prompt
	## builder. Absent (older helper, direct call) = generic prompt.
	var params: Dictionary = _pending.get(rid, {}).get("params", {})
	return _start_route(rid, "game", payload, data, connection, params)


## Returns true when a worker owns the reply; false means the caller should
## pass the original payload through unchanged.
func _start_route(rid: String, source: String, payload: Dictionary, data: Dictionary, connection: Object, params: Dictionary) -> bool:
	var provider_id := _active_provider_id()
	var base_provider: Dictionary = PROVIDERS.get(provider_id, PROVIDERS["groq"])
	## Worker-thread snapshot: the entered model id is resolved into the
	## provider dict here, once, so the thread sees a stable copy and
	## routed_via can report the exact model that was pinged.
	var provider := _provider_with_model(provider_id)
	var api_key := _resolved_api_key(provider_id)
	if api_key.is_empty():
		_log("vision routing: no API key for %s (set %s or paste one in the Vision Routing section) - screenshot %s passed through" % [provider_id, base_provider.get("env", ""), rid])
		_pending.erase(rid)
		return false
	if str(provider.get("model", "")).is_empty():
		## Empty model behaves exactly like empty key: routing declines, the
		## image passes through, and the log line says what is missing.
		_log("vision routing: no model id set for %s - screenshot %s passed through (set a model id in the Vision Routing section)" % [provider_id, rid])
		_pending.erase(rid)
		return false
	_pending[rid] = {"payload": payload, "data": data, "connection": connection, "provider_id": provider_id, "provider": provider, "params": params}
	var prompt := _build_prompt(params)
	var thread := Thread.new()
	var start_err := thread.start(_route_worker.bind(provider, str(data.get("image_base64", "")), prompt, api_key, rid))
	if start_err != OK:
		_pending.erase(rid)
		_log("vision routing: could not start worker for %s: %s - screenshot %s passed through" % [rid, error_string(start_err), source])
		return false
	_threads[rid] = thread
	_log("vision routing: routing %s screenshot %s (%d b64 chars) via %s (%s)" % [source, rid, str(data.get("image_base64", "")).length(), base_provider.get("label", provider_id), provider.get("model", "")])
	return true


func _on_route_complete(rid: String, result: Variant) -> void:
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
	var provider_id := str(entry.get("provider_id", "groq"))
	## Provider snapshot taken at route start (with the entered model id);
	## falls back to a fresh resolve if absent (direct test callers).
	var provider: Dictionary = entry.get("provider", {})
	if provider.is_empty():
		provider = _provider_with_model(provider_id)
	## Workers return {"desc": ..., "error": ...}; plain strings are accepted
	## for backwards compatibility (tests / older callers).
	var description_str := ""
	var error_str := ""
	if result is Dictionary:
		description_str = str(result.get("desc", ""))
		error_str = str(result.get("error", ""))
	elif result != null:
		description_str = str(result)
	if description_str.is_empty():
		if error_str.is_empty():
			error_str = "unknown error"
		_log("vision routing: %s failed for %s (%s) - returning original image with failure note" % [provider_id, rid, error_str])
		## Append a short templated reason to the note so text-only agents
		## (who otherwise just receive a useless image block) learn the
		## feature is down and why.
		var failed_data: Dictionary = entry.get("data", {}).duplicate()
		var failure_note := "Vision routing unavailable (%s): %s" % [provider_id, error_str]
		var existing_note := str(failed_data.get("note", ""))
		failed_data["note"] = (existing_note + " | " if not existing_note.is_empty() else "") + failure_note
		_pass_through(connection, rid, {"data": failed_data})
		return
	var data: Dictionary = entry.get("data", {}).duplicate()
	var routed_via := "%s:%s" % [provider_id, provider.get("model", "")]
	## The server forwards a fixed whitelist of metadata keys into the text
	## result; `note` is the free-form one, so a self-attributing description
	## rides there (plus an explicit `vision_description` key) so text-only
	## models can read it. The label keeps provider text from reading as if
	## the plugin said it. The image is replaced by a valid 2x2 placeholder
	## so the payload stays well-formed.
	data["vision_description"] = description_str
	data["routed_via"] = routed_via
	var original_note := str(data.get("note", ""))
	var labeled := "Vision description (%s): %s" % [routed_via, description_str]
	data["note"] = (original_note + " | " if not original_note.is_empty() else "") + labeled
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
	var user_prompt := str(params.get("user_prompt", ""))
	if not user_prompt.is_empty():
		lines.append("Context from the agent that requested this screenshot: %s" % user_prompt)
	return "\n".join(lines)


# --- routing worker (thread) ---------------------------------------------------

func _route_worker(provider: Dictionary, image_b64: String, prompt: String, api_key: String, rid: String) -> void:
	var result := _describe_blocking(provider, image_b64, prompt, api_key)
	_route_done.call_deferred(rid, result)


## Returns {"desc": String, "error": String}; "desc" is empty on failure and
## "error" carries the reason. Runs on a worker thread, so it never writes
## shared state - everything it needs is passed in and returned. `provider`
## is the route-start snapshot (includes the entered model id).
func _describe_blocking(provider: Dictionary, image_b64: String, prompt: String, api_key: String) -> Dictionary:
	var b64 := _downscale_image_if_needed(image_b64)
	var body := _build_request_body(provider, prompt, b64)
	var headers := _build_headers(provider, api_key)
	var response := _http_post_json(str(provider.get("host", "")), int(provider.get("port", 443)), _resolve_path(provider), headers, body)
	return _parse_description(provider, response)


## Provider paths may carry a {model} placeholder (Gemini's endpoint embeds
## the model id); substitute the entered model id verbatim.
func _resolve_path(provider: Dictionary) -> String:
	return str(provider.get("path", "")).replace("{model}", str(provider.get("model", "")))


func _build_request_body(provider: Dictionary, prompt: String, image_b64: String) -> String:
	var model := str(provider.get("model", ""))
	if str(provider.get("dialect", "")) == "gemini":
		return JSON.stringify({
			"contents": [{
				"role": "user",
				"parts": [
					{"text": prompt},
					{"inline_data": {"mime_type": "image/png", "data": image_b64}},
				],
			}],
		})
	var payload := {
		"model": model,
		"messages": [{
			"role": "user",
			"content": [
				{"type": "text", "text": prompt},
				{"type": "image_url", "image_url": {"url": "data:image/png;base64," + image_b64}},
			],
		}],
		"max_tokens": 512,
		"temperature": 0.2,
	}
	if provider.has("reasoning_effort"):
		payload["reasoning_effort"] = provider["reasoning_effort"]
	return JSON.stringify(payload)


func _build_headers(provider: Dictionary, api_key: String) -> PackedStringArray:
	if str(provider.get("dialect", "")) == "gemini":
		return PackedStringArray([
			"Content-Type: application/json",
			"x-goog-api-key: %s" % api_key,
		])
	return PackedStringArray([
		"Content-Type: application/json",
		"Authorization: Bearer %s" % api_key,
	])


func _parse_description(provider: Dictionary, response: Dictionary) -> Dictionary:
	var code: int = int(response.get("code", 0))
	var label := str(provider.get("label", str(provider.get("model", "?"))))
	if code == 0:
		return {"desc": "", "error": str(response.get("error", "HTTP request failed"))}
	if code != 200:
		return {"desc": "", "error": "%s HTTP %d: %s" % [label, code, _body_snippet(str(response.get("text", "")))]}
	var parsed: Variant = JSON.parse_string(str(response.get("text", "")))
	if not (parsed is Dictionary):
		return {"desc": "", "error": "%s response was not JSON: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	if str(provider.get("dialect", "")) == "gemini":
		return _parse_gemini(parsed, label, response)
	return _parse_openai(parsed, label, response)


func _parse_openai(parsed: Dictionary, label: String, response: Dictionary) -> Dictionary:
	var choices: Variant = parsed.get("choices")
	if not (choices is Array) or choices.is_empty():
		return {"desc": "", "error": "%s response had no choices: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	if not (choices[0] is Dictionary):
		return {"desc": "", "error": "%s response choice was not an object: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	var message: Variant = choices[0].get("message", {})
	if not (message is Dictionary):
		return {"desc": "", "error": "%s response message was not an object: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	var content: Variant = message.get("content", "")
	if content == null:
		return {"desc": "", "error": "%s response content was null: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	return {"desc": _strip_think(str(content)), "error": ""}


func _parse_gemini(parsed: Dictionary, label: String, response: Dictionary) -> Dictionary:
	var candidates: Variant = parsed.get("candidates")
	if not (candidates is Array) or candidates.is_empty():
		var reason := ""
		var feedback: Variant = parsed.get("promptFeedback")
		if feedback is Dictionary:
			reason = str(feedback.get("blockReason", ""))
		var reason_part := ""
		if not reason.is_empty():
			reason_part = " (blocked: %s)" % reason
		return {"desc": "", "error": "%s response had no candidates%s: %s" % [label, reason_part, _body_snippet(str(response.get("text", "")))]}
	if not (candidates[0] is Dictionary):
		return {"desc": "", "error": "%s response candidate was not an object: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	var content: Variant = candidates[0].get("content", {})
	if not (content is Dictionary):
		return {"desc": "", "error": "%s response content was missing: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	var parts: Variant = content.get("parts")
	if not (parts is Array) or parts.is_empty():
		return {"desc": "", "error": "%s response had no parts: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	var texts := PackedStringArray()
	for part in parts:
		if part is Dictionary:
			var part_text := str(part.get("text", ""))
			if not part_text.is_empty():
				texts.append(part_text)
	if texts.is_empty():
		return {"desc": "", "error": "%s response parts had no text: %s" % [label, _body_snippet(str(response.get("text", "")))]}
	return {"desc": _strip_think("\n".join(texts)), "error": ""}


func _strip_think(text: String) -> String:
	var out := text.strip_edges()
	## Reasoning models may wrap their answer in <think>...</think> blocks.
	var think_end := out.rfind("</think>")
	if think_end != -1:
		out = out.substr(think_end + "</think>".length()).strip_edges()
	return out


## Minimal vision call used by the "Test connection" button. Sends the same
## image-bearing body shape as real routing (with the 2x2 placeholder PNG),
## so one click validates key + model existence + image capability - a
## text-only or retired model id fails loudly here instead of at screenshot
## time. `provider` is the route-style snapshot (includes the model id).
func _ping_blocking(provider: Dictionary, api_key: String) -> Dictionary:
	var body := _build_request_body(provider, "Reply with exactly: OK", _PLACEHOLDER_PNG)
	var response := _http_post_json(str(provider.get("host", "")), int(provider.get("port", 443)), _resolve_path(provider), _build_headers(provider, api_key), body)
	var code: int = int(response.get("code", 0))
	if code == 200:
		return {"ok": true, "error": ""}
	if code == 0:
		return {"ok": false, "error": str(response.get("error", "request failed"))}
	return {"ok": false, "error": "%s HTTP %d: %s" % [provider.get("label", "provider"), code, _body_snippet(str(response.get("text", "")))]}


func _http_post_json(host: String, port: int, path: String, headers: PackedStringArray, body: String) -> Dictionary:
	if host.is_empty() or body.is_empty():
		return {"code": 0, "error": "invalid request (empty host or body)"}
	var http := HTTPClient.new()
	var connect_err := http.connect_to_host(host, port, TLSOptions.client())
	if connect_err != OK:
		http.close()
		return {"code": 0, "error": "connect_to_host failed: %s" % error_string(connect_err)}
	## One total deadline for the whole exchange (see TOTAL_ROUTE_BUDGET_MS),
	## so connect + request + body can never exceed it.
	var budget_deadline := Time.get_ticks_msec() + TOTAL_ROUTE_BUDGET_MS
	var deadline := mini(Time.get_ticks_msec() + CONNECT_TIMEOUT_MS, budget_deadline)
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
	if http.request(HTTPClient.METHOD_POST, path, headers, body) != OK:
		http.close()
		return {"code": 0, "error": "request() failed"}
	deadline = mini(Time.get_ticks_msec() + REQUEST_TIMEOUT_MS, budget_deadline)
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
	var body_deadline := mini(Time.get_ticks_msec() + REQUEST_TIMEOUT_MS, budget_deadline)
	while http.get_status() == HTTPClient.STATUS_BODY:
		if not _active:
			http.close()
			return {"code": 0, "error": "aborted (plugin teardown)"}
		chunks.append_array(http.read_response_body_chunk())
		if chunks.size() > MAX_RESPONSE_BODY_BYTES:
			http.close()
			return {"code": 0, "error": "response body exceeded %d bytes" % MAX_RESPONSE_BODY_BYTES}
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


func _ping_worker(provider: Dictionary, api_key: String, status_label: Label, key_source: String) -> void:
	var result := _ping_blocking(provider, api_key)
	Callable(self, "_on_ping_done").call_deferred(result, provider, status_label, key_source)


func _on_ping_done(result: Dictionary, provider: Dictionary, status_label: Label, key_source: String) -> void:
	_join_thread("_test")
	if _tab_test_button != null and is_instance_valid(_tab_test_button):
		_tab_test_button.disabled = false
	if status_label != null and is_instance_valid(status_label):
		var label := str(provider.get("label", "provider"))
		if result.get("ok", false):
			status_label.text = "OK - %s responded (%s)." % [label, key_source]
		else:
			status_label.text = "FAILED - %s (%s)." % [result.get("error", "unknown error"), key_source]
		_log("vision routing: ping result: %s" % status_label.text)


# --- settings / key storage ---------------------------------------------------

func _settings() -> EditorSettings:
	return EditorInterface.get_editor_settings()


func is_routing_enabled() -> bool:
	var es := _settings()
	if es == null or not es.has_setting(SETTING_ENABLED):
		return false
	var value = es.get_setting(SETTING_ENABLED)
	return value != null and value


func _active_provider_id() -> String:
	var es := _settings()
	if es == null:
		return "groq"
	var stored := ""
	if es.has_setting(SETTING_PROVIDER):
		stored = str(es.get_setting(SETTING_PROVIDER))
	if stored.is_empty() or not PROVIDERS.has(stored):
		return "groq"
	return stored


func _provider_setting(provider_id: String) -> String:
	return str(PROVIDERS.get(provider_id, PROVIDERS["groq"]).get("setting", SETTING_API_KEY_ENC))


func _resolved_api_key(provider_id: String) -> String:
	## Environment variable takes priority over the stored (encrypted) key.
	var provider: Dictionary = PROVIDERS.get(provider_id, PROVIDERS["groq"])
	var env_key := OS.get_environment(str(provider.get("env", "")))
	if not env_key.is_empty():
		return env_key
	var es := _settings()
	if es == null:
		return ""
	var setting := _provider_setting(provider_id)
	var blob := ""
	if es.has_setting(setting):
		blob = str(es.get_setting(setting))
	if blob.is_empty():
		return ""
	return _decrypt(blob)


func _decrypted_key(provider_id: String) -> String:
	var es := _settings()
	if es == null:
		return ""
	var setting := _provider_setting(provider_id)
	if not es.has_setting(setting):
		return ""
	return _decrypt(str(es.get_setting(setting)))


func set_api_key(provider_id: String, plain: String) -> void:
	var es := _settings()
	if es == null:
		return
	if plain.is_empty():
		es.set_setting(_provider_setting(provider_id), "")
		return
	var blob := _encrypt(plain)
	if blob.is_empty():
		_log("vision routing: cannot store %s key - this machine reports no unique id; set %s instead" % [provider_id, PROVIDERS.get(provider_id, PROVIDERS["groq"]).get("env", "")])
		return
	es.set_setting(_provider_setting(provider_id), blob)


## The model id is stored per provider next to the key (a plain Editor
## Setting - it is not a secret). Empty clears the slot.
func set_model_id(provider_id: String, model: String) -> void:
	var es := _settings()
	if es == null:
		return
	es.set_setting(_model_setting(provider_id), model.strip_edges())


func _model_setting(provider_id: String) -> String:
	return str(PROVIDERS.get(provider_id, PROVIDERS["groq"]).get("model_setting", ""))


func _resolved_model(provider_id: String) -> String:
	var es := _settings()
	if es == null:
		return ""
	var setting := _model_setting(provider_id)
	if not es.has_setting(setting):
		return ""
	return str(es.get_setting(setting)).strip_edges()


## Route-start snapshot: the curated provider table plus the user's entered
## model id. Used by the worker thread and by _on_route_complete for the
## routed_via label, so it always reports the model that was actually pinged.
func _provider_with_model(provider_id: String) -> Dictionary:
	var provider: Dictionary = PROVIDERS.get(provider_id, PROVIDERS["groq"]).duplicate()
	provider["model"] = _resolved_model(provider_id)
	return provider


## Machine-derived key: not a password, but enough that a casually-opened
## editor_settings-4.tres does not reveal the key in plain text. Separate
## domain tags give AES and HMAC independent keys so neither reuses the
## other's bytes.
func _derive_key(tag: String) -> PackedByteArray:
	var parts := PackedStringArray([
		OS.get_unique_id(),
		OS.get_environment("USERNAME"),
		OS.get_environment("USERPROFILE"),
		OS.get_environment("USER"),
		OS.get_environment("HOME"),
		OS.get_name(),
		_SALT,
		tag,
	])
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(("|".join(parts)).to_utf8_buffer())
	return ctx.finish()


func _encrypt(plain: String) -> String:
	if OS.get_unique_id().is_empty():
		## Without a machine id the key would be near-constant across users
		## on the same machine - refuse, and let callers fall back to the
		## provider's environment variable.
		return ""
	var aes_key := _derive_key("aes")
	var mac_key := _derive_key("mac")
	var iv := Crypto.new().generate_random_bytes(16)
	var raw := plain.to_utf8_buffer()
	## PKCS7 padding.
	var pad := 16 - (raw.size() % 16)
	var padded := raw.duplicate()
	for i in pad:
		padded.append(pad)
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_ENCRYPT, aes_key, iv)
	var cipher := aes.update(padded)
	aes.finish()
	var hmac := HMACContext.new()
	hmac.start(HashingContext.HASH_SHA256, mac_key)
	hmac.update(iv)
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
	var aes_key := _derive_key("aes")
	var mac_key := _derive_key("mac")
	var hmac := HMACContext.new()
	hmac.start(HashingContext.HASH_SHA256, mac_key)
	hmac.update(iv)
	hmac.update(cipher)
	var expected := hmac.finish()
	if expected != mac:
		return ""
	var aes := AESContext.new()
	aes.start(AESContext.MODE_CBC_DECRYPT, aes_key, iv)
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

## Builds the "Vision Routing" section inside the Clients & Tools Settings
## tab. Called by mcp_dock._build_settings_tab; `refresh_ui()` re-syncs the
## controls from Editor Settings each time the window opens.
func build_section(parent: VBoxContainer) -> void:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	parent.add_child(box)

	var header := Label.new()
	header.text = "Vision Routing"
	header.add_theme_font_size_override("font_size", 18)
	box.add_child(header)

	var provider_row := HBoxContainer.new()
	var provider_label := Label.new()
	provider_label.text = "Provider"
	provider_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	provider_row.add_child(provider_label)
	_tab_provider = OptionButton.new()
	_tab_provider.tooltip_text = "Which vision provider routes the screenshots. The model id is required per provider and is yours to maintain."
	var active_provider := _active_provider_id()
	for provider_index in PROVIDER_ORDER.size():
		var provider_item: Dictionary = PROVIDERS[PROVIDER_ORDER[provider_index]]
		_tab_provider.add_item(str(provider_item.get("label", PROVIDER_ORDER[provider_index])), provider_index)
		if PROVIDER_ORDER[provider_index] == active_provider:
			_tab_provider.select(provider_index)
	_tab_provider.item_selected.connect(_on_provider_changed)
	provider_row.add_child(_tab_provider)
	box.add_child(provider_row)

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
		"When enabled, every single-image screenshot the AI model takes through "
		+ "the godot-ai screenshot tool is sent to the selected provider's vision model (see "
		+ "the Provider dropdown) for a text description. The description is "
		+ "returned to the AI instead of the raw image, so models without image "
		+ "support (e.g. DeepSeek) can still \"see\" the editor and game. When "
		+ "the connected model analyzes images itself, switch this off here so "
		+ "screenshots pass through unchanged."
	)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	description.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(description)

	_tab_key_label = Label.new()
	box.add_child(_tab_key_label)

	var key_row := HBoxContainer.new()
	_tab_key_edit = LineEdit.new()
	_tab_key_edit.secret = true
	_tab_key_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	## Persist on commit (Enter / focus loss) instead of per keystroke, so
	## pasting a key does not re-encrypt and rewrite Editor Settings dozens
	## of times.
	_tab_key_edit.text_submitted.connect(_on_key_committed)
	_tab_key_edit.focus_exited.connect(func() -> void: _on_key_committed(_tab_key_edit.text))
	key_row.add_child(_tab_key_edit)
	var show_button := CheckButton.new()
	show_button.tooltip_text = "Show / hide key"
	show_button.toggled.connect(func(show: bool) -> void: _tab_key_edit.secret = not show)
	key_row.add_child(show_button)
	box.add_child(key_row)

	_tab_key_hint = Label.new()
	_tab_key_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tab_key_hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	box.add_child(_tab_key_hint)

	_tab_model_label = Label.new()
	box.add_child(_tab_model_label)

	var model_row := HBoxContainer.new()
	_tab_model_edit = LineEdit.new()
	_tab_model_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	## Persist on commit (Enter / focus loss), same pattern as the key field.
	_tab_model_edit.text_submitted.connect(_on_model_committed)
	_tab_model_edit.focus_exited.connect(func() -> void: _on_model_committed(_tab_model_edit.text))
	model_row.add_child(_tab_model_edit)
	box.add_child(model_row)

	_tab_model_hint = Label.new()
	_tab_model_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tab_model_hint.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	box.add_child(_tab_model_hint)

	var test_row := HBoxContainer.new()
	var test_button := Button.new()
	test_button.text = "Test connection"
	test_button.pressed.connect(_on_test_connection)
	_tab_test_button = test_button
	test_row.add_child(test_button)
	_tab_status = Label.new()
	_tab_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_status.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
	test_row.add_child(_tab_status)
	box.add_child(test_row)

	refresh_ui()


## Re-syncs every control from Editor Settings. Called after the section is
## built and again by mcp_dock each time the Clients & Tools window opens,
## so a change made in another editor instance (or a hand-edit of
## editor_settings-4.tres) is reflected.
func refresh_ui() -> void:
	_sync_ui_states()
	_sync_provider_ui()
	_ui_loading = true
	if _tab_key_edit != null and is_instance_valid(_tab_key_edit):
		_tab_key_edit.text = _decrypted_key(_active_provider_id())
	if _tab_model_edit != null and is_instance_valid(_tab_model_edit):
		_tab_model_edit.text = _resolved_model(_active_provider_id())
	_ui_loading = false


func _on_key_committed(_new_text: String) -> void:
	if _ui_loading:
		return
	set_api_key(_active_provider_id(), _tab_key_edit.text)


func _on_model_committed(_new_text: String) -> void:
	if _ui_loading:
		return
	set_model_id(_active_provider_id(), _tab_model_edit.text)


func _on_provider_changed(index: int) -> void:
	if index < 0 or index >= PROVIDER_ORDER.size():
		return
	var provider_id: String = PROVIDER_ORDER[index]
	var es := _settings()
	if es != null:
		es.set_setting(SETTING_PROVIDER, provider_id)
	_ui_loading = true
	if _tab_key_edit != null and is_instance_valid(_tab_key_edit):
		_tab_key_edit.text = _decrypted_key(provider_id)
	if _tab_model_edit != null and is_instance_valid(_tab_model_edit):
		_tab_model_edit.text = _resolved_model(provider_id)
	_ui_loading = false
	_sync_provider_ui()
	_log("vision routing: provider changed to %s (%s)" % [provider_id, PROVIDERS[provider_id].get("label", provider_id)])


func _sync_provider_ui() -> void:
	var provider_id := _active_provider_id()
	var provider: Dictionary = PROVIDERS.get(provider_id, PROVIDERS["groq"])
	if _tab_provider != null and is_instance_valid(_tab_provider):
		var provider_index := PROVIDER_ORDER.find(provider_id)
		if provider_index != -1 and _tab_provider.selected != provider_index:
			_tab_provider.select(provider_index)
	if _tab_key_label != null and is_instance_valid(_tab_key_label):
		_tab_key_label.text = str(provider.get("key_label", "API key"))
	if _tab_key_hint != null and is_instance_valid(_tab_key_hint):
		var hint := (
			"Stored encrypted (AES-256, key derived from this machine) in Editor Settings "
			+ "- not plain text, but local obfuscation only. You can also set the "
			+ "%s environment variable; it takes priority over this field."
		) % provider.get("env", "")
		if OS.get_unique_id().is_empty():
			hint += " This machine reports no unique id, so keys cannot be stored locally - use the %s environment variable." % provider.get("env", "")
		_tab_key_hint.text = hint
	if _tab_key_edit != null and is_instance_valid(_tab_key_edit):
		_tab_key_edit.placeholder_text = str(provider.get("placeholder", ""))
	if _tab_model_label != null and is_instance_valid(_tab_model_label):
		_tab_model_label.text = "Model id (required) - %s" % provider.get("label", provider_id)
	if _tab_model_edit != null and is_instance_valid(_tab_model_edit):
		_tab_model_edit.placeholder_text = str(provider.get("model_placeholder", ""))
		_tab_model_edit.tooltip_text = "The vision model this provider should ping. Yours to maintain: when a model id retires, replace it here."
	if _tab_model_hint != null and is_instance_valid(_tab_model_hint):
		_tab_model_hint.text = (
			"Required per provider; empty behaves like an empty key (routing "
			+ "declines and screenshots pass through). Suggested id (as of "
			+ "2026-08 - check your provider console, ids retire): %s."
		) % provider.get("model_placeholder", "")


func _on_test_connection() -> void:
	if _tab_status == null:
		return
	var provider_id := _active_provider_id()
	var provider := _provider_with_model(provider_id)
	var env_name := str(PROVIDERS.get(provider_id, PROVIDERS["groq"]).get("env", ""))
	if str(provider.get("model", "")).is_empty():
		_tab_status.text = "No model id set for %s - add one below." % provider.get("label", provider_id)
		return
	var api_key := _resolved_api_key(provider_id)
	if api_key.is_empty():
		_tab_status.text = "No key set - add one below or set %s." % env_name
		return
	var running: Thread = _threads.get("_test")
	if running != null and running.is_started() and running.is_alive():
		return
	var previous_status := _tab_status.text
	_tab_status.text = "Testing..."
	if _tab_test_button != null and is_instance_valid(_tab_test_button):
		_tab_test_button.disabled = true
	var key_source := "stored key"
	if not OS.get_environment(env_name).is_empty():
		key_source = "via %s" % env_name
	var thread := Thread.new()
	_threads["_test"] = thread
	var start_err := thread.start(_ping_worker.bind(provider, api_key, _tab_status, key_source))
	if start_err != OK:
		## A failed thread start must not leave the button disabled and the
		## status stuck on "Testing..." forever.
		_threads.erase("_test")
		_tab_status.text = previous_status
		if _tab_test_button != null and is_instance_valid(_tab_test_button):
			_tab_test_button.disabled = false
		_log("vision routing: could not start ping thread: %s" % error_string(start_err))


func _on_enable_toggled(enabled: bool) -> void:
	var es := _settings()
	if es != null:
		es.set_setting(SETTING_ENABLED, enabled)
	_sync_ui_states()


func _sync_ui_states() -> void:
	var enabled := is_routing_enabled()
	if _tab_enable != null and is_instance_valid(_tab_enable) and _tab_enable.button_pressed != enabled:
		_tab_enable.set_pressed_no_signal(enabled)


# --- logging --------------------------------------------------------------------

func _log(message: String) -> void:
	if log_buffer != null and is_instance_valid(log_buffer) and log_buffer.has_method("log"):
		log_buffer.log(message, false)
