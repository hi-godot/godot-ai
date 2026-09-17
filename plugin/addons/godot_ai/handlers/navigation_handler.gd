@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const VariantSerializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")

## Navigation authoring for 2D and 3D: regions + navmesh/polygon configuration
## and baking, agents, obstacles, and path queries.
##
## Every op is dimension-aware — the same params serve NavigationRegion3D /
## NavigationAgent3D / NavigationMesh and their 2D counterparts, selected by
## `dimension` ("3d" default) or inferred from an existing node's class.

const _CLASSES := {
	"2d": {
		"region": "NavigationRegion2D",
		"agent": "NavigationAgent2D",
		"obstacle": "NavigationObstacle2D",
		"mesh": "NavigationPolygon",
	},
	"3d": {
		"region": "NavigationRegion3D",
		"agent": "NavigationAgent3D",
		"obstacle": "NavigationObstacle3D",
		"mesh": "NavigationMesh",
	},
}

## Curated settable vocabulary per dimension. Class applicability is still
## checked against the object's own property list, so a 2D-only name on a 3D
## resource reports PROPERTY_NOT_ON_CLASS rather than being silently stored.
const _MESH_PROPERTIES := {
	"3d": [
		"agent_radius", "agent_height", "agent_max_climb", "agent_max_slope",
		"cell_size", "cell_height", "border_size",
		"region_min_size", "region_merge_size",
		"edge_max_length", "edge_max_error",
		"detail_sample_distance", "detail_sample_max_error",
		"geometry_collision_mask", "vertices_per_polygon",
		"geometry_parsed_geometry_type", "geometry_source_geometry_mode",
		"geometry_source_group_name",
	],
	"2d": [
		"agent_radius", "cell_size", "border_size",
		"parsed_collision_mask", "parsed_geometry_type",
		"source_geometry_mode", "source_geometry_group_name",
	],
}

const _AGENT_PROPERTIES := {
	"3d": [
		"radius", "height", "max_speed",
		"path_desired_distance", "target_desired_distance", "path_max_distance",
		"avoidance_enabled", "navigation_layers", "simplify_path", "debug_enabled",
	],
	"2d": [
		"radius", "max_speed",
		"path_desired_distance", "target_desired_distance", "path_max_distance",
		"avoidance_enabled", "navigation_layers", "simplify_path", "debug_enabled",
	],
}

const _OBSTACLE_PROPERTIES := {
	"3d": ["radius", "height", "avoidance_enabled"],
	"2d": ["radius", "avoidance_enabled"],
}

## Enum-by-name maps for the source-geometry selectors (identical values in
## both dimensions).
const _PARSED_GEOMETRY_TYPES := {
	"mesh_instances": 0,
	"static_colliders": 1,
	"both": 2,
}
const _SOURCE_GEOMETRY_MODES := {
	"root_children": 0,
	"groups_with_children": 1,
	"groups_explicit": 2,
}

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


# ============================================================================
# navigation_region_create
# ============================================================================

## Create a NavigationRegion2D/3D with a fresh NavigationPolygon/NavigationMesh
## attached, as one undo action.
func region_create(params: Dictionary) -> Dictionary:
	var dimension_result := _resolve_dimension(params)
	if dimension_result.has("error"):
		return dimension_result
	var dimension: String = dimension_result.dimension

	var scene_check := McpNodeValidator.require_scene_or_error(params.get("scene_file", ""))
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.scene_root
	var parent_result := _resolve_parent(params.get("parent_path", ""), scene_root)
	if parent_result.has("error"):
		return parent_result
	var parent: Node = parent_result.parent

	var region := ClassDB.instantiate(str(_CLASSES[dimension].region))
	if region == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to instantiate %s" % _CLASSES[dimension].region)
	var node_name: String = params.get("name", "")
	region.name = node_name if not node_name.is_empty() else str(_CLASSES[dimension].region)

	var mesh := ClassDB.instantiate(str(_CLASSES[dimension].mesh))
	if mesh == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to instantiate %s" % _CLASSES[dimension].mesh)
	if dimension == "3d":
		region.navigation_mesh = mesh
	else:
		region.navigation_polygon = mesh

	_undo_redo.create_action("MCP: Create %s '%s'" % [_CLASSES[dimension].region, region.name])
	_undo_redo.add_do_method(parent, "add_child", region, true)
	_undo_redo.add_do_method(region, "set_owner", scene_root)
	_undo_redo.add_do_reference(region)
	_undo_redo.add_do_reference(mesh)
	_undo_redo.add_undo_method(parent, "remove_child", region)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": McpScenePath.from_node(region, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
			"class": region.get_class(),
			"dimension": dimension,
			"mesh_class": mesh.get_class(),
			"undoable": true,
		}
	}


# ============================================================================
# navigation_mesh_configure
# ============================================================================

## Set navigation mesh / polygon parameters in one undo action.
func mesh_configure(params: Dictionary) -> Dictionary:
	var resolved := _resolve_navigation_node(params, "region")
	if resolved.has("error"):
		return resolved
	var region: Node = resolved.node
	var dimension: String = resolved.dimension
	var mesh: Resource = _get_region_mesh(region, dimension)
	if mesh == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND,
			"%s has no %s resource" % [resolved.path, _CLASSES[dimension].mesh])

	var applied := {}
	var previous := {}
	for key in params:
		if key == "path" or key == "scene_file" or key.begins_with("_"):
			continue
		if not (_MESH_PROPERTIES[dimension] as Array).has(key):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Unknown mesh property '%s'. Settable: %s" % [key, ", ".join(_MESH_PROPERTIES[dimension])])
		var prop_type := _property_type(mesh, key)
		if prop_type == TYPE_NIL:
			return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
				"%s has no '%s' property (class %s)" % [resolved.path, key, mesh.get_class()])
		var coerced := _coerce_mesh_value(params[key], prop_type, key)
		if coerced.has("error"):
			return coerced
		applied[key] = coerced.ok
		previous[key] = mesh.get(key)

	if applied.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
			"Provide at least one property to set. Settable: %s" % ", ".join(_MESH_PROPERTIES[dimension]))

	_undo_redo.create_action("MCP: Configure navigation mesh on %s" % region.name)
	for key in applied:
		_undo_redo.add_do_property(mesh, key, applied[key])
		_undo_redo.add_undo_property(mesh, key, previous[key])
	_undo_redo.commit_action()

	var applied_out := {}
	var previous_out := {}
	for key in applied:
		applied_out[key] = VariantSerializer.serialize(applied[key])
		previous_out[key] = VariantSerializer.serialize(previous[key])

	return {
		"data": {
			"path": resolved.path,
			"mesh_class": mesh.get_class(),
			"applied": applied_out,
			"previous": previous_out,
			"undoable": true,
		}
	}


# ============================================================================
# navigation_bake
# ============================================================================

## Bake a region's navigation mesh/polygon synchronously from its source
## geometry and force the server map to sync, so a path query right after the
## call sees the baked region. Undo restores the exact pre-bake resource.
func bake(params: Dictionary) -> Dictionary:
	var resolved := _resolve_navigation_node(params, "region")
	if resolved.has("error"):
		return resolved
	var region: Node = resolved.node
	var dimension: String = resolved.dimension
	var original: Resource = _get_region_mesh(region, dimension)
	if original == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND,
			"%s has no %s resource" % [resolved.path, _CLASSES[dimension].mesh])

	_undo_redo.create_action("MCP: Bake navigation on %s" % region.name)
	## `_do_bake` bakes into a duplicate, so redo never mutates `original` —
	## the resource this action's undo method restores.
	_undo_redo.add_do_method(self, "_do_bake", region, dimension, original)
	_undo_redo.add_undo_reference(original)
	if dimension == "3d":
		_undo_redo.add_undo_method(region, "set_navigation_mesh", original)
	else:
		_undo_redo.add_undo_method(region, "set_navigation_polygon", original)
	_undo_redo.commit_action()

	var baked: Resource = _get_region_mesh(region, dimension)
	return {
		"data": {
			"path": resolved.path,
			"mesh_class": baked.get_class() if baked != null else "",
			"polygon_count": int(baked.call("get_polygon_count")) if baked != null else 0,
			"vertex_count": int(baked.call("get_vertices").size()) if baked != null else 0,
			"undoable": true,
		}
	}


# ============================================================================
# navigation_agent_create / navigation_agent_configure
# ============================================================================

func agent_create(params: Dictionary) -> Dictionary:
	return _create_navigation_node(params, "agent")


## Configure a NavigationAgent2D/3D in one undo action.
func agent_configure(params: Dictionary) -> Dictionary:
	return _configure_navigation_node(params, "agent")


# ============================================================================
# navigation_obstacle_create / navigation_obstacle_configure
# ============================================================================

func obstacle_create(params: Dictionary) -> Dictionary:
	return _create_navigation_node(params, "obstacle")


## Configure a NavigationObstacle2D/3D in one undo action.
func obstacle_configure(params: Dictionary) -> Dictionary:
	return _configure_navigation_node(params, "obstacle")


# ============================================================================
# navigation_path_get
# ============================================================================

## Query a path on the edited scene's navigation map. Read-only: it syncs the
## server map first, then asks the map for a path between two world points.
func path_get(params: Dictionary) -> Dictionary:
	var dimension_result := _resolve_dimension(params)
	if dimension_result.has("error"):
		return dimension_result
	var dimension: String = dimension_result.dimension

	var from := _coerce_vector(params.get("from_point", null), dimension, "from_point")
	if from.has("error"):
		return from
	var to := _coerce_vector(params.get("to_point", null), dimension, "to_point")
	if to.has("error"):
		return to
	var optimize := bool(params.get("optimize", true))
	var navigation_layers := int(params.get("navigation_layers", 1))

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "No edited scene open")

	var map_result := _resolve_map(scene_root, dimension)
	if map_result.has("error"):
		return map_result
	var map: RID = map_result.map

	var points: Array = []
	if dimension == "3d":
		_force_map_sync_3d(map)
		for point in NavigationServer3D.map_get_path(map, from.ok, to.ok, optimize, navigation_layers):
			points.append(VariantSerializer.serialize(point))
	else:
		_force_map_sync_2d(map)
		for point in NavigationServer2D.map_get_path(map, from.ok, to.ok, optimize, navigation_layers):
			points.append(VariantSerializer.serialize(point))

	return {
		"data": {
			"dimension": dimension,
			"from_point": VariantSerializer.serialize(from.ok),
			"to_point": VariantSerializer.serialize(to.ok),
			"optimize": optimize,
			"navigation_layers": navigation_layers,
			"point_count": points.size(),
			"points": points,
		}
	}


# ============================================================================
# Helpers — creation / configuration
# ============================================================================

func _create_navigation_node(params: Dictionary, kind: String) -> Dictionary:
	var dimension_result := _resolve_dimension(params)
	if dimension_result.has("error"):
		return dimension_result
	var dimension: String = dimension_result.dimension

	var scene_check := McpNodeValidator.require_scene_or_error(params.get("scene_file", ""))
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.scene_root
	var parent_result := _resolve_parent(params.get("parent_path", ""), scene_root)
	if parent_result.has("error"):
		return parent_result
	var parent: Node = parent_result.parent

	var node := ClassDB.instantiate(str(_CLASSES[dimension][kind]))
	if node == null:
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to instantiate %s" % _CLASSES[dimension][kind])
	var node_name: String = params.get("name", "")
	node.name = node_name if not node_name.is_empty() else str(_CLASSES[dimension][kind])

	_undo_redo.create_action("MCP: Create %s '%s'" % [_CLASSES[dimension][kind], node.name])
	_undo_redo.add_do_method(parent, "add_child", node, true)
	_undo_redo.add_do_method(node, "set_owner", scene_root)
	_undo_redo.add_do_reference(node)
	_undo_redo.add_undo_method(parent, "remove_child", node)
	_undo_redo.commit_action()

	return {
		"data": {
			"path": McpScenePath.from_node(node, scene_root),
			"parent_path": McpScenePath.from_node(parent, scene_root),
			"class": node.get_class(),
			"dimension": dimension,
			"undoable": true,
		}
	}


func _configure_navigation_node(params: Dictionary, kind: String) -> Dictionary:
	var resolved := _resolve_navigation_node(params, kind)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var dimension: String = resolved.dimension
	var allowed: Array = _AGENT_PROPERTIES[dimension] if kind == "agent" else _OBSTACLE_PROPERTIES[dimension]

	var applied := {}
	var previous := {}
	for key in params:
		if key == "path" or key == "scene_file" or key.begins_with("_"):
			continue
		if not allowed.has(key):
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Unknown %s property '%s'. Settable: %s" % [kind, key, ", ".join(allowed)])
		var prop_type := _property_type(node, key)
		if prop_type == TYPE_NIL:
			return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
				"%s has no '%s' property (class %s)" % [resolved.path, key, node.get_class()])
		var coerced := _coerce_mesh_value(params[key], prop_type, key)
		if coerced.has("error"):
			return coerced
		applied[key] = coerced.ok
		previous[key] = node.get(key)

	if applied.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM,
			"Provide at least one property to set. Settable: %s" % ", ".join(allowed))

	_undo_redo.create_action("MCP: Configure %s on %s" % [kind, node.name])
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


## The map a path query should run against: the first navigation region of
## that dimension in the edited scene (that is the map holding the geometry),
## falling back to the scene root's world map. Resolving from a region keeps
## 2D queries working in a 3D-rooted scene and vice versa.
static func _resolve_map(scene_root: Node, dimension: String) -> Dictionary:
	var region := _find_navigation_region(scene_root, dimension)
	if region != null:
		var region_map: RID = region.call("get_navigation_map")
		if region_map.is_valid():
			return {"map": region_map}
	var world_method := "get_world_3d" if dimension == "3d" else "get_world_2d"
	if scene_root.has_method(world_method):
		var world_map: RID = scene_root.call(world_method).navigation_map
		if world_map.is_valid():
			return {"map": world_map}
	return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND,
		"No %s navigation map found in the edited scene" % dimension.to_upper())


static func _find_navigation_region(root: Node, dimension: String) -> Node:
	for child in root.get_children():
		if dimension == "3d" and child is NavigationRegion3D:
			return child
		if dimension == "2d" and child is NavigationRegion2D:
			return child
		var found := _find_navigation_region(child, dimension)
		if found != null:
			return found
	return null


# ============================================================================
# Helpers — bake
# ============================================================================

## Bake `original` into a fresh duplicate and install it. Baking in place
## would mutate the resource the undo action restores, so a second undo after
## a redo could no longer reach the pre-bake state.
func _do_bake(region: Node, dimension: String, original: Resource) -> void:
	if original == null:
		return
	var working: Resource = original.duplicate()
	if dimension == "3d":
		region.call("set_navigation_mesh", working)
		region.call("bake_navigation_mesh", false)
		var rid: RID = region.call("get_region_rid")
		if rid.is_valid():
			## Push the baked resource to the server explicitly: the region's
			## own change signal alone can leave the server map with the
			## pre-bake (empty) mesh until the next physics sync.
			NavigationServer3D.region_set_navigation_mesh(rid, working)
			_force_map_sync_3d(region.call("get_navigation_map"))
	else:
		region.call("set_navigation_polygon", working)
		region.call("bake_navigation_polygon", false)
		var rid_2d: RID = region.call("get_region_rid")
		if rid_2d.is_valid():
			NavigationServer2D.region_set_navigation_polygon(rid_2d, working)
			_force_map_sync_2d(region.call("get_navigation_map"))


## Sync a 3D map immediately. Godot 4.7's navigation server iterates maps
## asynchronously by default, and `map_force_update` is documented as
## unsupported in that mode — turn async iterations off for the forced sync,
## then restore the previous setting.
static func _force_map_sync_3d(map: RID) -> void:
	if not map.is_valid():
		return
	var was_async := NavigationServer3D.map_get_use_async_iterations(map)
	if was_async:
		NavigationServer3D.map_set_use_async_iterations(map, false)
	NavigationServer3D.map_force_update(map)
	if was_async:
		NavigationServer3D.map_set_use_async_iterations(map, true)


static func _force_map_sync_2d(map: RID) -> void:
	if not map.is_valid():
		return
	var was_async := NavigationServer2D.map_get_use_async_iterations(map)
	if was_async:
		NavigationServer2D.map_set_use_async_iterations(map, false)
	NavigationServer2D.map_force_update(map)
	if was_async:
		NavigationServer2D.map_set_use_async_iterations(map, true)


# ============================================================================
# Helpers — resolution
# ============================================================================

static func _resolve_dimension(params: Dictionary) -> Dictionary:
	var dimension: String = params.get("dimension", "3d")
	if dimension != "2d" and dimension != "3d":
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Invalid dimension '%s'. Valid: 2d, 3d" % dimension)
	return {"dimension": dimension}


func _resolve_parent(parent_path: String, scene_root: Node) -> Dictionary:
	if parent_path.is_empty():
		return {"parent": scene_root}
	var parent := McpScenePath.resolve(parent_path, scene_root)
	if parent == null:
		return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
			McpScenePath.format_parent_error(parent_path, scene_root))
	return {"parent": parent}


## Resolve `path` to a navigation node of `kind` and infer its dimension from
## the class. Success shape: `{node, dimension, path}`.
func _resolve_navigation_node(params: Dictionary, kind: String) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(
		params.get("path", ""), "path", params.get("scene_file", "")
	)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var dimension := ""
	if node is NavigationRegion2D or node is NavigationAgent2D or node is NavigationObstacle2D:
		dimension = "2d"
	elif node is NavigationRegion3D or node is NavigationAgent3D or node is NavigationObstacle3D:
		dimension = "3d"
	else:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node at %s is %s — expected a navigation region, agent, or obstacle" % [resolved.path, node.get_class()])
	var expected: String = _CLASSES[dimension][kind]
	if not _is_a_class(node, expected):
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node at %s is %s — expected a %s" % [resolved.path, node.get_class(), expected])
	return {
		"node": node,
		"dimension": dimension,
		"path": McpScenePath.from_node(node, resolved.scene_root),
	}


## Exact class or subclass check. `ClassDB.is_parent_class` is strict, so an
## exact-class node would otherwise be rejected.
static func _is_a_class(node: Node, expected: String) -> bool:
	return node.get_class() == expected or ClassDB.is_parent_class(node.get_class(), expected)


static func _get_region_mesh(region: Node, dimension: String) -> Resource:
	if dimension == "3d":
		return region.get("navigation_mesh")
	return region.get("navigation_polygon")


## Declared Variant type of `prop` on `object`, or TYPE_NIL when absent.
static func _property_type(object: Object, prop: String) -> int:
	for entry in object.get_property_list():
		if entry.name == prop:
			return int(entry.get("type", TYPE_NIL))
	return TYPE_NIL


# ============================================================================
# Helpers — value coercion
# ============================================================================

## Coerce a mesh/agent/obstacle property to its declared type, with
## enum-by-name support for the source-geometry selectors.
static func _coerce_mesh_value(raw: Variant, prop_type: int, key: String) -> Dictionary:
	if prop_type == TYPE_INT and raw is String:
		## Enum names are only accepted for the property that owns the
		## vocabulary: `vertices_per_polygon: "both"` must not silently store 2.
		var enum_map := _enum_map_for_property(key)
		if not enum_map.is_empty():
			if enum_map.has(raw):
				return {"ok": int(enum_map[raw])}
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Invalid '%s' value '%s'. Valid names: %s" % [key, raw, ", ".join(enum_map.keys())])
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Cannot set '%s' to %s (expected %s)" % [key, type_string(typeof(raw)), type_string(prop_type)])
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
		TYPE_STRING:
			if raw is String:
				return {"ok": raw}
	return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
		"Cannot set '%s' to %s (expected %s)" % [key, type_string(typeof(raw)), type_string(prop_type)])


## The enum-name vocabulary a property accepts, or an empty dict for plain
## integer properties. The 2D and 3D source-geometry selectors share their
## tables because the enum values are identical.
static func _enum_map_for_property(key: String) -> Dictionary:
	match key:
		"geometry_parsed_geometry_type", "parsed_geometry_type":
			return _PARSED_GEOMETRY_TYPES
		"geometry_source_geometry_mode", "source_geometry_mode":
			return _SOURCE_GEOMETRY_MODES
	return {}


## Parse a world point for path queries from {x,y[,z]} / [x,y[,z]].
static func _coerce_vector(raw: Variant, dimension: String, param_name: String) -> Dictionary:
	var parsed: Variant = null
	if dimension == "3d":
		parsed = McpJsonValues.parse_vector3(raw)
	else:
		parsed = McpJsonValues.parse_vector2(raw)
	if parsed == null:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"'%s' must be a %s point ({x,y%s} or [x,y%s])" % [
				param_name, dimension.to_upper(), ",z" if dimension == "3d" else "", ",z" if dimension == "3d" else ""
			])
	return {"ok": parsed}
