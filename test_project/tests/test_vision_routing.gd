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


# ----- prompt -----

func test_build_prompt_includes_user_context() -> void:
	var router := _make_router()
	var prompt := router._build_prompt({"_user_prompt": "Why is the spider red?"})
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
	assert_eq(data["routed_via"], VisionRoutingScript.MODEL_ID)
	assert_true(str(data["note"]).contains("A rusty spider robot on a platform."))
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
	router._error_notes[rid] = "Groq HTTP 401: bad key"
	router._on_route_complete(rid, "")
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