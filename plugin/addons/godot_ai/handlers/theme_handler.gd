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
		func(v): return int(v) if (v is int or v is float or (v is String and v.is_valid_int())) else null)


func set_font_size(params: Dictionary) -> Dictionary:
	return _set_scalar(params, "font_size", func(theme, name, cls): return theme.get_font_size(name, cls),
		func(theme, name, cls, val): theme.set_font_size(name, cls, int(val)),
		func(theme, name, cls): theme.clear_font_size(name, cls),
		func(theme, name, cls): return theme.has_font_size(name, cls),
		func(v): return int(v) if (v is int or v is float or (v is String and v.is_valid_int())) else null)


# Shared implementation for scalar Theme slots (color, constant, font_size).
# Captures old value, applies new value, saves to disk, registers undo that
# restores the old value and saves again.
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
		var hint := _COLOR_HINT if kind == "color" else "expected an integer"
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid %s value: %s (%s)" % [kind, raw_value, hint])

	var had_before: bool = has_fn.call(theme, name, class_name_param)
	var before_value = getter.call(theme, name, class_name_param) if had_before else null

	_undo_redo.create_action("MCP: Theme set %s %s/%s" % [kind, class_name_param, name])
	_undo_redo.add_do_method(self, "_apply_scalar", theme_path, setter, name, class_name_param, parsed)
	if had_before:
		_undo_redo.add_undo_method(self, "_apply_scalar", theme_path, setter, name, class_name_param, before_value)
	else:
		_undo_redo.add_undo_method(self, "_clear_scalar", theme_path, clearer, name, class_name_param)
	_undo_redo.commit_action()

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


func _apply_scalar(theme_path: String, setter: Callable, name: String, class_name_param: String, value: Variant) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	setter.call(theme, name, class_name_param, value)
	McpResourceIO.guarded_save(theme, theme_path, _connection)


func _clear_scalar(theme_path: String, clearer: Callable, name: String, class_name_param: String) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	clearer.call(theme, name, class_name_param)
	McpResourceIO.guarded_save(theme, theme_path, _connection)


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
## typos fail loudly instead of silently being ignored.
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

	# border: {all, top, bottom, left, right} — int widths
	if params.has("border"):
		var err := _apply_sides(sb, params.border, "border",
			["top", "bottom", "left", "right"],
			"border_width_",
			TYPE_INT)
		if err != "":
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, err)

	# corners: {all, top_left, top_right, bottom_left, bottom_right} — int radii
	if params.has("corners"):
		var err2 := _apply_sides(sb, params.corners, "corners",
			["top_left", "top_right", "bottom_left", "bottom_right"],
			"corner_radius_",
			TYPE_INT)
		if err2 != "":
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, err2)

	# margins: {all, top, bottom, left, right} — float padding
	if params.has("margins"):
		var err3 := _apply_sides(sb, params.margins, "margins",
			["top", "bottom", "left", "right"],
			"content_margin_",
			TYPE_FLOAT)
		if err3 != "":
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, err3)

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
			sb.shadow_size = int(shadow.size)
		if shadow.has("offset_x") or shadow.has("offset_y"):
			sb.shadow_offset = Vector2(
				float(shadow.get("offset_x", 0)),
				float(shadow.get("offset_y", 0)),
			)

	if params.has("anti_aliasing"):
		sb.anti_aliasing = bool(params.anti_aliasing)
	return {"ok": true}


## Record one stylebox set as an undoable action (apply new, restore or clear
## the previous slot). Shared by set_stylebox_flat and set_stylebox_texture.
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
	_undo_redo.commit_action()


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
		var margin_err := _apply_texture_margins(sb, params.margins)
		if margin_err != "":
			return ErrorCodes.make(ErrorCodes.INVALID_PARAMS, margin_err)
	if params.has("modulate_color"):
		var mc := _parse_color(params.modulate_color)
		if mc == null:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid modulate_color: %s (%s)" % [str(params.modulate_color), _COLOR_HINT])
		sb.modulate_color = mc
	if params.has("draw_center"):
		sb.draw_center = bool(params.draw_center)
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

	_undo_redo.create_action("MCP: Theme set %s %s/%s" % [kind, class_name_param, name])
	_undo_redo.add_do_method(self, "_apply_slot", theme_path, kind, name, class_name_param, loaded)
	if had_before:
		_undo_redo.add_undo_method(self, "_apply_slot", theme_path, kind, name, class_name_param, before_value)
	else:
		_undo_redo.add_undo_method(self, "_clear_slot", theme_path, kind, name, class_name_param)
	_undo_redo.commit_action()

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
## the node had none.
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
	_undo_redo.create_action("MCP: Stylebox override %s on %s" % [slot, node.name])
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


## Parse a {all, <side1>, <side2>, ...} dict and apply it to StyleBoxFlat via
## its set_<prop_prefix><side> properties. Returns "" on success, an error
## message on failure. Validates that only known keys are present.
func _apply_sides(sb: StyleBoxFlat, sides_dict: Variant, dict_name: String,
		side_names: Array, prop_prefix: String, value_type: int) -> String:
	if typeof(sides_dict) != TYPE_DICTIONARY:
		return "'%s' must be a dict with 'all' and/or side-specific keys" % dict_name
	var valid_keys := {"all": true}
	for s in side_names:
		valid_keys[s] = true
	for k in sides_dict.keys():
		if not valid_keys.has(k):
			return "Unknown key in '%s': %s (valid: all, %s)" % [
				dict_name, k, ", ".join(side_names)
			]
	# Apply `all` first, then override with side-specific keys.
	if sides_dict.has("all"):
		var all_val: Variant = sides_dict.all
		for s in side_names:
			var v: Variant = int(all_val) if value_type == TYPE_INT else float(all_val)
			sb.set(prop_prefix + s, v)
	for s in side_names:
		if sides_dict.has(s):
			var v2: Variant = int(sides_dict[s]) if value_type == TYPE_INT else float(sides_dict[s])
			sb.set(prop_prefix + s, v2)
	return ""


func _apply_stylebox(theme_path: String, name: String, class_name_param: String, sb: StyleBox) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	theme.set_stylebox(name, class_name_param, sb)
	McpResourceIO.guarded_save(theme, theme_path, _connection)


func _clear_stylebox(theme_path: String, name: String, class_name_param: String) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	theme.clear_stylebox(name, class_name_param)
	McpResourceIO.guarded_save(theme, theme_path, _connection)


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
## color-accepting handler.
static func _parse_color(value: Variant) -> Variant:
	return McpJsonValues.parse_color(value)


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
func _apply_slot(theme_path: String, kind: String, name: String, class_name_param: String, value: Variant) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	match kind:
		"font":
			theme.set_font(name, class_name_param, value)
		"icon":
			theme.set_icon(name, class_name_param, value)
	McpResourceIO.guarded_save(theme, theme_path, _connection)


func _clear_slot(theme_path: String, kind: String, name: String, class_name_param: String) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	match kind:
		"font":
			theme.clear_font(name, class_name_param)
		"icon":
			theme.clear_icon(name, class_name_param)
	McpResourceIO.guarded_save(theme, theme_path, _connection)


## Parse a 9-slice region from {position: {x,y}, size: {x,y}} or [x,y,w,h].
static func _parse_rect2(value: Variant) -> Variant:
	if value is Rect2:
		return value
	if value is Dictionary:
		var d: Dictionary = value
		if not (d.has("position") and d.has("size")):
			return null
		var pos := McpJsonValues.parse_vector2(d.position)
		var size := McpJsonValues.parse_vector2(d.size)
		if pos == null or size == null:
			return null
		return Rect2(pos, size)
	if value is Array:
		var arr: Array = value
		if arr.size() != 4:
			return null
		for item in arr:
			if not (item is int or item is float):
				return null
		return Rect2(float(arr[0]), float(arr[1]), float(arr[2]), float(arr[3]))
	return null


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
## Returns "" on success, an error message on failure.
func _apply_texture_margins(sb: StyleBoxTexture, margins: Variant) -> String:
	if typeof(margins) != TYPE_DICTIONARY:
		return "'margins' must be a dict with 'all' and/or side-specific keys"
	var side_names := ["left", "top", "right", "bottom"]
	var valid_keys := {"all": true}
	for s in side_names:
		valid_keys[s] = true
	for k in margins.keys():
		if not valid_keys.has(k):
			return "Unknown key in 'margins': %s (valid: all, %s)" % [k, ", ".join(side_names)]
	if margins.has("all"):
		var all_val := float(margins.all)
		for s in side_names:
			sb.set("texture_margin_" + s, all_val)
	for s in side_names:
		if margins.has(s):
			sb.set("texture_margin_" + s, float(margins[s]))
	return ""
