@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

## Creates procedural textures — GradientTexture2D (wrapping a Gradient)
## and NoiseTexture2D (wrapping a FastNoiseLite). Assigns to a node slot
## (undoable, bundles sub-resources) or saves to a .tres file.

const NodeHandler := preload("res://addons/godot_ai/handlers/node_handler.gd")

var _undo_redo: EditorUndoRedoManager
var _connection: McpConnection


func _init(undo_redo: EditorUndoRedoManager, connection: McpConnection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


const _FILL_MODES := {
	"linear": GradientTexture2D.FILL_LINEAR,
	"radial": GradientTexture2D.FILL_RADIAL,
	"square": GradientTexture2D.FILL_SQUARE,
}

const _NOISE_TYPES := {
	"simplex": FastNoiseLite.TYPE_SIMPLEX,
	"simplex_smooth": FastNoiseLite.TYPE_SIMPLEX_SMOOTH,
	"perlin": FastNoiseLite.TYPE_PERLIN,
	"cellular": FastNoiseLite.TYPE_CELLULAR,
	"value": FastNoiseLite.TYPE_VALUE,
	"value_cubic": FastNoiseLite.TYPE_VALUE_CUBIC,
}


# ============================================================================
# gradient_texture_create
# ============================================================================

func create_gradient_texture(params: Dictionary) -> Dictionary:
	var stops: Array = params.get("stops", [])
	var width: int = params.get("width", 256)
	var height: int = params.get("height", 1)
	var fill: String = params.get("fill", "linear")

	if stops.size() < 2:
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"gradient_texture_create requires at least 2 stops, got %d" % stops.size()
		)
	if not _FILL_MODES.has(fill):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid fill '%s'. Valid: %s" % [fill, ", ".join(_FILL_MODES.keys())]
		)

	var home_err := McpResourceIO.validate_home(params)
	if home_err != null:
		return home_err

	var gradient := Gradient.new()
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for i in range(stops.size()):
		var stop = stops[i]
		if not stop is Dictionary:
			return ErrorCodes.make(
				ErrorCodes.WRONG_TYPE,
				"stops[%d] must be a dict with 'offset' and 'color' keys" % i
			)
		if not stop.has("offset") or not stop.has("color"):
			return ErrorCodes.make(
				ErrorCodes.INVALID_PARAMS,
				"stops[%d] missing 'offset' or 'color' key" % i
			)
		offsets.append(float(stop["offset"]))
		var color_value = NodeHandler._coerce_value(stop["color"], TYPE_COLOR)
		var color_err := NodeHandler._check_coerced(color_value, TYPE_COLOR, "stops[%d].color" % i)
		if color_err != null:
			return color_err
		colors.append(color_value)
	gradient.offsets = offsets
	gradient.colors = colors

	var tex := GradientTexture2D.new()
	tex.gradient = gradient
	tex.width = width
	tex.height = height
	tex.fill = _FILL_MODES[fill]

	return _finalize(tex, [gradient], params, "Gradient texture", {
		"texture_class": "GradientTexture2D",
		"gradient_class": "Gradient",
		"stop_count": stops.size(),
		"fill": fill,
	})


# ============================================================================
# noise_texture_create
# ============================================================================

func create_noise_texture(params: Dictionary) -> Dictionary:
	var noise_type: String = params.get("noise_type", "simplex_smooth")
	var width: int = params.get("width", 512)
	var height: int = params.get("height", 512)
	var frequency: float = params.get("frequency", 0.01)
	var seed_value: int = params.get("seed", 0)
	var fractal_octaves: int = params.get("fractal_octaves", 0)  # 0 = leave default

	if not _NOISE_TYPES.has(noise_type):
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid noise_type '%s'. Valid: %s" % [noise_type, ", ".join(_NOISE_TYPES.keys())]
		)

	var home_err := McpResourceIO.validate_home(params)
	if home_err != null:
		return home_err

	var noise := FastNoiseLite.new()
	noise.noise_type = _NOISE_TYPES[noise_type]
	noise.frequency = frequency
	noise.seed = seed_value
	if fractal_octaves > 0:
		noise.fractal_octaves = fractal_octaves

	var tex := NoiseTexture2D.new()
	tex.noise = noise
	tex.width = width
	tex.height = height

	return _finalize(tex, [noise], params, "Noise texture", {
		"texture_class": "NoiseTexture2D",
		"noise_class": "FastNoiseLite",
		"noise_type": noise_type,
	})


# ============================================================================
# shared helpers
# ============================================================================

func _finalize(tex: Resource, sub_resources: Array, params: Dictionary, label: String, extra: Dictionary) -> Dictionary:
	var node_path: String = params.get("path", "")
	var property: String = params.get("property", "")
	var resource_path: String = params.get("resource_path", "")
	var overwrite: bool = params.get("overwrite", false)

	if not resource_path.is_empty():
		return McpResourceIO.save_to_disk(tex, resource_path, overwrite, label, extra, _connection)
	return _assign_texture(tex, sub_resources, node_path, property, label, extra)


func _assign_texture(tex: Resource, sub_resources: Array, node_path: String, property: String, label: String, extra: Dictionary) -> Dictionary:
	var _resolved := McpNodeValidator.resolve_or_error(node_path, "node_path")
	if _resolved.has("error"):
		return _resolved
	var node: Node = _resolved.node
	var scene_root: Node = _resolved.scene_root

	var found := false
	var prop_type: int = TYPE_NIL
	for prop in node.get_property_list():
		if prop.name == property:
			found = true
			prop_type = prop.get("type", TYPE_NIL)
			break
	if not found:
		return ErrorCodes.make(
			ErrorCodes.PROPERTY_NOT_ON_CLASS,
			"Property '%s' not found on %s" % [property, node.get_class()]
		)
	if prop_type != TYPE_NIL and prop_type != TYPE_OBJECT:
		return ErrorCodes.make(
			ErrorCodes.PROPERTY_NOT_ON_CLASS,
			"Property '%s' on %s is not an Object slot" % [property, node.get_class()]
		)

	var old_value = node.get(property)

	_undo_redo.create_action("MCP: Create %s for %s.%s" % [label, node.name, property])
	_undo_redo.add_do_property(node, property, tex)
	_undo_redo.add_undo_property(node, property, old_value)
	_undo_redo.add_do_reference(tex)
	for sub in sub_resources:
		_undo_redo.add_do_reference(sub)
	_undo_redo.commit_action()

	var data := {
		"path": node_path,
		"property": property,
		"undoable": true,
	}
	data.merge(extra)
	return {"data": data}


