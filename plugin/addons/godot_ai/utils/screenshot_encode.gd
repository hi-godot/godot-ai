@tool
class_name McpScreenshotEncode
extends RefCounted

## Shared downscale + PNG + base64 block for the screenshot paths (#716).
##
## Two call sites straddle the editor/game process boundary — the editor's
## take_screenshot (editor_handler) and the game-process autoload
## (runtime/game_helper) — and were maintained as manually synchronized
## copies. Pure static, no editor APIs, so it loads safely in the game
## process too.


## Downscale `image` in place so its longest edge is at most
## `max_resolution` (0 = no cap), then PNG-encode. Returns
## {base64, width, height, original_width, original_height}.
static func downscale_and_encode(image: Image, max_resolution: int) -> Dictionary:
	var original_width := image.get_width()
	var original_height := image.get_height()

	if max_resolution > 0:
		var longest := maxi(original_width, original_height)
		if longest > max_resolution:
			var scale := float(max_resolution) / float(longest)
			## Clamp to 1px min: extreme aspect ratios at very small
			## max_resolution could otherwise compute a zero dimension and
			## crash image.resize().
			var new_w := maxi(1, int(original_width * scale))
			var new_h := maxi(1, int(original_height * scale))
			image.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)

	return {
		"base64": Marshalls.raw_to_base64(image.save_png_to_buffer()),
		"width": image.get_width(),
		"height": image.get_height(),
		"original_width": original_width,
		"original_height": original_height,
	}
