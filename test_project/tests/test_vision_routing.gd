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
	}
	router._on_route_complete(rid, "A rusty spider robot on a platform.")
	assert_eq(stub.replies.size(), 1)
	var data: Dictionary = stub.replies[0]["payload"]["data"]
	assert_eq(data["vision_description"], "A rusty spider robot on a platform.")
	assert_eq(data["routed_via"], "groq:" + VisionRoutingScript.MODEL_ID)
	assert_true(str(data["note"]).contains("Vision description (groq:" + VisionRoutingScript.MODEL_ID + "): A rusty spider robot on a platform."))
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
	}
	router._on_route_complete(rid, {"desc": "", "error": "Groq HTTP 401: bad key"})
	assert_eq(stub.replies.size(), 1)
	var data: Dictionary = stub.replies[0]["payload"]["data"]
	assert_eq(data["image_base64"], "AAAA")


func test_route_complete_keeps_existing_note() -> void:
	var router := _make_router()
	var stub := StubConnection.new()
	var rid := "test-rid-3"
	router._pending[rid] = {
		"payload": {"data": {"source": "game", "image_base64": "AAAA"}},
		"data": {"source": "game", "image_base64": "AAAA", "format": "png", "note": "stale frame"},
		"connection": stub,
	}
	router._on_route_complete(rid, "A game window showing the main menu.")
	assert_eq(stub.replies.size(), 1)
	var data: Dictionary = stub.replies[0]["payload"]["data"]
	var note := str(data["note"])
	assert_true(note.contains("stale frame"))
	assert_true(note.contains("A game window showing the main menu."))

func test_route_complete_reports_active_provider_in_routed_via() -> void:
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var router := _make_router()
		var stub := StubConnection.new()
		var rid := "test-rid-%s" % provider_id
		router._pending[rid] = {
			"payload": {"data": {"source": "viewport", "image_base64": "AAAA"}},
			"data": {"source": "viewport", "width": 100, "height": 100, "image_base64": "AAAA", "format": "png"},
			"connection": stub,
			"provider": provider_id,
		}
		router._on_route_complete(rid, {"desc": "A rusty spider robot on a platform.", "error": ""})
		assert_eq(stub.replies.size(), 1)
		var data: Dictionary = stub.replies[0]["payload"]["data"]
		var model := str(VisionRoutingScript.PROVIDERS[provider_id]["model"])
		assert_eq(str(data["routed_via"]), "%s:%s" % [provider_id, model])


# ----- providers -----

func test_provider_table_is_curated() -> void:
	assert_eq(VisionRoutingScript.PROVIDER_ORDER, ["groq", "google", "grok"])
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var provider: Dictionary = VisionRoutingScript.PROVIDERS[provider_id]
		assert_true(str(provider.get("model", "")).length() > 0)
		assert_true(str(provider.get("host", "")).length() > 0)
		assert_true(str(provider.get("path", "")).length() > 0)
		assert_true(str(provider.get("env", "")).length() > 0)
		assert_true(str(provider.get("setting", "")).begins_with("vision_routing/"))
		assert_true(str(provider.get("dialect", "")) in ["openai", "gemini"])


func test_aes_and_mac_keys_are_distinct() -> void:
	var router := _make_router()
	assert_ne(router._derive_key("aes"), router._derive_key("mac"))


func test_provider_models_are_distinct_and_fixed() -> void:
	var models := {}
	for provider_id in VisionRoutingScript.PROVIDER_ORDER:
		var model := str(VisionRoutingScript.PROVIDERS[provider_id]["model"])
		assert_false(models.has(model), "duplicate model %s across providers" % model)
		models[model] = true
	assert_eq(VisionRoutingScript.PROVIDERS["groq"]["model"], VisionRoutingScript.MODEL_ID)


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
		var provider: Dictionary = VisionRoutingScript.PROVIDERS[provider_id]
		var body: Dictionary = JSON.parse_string(router._build_request_body(provider, "describe it", "B64DATA"))
		assert_eq(body["model"], provider["model"])
		var content: Array = body["messages"][0]["content"]
		assert_eq(content[1]["image_url"]["url"], "data:image/png;base64,B64DATA")


func test_gemini_body_builder_uses_inline_data() -> void:
	var router := _make_router()
	var provider: Dictionary = VisionRoutingScript.PROVIDERS["google"]
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
