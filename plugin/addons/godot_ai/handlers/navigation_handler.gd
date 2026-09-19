@tool
extends "res://addons/godot_ai/handlers/command_handler.gd"

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const VariantSerializer := preload("res://addons/godot_ai/utils/variant_serializer.gd")

## Navigation authoring for 2D and 3D: regions + navmesh/polygon configuration
## and baking, and path queries on an explicitly selected map.
##
## Every op is dimension-aware — the same params serve NavigationRegion3D /
## NavigationMesh and their 2D counterparts, selected by `dimension` ("3d"
## default) or inferred from an existing node's class.

const _CLASSES := {
	"2d": {
		"region": "NavigationRegion2D",
		"mesh": "NavigationPolygon",
	},
	"3d": {
		"region": "NavigationRegion3D",
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

## One deferred bake may spend this long across editor frames. The Python
## handler's timeout is this plus its transport margin (a source-shape test
## keeps the two together).
const _BAKE_DEFERRED_TIMEOUT_MS := 30000

var _undo_redo: EditorUndoRedoManager
var _connection


func _init(undo_redo: EditorUndoRedoManager, connection = null) -> void:
	_undo_redo = undo_redo
	_connection = connection


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
	var resolved := _resolve_region(params)
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

## Bake a region's navigation mesh/polygon and commit a scene-anchored swap
## between the retained pre-bake and baked resources.
##
## The bake runs on the region's own background thread (`bake_navigation_mesh(true)`);
## Godot still parses the source geometry on the main thread, but the Recast
## bake itself never blocks it. The op replies out-of-band (deferred) and is
## bounded by `_BAKE_DEFERRED_TIMEOUT_MS` with per-frame cancellation checks.
## Undo restores the exact pre-bake resource; redo restores the exact baked
## resource instead of re-baking current geometry.
func bake(params: Dictionary) -> Dictionary:
	var resolved := _resolve_region(params)
	if resolved.has("error"):
		return resolved
	var region: Node = resolved.node
	var dimension: String = resolved.dimension
	var before: Resource = _get_region_mesh(region, dimension)
	if before == null:
		return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND,
			"%s has no %s resource" % [resolved.path, _CLASSES[dimension].mesh])
	if bool(region.call("is_baking")):
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"%s is already baking a navigation mesh" % resolved.path)

	var request_id: String = params.get("_request_id", "")
	if _connection == null or request_id.is_empty():
		## The bake is threaded and answered out-of-band, so a direct caller
		## (batch_execute, unit tests) cannot wait for it without blocking the
		## editor's frame budget. Refuse instead of silently baking in place.
		return ErrorCodes.make(ErrorCodes.INVALID_PARAMS,
			"navigation_bake is deferred (threaded bake, bounded deadline); call "
			+ "navigation_manage(op='bake') directly - batch_execute cannot await it")

	var force_sync := bool(params.get("force_sync", true))
	var prepared := _begin_bake(region, dimension)
	if prepared.is_empty():
		return ErrorCodes.make(ErrorCodes.INTERNAL_ERROR,
			"Failed to prepare the %s bake" % _CLASSES[dimension].mesh)
	var job := _bake_job(
		region, dimension, resolved.scene_root, prepared.before, prepared.working,
		_undo_redo, _connection, request_id, force_sync
	)
	_bake_step(job)
	_drive_bake_job(job)

	return {
		"_deferred": true,
		"_deferred_timeout_ms": _BAKE_DEFERRED_TIMEOUT_MS,
	}


# ============================================================================
# navigation_path_get
# ============================================================================

## Query a path on an explicitly selected navigation map. Read-only: it never
## guesses a region and never changes the shared async-iteration policy unless
## `force_sync` asks it to.
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
	var force_sync := bool(params.get("force_sync", false))
	var region_path := String(params.get("region_path", ""))

	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "No edited scene open")

	var map_result := _resolve_query_map(
		scene_root, dimension, region_path, params.get("scene_file", "")
	)
	if map_result.has("error"):
		return map_result

	var points: Array = []
	if dimension == "3d":
		if force_sync:
			_force_map_sync_3d(map_result.map)
		for point in NavigationServer3D.map_get_path(map_result.map, from.ok, to.ok, optimize, navigation_layers):
			points.append(VariantSerializer.serialize(point))
	else:
		if force_sync:
			_force_map_sync_2d(map_result.map)
		for point in NavigationServer2D.map_get_path(map_result.map, from.ok, to.ok, optimize, navigation_layers):
			points.append(VariantSerializer.serialize(point))

	return {
		"data": {
			"dimension": dimension,
			"from_point": VariantSerializer.serialize(from.ok),
			"to_point": VariantSerializer.serialize(to.ok),
			"optimize": optimize,
			"navigation_layers": navigation_layers,
			"force_sync": force_sync,
			"region_path": map_result.region_path,
			"map_source": map_result.map_source,
			"point_count": points.size(),
			"points": points,
		}
	}


# ============================================================================
# Helpers — deferred bake
# ============================================================================

## Snapshot the pre-bake resource and install the working duplicate the
## threaded bake writes into. Returns `{}` when there is no mesh to bake.
## Baking in place would mutate the resource the undo action restores, so a
## second undo after a redo could no longer reach the pre-bake state.
static func _begin_bake(region: Node, dimension: String) -> Dictionary:
	var before: Resource = _get_region_mesh(region, dimension)
	if before == null:
		return {}
	var working: Resource = before.duplicate()
	if dimension == "3d":
		region.call("set_navigation_mesh", working)
	else:
		region.call("set_navigation_polygon", working)
	return {"before": before, "working": working}


## The whole bake request as a value the frame loop (or a test) advances with
## `_bake_step`. The bake itself runs on the region's own thread; every step
## only polls it and performs the bounded lifecycle/cancellation checks.
static func _bake_job(
	region: Node, dimension: String, scene_root: Node, before: Resource,
	working: Resource, undo_redo: EditorUndoRedoManager, connection, request_id: String,
	force_sync: bool,
) -> Dictionary:
	return {
		"region": region,
		"dimension": dimension,
		"scene_root": scene_root,
		"before": before,
		"working": working,
		"undo_redo": undo_redo,
		"connection": connection,
		"request_id": request_id,
		"force_sync": force_sync,
		"phase": "start",
		"started_ms": Time.get_ticks_msec(),
		"deadline_ms": _BAKE_DEFERRED_TIMEOUT_MS,
		"result": {},
	}


## Advance a bake job by one editor-frame check. Returns true once the job is
## resolved (committed, aborted, or abandoned); `job.result` holds the reply,
## or stays empty when the request was abandoned and nothing may be answered.
static func _bake_step(job: Dictionary) -> bool:
	if str(job.phase) == "done":
		return true
	var region: Node = job.region
	if not is_instance_valid(region) or not region.is_inside_tree():
		_bake_abort(job, ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
			"The navigation region went away while it was baking"))
		return true
	var connection = job.connection
	if connection != null and not _deferred_request_pending(connection, str(job.request_id)):
		## The dispatcher gave up on this request (timeout, client gone):
		## restore the pre-bake resource and answer nothing.
		_bake_restore(job)
		job.phase = "done"
		return true
	if Time.get_ticks_msec() - int(job.started_ms) > int(job.deadline_ms):
		_bake_abort(job, ErrorCodes.make(ErrorCodes.DEFERRED_TIMEOUT,
			"navigation_bake exceeded its %d ms budget" % int(job.deadline_ms)))
		return true
	if EditorInterface.get_edited_scene_root() != job.scene_root:
		_bake_abort(job, ErrorCodes.make(ErrorCodes.EDITED_SCENE_MISMATCH,
			"The edited scene changed while the navigation mesh was baking"))
		return true
	if str(job.phase) == "start":
		job.phase = "baking"
		if str(job.dimension) == "3d":
			region.call("bake_navigation_mesh", true)
		else:
			region.call("bake_navigation_polygon", true)
		return false
	if bool(region.call("is_baking")):
		return false
	## `is_baking()` is cleared by NavMeshGenerator3D::sync() only after the
	## worker finished and wrote the baked data, so the mesh is final here.
	_bake_commit(job)
	return true


## Push the baked resource to the server region and commit one scene-anchored
## swap action. Every do/undo target is the region node, so the action lands in
## the edited scene's history — a RefCounted handler target would select the
## global history and trip the editor's history-mismatch check.
static func _bake_commit(job: Dictionary) -> void:
	var region: Node = job.region
	var dimension: String = job.dimension
	var working: Resource = job.working
	var rid: RID = region.call("get_rid")
	if rid.is_valid():
		if dimension == "3d":
			NavigationServer3D.region_set_navigation_mesh(rid, working)
		else:
			NavigationServer2D.region_set_navigation_polygon(rid, working)
	if bool(job.force_sync):
		var map: RID = region.call("get_navigation_map")
		if dimension == "3d":
			_force_map_sync_3d(map)
		else:
			_force_map_sync_2d(map)

	var undo_redo: EditorUndoRedoManager = job.undo_redo
	undo_redo.create_action("MCP: Bake navigation on %s" % region.name)
	if dimension == "3d":
		undo_redo.add_do_method(region, "set_navigation_mesh", working)
		undo_redo.add_undo_method(region, "set_navigation_mesh", job.before)
	else:
		undo_redo.add_do_method(region, "set_navigation_polygon", working)
		undo_redo.add_undo_method(region, "set_navigation_polygon", job.before)
	## Both retained resources stay referenced by the action: the scene holds
	## only one of them at a time, the other must survive for undo/redo.
	undo_redo.add_do_reference(working)
	undo_redo.add_undo_reference(job.before)
	## The region already holds `working`, so record without re-running do.
	undo_redo.commit_action(false)

	var polygon_count := 0
	var vertex_count := 0
	if working != null:
		polygon_count = int(working.call("get_polygon_count"))
		vertex_count = int(working.call("get_vertices").size())
	job.result = {
		"data": {
			"path": McpScenePath.from_node(region, job.scene_root),
			"mesh_class": working.get_class() if working != null else "",
			"polygon_count": polygon_count,
			"vertex_count": vertex_count,
			"force_sync": bool(job.force_sync),
			"bake_settle": "settled",
			"undoable": true,
		}
	}
	job.phase = "done"


static func _bake_abort(job: Dictionary, error: Dictionary) -> void:
	_bake_restore(job)
	job.result = error
	job.phase = "done"


## Put the pre-bake resource back after an aborted bake. The region may have
## been freed meanwhile; only touch it when it is still a valid instance.
static func _bake_restore(job: Dictionary) -> void:
	var region: Node = job.region
	if not is_instance_valid(region):
		return
	if str(job.dimension) == "3d":
		region.call("set_navigation_mesh", job.before)
	else:
		region.call("set_navigation_polygon", job.before)


## Drive a bake job one editor frame at a time and reply when it ends.
## `static` is load-bearing: the coroutine must outlive this RefCounted
## handler, which can be freed mid-await by an editor_reload_plugin.
static func _drive_bake_job(job: Dictionary) -> void:
	var connection = job.connection
	if not is_instance_valid(connection):
		return
	var tree: SceneTree = connection.get_tree()
	if tree == null:
		return
	var work := ScriptWork.begin("navigation_bake")
	## The first yield lets the dispatcher register the deferred request before
	## any result or abort can be answered.
	await tree.process_frame
	while not _bake_step(job):
		await tree.process_frame
	ScriptWork.finish(work)
	if is_instance_valid(connection) and not job.result.is_empty():
		connection.send_deferred_response(str(job.request_id), job.result)


## Check that the connection and deferred dispatcher entry are both live.
static func _deferred_request_pending(connection, request_id: String) -> bool:
	if not is_instance_valid(connection):
		return false
	var dispatcher = connection.dispatcher
	return dispatcher == null or dispatcher.has_pending_deferred_response(request_id)


## Sync a 3D map immediately. Godot 4.7's navigation server iterates maps
## asynchronously by default, and `map_force_update` is documented as
## unsupported in that mode — turn async iterations off for the forced sync,
## then restore the previous setting. Only ever called when the caller asked
## for it (`force_sync`), never silently from a read.
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


## Resolve `path` to a navigation region and infer its dimension from the
## class. Success shape: `{node, dimension, path, scene_root}`.
func _resolve_region(params: Dictionary) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(
		params.get("path", ""), "path", params.get("scene_file", "")
	)
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	var dimension := ""
	if node is NavigationRegion2D:
		dimension = "2d"
	elif node is NavigationRegion3D:
		dimension = "3d"
	else:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node at %s is %s — expected a navigation region" % [resolved.path, node.get_class()])
	return {
		"node": node,
		"dimension": dimension,
		"path": McpScenePath.from_node(node, resolved.scene_root),
		"scene_root": resolved.scene_root,
	}


## The map a path query runs against: the explicitly named region's map, or
## the edited scene root's world map when no region is given. Never guesses
## the scene's "first" region — a scene can host several maps.
static func _resolve_query_map(
	scene_root: Node, dimension: String, region_path: String, scene_file: String
) -> Dictionary:
	if not region_path.is_empty():
		var resolved := McpNodeValidator.resolve_or_error(region_path, "region_path", scene_file)
		if resolved.has("error"):
			return resolved
		var node: Node = resolved.node
		var expected: String = _CLASSES[dimension].region
		if not _is_a_class(node, expected):
			return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
				"Node at %s is %s — expected a %s for a %s query"
				% [resolved.path, node.get_class(), expected, dimension.to_upper()])
		var region_map: RID = node.call("get_navigation_map")
		if not region_map.is_valid():
			return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND,
				"%s has no valid navigation map" % resolved.path)
		return {"map": region_map, "map_source": "region", "region_path": resolved.path}
	var world_method := "get_world_3d" if dimension == "3d" else "get_world_2d"
	if scene_root.has_method(world_method):
		var world_map: RID = scene_root.call(world_method).navigation_map
		if world_map.is_valid():
			return {"map": world_map, "map_source": "world", "region_path": ""}
	return ErrorCodes.make(ErrorCodes.RESOURCE_NOT_FOUND,
		"No %s navigation map found in the edited scene" % dimension.to_upper())


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

## Coerce a mesh property to its declared type, with enum-by-name support for
## the source-geometry selectors.
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
