@tool
extends McpTestSuite

const ScreenshotEncode := preload("res://addons/godot_ai/utils/screenshot_encode.gd")

func suite_name() -> String:
	return "screenshot_encode"

func test_sdr_retains_gray_at_native_and_reduced_sizes() -> void:
	_check_gray(false)

func test_hdr_retains_gray_at_native_and_reduced_sizes() -> void:
	_check_gray(true)

func _check_gray(hdr: bool) -> void:
	var linear := hdr and RenderingServer.get_current_rendering_method() != "gl_compatibility"
	for limit in [0, 16]:
		var image := Image.create(64, 32, false, Image.FORMAT_RGBAF if hdr else Image.FORMAT_RGBA8)
		image.fill(Color(0.214041 if linear else 0.5, 0.214041 if linear else 0.5, 0.214041 if linear else 0.5, 1.0))
		var result := ScreenshotEncode.downscale_and_encode(image, limit, hdr)
		var decoded := Image.new()
		assert_eq(decoded.load_png_from_buffer(Marshalls.base64_to_raw(result.base64)), OK)
		assert_eq(result.original_width, 64)
		assert_eq(result.original_height, 32)
		assert_eq(decoded.get_width(), 16 if limit else 64)
		assert_eq(decoded.get_height(), 8 if limit else 32)
		var pixel := decoded.get_pixel(0, 0)
		for channel in [pixel.r, pixel.g, pixel.b]:
			assert_true(absi(roundi(channel * 255.0) - 127) <= 1, "PNG keeps display gray")
		assert_eq(pixel.a, 1.0)

func _noisy_image() -> Image:
	var bytes := PackedByteArray()
	bytes.resize(1024 * 1024 * 3)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1170
	for i in bytes.size():
		bytes[i] = rng.randi() & 255
	return Image.create_from_data(1024, 1024, false, Image.FORMAT_RGB8, bytes)

func test_noisy_png_fits_single_and_coverage_budgets() -> void:
	var original := _noisy_image()
	assert_true(original.save_png_to_buffer().size() > 1024 * 1024, "fixture exceeds client event limit before base64")
	for image_count in [1, 2]:
		var image := original.duplicate()
		var budget: int = ScreenshotEncode.MAX_PNG_BYTES / image_count
		var result := ScreenshotEncode.downscale_and_encode(image, 0, false, budget)
		var png := Marshalls.base64_to_raw(result.base64)
		var decoded := Image.new()
		assert_eq(decoded.load_png_from_buffer(png), OK)
		assert_true(png.size() <= budget, "encoded noisy image fits its share of response")
		assert_eq(result.original_width, 1024)
		assert_eq(result.original_height, 1024)
		assert_true(result.width < 1024 and result.width > 1, "large PNG downscales even without requested cap")
		assert_eq(decoded.get_width(), result.width)
		assert_eq(decoded.get_height(), result.height)
		assert_eq(result.width, result.height, "preserve aspect ratio")
		assert_true(decoded.get_pixel(0, 0) != decoded.get_pixel(10, 10), "preserve image content")

func test_impossible_png_budget_stops_at_one_pixel() -> void:
	var image := Image.create(8, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color.RED)
	var result := ScreenshotEncode.downscale_and_encode(image, 0, false, 1)
	assert_eq(result.width, 1)
	assert_eq(result.height, 1)
	assert_eq(result.original_width, 8)
	assert_eq(result.original_height, 4)
	var decoded := Image.new()
	assert_eq(decoded.load_png_from_buffer(Marshalls.base64_to_raw(result.base64)), OK)
	assert_eq(decoded.get_pixel(0, 0), Color.RED)

func test_small_png_keeps_original_bytes_and_dimensions() -> void:
	var image := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.25, 0.5, 0.75, 0.5))
	var original := image.save_png_to_buffer()
	var result := ScreenshotEncode.downscale_and_encode(image, 0)
	assert_eq(Marshalls.base64_to_raw(result.base64), original)
	assert_eq(result.width, 64)
	assert_eq(result.height, 32)
