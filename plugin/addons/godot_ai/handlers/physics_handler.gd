@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const VariantSerializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")

## Physics body configuration plus collision layer/mask helpers.
##
## `body_configure` writes the class-appropriate subset of a body's or area's
## physics properties as one undo action. `collision_layer` / `collision_mask`
## accept either a bitmask int or an array of the project's layer names, which
## `layers_get` / `layers_set` read and write
## (`layer_names/{2d,3d}_physics/layer_N`).
##
## The settable vocabulary is curated on purpose: this op configures existing
## bodies, it is not a second generic `node_set_property`. Class applicability
## is still checked against the node's own property list, so `mass` on a
## StaticBody reports PROPERTY_NOT_ON_CLASS rather than being silently stored.

## The only properties `body_configure` may write.
const _SETTABLE := [
	"collision_layer",
	"collision_mask",
	"gravity",
	"gravity_scale",
	"mass",
	"linear_damp",
	"angular_damp",
	"continuous_cd",
	"freeze",
	"priority",
	"monitoring",
	"monitorable",
	"physics_material_override",
]

const _LAYER_NAMES_PREFIX := "layer_names/%s_physics/layer_"
const _LAYER_COUNT := 32

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# physics_body_get
# ============================================================================

func body_get(params: Dictionary) -> Dictionary:
	var resolved := _resolve_body(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var dimension: String = resolved.dimension

	var config := {}
	for key in _SETTABLE:
		if _property_type(node, key) == TYPE_NIL:
			continue
		config[key] = VariantSerializer.serialize(node.get(key))

	var data := {
		"path": resolved.path,
		"class": node.get_class(),
		"dimension": dimension,
		"config": config,
	}
	if _property_type(node, "collision_layer") != TYPE_NIL:
		data["collision_layer_names"] = _bits_to_names(int(node.get("collision_layer")), dimension)
		data["collision_mask_names"] = _bits_to_names(int(node.get("collision_mask")), dimension)
	return {"data": data}


# ============================================================================
# physics_body_configure
# ============================================================================

func body_configure(params: Dictionary) -> Dictionary:
	var resolved := _resolve_body(params)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var dimension: String = resolved.dimension

	var applied := {}
	var previous := {}
	for key in params:
		if key == "path" or key == "scene_file" or key.begins_with("_"):
			## `_`-prefixed keys are dispatcher-internal (e.g. `_request_id`).
			continue
		if not _SETTABLE.has(key):
			return ErrorCodes.make(
				ErrorCodes.VALUE_OUT_OF_RANGE,
				"Unknown property '%s'. Settable: %s" % [key, ", ".join(_SETTABLE)],
			)
		if _property_type(node, key) == TYPE_NIL:
			return ErrorCodes.make(
				ErrorCodes.PROPERTY_NOT_ON_CLASS,
				"%s has no '%s' property (class %s)" % [resolved.path, key, node.get_class()],
			)
		var raw: Variant = params[key]
		var coerced: Dictionary
		if key == "collision_layer" or key == "collision_mask":
			coerced = _coerce_layers(raw, dimension)
		elif key == "physics_material_override":
			coerced = _coerce_physics_material(raw)
		else:
			coerced = _coerce_scalar(raw, _property_type(node, key), key)
		if coerced.has("error"):
			return coerced
		applied[key] = coerced.ok
		previous[key] = node.get(key)

	if applied.is_empty():
		return ErrorCodes.make(
			ErrorCodes.MISSING_REQUIRED_PARAM,
			"Provide at least one property to set. Settable: %s" % ", ".join(_SETTABLE),
		)

	_undo_redo.create_action("MCP: Configure physics body %s" % node.name)
	for key in applied:
		_undo_redo.add_do_property(node, key, applied[key])
		_undo_redo.add_undo_property(node, key, previous[key])
	_undo_redo.commit_action()

	var applied_out := {}
	var previous_out := {}
	for key in applied:
		applied_out[key] = VariantSerializer.serialize(applied[key])
		previous_out[key] = VariantSerializer.serialize(previous[key])

	return {
		"data": {
			"path": resolved.path,
			"class": node.get_class(),
			"dimension": dimension,
			"applied": applied_out,
			"previous": previous_out,
			"undoable": true,
		}
	}


# ============================================================================
# physics_layers_get / physics_layers_set
# ============================================================================

func layers_get(params: Dictionary) -> Dictionary:
	var dimension_result := _resolve_dimension(params)
	if dimension_result.has("error"):
		return dimension_result
	var dimension: String = dimension_result.dimension

	var entries: Array[Dictionary] = []
	for index in range(1, _LAYER_COUNT + 1):
		var layer_name := _layer_name(dimension, index)
		if not layer_name.is_empty():
			entries.append({"index": index, "bit": 1 << (index - 1), "name": layer_name})
	return {"data": {"dimension": dimension, "layers": entries, "count": entries.size()}}


func layers_set(params: Dictionary) -> Dictionary:
	var dimension_result := _resolve_dimension(params)
	if dimension_result.has("error"):
		return dimension_result
	var dimension: String = dimension_result.dimension

	var layers: Variant = params.get("layers", null)
	if not layers is Dictionary:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"layers must be a dictionary of {layer_index: name}, got %s" % type_string(typeof(layers)),
		)
	var layer_dict: Dictionary = layers
	if layer_dict.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: layers")

	var updates: Array[Dictionary] = []
	var previous: Array[Dictionary] = []
	for raw_index in layer_dict:
		var index := int(str(raw_index))
		if index < 1 or index > _LAYER_COUNT:
			return ErrorCodes.make(
				ErrorCodes.VALUE_OUT_OF_RANGE,
				"Layer index %s is out of range (1-%d)" % [str(raw_index), _LAYER_COUNT],
			)
		var raw_name: Variant = layer_dict[raw_index]
		if not raw_name is String:
			return ErrorCodes.make(
				ErrorCodes.WRONG_TYPE,
				"Layer name must be a string, got %s" % type_string(typeof(raw_name)),
			)
		var key := _LAYER_NAMES_PREFIX % dimension + str(index)
		previous.append({"key": key, "name": str(ProjectSettings.get_setting(key, ""))})
		updates.append({"index": index, "key": key, "name": raw_name})

	## A name that lands on two indices cannot be resolved unambiguously by
	## body_configure's name arrays, so refuse the update before writing.
	var duplicate_error := _duplicate_layer_name_error(dimension, updates)
	if duplicate_error != null:
		return duplicate_error

	for update in updates:
		ProjectSettings.set_setting(str(update.key), str(update.name))
	var err := ProjectSettings.save()
	if err != OK:
		for entry in previous:
			ProjectSettings.set_setting(str(entry.key), str(entry.name))
		return ErrorCodes.make(
			ErrorCodes.INTERNAL_ERROR,
			"Failed to save project settings (error %d)" % err,
		)

	var applied: Array[Dictionary] = []
	for update in updates:
		var index := int(update.index)
		applied.append({"index": index, "bit": 1 << (index - 1), "name": str(update.name)})
	return {
		"data": {
			"dimension": dimension,
			"updated": applied,
			"undoable": false,
			"reason": "ProjectSettings layer names are saved to disk",
		}
	}


## The error to surface when applying `updates` would leave one non-empty
## layer name on more than one index, or null when the result is unique.
##
## Only names the call touches (the written names and whatever currently sits
## at the updated indices) are checked: a pre-existing duplicate elsewhere in
## project.godot must not block unrelated layer edits — `_coerce_layers`
## already refuses to resolve such a name. Because the check runs on the
## post-update state, moving a name between indices in one call is allowed.
static func _duplicate_layer_name_error(dimension: String, updates: Array[Dictionary]) -> Variant:
	var touched := {}
	for update in updates:
		touched[str(update.name)] = true
		var current := _layer_name(dimension, int(update.index))
		if not current.is_empty():
			touched[current] = true
	var final_names := {}
	for index in range(1, _LAYER_COUNT + 1):
		final_names[index] = _layer_name(dimension, index)
	for update in updates:
		final_names[int(update.index)] = str(update.name)
	var by_name := {}
	for index in final_names:
		var layer_name: String = final_names[index]
		if layer_name.is_empty() or not touched.has(layer_name):
			continue
		if not by_name.has(layer_name):
			by_name[layer_name] = []
		(by_name[layer_name] as Array).append(index)
	for layer_name in by_name:
		var indices: Array = by_name[layer_name]
		if indices.size() > 1:
			var labels: Array[String] = []
			for index in indices:
				labels.append(str(index))
			return ErrorCodes.make(
				ErrorCodes.VALUE_OUT_OF_RANGE,
				(
					"Layer name '%s' would be assigned to layers %s — names must be unique "
					+ "so collision_layer name arrays resolve to one bit"
				) % [layer_name, ", ".join(labels)],
			)
	return null


# ============================================================================
# Helpers — resolution
# ============================================================================

## Resolve `path` to a CollisionObject2D/3D and classify its dimension.
## Success shape: `{node, dimension, path}` (clean scene path) or an error.
func _resolve_body(params: Dictionary) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(
		params.get("path", ""), "path", params.get("scene_file", "")
	)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var dimension := ""
	if node is CollisionObject2D:
		dimension = "2d"
	elif node is CollisionObject3D:
		dimension = "3d"
	else:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			(
				"Node at %s is %s — must be a CollisionObject2D or CollisionObject3D "
				+ "(a physics body or area)"
			) % [resolved.path, node.get_class()],
		)
	return {
		"node": node,
		"dimension": dimension,
		"path": McpScenePath.from_node(node, resolved.scene_root),
	}


static func _resolve_dimension(params: Dictionary) -> Dictionary:
	var dimension: String = params.get("dimension", "3d")
	if dimension != "2d" and dimension != "3d":
		return ErrorCodes.make(
			ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid dimension '%s'. Valid: 2d, 3d" % dimension,
		)
	return {"dimension": dimension}


## Declared Variant type of `prop` on `node`, or TYPE_NIL when the node has
## no such property (the class-applicability check).
static func _property_type(node: Object, prop: String) -> int:
	for entry in node.get_property_list():
		if entry.name == prop:
			return int(entry.get("type", TYPE_NIL))
	return TYPE_NIL


# ============================================================================
# Helpers — value coercion
# ============================================================================

## `collision_layer` / `collision_mask`: a bitmask int, or an array of the
## project's layer names for that dimension. Unknown names fail with the
## currently defined set so the caller can fix the name or define it first.
static func _coerce_layers(raw: Variant, dimension: String) -> Dictionary:
	if raw is int or raw is float:
		var bits := int(raw)
		if bits < 0 or bits > 0xFFFFFFFF:
			return ErrorCodes.make(
				ErrorCodes.VALUE_OUT_OF_RANGE,
				"Layer bitmask %s is out of range (0-%d)" % [str(raw), 0xFFFFFFFF],
			)
		return {"ok": bits}
	if raw is Array:
		var known := _layer_name_index(dimension)
		var bits := 0
		for entry in raw:
			if not entry is String:
				return ErrorCodes.make(
					ErrorCodes.WRONG_TYPE,
					"Layer name entries must be strings, got %s" % type_string(typeof(entry)),
				)
			if not known.has(entry):
				var named := ", ".join(known.keys()) if not known.is_empty() else "(none defined)"
				return ErrorCodes.make(
					ErrorCodes.VALUE_OUT_OF_RANGE,
					(
						"Unknown %s physics layer name '%s'. Defined names: %s. "
						+ "Define names with physics_manage(op='layers_set')."
					) % [dimension, entry, named],
				)
			var indices: Array = known[entry]
			if indices.size() > 1:
				var labels: Array[String] = []
				for index in indices:
					labels.append(str(index))
				return ErrorCodes.make(
					ErrorCodes.VALUE_OUT_OF_RANGE,
					(
						"Layer name '%s' is ambiguous — it is assigned to layers %s. "
						+ "Make names unique with physics_manage(op='layers_set')."
					) % [entry, ", ".join(labels)],
				)
			bits |= 1 << (int(indices[0]) - 1)
		return {"ok": bits}
	return ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		(
			"collision_layer/collision_mask must be a bitmask int or an array of layer names, got %s"
		) % type_string(typeof(raw)),
	)


## Scalar properties: coerce to the property's declared type, or fail with
## both the received and the expected type named.
static func _coerce_scalar(raw: Variant, prop_type: int, key: String) -> Dictionary:
	match prop_type:
		TYPE_FLOAT:
			var parsed: Variant = McpJsonValues.parse_float(raw)
			if parsed != null:
				return {"ok": parsed}
		TYPE_INT:
			if raw is int or raw is float or raw is bool:
				return {"ok": int(raw)}
		TYPE_BOOL:
			if raw is bool or raw is int or raw is float:
				return {"ok": bool(raw)}
	return ErrorCodes.make(
		ErrorCodes.WRONG_TYPE,
		"Cannot set '%s' to %s (expected %s)" % [key, type_string(typeof(raw)), type_string(prop_type)],
	)


## `physics_material_override`: a loadable PhysicsMaterial path, or ""/null
## to clear the override.
static func _coerce_physics_material(raw: Variant) -> Dictionary:
	if raw == null or (raw is String and (raw as String).is_empty()):
		return {"ok": null}
	if not raw is String:
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			(
				"physics_material_override must be a res:// PhysicsMaterial path or \"\" to clear, got %s"
			) % type_string(typeof(raw)),
		)
	var path := raw as String
	var path_err = McpPathValidator.loadable_error(path, "physics_material_override")
	if path_err != null:
		return path_err
	if not ResourceLoader.exists(path):
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND, "PhysicsMaterial not found: %s" % path)
	var loaded := ResourceLoader.load(path)
	if loaded == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR, "Failed to load PhysicsMaterial: %s" % path)
	if not (loaded is PhysicsMaterial):
		return ErrorCodes.make(
			ErrorCodes.WRONG_TYPE,
			"Resource at %s is not a PhysicsMaterial (got %s)" % [path, loaded.get_class()],
		)
	return {"ok": loaded}


# ============================================================================
# Helpers — project layer names
# ============================================================================

static func _layer_name(dimension: String, index: int) -> String:
	return str(ProjectSettings.get_setting(_LAYER_NAMES_PREFIX % dimension + str(index), ""))


## `{layer_name: [layer_index, ...]}` for the named layers of one dimension.
## A list per name keeps pre-existing duplicates (project.godot edited by
## hand) visible, so `_coerce_layers` can refuse to guess which bit was meant.
static func _layer_name_index(dimension: String) -> Dictionary:
	var out := {}
	for index in range(1, _LAYER_COUNT + 1):
		var layer_name := _layer_name(dimension, index)
		if not layer_name.is_empty():
			if not out.has(layer_name):
				out[layer_name] = []
			(out[layer_name] as Array).append(index)
	return out


## Names of every bit set in `bits`, falling back to `layer_N` for unnamed
## layers so a raw bitmask still reads back actionably.
static func _bits_to_names(bits: int, dimension: String) -> Array[String]:
	var names: Array[String] = []
	for index in range(1, _LAYER_COUNT + 1):
		if bits & (1 << (index - 1)):
			var layer_name := _layer_name(dimension, index)
			names.append(layer_name if not layer_name.is_empty() else "layer_%d" % index)
	return names
