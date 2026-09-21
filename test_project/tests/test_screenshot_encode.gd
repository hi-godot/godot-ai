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
