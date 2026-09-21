@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Handles Theme resource authoring: creating, modifying color/constant/font-size/
## stylebox slots, and applying a theme to a Control subtree.
##
## Themes are Godot's equivalent of USS: a Theme holds (class, name) -> value
## entries (colors, constants, fonts, font_sizes, styleboxes, icons) which
## cascade down a Control subtree when the theme is assigned at any ancestor.
## One well-authored theme replaces hundreds of per-node property sets.

const _COLOR_HINT := "expected hex #rrggbb, named color, or {r,g,b,a} dict"

## Theme constants/font sizes and StyleBoxFlat int properties are 32-bit in the
## engine; GDScript ints are 64-bit, so an unvalidated 4294967296 narrows to 0
## (and 2147483648 to -2147483648) at the property assignment.
const _INT32_MIN := -2147483648
const _INT32_MAX := 2147483647

## Native storage kinds for numeric theme destinations, so validation models
## what the engine actually keeps:
##   _NATIVE_INT32          C++ int32 (Theme constants/font sizes, shadow_size)
##   _NATIVE_FLOAT32        C++ real_t (margins, shadow offsets, Color components)
##   _NATIVE_INT32_FLOAT32  int accessors backed by real_t storage: StyleBoxFlat
##                          border widths and corner radii take ints but store
##                          real_t, so 16777217 rounds to 16777216 and
##                          2147483647 reads back as -2147483648
const _NATIVE_INT32 := 0
const _NATIVE_FLOAT32 := 1
const _NATIVE_INT32_FLOAT32 := 2

## Top-level keys of the StyleBoxFlat patch vocabulary shared by
## set_stylebox_flat and stylebox_override. Nested dicts validate their own
## keys inside _apply_flat_props; this guards the outer dict so a typo
## (`bg_colour`) cannot install an unchanged override plus an undo entry while
## reporting success.
const _FLAT_PATCH_KEYS := ["bg_color", "border_color", "border", "corners", "margins", "shadow", "anti_aliasing"]

var _undo_redo: EditorUndoRedoManager
var _connection: McpConnection


func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


# ============================================================================
# theme_create
# ============================================================================

func create_theme(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var overwrite: bool = params.get("overwrite", false)

	var err := _validate_res_path(path, ".tres", "path", true)
	if err != null:
		return err

	# Capture whether the file was already there BEFORE the save so we can
	# report `overwritten` accurately (after save the file always exists).
	var existed_before := FileAccess.file_exists(path)
	if existed_before and not overwrite:
		return ErrorCodes.make(
			ErrorCodes.INVALID_PARAMS,
			"Theme already exists at %s (pass overwrite=true to replace)" % path
		)

	# Ensure parent directory exists. make_dir_recursive is idempotent —
	# no need to check dir_exists first (avoids TOCTOU race).
	var dir_path := path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to create directory: %s (error %d)" % [dir_path, mkdir_err]
		)

	var theme := Theme.new()
	var save_err := McpResourceIO.guarded_save(theme, path, _connection)
	if save_err != OK:
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to save theme to %s: %s (error %d)" % [path, error_string(save_err), save_err]
		)

	# Make sure the editor's filesystem picks up the new file.
	var efs := EditorInterface.get_resource_filesystem()
	if efs != null:
		efs.update_file(path)

	return {
		"data": {
			"path": path,
			"overwritten": existed_before,
			"undoable": false,
			"reason": "File creation is persistent; delete the file manually to revert",
		}
	}


# ============================================================================
# theme_set_color / theme_set_constant / theme_set_font_size
# ============================================================================

func set_color(params: Dictionary) -> Dictionary:
	return _set_scalar(params, "color", func(theme, name, cls): return theme.get_color(name, cls),
		func(theme, name, cls, val): theme.set_color(name, cls, val),
		func(theme, name, cls): theme.clear_color(name, cls),
		func(theme, name, cls): return theme.has_color(name, cls),
		func(v): return _parse_color(v))


# constant / font_size parsers validate before coercing: int("abc")/int({})/int([])
# all return 0 in GDScript (never null), so a bare `int(v)` would silently store
# garbage as 0 and report success. Returning null for non-numeric input lets
# _set_scalar's null guard surface a VALUE_OUT_OF_RANGE error, matching the
# color path's contract.
func set_constant(params: Dictionary) -> Dictionary:
	return _set_scalar(params, "constant", func(theme, name, cls): return theme.get_constant(name, cls),
		func(theme, name, cls, val): theme.set_constant(name, cls, int(val)),
		func(theme, name, cls): theme.clear_constant(name, cls),
		func(theme, name, cls): return theme.has_constant(name, cls),
		func(v): return _parse_int32_value(v))


func set_font_size(params: Dictionary) -> Dictionary:
	return _set_scalar(params, "font_size", func(theme, name, cls): return theme.get_font_size(name, cls),
		func(theme, name, cls, val): theme.set_font_size(name, cls, int(val)),
		func(theme, name, cls): theme.clear_font_size(name, cls),
		func(theme, name, cls): return theme.has_font_size(name, cls),
		func(v): return _parse_int32_value(v))


## Theme constant/font_size slots are 32-bit ints. Accepts int/float and
## valid-int strings, but rejects non-finite or out-of-int32 values before the
## engine narrowing can wrap them (4294967296 -> 0, 2147483648 -> -2147483648).
## In-range fractional values keep the existing truncation policy.
static func _parse_int32_value(v: Variant) -> Variant:
	var number: float
	if v is int or v is float:
		number = float(v)
	elif v is String and v.is_valid_int():
		number = float(v.to_int())
	else:
		return null
	if not is_finite(number) or number < float(_INT32_MIN) or number > float(_INT32_MAX):
		return null
	return int(number)


# Shared implementation for scalar Theme slots (color, constant, font_size).
# Captures old value, applies new value, persists it as a pre-flight save, then
# registers undo that restores the old value and saves again. A failed
# pre-flight save restores the old value and reports an error instead of
# leaving memory and disk out of sync.
func _set_scalar(
	params: Dictionary,
	kind: String,
	getter: Callable,
	setter: Callable,
	clearer: Callable,
	has_fn: Callable,
	parser: Callable,
) -> Dictionary:
	var load_result := _load_theme_from_params(params)
	if load_result.has("error"):
		return load_result
	var theme: Theme = load_result.theme
	var theme_path: String = load_result.path

	var class_name_param: String = params.get("class_name", "")
	if class_name_param.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: class_name")

	var name: String = params.get("name", "")
	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")

	if not "value" in params:
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: value")

	var raw_value = params.get("value")
	if raw_value == null:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid %s value: null (pass a concrete value; use the appropriate clear command to remove a slot)" % kind
		)
	var parsed = parser.call(raw_value)
	if parsed == null:
		## color slots want a color hint; constant/font_size are integer slots.
		var hint := _COLOR_HINT if kind == "color" else "expected a 32-bit integer"
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid %s value: %s (%s)" % [kind, raw_value, hint])

	var had_before: bool = has_fn.call(theme, name, class_name_param)
	var before_value = getter.call(theme, name, class_name_param) if had_before else null

	## Pre-flight: apply and persist before the undo action exists, so an
	## unwritable theme file (read-only, permissions) fails here with the
	## cached resource restored instead of reporting success while the file
	## never changed.
	var save_err: int = _apply_scalar(theme_path, setter, name, class_name_param, parsed)
	if save_err != OK:
		if had_before:
			_apply_scalar(theme_path, setter, name, class_name_param, before_value)
		else:
			_clear_scalar(theme_path, clearer, name, class_name_param)
		return _save_failure(theme_path, save_err)

	_undo_redo.create_action("MCP: Theme set %s %s/%s" % [kind, class_name_param, name])
	_undo_redo.add_do_method(self, "_apply_scalar", theme_path, setter, name, class_name_param, parsed)
	if had_before:
		_undo_redo.add_undo_method(self, "_apply_scalar", theme_path, setter, name, class_name_param, before_value)
	else:
		_undo_redo.add_undo_method(self, "_clear_scalar", theme_path, clearer, name, class_name_param)
	## The do method already ran as the pre-flight save; register without
	## re-executing so a second save's error cannot be discarded.
	_undo_redo.commit_action(false)

	return {
		"data": {
			"path": theme_path,
			"kind": kind,
			"class_name": class_name_param,
			"name": name,
			"value": _serialize_value(parsed),
			"previous_value": _serialize_value(before_value) if had_before else null,
			"undoable": true,
		}
	}


func _apply_scalar(theme_path: String, setter: Callable, name: String, class_name_param: String, value: Variant) -> int:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return ERR_FILE_CANT_OPEN
	setter.call(theme, name, class_name_param, value)
	return McpResourceIO.guarded_save(theme, theme_path, _connection)


func _clear_scalar(theme_path: String, clearer: Callable, name: String, class_name_param: String) -> int:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return ERR_FILE_CANT_OPEN
	clearer.call(theme, name, class_name_param)
	return McpResourceIO.guarded_save(theme, theme_path, _connection)


## Error dict for a failed pre-flight save. The caller has already restored the
## previous slot in memory, so the theme file and the cached resource both hold
## the pre-request state and no undo action was committed.
static func _save_failure(theme_path: String, save_err: int) -> Dictionary:
	return ErrorCodes.make(
		ErrorCodes.INTERNAL_ERROR,
		"Failed to save theme to %s: %s (error %d); the change was rolled back"
		% [theme_path, error_string(save_err), save_err]
	)


# ============================================================================
# theme_set_stylebox_flat
# ============================================================================

## Compose a StyleBoxFlat and assign it to a theme slot.
##
## Parameters (beyond theme_path / class_name / name):
##   bg_color       (Color, "#rrggbb", "#rrggbbaa", or {r,g,b,a})
##   border_color   (Color)
##   border         {all|top|bottom|left|right: int}  — side keys override `all`
##   corners        {all|top_left|top_right|bottom_left|bottom_right: int}
##   margins        {all|top|bottom|left|right: float}
##   shadow         {color, size: int, offset_x: float, offset_y: float}
##   anti_aliasing  (bool)
##
## Unknown keys inside any nested dict are rejected with INVALID_PARAMS so
## typos fail loudly instead of silently being ignored. Numeric values must be
## finite and within the native storage's range (32-bit ints, 32-bit floats,
## and the float32-backed ints behind border widths/corner radii) and flags
## real booleans; invalid input is refused with a structured error before
## anything is applied, so a refused call leaves the theme slot and undo
## history untouched. A slot change is persisted before the undo action is
## registered: if the theme file cannot be written, the previous slot is
## restored and the call fails with INTERNAL_ERROR.
func set_stylebox_flat(params: Dictionary) -> Dictionary:
	var load_result := _load_theme_from_params(params)
	if load_result.has("error"):
		return load_result
	var theme: Theme = load_result.theme
	var theme_path: String = load_result.path

	var class_name_param: String = params.get("class_name", "")
	if class_name_param.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: class_name")

	var name: String = params.get("name", "")
	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")

	var sb := StyleBoxFlat.new()
	var applied := _apply_flat_props(sb, params)
	if applied.has("error"):
		return applied

	var had_before := theme.has_stylebox(name, class_name_param)
	var before_sb: StyleBox = theme.get_stylebox(name, class_name_param) if had_before else null
	## Pre-flight: apply and persist before the undo action exists, so an
	## unwritable theme file fails here with the cached resource restored
	## instead of reporting success while the file never changed.
	var save_err: int = _apply_stylebox(theme_path, name, class_name_param, sb)
	if save_err != OK:
		if had_before:
			_apply_stylebox(theme_path, name, class_name_param, before_sb)
		else:
			_clear_stylebox(theme_path, name, class_name_param)
		return _save_failure(theme_path, save_err)
	_commit_stylebox(theme_path, name, class_name_param, sb, before_sb, had_before)

	return {
		"data": {
			"path": theme_path,
			"class_name": class_name_param,
			"name": name,
			"stylebox_class": "StyleBoxFlat",
			"bg_color": _serialize_value(sb.bg_color),
			"border": {
				"top": sb.border_width_top,
				"bottom": sb.border_width_bottom,
				"left": sb.border_width_left,
				"right": sb.border_width_right,
			},
			"corners": {
				"top_left": sb.corner_radius_top_left,
				"top_right": sb.corner_radius_top_right,
				"bottom_left": sb.corner_radius_bottom_left,
				"bottom_right": sb.corner_radius_bottom_right,
			},
			"margins": {
				"top": sb.content_margin_top,
				"bottom": sb.content_margin_bottom,
				"left": sb.content_margin_left,
				"right": sb.content_margin_right,
			},
			"undoable": true,
		}
	}


## Apply the StyleBoxFlat property vocabulary shared by `set_stylebox_flat`
## and `stylebox_override` to an existing StyleBoxFlat. Returns `{ok: true}`
## or the error dict to surface.
func _apply_flat_props(sb: StyleBoxFlat, params: Dictionary) -> Dictionary:
	if params.has("bg_color"):
		var bg := _parse_color(params.bg_color)
		if bg == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid bg_color: %s (%s)" % [str(params.bg_color), _COLOR_HINT])
		sb.bg_color = bg
	if params.has("border_color"):
		var bc := _parse_color(params.border_color)
		if bc == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "Invalid border_color: %s (%s)" % [str(params.border_color), _COLOR_HINT])
		sb.border_color = bc

	# border: {all, top, bottom, left, right} — int widths (real_t storage)
	if params.has("border"):
		var border_result := _apply_sides(sb, params.border, "border",
			["top", "bottom", "left", "right"],
			"border_width_",
			_NATIVE_INT32_FLOAT32)
		if border_result.has("error"):
			return border_result

	# corners: {all, top_left, top_right, bottom_left, bottom_right} — int radii (real_t storage)
	if params.has("corners"):
		var corners_result := _apply_sides(sb, params.corners, "corners",
			["top_left", "top_right", "bottom_left", "bottom_right"],
			"corner_radius_",
			_NATIVE_INT32_FLOAT32)
		if corners_result.has("error"):
			return corners_result

	# margins: {all, top, bottom, left, right} — float padding
	if params.has("margins"):
		var margins_result := _apply_sides(sb, params.margins, "margins",
			["top", "bottom", "left", "right"],
			"content_margin_",
			_NATIVE_FLOAT32)
		if margins_result.has("error"):
			return margins_result

	# shadow: {color, size, offset_x, offset_y}
	if params.has("shadow"):
		if typeof(params.shadow) != TYPE_DICTIONARY:
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, "'shadow' must be a dict with color/size/offset_x/offset_y")
		var shadow: Dictionary = params.shadow
		var allowed_shadow_keys := {"color": true, "size": true, "offset_x": true, "offset_y": true}
		for k in shadow.keys():
			if not allowed_shadow_keys.has(k):
				return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
					"Unknown key in 'shadow': %s (valid: color, size, offset_x, offset_y)" % k)
		if shadow.has("color"):
			var sc := _parse_color(shadow.color)
			if sc == null:
				return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
					"Invalid shadow.color: %s (%s)" % [str(shadow.color), _COLOR_HINT])
			sb.shadow_color = sc
		if shadow.has("size"):
			var size_result := _parse_number_field("shadow", "size", shadow.size, _NATIVE_INT32)
			if size_result.has("error"):
				return size_result
			sb.shadow_size = size_result.value
		if shadow.has("offset_x") or shadow.has("offset_y"):
			## Missing components keep the stylebox's current offset: on the
			## stylebox_override path `sb` is a duplicate of the resolved
			## stylebox, and a patch must not silently reset the other axis.
			var offset_x := sb.shadow_offset.x
			var offset_y := sb.shadow_offset.y
			if shadow.has("offset_x"):
				var offset_x_result := _parse_number_field("shadow", "offset_x", shadow.offset_x, _NATIVE_FLOAT32)
				if offset_x_result.has("error"):
					return offset_x_result
				offset_x = offset_x_result.value
			if shadow.has("offset_y"):
				var offset_y_result := _parse_number_field("shadow", "offset_y", shadow.offset_y, _NATIVE_FLOAT32)
				if offset_y_result.has("error"):
					return offset_y_result
				offset_y = offset_y_result.value
			sb.shadow_offset = Vector2(offset_x, offset_y)

	if params.has("anti_aliasing"):
		var anti_aliasing_result := _parse_bool_field("anti_aliasing", params.anti_aliasing)
		if anti_aliasing_result.has("error"):
			return anti_aliasing_result
		sb.anti_aliasing = anti_aliasing_result.value
	return {"ok": true}


## Top-level keys in `patch` that are not part of the StyleBoxFlat vocabulary.
static func _unknown_flat_keys(patch: Dictionary) -> Array:
	var unknown: Array = []
	for key in patch.keys():
		if not _FLAT_PATCH_KEYS.has(key):
			unknown.append(str(key))
	return unknown


## Record one stylebox set as an undoable action (apply new, restore or clear
## the previous slot). Shared by set_stylebox_flat and set_stylebox_texture.
## The caller has already applied and persisted the new stylebox as its
## pre-flight save, so the action is committed without re-executing the do
## method.
func _commit_stylebox(
	theme_path: String, name: String, class_name_param: String,
	sb: StyleBox, before_sb: StyleBox, had_before: bool
) -> void:
	_undo_redo.create_action("MCP: Theme set stylebox %s/%s" % [class_name_param, name])
	_undo_redo.add_do_method(self, "_apply_stylebox", theme_path, name, class_name_param, sb)
	if had_before:
		_undo_redo.add_undo_method(self, "_apply_stylebox", theme_path, name, class_name_param, before_sb)
	else:
		_undo_redo.add_undo_method(self, "_clear_stylebox", theme_path, name, class_name_param)
	_undo_redo.commit_action(false)


# ============================================================================
# theme_set_stylebox_texture
# ============================================================================

## Compose a StyleBoxTexture (9-slice) and assign it to a theme slot.
##
## Parameters (beyond theme_path / class_name / name):
##   texture_path             res:// path to a Texture2D
##   region                   {position: {x,y}, size: {x,y}} or [x,y,w,h]
##   margins                  {all|left|top|right|bottom: float} texture margins
##   axis_stretch_horizontal  "stretch" | "tile" | "tile_fit"
##   axis_stretch_vertical    "stretch" | "tile" | "tile_fit"
##   modulate_color           Color
##   draw_center              bool
##
## Numeric values must be finite and within the native storage's range, and
## flags real booleans; invalid input is refused with a structured error before
## anything is applied. A slot change is persisted before the undo action is
## registered: if the theme file cannot be written, the previous slot is
## restored and the call fails with INTERNAL_ERROR.
func set_stylebox_texture(params: Dictionary) -> Dictionary:
	var load_result := _load_theme_from_params(params)
	if load_result.has("error"):
		return load_result
	var theme: Theme = load_result.theme
	var theme_path: String = load_result.path

	var class_name_param: String = params.get("class_name", "")
	if class_name_param.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: class_name")
	var name: String = params.get("name", "")
	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")
	var texture_path: String = params.get("texture_path", "")
	if texture_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: texture_path")
	var path_err = McpPathValidator.loadable_error(texture_path, "texture_path")
	if path_err != null:
		return path_err
	if not ResourceLoader.exists(texture_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Texture not found: %s" % texture_path)
	var texture := ResourceLoader.load(texture_path)
	if texture == null or not (texture is Texture2D):
		var got := texture.get_class() if texture != null else "null"
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Resource at %s is not a Texture2D (got %s)" % [texture_path, got])

	var sb := StyleBoxTexture.new()
	sb.texture = texture
	if params.has("region"):
		var region := _parse_rect2(params.region)
		if region == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid region: %s (expected {position, size} or [x,y,w,h])" % str(params.region))
		sb.region_rect = region
	if params.has("margins"):
		var margin_result := _apply_texture_margins(sb, params.margins)
		if margin_result.has("error"):
			return margin_result
	if params.has("modulate_color"):
		var mc := _parse_color(params.modulate_color)
		if mc == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid modulate_color: %s (%s)" % [str(params.modulate_color), _COLOR_HINT])
		sb.modulate_color = mc
	if params.has("draw_center"):
		var draw_center_result := _parse_bool_field("draw_center", params.draw_center)
		if draw_center_result.has("error"):
			return draw_center_result
		sb.draw_center = draw_center_result.value
	if params.has("axis_stretch_horizontal"):
		var ash := _parse_axis_stretch(str(params.axis_stretch_horizontal))
		if ash == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid axis_stretch_horizontal '%s'. Valid: stretch, tile, tile_fit" % str(params.axis_stretch_horizontal))
		sb.axis_stretch_horizontal = ash
	if params.has("axis_stretch_vertical"):
		var asv := _parse_axis_stretch(str(params.axis_stretch_vertical))
		if asv == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid axis_stretch_vertical '%s'. Valid: stretch, tile, tile_fit" % str(params.axis_stretch_vertical))
		sb.axis_stretch_vertical = asv

	var had_before := theme.has_stylebox(name, class_name_param)
	var before_sb: StyleBox = theme.get_stylebox(name, class_name_param) if had_before else null
	## Pre-flight: apply and persist before the undo action exists, so an
	## unwritable theme file fails here with the cached resource restored
	## instead of reporting success while the file never changed.
	var save_err: int = _apply_stylebox(theme_path, name, class_name_param, sb)
	if save_err != OK:
		if had_before:
			_apply_stylebox(theme_path, name, class_name_param, before_sb)
		else:
			_clear_stylebox(theme_path, name, class_name_param)
		return _save_failure(theme_path, save_err)
	_commit_stylebox(theme_path, name, class_name_param, sb, before_sb, had_before)

	return {
		"data": {
			"path": theme_path,
			"class_name": class_name_param,
			"name": name,
			"stylebox_class": "StyleBoxTexture",
			"texture_path": texture_path,
			"region": _serialize_value(sb.region_rect),
			"margins": {
				"left": sb.texture_margin_left,
				"top": sb.texture_margin_top,
				"right": sb.texture_margin_right,
				"bottom": sb.texture_margin_bottom,
			},
			"draw_center": sb.draw_center,
			"undoable": true,
		}
	}


# ============================================================================
# theme_set_font / theme_set_icon
# ============================================================================

## Assign a Font resource to a theme font slot (button/body/heading fonts).
func set_font(params: Dictionary) -> Dictionary:
	return _set_resource_slot(params, "font", "font_path", "Font")


## Assign a Texture2D to a theme icon slot (checkbox marks, dropdown arrows).
func set_icon(params: Dictionary) -> Dictionary:
	return _set_resource_slot(params, "icon", "texture_path", "Texture2D")


## Shared implementation for font/icon slots: load the resource, verify its
## class, then set/clear the slot as one undoable action.
func _set_resource_slot(
	params: Dictionary, kind: String, path_param: String, expected_class: String
) -> Dictionary:
	var load_result := _load_theme_from_params(params)
	if load_result.has("error"):
		return load_result
	var theme: Theme = load_result.theme
	var theme_path: String = load_result.path

	var class_name_param: String = params.get("class_name", "")
	if class_name_param.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: class_name")
	var name: String = params.get("name", "")
	if name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: name")
	var resource_path: String = params.get(path_param, "")
	if resource_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: %s" % path_param)
	var path_err = McpPathValidator.loadable_error(resource_path, path_param)
	if path_err != null:
		return path_err
	if not ResourceLoader.exists(resource_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "%s not found: %s" % [expected_class, resource_path])
	var loaded := ResourceLoader.load(resource_path)
	if loaded == null or not _is_instance_of_class(loaded, expected_class):
		var got := loaded.get_class() if loaded != null else "null"
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Resource at %s is not a %s (got %s)" % [resource_path, expected_class, got])

	var had_before := theme.has_font(name, class_name_param) if kind == "font" else theme.has_icon(name, class_name_param)
	var before_value = theme.get_font(name, class_name_param) if kind == "font" else theme.get_icon(name, class_name_param)
	if not had_before:
		before_value = null

	## Pre-flight: apply and persist before the undo action exists, so an
	## unwritable theme file fails here with the cached resource restored
	## instead of reporting success while the file never changed.
	var save_err: int = _apply_slot(theme_path, kind, name, class_name_param, loaded)
	if save_err != OK:
		if had_before:
			_apply_slot(theme_path, kind, name, class_name_param, before_value)
		else:
			_clear_slot(theme_path, kind, name, class_name_param)
		return _save_failure(theme_path, save_err)

	_undo_redo.create_action("MCP: Theme set %s %s/%s" % [kind, class_name_param, name])
	_undo_redo.add_do_method(self, "_apply_slot", theme_path, kind, name, class_name_param, loaded)
	if had_before:
		_undo_redo.add_undo_method(self, "_apply_slot", theme_path, kind, name, class_name_param, before_value)
	else:
		_undo_redo.add_undo_method(self, "_clear_slot", theme_path, kind, name, class_name_param)
	## The do method already ran as the pre-flight save; register without
	## re-executing so a second save's error cannot be discarded.
	_undo_redo.commit_action(false)

	return {
		"data": {
			"path": theme_path,
			"kind": kind,
			"class_name": class_name_param,
			"name": name,
			"resource_path": resource_path,
			"resource_class": loaded.get_class(),
			"undoable": true,
		}
	}


## True when `resource` is an instance of `class_name` (or a subclass).
static func _is_instance_of_class(resource: Resource, expected_class: String) -> bool:
	return ClassDB.is_parent_class(resource.get_class(), expected_class)


# ============================================================================
# theme_stylebox_override — per-node override
# ============================================================================

## Duplicate the stylebox a Control resolves for `slot`, apply a StyleBoxFlat
## patch (same keys as set_stylebox_flat), and attach it as a per-node
## override. Undo restores the previous override, or removes the override when
## the node had none. Patch values are validated the same way as
## set_stylebox_flat — unknown top-level keys are refused — and a refused
## patch leaves the node's override untouched. The action is committed to the
## Control's scene history, so the editor's scene undo reverts it (a method
## bound to this handler object would land in GLOBAL_HISTORY instead).
func stylebox_override(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	if node_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: path")
	var slot: String = params.get("slot", "")
	if slot.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: slot")
	var patch: Variant = params.get("patch", {})
	if typeof(patch) != TYPE_DICTIONARY:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "'patch' must be a dict of StyleBoxFlat properties")
	var unknown_keys := _unknown_flat_keys(patch)
	if not unknown_keys.is_empty():
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"Unknown patch key(s): %s (valid: %s)" % [", ".join(unknown_keys), ", ".join(_FLAT_PATCH_KEYS)])

	var resolved := McpNodeValidator.resolve_or_error(node_path, "path")
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if not node is Control:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node %s is not a Control (got %s)" % [node_path, node.get_class()])
	var control := node as Control

	var base: StyleBox = control.get_theme_stylebox(slot)
	if base == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND,
			"No stylebox resolves for slot '%s' on %s" % [slot, node.get_class()])
	var patched: StyleBox = base.duplicate()
	if not patched is StyleBoxFlat:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Slot '%s' resolves to %s; stylebox_override patches StyleBoxFlat slots only"
			% [slot, patched.get_class()])
	var applied := _apply_flat_props(patched as StyleBoxFlat, patch)
	if applied.has("error"):
		return applied

	var had_override: bool = control.has_theme_stylebox_override(slot)
	var scene_root: Node = resolved.scene_root
	_undo_redo.create_action("MCP: Stylebox override %s on %s" % [slot, node.name],
		UndoRedo.MERGE_DISABLE, scene_root)
	_undo_redo.add_do_method(self, "_apply_node_stylebox", control, slot, patched)
	if had_override:
		_undo_redo.add_undo_method(self, "_apply_node_stylebox", control, slot, base)
	else:
		_undo_redo.add_undo_method(self, "_remove_node_stylebox", control, slot)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": McpScenePath.from_node(node, resolved.scene_root),
			"slot": slot,
			"stylebox_class": patched.get_class(),
			"overrode_existing": had_override,
			"undoable": true,
		}
	}


func _apply_node_stylebox(control: Control, slot: String, sb: StyleBox) -> void:
	control.add_theme_stylebox_override(slot, sb)


func _remove_node_stylebox(control: Control, slot: String) -> void:
	control.remove_theme_stylebox_override(slot)


## Strict finite-number parser for stylebox numeric fields. Accepts int/float
## and numeric strings (the McpJsonValues.parse_float vocabulary) and returns
## `{"value": <int|float>}`; non-numeric input and non-finite results return a
## structured error instead, so a bad value can neither raise an engine
## conversion error nor be silently stored as 0.
##
## The value is validated against the *native destination* before narrowing
## (see the _NATIVE_* kinds), and the returned value is the narrowed one, so
## what was validated is what gets stored.
static func _parse_number_field(dict_name: String, key: String, raw: Variant, storage: int) -> Dictionary:
	var parsed: Variant = McpJsonValues.parse_float(raw)
	if parsed == null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"'%s.%s' must be a number, got %s" % [dict_name, key, type_string(typeof(raw))])
	var number := float(parsed)
	if not is_finite(number):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"'%s.%s' must be finite, got %s" % [dict_name, key, str(number)])
	match storage:
		_NATIVE_INT32:
			if number < float(_INT32_MIN) or number > float(_INT32_MAX):
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
					"'%s.%s' is out of range for a 32-bit integer (got %s)" % [dict_name, key, str(number)])
			return {"value": int(number)}
		_NATIVE_FLOAT32:
			var narrowed: float = PackedFloat32Array([number])[0]
			if not is_finite(narrowed):
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
					"'%s.%s' is out of range for a 32-bit float (got %s)" % [dict_name, key, str(number)])
			return {"value": narrowed}
		_NATIVE_INT32_FLOAT32:
			## Must survive the float32 round-trip and stay in int32, or the
			## int getter reads back a rounded or wrapped value.
			var narrowed: float = PackedFloat32Array([number])[0]
			if not is_finite(narrowed) or narrowed < float(_INT32_MIN) or narrowed > float(_INT32_MAX) \
					or int(narrowed) != int(number):
				return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
					"'%s.%s' is out of range for the float-backed 32-bit int storage (got %s)" % [dict_name, key, str(number)])
			return {"value": int(narrowed)}
	return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Unknown numeric storage kind: %d" % storage)


## Strict bool parser for stylebox flags. `bool("false")` is true in GDScript,
## so a stringified flag would silently invert the caller's intent.
static func _parse_bool_field(name: String, raw: Variant) -> Dictionary:
	if raw is bool:
		return {"value": raw}
	return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
		"'%s' must be a boolean, got %s" % [name, type_string(typeof(raw))])


## Parse a {all, <side1>, <side2>, ...} dict into StyleBox numeric properties.
## Every value is parsed and validated before anything is assigned, so an
## invalid value can neither raise an engine conversion error nor leave a
## partially applied stylebox. `sb` is a StyleBoxFlat or StyleBoxTexture (both
## expose `set`); `storage` is one of the _NATIVE_* kinds. Returns
## {"ok": true} or the error dict to surface.
static func _apply_sides(sb: Object, sides_dict: Variant, dict_name: String,
		side_names: Array, prop_prefix: String, storage: int) -> Dictionary:
	if typeof(sides_dict) != TYPE_DICTIONARY:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"'%s' must be a dict with 'all' and/or side-specific keys" % dict_name)
	var valid_keys := {"all": true}
	for s in side_names:
		valid_keys[s] = true
	for k in sides_dict.keys():
		if not valid_keys.has(k):
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
				"Unknown key in '%s': %s (valid: all, %s)" % [dict_name, k, ", ".join(side_names)])
	var parsed_values := {}
	if sides_dict.has("all"):
		var all_result := _parse_number_field(dict_name, "all", sides_dict.all, storage)
		if all_result.has("error"):
			return all_result
		parsed_values["all"] = all_result.value
	for s in side_names:
		if sides_dict.has(s):
			var side_result := _parse_number_field(dict_name, s, sides_dict[s], storage)
			if side_result.has("error"):
				return side_result
			parsed_values[s] = side_result.value
	# Every value parsed: apply `all` first, then the side-specific overrides.
	if parsed_values.has("all"):
		for s in side_names:
			sb.set(prop_prefix + s, parsed_values["all"])
	for s in side_names:
		if parsed_values.has(s):
			sb.set(prop_prefix + s, parsed_values[s])
	return {"ok": true}


func _apply_stylebox(theme_path: String, name: String, class_name_param: String, sb: StyleBox) -> int:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return ERR_FILE_CANT_OPEN
	theme.set_stylebox(name, class_name_param, sb)
	return McpResourceIO.guarded_save(theme, theme_path, _connection)


func _clear_stylebox(theme_path: String, name: String, class_name_param: String) -> int:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return ERR_FILE_CANT_OPEN
	theme.clear_stylebox(name, class_name_param)
	return McpResourceIO.guarded_save(theme, theme_path, _connection)


# ============================================================================
# theme_apply — assign a theme to a Control
# ============================================================================

func apply_theme(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: node_path")

	var theme_path: String = params.get("theme_path", "")
	var theme: Theme = null
	if not theme_path.is_empty():
		var path_err := _validate_res_path(theme_path, ".tres")
		if path_err != null:
			return path_err
		if not ResourceLoader.exists(theme_path):
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Theme not found: %s" % theme_path)
		theme = ResourceLoader.load(theme_path)
		if theme == null or not theme is Theme:
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Theme" % theme_path)

	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var _scene_root: Node = _resolved.scene_root
	if not node is Control and not node is Window:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Node %s is not a Control or Window (got %s)" % [node_path, node.get_class()]
		)

	var before_theme: Theme = node.theme
	_undo_redo.create_action("MCP: Apply theme to %s" % node.name)
	_undo_redo.add_do_property(node, "theme", theme)
	_undo_redo.add_undo_property(node, "theme", before_theme)
	_undo_redo.commit_action()

	return {
		"data": {
			"node_path": node_path,
			"theme_path": theme_path if theme != null else "",
			"cleared": theme == null,
			"undoable": true,
		}
	}


# ============================================================================
# Helpers
# ============================================================================

func _load_theme_from_params(params: Dictionary) -> Dictionary:
	var theme_path: String = params.get("theme_path", "")
	var err := _validate_res_path(theme_path, ".tres", "theme_path", true)
	if err != null:
		return err
	if not ResourceLoader.exists(theme_path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "Theme not found: %s" % theme_path)
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null or not theme is Theme:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE, "Resource at %s is not a Theme" % theme_path)
	return {"theme": theme, "path": theme_path}


static func _validate_res_path(path: String, required_suffix: String, param_name: String = "theme_path", for_write: bool = false) -> Variant:
	if path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: %s" % param_name)
	var path_err := McpPathValidator.validate_resource_path(path, for_write)
	if not path_err.is_empty():
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE, "%s: %s" % [param_name, path_err])
	if not path.ends_with(required_suffix):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"%s must end with %s (got %s)" % [param_name, required_suffix, path]
		)
	return null


## Parse a color from Color, "#rrggbb", "#rrggbbaa", named (red/blue/...) or dict.
## Returns null if the input cannot be parsed.
## Delegates to the canonical parser (#714) — gains [r,g,b(,a)] array
## support and strict key/component checking, same shapes as every other
## color-accepting handler. Color components are 32-bit floats, so a finite
## double like 1e40 narrows to INF at construction; the parsed value is
## re-checked for finiteness and refused instead of storing an infinite color.
static func _parse_color(value: Variant) -> Variant:
	var parsed: Variant = McpJsonValues.parse_color(value)
	if parsed == null:
		return null
	var color := parsed as Color
	if not (is_finite(color.r) and is_finite(color.g) and is_finite(color.b) and is_finite(color.a)):
		return null
	return color


static func _serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	if value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	if value is Rect2:
		return {
			"position": {"x": value.position.x, "y": value.position.y},
			"size": {"x": value.size.x, "y": value.size.y},
		}
	return value


## Set a font/icon slot from inside an undo action. Stylebox slots use the
## dedicated `_apply_stylebox` path (they need the StyleBox-typed setter).
func _apply_slot(theme_path: String, kind: String, name: String, class_name_param: String, value: Variant) -> int:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return ERR_FILE_CANT_OPEN
	match kind:
		"font":
			theme.set_font(name, class_name_param, value)
		"icon":
			theme.set_icon(name, class_name_param, value)
	return McpResourceIO.guarded_save(theme, theme_path, _connection)


func _clear_slot(theme_path: String, kind: String, name: String, class_name_param: String) -> int:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return ERR_FILE_CANT_OPEN
	match kind:
		"font":
			theme.clear_font(name, class_name_param)
		"icon":
			theme.clear_icon(name, class_name_param)
	return McpResourceIO.guarded_save(theme, theme_path, _connection)


## Parse a 9-slice region from {position: {x,y}, size: {x,y}} or [x,y,w,h].
## Non-finite components are rejected (null), so a NaN/INF region can never be
## committed to a stylebox slot.
static func _parse_rect2(value: Variant) -> Variant:
	if value is Rect2:
		return value if _is_finite_rect2(value) else null
	if value is Dictionary:
		var d: Dictionary = value
		if not (d.has("position") and d.has("size")):
			return null
		var pos := McpJsonValues.parse_vector2(d.position)
		var size := McpJsonValues.parse_vector2(d.size)
		if pos == null or size == null:
			return null
		var rect := Rect2(pos, size)
		return rect if _is_finite_rect2(rect) else null
	if value is Array:
		var arr: Array = value
		if arr.size() != 4:
			return null
		for item in arr:
			if not (item is int or item is float):
				return null
		var rect := Rect2(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))
		return rect if _is_finite_rect2(rect) else null
	return null


static func _is_finite_rect2(rect: Rect2) -> bool:
	return (
		is_finite(rect.position.x)
		and is_finite(rect.position.y)
		and is_finite(rect.size.x)
		and is_finite(rect.size.y)
	)


## StyleBoxTexture axis stretch mode by name. Returns null on an unknown name.
static func _parse_axis_stretch(value: String) -> Variant:
	match value:
		"stretch":
			return StyleBoxTexture.AXIS_STRETCH_MODE_STRETCH
		"tile":
			return StyleBoxTexture.AXIS_STRETCH_MODE_TILE
		"tile_fit":
			return StyleBoxTexture.AXIS_STRETCH_MODE_TILE_FIT
	return null


## Apply {all, left, top, right, bottom} texture margins to a StyleBoxTexture.
## Shares the flat side parser's validate-then-apply contract: every value is
## parsed before any margin is assigned. Returns {"ok": true} or the error dict.
static func _apply_texture_margins(sb: StyleBoxTexture, margins: Variant) -> Dictionary:
	return _apply_sides(sb, margins, "margins", ["left", "top", "right", "bottom"],
		"texture_margin_", _NATIVE_FLOAT32)
