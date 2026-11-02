@tool
extends McpTestSuite

const EditorHandler := preload("res://addons/godot_ai/handlers/editor_handler.gd")
const OUTPUT_DIR := "res://tests/_capture_output"
var _handler: EditorHandler


class FailedPreviewHandler extends EditorHandler:
	func _finalize_image(_image: Image, _source: String, _max_resolution: int, _use_hdr_2d := false, _max_png_bytes: int = McpScreenshotEncode.MAX_PNG_BYTES) -> Dictionary:
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Injected preview failure")


func suite_name() -> String:
	return "capture_output"


func suite_setup(ctx: Dictionary) -> void:
	_handler = EditorHandler.new(ctx.get("log_buffer"))


func teardown() -> void:
	var dir := DirAccess.open(OUTPUT_DIR)
	if dir != null:
		for name in dir.get_files():
			DirAccess.remove_absolute(OUTPUT_DIR.path_join(name))
		for name in dir.get_directories():
			DirAccess.remove_absolute(OUTPUT_DIR.path_join(name))
		DirAccess.remove_absolute(OUTPUT_DIR)


func _params(path: String = "capture.png", include_image: bool = false) -> Dictionary:
	return {"source": "cinematic", "save_to": OUTPUT_DIR.path_join(path), "include_image": include_image}


func _image() -> Image:
	var image := Image.create(128, 64, false, Image.FORMAT_RGB8)
	image.fill(Color.RED)
	image.set_pixel(10, 20, Color.BLUE)
	return image


func test_cinematic_dimensions_require_a_bounded_integer_pair() -> void:
	assert_true(EditorHandler._screenshot_output_error({"source": "cinematic"}).is_empty())
	assert_true(EditorHandler._screenshot_output_error({"source": "cinematic", "width": 1920.0, "height": 1080.0}).is_empty())
	assert_true(EditorHandler._screenshot_output_error({"source": "cinematic", "width": 4096, "height": 4096}).is_empty())
	assert_is_error(EditorHandler._screenshot_output_error({"source": "cinematic", "width": 100}), McpErrorCodes.MISSING_REQUIRED_PARAM)
	for value in [0, -1, 4097, 1.5, INF, NAN, true, "1920", null]:
		assert_has_key(EditorHandler._screenshot_output_error({"source": "cinematic", "width": value, "height": 100}), "error")
	assert_is_error(EditorHandler._screenshot_output_error({"source": "viewport", "width": 100, "height": 100}), McpErrorCodes.VALUE_OUT_OF_RANGE)


func test_capture_paths_use_existing_write_guards() -> void:
	for path in ["/tmp/capture.png", "user://capture.png", "res://../capture.png", "res://.godot/capture.png", "res://project.godot", OUTPUT_DIR.path_join("capture.txt")]:
		var result := _handler._finalize_cinematic_image(_image(), 32, {"source": "cinematic", "save_to": path, "include_image": false})
		assert_is_error(result, McpErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(EditorHandler._screenshot_output_error({"source": "game", "save_to": "res://capture.png"}), McpErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(EditorHandler._screenshot_output_error({"source": "cinematic", "overwrite": true}), McpErrorCodes.VALUE_OUT_OF_RANGE)


func test_saved_png_keeps_full_pixels_while_inline_preview_downscales() -> void:
	var params := _params("full.png", true)
	var result := _handler._finalize_cinematic_image(_image(), 32, params)
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	var saved := Image.load_from_file(params.save_to)
	assert_eq(saved.get_size(), Vector2i(128, 64))
	assert_eq(saved.get_pixel(10, 20), Color.BLUE)
	assert_eq(saved.get_pixel(0, 0), Color.RED)
	var preview := Image.new()
	assert_eq(preview.load_png_from_buffer(Marshalls.base64_to_raw(result.data.image_base64)), OK)
	assert_eq(preview.get_size(), Vector2i(32, 16))
	assert_eq(result.data.saved_path, params.save_to)
	assert_eq(result.data.saved_width, 128)
	assert_eq(result.data.saved_height, 64)
	assert_eq(result.data.saved_bytes, FileAccess.get_file_as_bytes(params.save_to).size())
	assert_eq(result.data.original_width, 128)
	assert_eq(result.data.width, 32)
	assert_false(result.data.undoable)


func test_metadata_only_large_png_never_enters_response() -> void:
	var bytes := PackedByteArray()
	bytes.resize(1024 * 1024 * 3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1170
	for i in bytes.size():
		bytes[i] = rng.randi() & 255
	var image := Image.create_from_data(1024, 1024, false, Image.FORMAT_RGB8, bytes)
	var result := _handler._finalize_cinematic_image(image, 32, _params())
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_false(result.data.has("image_base64"))
	assert_gt(result.data.saved_bytes, 1024 * 1024)
	assert_true(JSON.stringify(result).length() < 1024, "full PNG must stay on disk, not cross the transport")
	var saved := Image.load_from_file(result.data.saved_path)
	assert_eq(saved.get_size(), Vector2i(1024, 1024))
	assert_eq(saved.get_data(), bytes)
	assert_eq(result.data.width, 1024)
	assert_eq(result.data.height, 1024)


func test_existing_png_requires_explicit_overwrite() -> void:
	var params := _params()
	assert_has_key(_handler._finalize_cinematic_image(_image(), 32, params), "data")
	var original := FileAccess.get_file_as_bytes(params.save_to)
	var replacement := _image()
	replacement.fill(Color.GREEN)
	assert_is_error(_handler._finalize_cinematic_image(replacement, 32, params), McpErrorCodes.INVALID_PARAMS)
	assert_eq(FileAccess.get_file_as_bytes(params.save_to), original)
	params.overwrite = true
	assert_has_key(_handler._finalize_cinematic_image(replacement, 32, params), "data")
	assert_eq(Image.load_from_file(params.save_to).get_pixel(0, 0), Color.GREEN)


func test_failed_publish_preserves_staged_png_for_recovery() -> void:
	var params := _params()
	assert_eq(DirAccess.make_dir_recursive_absolute(params.save_to), OK)
	var result := _handler._finalize_cinematic_image(_image(), 32, params)
	assert_is_error(result, McpErrorCodes.INTERNAL_ERROR)
	assert_true(DirAccess.dir_exists_absolute(params.save_to))
	assert_false(result.error.data.disk_committed)
	assert_false(result.error.data.restore_failed)
	var staged := Image.new()
	assert_eq(staged.load_png_from_buffer(FileAccess.get_file_as_bytes(result.error.data.staged_resource)), OK)
	assert_eq(staged.get_pixel(10, 20), Color.BLUE)


func test_preview_failure_still_reports_successfully_saved_file() -> void:
	var handler := FailedPreviewHandler.new(null)
	var params := _params("preview_failure.png", true)
	var result := handler._finalize_cinematic_image(_image(), 32, params)
	assert_has_key(result, "data")
	if not result.has("data"):
		return
	assert_eq(result.data.saved_path, params.save_to)
	assert_eq(result.data.saved_width, 128)
	assert_eq(result.data.width, 128)
	assert_eq(result.data.preview_error.message, "Injected preview failure")
	assert_false(result.data.has("image_base64"))
	assert_eq(Image.load_from_file(params.save_to).get_pixel(10, 20), Color.BLUE)


func test_explicit_render_size_and_file_output() -> void:
	if DisplayServer.get_name() == "headless":
		skip("Actual cinematic rendering requires the graphical Windows/CI qualification")
		return
	var params := _params()
	params.width = 320
	params.height = 180
	params.max_resolution = 64
	var result := _handler.take_screenshot(params)
	assert_has_key(result, "data", str(result))
	if not result.has("data"):
		return
	assert_eq(result.data.width, 320)
	assert_eq(result.data.height, 180)
	assert_eq(Image.load_from_file(params.save_to).get_size(), Vector2i(320, 180))
	assert_false(result.data.has("image_base64"))
	params.overwrite = true
	params.include_image = true
	var inline := _handler.take_screenshot(params)
	assert_eq(inline.data.saved_width, 320)
	assert_eq(inline.data.width, 64)
	assert_eq(inline.data.height, 36)
