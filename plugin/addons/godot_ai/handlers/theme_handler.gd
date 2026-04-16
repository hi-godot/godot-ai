@tool
class_name ThemeHandler
extends RefCounted

## Handles Theme resource authoring: creating, modifying color/constant/font-size/
## stylebox slots, and applying a theme to a Control subtree.
##
## Themes are Godot's equivalent of USS: a Theme holds (class, name) -> value
## entries (colors, constants, fonts, font_sizes, styleboxes, icons) which
## cascade down a Control subtree when the theme is assigned at any ancestor.
## One well-authored theme replaces hundreds of per-node property sets.

const _COLOR_HINT := "expected hex #rrggbb, named color, or {r,g,b,a} dict"

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# theme_create
# ============================================================================

func create_theme(params: Dictionary) -> Dictionary:
	var path: String = params.get("path", "")
	var overwrite: bool = params.get("overwrite", false)

	var err := _validate_res_path(path, ".tres", "path")
	if err != null:
		return err

	# Capture whether the file was already there BEFORE the save so we can
	# report `overwritten` accurately (after save the file always exists).
	var existed_before := FileAccess.file_exists(path)
	if existed_before and not overwrite:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Theme already exists at %s (pass overwrite=true to replace)" % path
		)

	# Ensure parent directory exists. make_dir_recursive is idempotent —
	# no need to check dir_exists first (avoids TOCTOU race).
	var dir_path := path.get_base_dir()
	var mkdir_err := DirAccess.make_dir_recursive_absolute(dir_path)
	if mkdir_err != OK and mkdir_err != ERR_ALREADY_EXISTS:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
			"Failed to create directory: %s (error %d)" % [dir_path, mkdir_err]
		)

	var theme := Theme.new()
	var save_err := ResourceSaver.save(theme, path)
	if save_err != OK:
		return McpErrorCodes.make(
			McpErrorCodes.INTERNAL_ERROR,
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


func set_constant(params: Dictionary) -> Dictionary:
	return _set_scalar(params, "constant", func(theme, name, cls): return theme.get_constant(name, cls),
		func(theme, name, cls, val): theme.set_constant(name, cls, int(val)),
		func(theme, name, cls): theme.clear_constant(name, cls),
		func(theme, name, cls): return theme.has_constant(name, cls),
		func(v): return int(v))


func set_font_size(params: Dictionary) -> Dictionary:
	return _set_scalar(params, "font_size", func(theme, name, cls): return theme.get_font_size(name, cls),
		func(theme, name, cls, val): theme.set_font_size(name, cls, int(val)),
		func(theme, name, cls): theme.clear_font_size(name, cls),
		func(theme, name, cls): return theme.has_font_size(name, cls),
		func(v): return int(v))


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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: class_name")

	var name: String = params.get("name", "")
	if name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: name")

	if not "value" in params:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: value")

	var raw_value = params.get("value")
	if raw_value == null:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid %s value: null (pass a concrete value; use the appropriate clear command to remove a slot)" % kind
		)
	var parsed = parser.call(raw_value)
	if parsed == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
			"Invalid %s value: %s (%s)" % [kind, raw_value, _COLOR_HINT])

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
	ResourceSaver.save(theme, theme_path)


func _clear_scalar(theme_path: String, clearer: Callable, name: String, class_name_param: String) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	clearer.call(theme, name, class_name_param)
	ResourceSaver.save(theme, theme_path)


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
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: class_name")

	var name: String = params.get("name", "")
	if name.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: name")

	var sb := StyleBoxFlat.new()
	if params.has("bg_color"):
		var bg := _parse_color(params.bg_color)
		if bg == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Invalid bg_color: %s (%s)" % [str(params.bg_color), _COLOR_HINT])
		sb.bg_color = bg
	if params.has("border_color"):
		var bc := _parse_color(params.border_color)
		if bc == null:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Invalid border_color: %s (%s)" % [str(params.border_color), _COLOR_HINT])
		sb.border_color = bc

	# border: {all, top, bottom, left, right} — int widths
	if params.has("border"):
		var err := _apply_sides(sb, params.border, "border",
			["top", "bottom", "left", "right"],
			"border_width_",
			TYPE_INT)
		if err != "":
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, err)

	# corners: {all, top_left, top_right, bottom_left, bottom_right} — int radii
	if params.has("corners"):
		var err2 := _apply_sides(sb, params.corners, "corners",
			["top_left", "top_right", "bottom_left", "bottom_right"],
			"corner_radius_",
			TYPE_INT)
		if err2 != "":
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, err2)

	# margins: {all, top, bottom, left, right} — float padding
	if params.has("margins"):
		var err3 := _apply_sides(sb, params.margins, "margins",
			["top", "bottom", "left", "right"],
			"content_margin_",
			TYPE_FLOAT)
		if err3 != "":
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, err3)

	# shadow: {color, size, offset_x, offset_y}
	if params.has("shadow"):
		if typeof(params.shadow) != TYPE_DICTIONARY:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "'shadow' must be a dict with color/size/offset_x/offset_y")
		var shadow: Dictionary = params.shadow
		var allowed_shadow_keys := {"color": true, "size": true, "offset_x": true, "offset_y": true}
		for k in shadow.keys():
			if not allowed_shadow_keys.has(k):
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
					"Unknown key in 'shadow': %s (valid: color, size, offset_x, offset_y)" % k)
		if shadow.has("color"):
			var sc := _parse_color(shadow.color)
			if sc == null:
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS,
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

	var had_before := theme.has_stylebox(name, class_name_param)
	var before_sb: StyleBox = theme.get_stylebox(name, class_name_param) if had_before else null

	_undo_redo.create_action("MCP: Theme set stylebox %s/%s" % [class_name_param, name])
	_undo_redo.add_do_method(self, "_apply_stylebox", theme_path, name, class_name_param, sb)
	if had_before:
		_undo_redo.add_undo_method(self, "_apply_stylebox", theme_path, name, class_name_param, before_sb)
	else:
		_undo_redo.add_undo_method(self, "_clear_stylebox", theme_path, name, class_name_param)
	_undo_redo.commit_action()

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
	ResourceSaver.save(theme, theme_path)


func _clear_stylebox(theme_path: String, name: String, class_name_param: String) -> void:
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null:
		push_warning("MCP: Failed to load theme for undo/redo: %s" % theme_path)
		return
	theme.clear_stylebox(name, class_name_param)
	ResourceSaver.save(theme, theme_path)


# ============================================================================
# theme_apply — assign a theme to a Control
# ============================================================================

func apply_theme(params: Dictionary) -> Dictionary:
	var node_path: String = params.get("node_path", "")
	if node_path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: node_path")

	var theme_path: String = params.get("theme_path", "")
	var theme: Theme = null
	if not theme_path.is_empty():
		var path_err := _validate_res_path(theme_path, ".tres")
		if path_err != null:
			return path_err
		if not ResourceLoader.exists(theme_path):
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Theme not found: %s" % theme_path)
		theme = ResourceLoader.load(theme_path)
		if theme == null or not theme is Theme:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Theme" % theme_path)

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var node := ScenePath.resolve(node_path, scene_root)
	if node == null:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Node not found: %s" % node_path)
	if not node is Control and not node is Window:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
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
	var err := _validate_res_path(theme_path, ".tres")
	if err != null:
		return err
	if not ResourceLoader.exists(theme_path):
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Theme not found: %s" % theme_path)
	var theme: Theme = ResourceLoader.load(theme_path)
	if theme == null or not theme is Theme:
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Resource at %s is not a Theme" % theme_path)
	return {"theme": theme, "path": theme_path}


static func _validate_res_path(path: String, required_suffix: String, param_name: String = "theme_path") -> Variant:
	if path.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Missing required param: %s" % param_name)
	if not path.begins_with("res://"):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s must start with res:// (got %s)" % [param_name, path]
		)
	if not path.ends_with(required_suffix):
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"%s must end with %s (got %s)" % [param_name, required_suffix, path]
		)
	return null


## Parse a color from Color, "#rrggbb", "#rrggbbaa", named (red/blue/...) or dict.
## Returns null if the input cannot be parsed.
static func _parse_color(value: Variant) -> Variant:
	if value is Color:
		return value
	if value is String:
		var s: String = value
		# Color.from_string returns the default on parse failure, so call it twice
		# with distinct sentinels — if both agree, parsing succeeded.
		var sentinel_a := Color(0, 0, 0, 0)
		var sentinel_b := Color(1, 1, 1, 1)
		var a := Color.from_string(s, sentinel_a)
		var b := Color.from_string(s, sentinel_b)
		if a != b:
			return null
		return a
	if value is Dictionary:
		var d: Dictionary = value
		if d.has("r") and d.has("g") and d.has("b"):
			return Color(float(d.r), float(d.g), float(d.b), float(d.get("a", 1.0)))
	return null


static func _serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	if value is Color:
		return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
	if value is Vector2:
		return {"x": value.x, "y": value.y}
	return value
