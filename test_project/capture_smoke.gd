@tool
extends Control

var _editor_viewport: SubViewport
var _previous_hdr := false

@export var capture_metadata: Dictionary:
	get:
		if not Engine.is_editor_hint() or not is_instance_valid(_editor_viewport):
			return {}
		var image := _editor_viewport.get_texture().get_image()
		if image == null or image.is_empty():
			return {"error": "Editor viewport has not rendered"}
		var gray: ColorRect = get_node("Gray")
		var sample := _editor_viewport.global_canvas_transform * gray.get_global_transform_with_canvas() * (gray.size / 2.0)
		if not Rect2(Vector2.ZERO, image.get_size()).has_point(sample):
			return {
				"error": "Gray patch is outside editor viewport", "sample": str(sample),
				"image_size": str(image.get_size()), "viewport_size": str(_editor_viewport.size),
			}
		return {
			"hdr": _editor_viewport.use_hdr_2d,
			"renderer": RenderingServer.get_current_rendering_method(),
			"format": image.get_format(),
			"raw_gray": image.get_pixel(int(sample.x), int(sample.y)).r,
			"sample_x": sample.x / image.get_width(),
			"sample_y": sample.y / image.get_height(),
		}

func _ready() -> void:
	if Engine.is_editor_hint():
		if not OS.has_environment("CAPTURE_HDR_2D"):
			return
		_editor_viewport = EditorInterface.get_editor_viewport_2d()
		_previous_hdr = _editor_viewport.use_hdr_2d
		_editor_viewport.use_hdr_2d = OS.get_environment("CAPTURE_HDR_2D") == "1"
		# Select after scene activation, which can overwrite a selection made in _ready.
		EditorInterface.set_main_screen_editor.call_deferred("2D")
		# Hosted editor viewports are smaller than the game's 1920x1080 layout.
		# Game smoke disables autosave, preserving the subprocess layout on disk.
		var gray: ColorRect = get_node("Gray")
		gray.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
		gray.position = Vector2(32, 32)
		gray.size = Vector2(192, 192)
	else:
		get_viewport().use_hdr_2d = OS.get_environment("CAPTURE_HDR_2D") == "1"

func _exit_tree() -> void:
	if is_instance_valid(_editor_viewport):
		_editor_viewport.use_hdr_2d = _previous_hdr
