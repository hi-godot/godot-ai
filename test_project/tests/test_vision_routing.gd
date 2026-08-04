@tool
extends McpTestSuite

## Tests for Vision Routing (vision_routing.gd): the encrypted key storage,
## prompt building, and the deferred-reply conversion that replaces the raw
## screenshot with a text description for text-only models. The Groq HTTP
## worker itself is live-verified in the editor (see docs/vision-routing.md).

const VisionRoutingScript := preload("res://addons/godot_ai/vision_routing.gd")


func suite_name() -> String:
	return "vision_routing"


## Stub connection capturing deferred replies instead of sending them.
class StubConnection:
	extends RefCounted
	var replies: Array = []

	func send_deferred_response(request_id: String, payload: Dictionary) -> void:
		replies.append({"request_id": request_id, "payload": payload})


func _make_router() -> VisionRoutingScript:
	var router := VisionRoutingScript.new()
	router.log_buffer = null
	return router


# ----- key storage -----

func test_key_encrypt_decrypt_roundtrip() -> void:
	var router := _make_router()
	var plain := "gsk_test_secret_key_123"
	var blob := router._encrypt(plain)
	assert_ne(blob, "")
	assert_eq(router._decrypt(blob), plain)


func test_key_encrypted_blob_hides_plaintext() -> void:
	var router := _make_router()
	var plain := "gsk_super_secret_value"
	var blob := router._encrypt(plain)
	assert_ne(blob, plain)
	assert_true(blob.begins_with("v1:"))
	assert_false(blob.contains("super_secret"))


func test_decrypt_rejects_tampered_blob() -> void:
	var router := _make_router()
	var parts := router._encrypt("gsk_test_secret_key_123").split(":")
	assert_eq(parts.size(), 4)
	## Flip one byte of the ciphertext so the MAC check must fail.
	var tampered := Marshalls.base64_to_raw(parts[3])
	var mid := tampered.size() / 2
	tampered[mid] = tampered[mid] ^ 0xFF
	parts[3] = Marshalls.raw_to_base64(tampered)
	assert_eq(router._decrypt(":".join(parts)), "")


func test_decrypt_rejects_tampered_iv() -> void:
	var router := _make_router()
	var parts := router._encrypt("gsk_test_secret_key_123").split(":")
	## Flip one byte of the IV: it is inside the MAC, so decryption must fail
	## instead of silently decrypting to a different plaintext.
	var iv := Marshalls.base64_to_raw(parts[1])
	iv[0] = iv[0] ^ 0xFF
	parts[1] = Marshalls.raw_to_base64(iv)
	assert_eq(router._decrypt(":".join(parts)), "")


# ----- prompt -----

func test_build_prompt_includes_user_context() -> void:
	var router := _make_router()
	var prompt := router._build_prompt({"user_prompt": "Why is the spider red?"})
	assert_true(prompt.contains("Why is the spider red?"))
	assert_true(prompt.contains("Godot editor"))


# ----- deferred reply conversion -----

func test_route_complete_injects_description_and_placeholder() -> void:
	var router := _make_router()
	var stub := StubConnection.new()
	var rid := "test-rid-1"
	router._pending[rid] = {
		"payload": {"data": {"source": "viewport", "image_base64": "AAAA"}},
		"data": {"source": "viewport", "width": 100, "height": 100, "image_base64": "AAAA", "format": "png"},
		"connection": stub,
		"provider_id": "groq",
		"provider": {"label": "Groq", "model": "qwen/qwen3.6-27b"},
	}
	router._on_route_complete(rid, "A rusty spider robot on a platform.")
	assert_eq(stub.replies.size(), 1)
	var data: Dictionary = stub.replies[0]["payload"]["data"]
	assert_eq(data["vision_description"], "A rusty spider robot on a platform.")
	assert_eq(data["routed_via"], "groq:qwen/qwen3.6-27b")
	assert_true(str(data["note"]).contains("Vision description (groq:qwen/qwen3.6-27b): A rusty spider robot on a platform."))
	## The original image is replaced by the 2x2 placeholder PNG.
	assert_eq(data["image_base64"], VisionRoutingScript._PLACEHOLDER_PNG)
	assert_eq(data["format"], "png")


func test_route_complete_failure_passes_original_through() -> void:
	var router := _make_router()
	var stub := StubConnection.new()
	var rid := "test-rid-2"
	router._pending[rid] = {
		"payload": {"data": {"source": "viewport", "image_base64": "AAAA"}},
		"data": {"source": "viewport", "image_base64": "AAAA", "format": "png"},
		"connection": stub,
		"provider_id": "groq",
		"provider": {"label": "Groq", "model": "qwen/qwen3.6-27b"},
	}
	router._on_route_complete(rid, {"desc": "", "error": "Groq HTTP 401: bad key"})
	assert_eq(stub.replies.size(), 1)
	var data: Dictionary = stub.replies[0]["payload"]["data"]
	assert_eq(data["image_base64"], "AAAA")
	## A text-only agent gets a short templated reason instead of a bare image.
	assert_true(str(data["note"]).contains("Vision routing unavailable (groq): Groq HTTP 401: bad key"))


func test_route_complete_keeps_existing_note() -> void:
	var router := _make_router()
	var stub := StubConnection.new()
	var rid := "test-rid-3"
	router._pending[rid] = {
		"payload": {"data": {"source": "game", "image_base64": "AAAA"}},
		"data": {"source": "game", "image_base64": "AAAA", "format": "png", "note": "stale frame"},
		"connection": stub,
		"provider_id": "groq",
		"provider": {"label": "Groq", "model": "qwen/qwen3.6-27b"},
	}
	router._on_route_complete(rid, "A game window showing the main menu.")
	assert_eq(stub.replies.size(), 1)
	var data: Dictionary = stub.replies[0]["payload"]["data"]
	var note := str(data["note"])
	assert_true(note.contains("stale frame"))
	assert_true(note.contains("A game window showing the main menu."))

func test_route_complete_reports_active_provider_in_routed_via() -> void:
	var models := {
		"groq": "qwen/qwen3.6-27b",
		"google": "gemini-flash-latest",
		"grok": "grok-4.5",
	}
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var router := _make_router()
		var stub := StubConnection.new()
		var rid := "test-rid-%s" % provider_id
		router._pending[rid] = {
			"payload": {"data": {"source": "viewport", "image_base64": "AAAA"}},
			"data": {"source": "viewport", "width": 100, "height": 100, "image_base64": "AAAA", "format": "png"},
			"connection": stub,
			"provider_id": provider_id,
			"provider": {"label": provider_id, "model": models[provider_id]},
		}
		router._on_route_complete(rid, {"desc": "A rusty spider robot on a platform.", "error": ""})
		assert_eq(stub.replies.size(), 1)
		var data: Dictionary = stub.replies[0]["payload"]["data"]
		assert_eq(str(data["routed_via"]), "%s:%s" % [provider_id, models[provider_id]])


# ----- providers -----

func test_provider_table_is_curated() -> void:
	assert_eq(VisionRoutingScript.PROVIDER_ORDER, ["groq", "google", "grok"])
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var provider: Dictionary = VisionRoutingScript.PROVIDERS[provider_id]
		## Model ids are NOT baked into the table - they are user-entered per
		## provider. The table only curates label, dialect, endpoint, env var
		## and the key/model setting slots.
		assert_false(provider.has("model"))
		assert_true(str(provider.get("model_setting", "")).begins_with("vision_routing/"))
		assert_true(str(provider.get("model_placeholder", "")).length() > 0)
		assert_true(str(provider.get("host", "")).length() > 0)
		assert_true(str(provider.get("path", "")).length() > 0)
		assert_true(str(provider.get("env", "")).length() > 0)
		assert_true(str(provider.get("setting", "")).begins_with("vision_routing/"))
		assert_true(str(provider.get("dialect", "")) in ["openai", "gemini"])


func test_aes_and_mac_keys_are_distinct() -> void:
	var router := _make_router()
	assert_ne(router._derive_key("aes"), router._derive_key("mac"))


func test_provider_model_round_trip_via_settings() -> void:
	var router := _make_router()
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorInterface.get_editor_settings() unavailable in test env")
		return
	## Save/restore so the test never leaves junk in the user's Editor
	## Settings (same pattern as test_allow_hosts.gd).
	var had := {}
	var saved := {}
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var setting := router._model_setting(provider_id)
		had[provider_id] = es.has_setting(setting)
		saved[provider_id] = es.get_setting(setting) if had[provider_id] else ""
	router.set_model_id("groq", "qwen/qwen3.6-27b")
	assert_eq(router._resolved_model("groq"), "qwen/qwen3.6-27b")
	router.set_model_id("google", "gemini-flash-latest")
	assert_eq(router._resolved_model("google"), "gemini-flash-latest")
	assert_eq(router._resolved_model("grok"), "")
	## _provider_with_model snapshots the entered id into the worker dict.
	var snapshot := router._provider_with_model("google")
	assert_eq(snapshot["model"], "gemini-flash-latest")
	assert_false(VisionRoutingScript.PROVIDERS["google"].has("model"))
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var setting := router._model_setting(provider_id)
		if had[provider_id]:
			es.set_setting(setting, saved[provider_id])
		elif es.has_setting(setting):
			es.erase(setting)


func test_provider_key_slots_are_distinct() -> void:
	var router := _make_router()
	var slots := {}
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var setting := router._provider_setting(provider_id)
		assert_false(slots.has(setting), "duplicate key slot %s" % setting)
		slots[setting] = true


func test_openai_body_builder_sends_image_data_url() -> void:
	var router := _make_router()
	for provider_id in ["groq", "grok"]:
		var provider: Dictionary = VisionRoutingScript.PROVIDERS[provider_id].duplicate()
		provider["model"] = "test-model"
		var body: Dictionary = JSON.parse_string(router._build_request_body(provider, "describe it", "B64DATA"))
		assert_eq(body["model"], "test-model")
		var content: Array = body["messages"][0]["content"]
		assert_eq(content[1]["image_url"]["url"], "data:image/png;base64,B64DATA")


func test_gemini_body_builder_uses_inline_data() -> void:
	var router := _make_router()
	var provider: Dictionary = VisionRoutingScript.PROVIDERS["google"].duplicate()
	provider["model"] = "gemini-test"
	var body: Dictionary = JSON.parse_string(router._build_request_body(provider, "describe it", "B64DATA"))
	assert_false(body.has("messages"))
	var parts: Array = body["contents"][0]["parts"]
	var inline: Dictionary = parts[1]["inline_data"]
	assert_eq(inline["mime_type"], "image/png")
	assert_eq(inline["data"], "B64DATA")


func test_gemini_response_parser_extracts_text() -> void:
	var router := _make_router()
	var provider: Dictionary = VisionRoutingScript.PROVIDERS["google"]
	var response := {
		"code": 200,
		"text": JSON.stringify({"candidates": [{"content": {"parts": [{"text": "A goldfish in a bowl."}]}}]}),
	}
	assert_eq(router._parse_description(provider, response)["desc"], "A goldfish in a bowl.")


func test_gemini_response_parser_rejects_empty_candidates() -> void:
	var router := _make_router()
	var provider: Dictionary = VisionRoutingScript.PROVIDERS["google"]
	var response := {
		"code": 200,
		"text": JSON.stringify({"candidates": [], "promptFeedback": {"blockReason": "SAFETY"}}),
	}
	var failed := router._parse_description(provider, response)
	assert_eq(failed["desc"], "")
	assert_true(str(failed["error"]).contains("SAFETY"))


func test_openai_parser_strips_think_blocks() -> void:
	var router := _make_router()
	var provider: Dictionary = VisionRoutingScript.PROVIDERS["groq"]
	var response := {
		"code": 200,
		"text": JSON.stringify({"choices": [{"message": {"content": "<think>hmm</think>\nThe scene shows a red door."}}]}),
	}
	assert_eq(router._parse_description(provider, response)["desc"], "The scene shows a red door.")
# ----- round-3 regressions -----

func test_resolve_path_substitutes_model_placeholder() -> void:
	var router := _make_router()
	var provider: Dictionary = VisionRoutingScript.PROVIDERS["google"].duplicate()
	provider["model"] = "gemini-flash-latest"
	assert_eq(router._resolve_path(provider), "/v1beta/models/gemini-flash-latest:generateContent")
	## Openai-dialect paths carry no placeholder and pass through unchanged.
	var groq_provider: Dictionary = VisionRoutingScript.PROVIDERS["groq"].duplicate()
	groq_provider["model"] = "qwen/qwen3.6-27b"
	assert_eq(router._resolve_path(groq_provider), "/openai/v1/chat/completions")


func test_ping_body_shape_matches_routing() -> void:
	## The Test connection button must validate vision, not just auth: the
	## ping body carries the placeholder image exactly like a real route.
	var router := _make_router()
	var provider: Dictionary = VisionRoutingScript.PROVIDERS["groq"].duplicate()
	provider["model"] = "qwen/qwen3.6-27b"
	var body: Dictionary = JSON.parse_string(router._build_request_body(provider, "Reply with exactly: OK", VisionRoutingScript._PLACEHOLDER_PNG))
	assert_eq(body["model"], "qwen/qwen3.6-27b")
	var content: Array = body["messages"][0]["content"]
	assert_eq(content[0]["text"], "Reply with exactly: OK")
	assert_true(str(content[1]["image_url"]["url"]).begins_with("data:image/png;base64,"))


func test_empty_model_declines_route_like_empty_key() -> void:
	var router := _make_router()
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("EditorInterface.get_editor_settings() unavailable in test env")
		return
	## Save/restore the groq key + model slots so the test never leaves junk
	## behind. The model slot is forced empty; the key slot is set so the
	## decline is provably caused by the missing model, not the missing key.
	var model_setting := router._model_setting("groq")
	var had_model := es.has_setting(model_setting)
	var saved_model: String = es.get_setting(model_setting) if had_model else ""
	var key_setting := router._provider_setting("groq")
	var had_key := es.has_setting(key_setting)
	var saved_key: String = es.get_setting(key_setting) if had_key else ""
	router.set_model_id("groq", "")
	es.set_setting(key_setting, router._encrypt("gsk_test_route_key"))
	var declined := not router._start_route(
		"test-rid-empty-model", "viewport",
		{"data": {"image_base64": "AAAA"}}, {"image_base64": "AAAA"},
		StubConnection.new(), {})
	if had_key:
		es.set_setting(key_setting, saved_key)
	elif es.has_setting(key_setting):
		es.erase(key_setting)
	if had_model:
		es.set_setting(model_setting, saved_model)
	elif es.has_setting(model_setting):
		es.erase(model_setting)
	assert_true(declined)
	assert_false(router._pending.has("test-rid-empty-model"))


func test_game_capture_stashes_and_forwards_user_prompt() -> void:
	## The editor handler stashes params by request id when it defers a game
	## capture; route_game_payload hands them to the prompt builder.
	var router := _make_router()
	var rid := "test-rid-game"
	router._pending[rid] = {"params": {"user_prompt": "Why is the spider red?", "source": "game"}}
	var params: Dictionary = router._pending.get(rid, {}).get("params", {})
	var prompt := router._build_prompt(params)
	assert_true(prompt.contains("Why is the spider red?"))


func test_route_game_payload_clears_stash_when_not_routeable() -> void:
	var router := _make_router()
	var rid := "test-rid-game-nodata"
	router._pending[rid] = {"params": {"user_prompt": "x"}}
	assert_false(router.route_game_payload(StubConnection.new(), rid, {"data": {"note": "no image"}}))
	assert_false(router._pending.has(rid))
