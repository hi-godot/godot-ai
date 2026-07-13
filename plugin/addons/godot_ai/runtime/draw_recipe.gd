@tool
extends Control

## Runtime helper attached by control_draw_recipe.
## Reads an array of op dicts from node metadata under key "_ops" and dispatches
## each to a CanvasItem draw call in _draw(). The ops list is set by the handler
## via set_meta; this script is deterministic — re-setting meta + queue_redraw
## is enough to update the visuals.

const META_KEY := "_ops"


func _ready() -> void:
	queue_redraw()


func _draw() -> void:
	if not has_meta(META_KEY):
		return
	var ops: Variant = get_meta(META_KEY)
	if typeof(ops) != TYPE_ARRAY:
		return
	for op in ops:
		if typeof(op) != TYPE_DICTIONARY:
			continue
		match op.get("draw", ""):
			"line":
				draw_line(
					op.from,
					op.to,
					op.color,
					float(op.get("width", 1.0)),
					bool(op.get("antialiased", false))
				)
			"rect":
				# Godot warns if `width` is passed when `filled` is true —
				# width has no effect on filled rects. Split the call so we
				# only pass width when stroking an outline.
				var filled := bool(op.get("filled", true))
				if filled:
					draw_rect(op.rect, op.color, true)
				else:
					draw_rect(
						op.rect,
						op.color,
						false,
						float(op.get("width", 1.0))
					)
			"arc":
				draw_arc(
					op.center,
					float(op.radius),
					float(op.start_angle),
					float(op.end_angle),
					int(op.get("point_count", 32)),
					op.color,
					float(op.get("width", 1.0)),
					bool(op.get("antialiased", false))
				)
			"circle":
				draw_circle(op.center, float(op.radius), op.color)
			"polyline":
				draw_polyline(
					op.points,
					op.color,
					float(op.get("width", 1.0)),
					bool(op.get("antialiased", false))
				)
			"polygon":
				var colors: PackedColorArray = (
					op.colors if op.has("colors") else PackedColorArray([op.color])
				)
				draw_polygon(op.points, colors)
			"string":
				var font: Font = get_theme_default_font()
				if font == null:
					continue
				draw_string(
					font,
					op.position,
					str(op.text),
					int(op.get("align", HORIZONTAL_ALIGNMENT_LEFT)),
					float(op.get("max_width", -1.0)),
					int(op.get("font_size", 16)),
					op.color
				)
