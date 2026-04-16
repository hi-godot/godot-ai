@tool
class_name EditorHandler
extends RefCounted

## Handles editor state, selection, log, screenshot, and performance commands.

var _log_buffer: McpLogBuffer
var _connection: Connection


func _init(log_buffer: McpLogBuffer, connection: Connection = null) -> void:
	_log_buffer = log_buffer
	_connection = connection


func get_editor_state(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	return {
		"data": {
			"godot_version": Engine.get_version_info().get("string", "unknown"),
			"project_name": ProjectSettings.get_setting("application/config/name", ""),
			"current_scene": scene_root.scene_file_path if scene_root else "",
			"is_playing": EditorInterface.is_playing_scene(),
			"readiness": Connection.get_readiness(),
		}
	}


func get_selection(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var paths: Array[String] = []
	for node in selected:
		paths.append(ScenePath.from_node(node, scene_root))
	return {"data": {"selected_paths": paths, "count": paths.size()}}


func get_logs(params: Dictionary) -> Dictionary:
	var count: int = params.get("count", 50)
	var lines := _log_buffer.get_recent(count)
	return {
		"data": {
			"lines": lines,
			"total_count": _log_buffer.total_count(),
			"returned_count": lines.size(),
		}
	}


## Map of human-readable monitor names to Performance.Monitor enum values.
const MONITORS := {
	"time/fps": Performance.TIME_FPS,
	"time/process": Performance.TIME_PROCESS,
	"time/physics_process": Performance.TIME_PHYSICS_PROCESS,
	"time/navigation_process": Performance.TIME_NAVIGATION_PROCESS,
	"memory/static": Performance.MEMORY_STATIC,
	"memory/static_max": Performance.MEMORY_STATIC_MAX,
	"memory/message_buffer_max": Performance.MEMORY_MESSAGE_BUFFER_MAX,
	"object/count": Performance.OBJECT_COUNT,
	"object/resource_count": Performance.OBJECT_RESOURCE_COUNT,
	"object/node_count": Performance.OBJECT_NODE_COUNT,
	"object/orphan_node_count": Performance.OBJECT_ORPHAN_NODE_COUNT,
	"render/total_objects_in_frame": Performance.RENDER_TOTAL_OBJECTS_IN_FRAME,
	"render/total_primitives_in_frame": Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME,
	"render/total_draw_calls_in_frame": Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME,
	"render/video_mem_used": Performance.RENDER_VIDEO_MEM_USED,
	"physics_2d/active_objects": Performance.PHYSICS_2D_ACTIVE_OBJECTS,
	"physics_2d/collision_pairs": Performance.PHYSICS_2D_COLLISION_PAIRS,
	"physics_2d/island_count": Performance.PHYSICS_2D_ISLAND_COUNT,
	"physics_3d/active_objects": Performance.PHYSICS_3D_ACTIVE_OBJECTS,
	"physics_3d/collision_pairs": Performance.PHYSICS_3D_COLLISION_PAIRS,
	"physics_3d/island_count": Performance.PHYSICS_3D_ISLAND_COUNT,
	"navigation/active_maps": Performance.NAVIGATION_ACTIVE_MAPS,
	"navigation/region_count": Performance.NAVIGATION_REGION_COUNT,
	"navigation/agent_count": Performance.NAVIGATION_AGENT_COUNT,
	"navigation/link_count": Performance.NAVIGATION_LINK_COUNT,
	"navigation/polygon_count": Performance.NAVIGATION_POLYGON_COUNT,
	"navigation/edge_count": Performance.NAVIGATION_EDGE_COUNT,
	"navigation/edge_merge_count": Performance.NAVIGATION_EDGE_MERGE_COUNT,
	"navigation/edge_connection_count": Performance.NAVIGATION_EDGE_CONNECTION_COUNT,
	"navigation/edge_free_count": Performance.NAVIGATION_EDGE_FREE_COUNT,
}


## Compute coverage angles from the target's AABB geometry.
## Returns an establishing perspective shot (faces the longest ground axis)
## and an orthographic top-down for spatial layout. The AI iterates from
## there with explicit elevation/azimuth/fov for closeups and detail shots.
func _compute_coverage_angles(aabb: AABB) -> Array[Dictionary]:
	var size := aabb.size
	var ground_x := maxf(size.x, 0.01)
	var ground_z := maxf(size.z, 0.01)

	## Face the longest ground axis — establishing shot shows maximum extent
	var estab_azimuth: float
	if ground_x >= ground_z:
		estab_azimuth = 0.0     # face along Z, showing X width
	else:
		estab_azimuth = 90.0    # face along X, showing Z width

	## FOV: wider for spread-out subjects, narrower for compact ones
	var ground_ratio := maxf(ground_x, ground_z) / minf(ground_x, ground_z)
	var estab_fov := clampf(40.0 + ground_ratio * 5.0, 45.0, 65.0)

	return [
		{"label": "establishing", "elevation": 25.0, "azimuth": estab_azimuth + 20.0,
			"fov": estab_fov, "ortho": false, "padding": 1.8},
		{"label": "top", "elevation": 90.0, "azimuth": 0.0,
			"fov": 0.0, "ortho": true},
	]


func take_screenshot(params: Dictionary) -> Dictionary:
	var source: String = params.get("source", "viewport")
	var max_resolution: int = params.get("max_resolution", 0)
	var view_target: String = params.get("view_target", "")
	var coverage: bool = params.get("coverage", false)
	var custom_elevation = params.get("elevation", null)
	var custom_azimuth = params.get("azimuth", null)
	var custom_fov = params.get("fov", null)

	var viewport: Viewport
	match source:
		"viewport":
			viewport = EditorInterface.get_editor_viewport_3d()
			if viewport == null:
				return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No 3D viewport available")
		"game":
			if not EditorInterface.is_playing_scene():
				return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Game is not running — use source='viewport' or start the project first")
			# The game viewport is the editor window's root viewport, not a SubViewport.
			# Using the main screen's viewport captures the game view area.
			viewport = EditorInterface.get_editor_main_screen().get_viewport()
			if viewport == null:
				return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "Could not access game viewport")
		_:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Invalid source '%s' — use 'viewport' or 'game'" % source)

	## Handle view_target: temporarily reposition the editor's own camera to
	## frame one or more target nodes, force a render, capture, then restore.
	if not view_target.is_empty() and source == "viewport":
		var scene_root := EditorInterface.get_edited_scene_root()
		if scene_root == null:
			return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

		## Parse comma-separated paths, deduplicate
		var raw_paths := view_target.split(",")
		var seen := {}
		var unique_paths: Array[String] = []
		for rp in raw_paths:
			var p := rp.strip_edges()
			if not p.is_empty() and not seen.has(p):
				seen[p] = true
				unique_paths.append(p)

		## Resolve each path, collect valid Node3D targets
		var targets: Array[Node3D] = []
		var not_found: Array[String] = []
		for p in unique_paths:
			var node := ScenePath.resolve(p, scene_root)
			if node == null:
				not_found.append(p)
			elif not node is Node3D:
				not_found.append(p)
			else:
				targets.append(node as Node3D)

		if targets.is_empty():
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "No valid Node3D targets found: %s" % ", ".join(not_found))

		var cam := viewport.get_camera_3d()
		if cam == null:
			return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No camera in 3D viewport")

		## Merge AABBs from all targets
		var combined_aabb := _get_visual_aabb(targets[0])
		for i in range(1, targets.size()):
			combined_aabb = combined_aabb.merge(_get_visual_aabb(targets[i]))

		var cam_rid := cam.get_camera_rid()
		var saved_xform := cam.global_transform
		var saved_fov := cam.fov
		var saved_near := cam.near
		var saved_far := cam.far

		## --- Coverage path: multi-angle sweep ---
		if coverage:
			var images: Array[Dictionary] = []
			for preset in _compute_coverage_angles(combined_aabb):
				if preset.get("ortho", false):
					## Orthographic top-down view
					var ortho_size := combined_aabb.size.length() * 1.8
					var cam_height := maxf(combined_aabb.size.length() * 3.0, 10.0)
					var center := combined_aabb.get_center()
					var xform := Transform3D(Basis.IDENTITY, center + Vector3.UP * cam_height)
					xform = xform.looking_at(center, Vector3.FORWARD)
					RenderingServer.camera_set_orthogonal(cam_rid, ortho_size, saved_near, maxf(saved_far, cam_height * 2.0))
					RenderingServer.camera_set_transform(cam_rid, xform)
				else:
					## Perspective view — padding per preset (wide for establishing, tight for detail)
					var pad: float = preset.get("padding", 2.5)
					var xform := _frame_transform_for_aabb(combined_aabb, preset.fov, preset.elevation, preset.azimuth, pad)
					RenderingServer.camera_set_perspective(cam_rid, preset.fov, saved_near, saved_far)
					RenderingServer.camera_set_transform(cam_rid, xform)
				RenderingServer.force_draw(false)
				var img: Image = viewport.get_texture().get_image()
				if img != null and not img.is_empty():
					var entry := _finalize_image(img, "viewport", max_resolution)
					entry.data["label"] = preset.label
					entry.data["elevation"] = preset.elevation
					entry.data["azimuth"] = preset.azimuth
					entry.data["fov"] = preset.fov
					entry.data["ortho"] = preset.get("ortho", false)
					images.append(entry.data)

			## Restore camera state (back to perspective + original transform)
			RenderingServer.camera_set_perspective(cam_rid, saved_fov, saved_near, saved_far)
			RenderingServer.camera_set_transform(cam_rid, saved_xform)

			## Consistent with single-shot path: error if no frames rendered
			## (e.g. headless mode where force_draw produces no output).
			if images.is_empty():
				return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Coverage sweep rendered no images")

			var aabb_center := combined_aabb.get_center()
			var aabb_size := combined_aabb.size
			var result_data := {
				"source": "viewport",
				"view_target": view_target,
				"view_target_count": targets.size(),
				"coverage": true,
				"images": images,
				"aabb_center": [aabb_center.x, aabb_center.y, aabb_center.z],
				"aabb_size": [aabb_size.x, aabb_size.y, aabb_size.z],
				"aabb_longest_ground_axis": "x" if aabb_size.x >= aabb_size.z else "z",
			}
			if not not_found.is_empty():
				result_data["view_target_not_found"] = not_found
			return {"data": result_data}

		## --- Custom angle / FOV path ---
		var use_elev: float = 25.0 if custom_elevation == null else float(custom_elevation)
		var use_azim: float = 30.0 if custom_azimuth == null else float(custom_azimuth)
		var use_fov: float = saved_fov if custom_fov == null else float(custom_fov)

		var cam_xform := _frame_transform_for_aabb(combined_aabb, use_fov, use_elev, use_azim)

		if custom_fov != null:
			RenderingServer.camera_set_perspective(cam_rid, use_fov, saved_near, saved_far)
		RenderingServer.camera_set_transform(cam_rid, cam_xform)
		RenderingServer.force_draw(false)

		var image: Image = viewport.get_texture().get_image()

		## Restore camera state
		if custom_fov != null:
			RenderingServer.camera_set_perspective(cam_rid, saved_fov, saved_near, saved_far)
		RenderingServer.camera_set_transform(cam_rid, saved_xform)

		if image == null or image.is_empty():
			return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Framed viewport rendered an empty image")

		var result := _finalize_image(image, "viewport", max_resolution)
		result.data["view_target"] = view_target
		result.data["view_target_count"] = targets.size()
		var aabb_c := combined_aabb.get_center()
		var aabb_s := combined_aabb.size
		result.data["aabb_center"] = [aabb_c.x, aabb_c.y, aabb_c.z]
		result.data["aabb_size"] = [aabb_s.x, aabb_s.y, aabb_s.z]
		result.data["aabb_longest_ground_axis"] = "x" if aabb_s.x >= aabb_s.z else "z"
		if custom_elevation != null or custom_azimuth != null:
			result.data["elevation"] = use_elev
			result.data["azimuth"] = use_azim
		if custom_fov != null:
			result.data["fov"] = use_fov
		if not not_found.is_empty():
			result.data["view_target_not_found"] = not_found
		return result

	var image: Image = viewport.get_texture().get_image()

	if image == null or image.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Failed to capture image from %s" % source)

	return _finalize_image(image, source, max_resolution)


func _finalize_image(image: Image, source: String, max_resolution: int) -> Dictionary:
	var original_width := image.get_width()
	var original_height := image.get_height()

	if max_resolution > 0:
		var longest := maxi(original_width, original_height)
		if longest > max_resolution:
			var scale := float(max_resolution) / float(longest)
			## Clamp to 1px min: extreme aspect ratios at very small max_resolution
			## could otherwise compute a zero dimension and crash image.resize().
			var new_w := maxi(1, int(original_width * scale))
			var new_h := maxi(1, int(original_height * scale))
			image.resize(new_w, new_h, Image.INTERPOLATE_LANCZOS)

	var img_bytes := image.save_png_to_buffer()
	var base64_str := Marshalls.raw_to_base64(img_bytes)

	return {
		"data": {
			"source": source,
			"width": image.get_width(),
			"height": image.get_height(),
			"original_width": original_width,
			"original_height": original_height,
			"format": "png",
			"image_base64": base64_str,
		}
	}


## Recursively compute the visual bounding box of a Node3D and its children.
func _get_visual_aabb(node: Node3D) -> AABB:
	var aabb := AABB()
	var found := false
	if node is VisualInstance3D:
		aabb = node.global_transform * node.get_aabb()
		found = true
	for child in node.get_children():
		if child is Node3D:
			var child_aabb := _get_visual_aabb(child)
			if child_aabb.size != Vector3.ZERO:
				if found:
					aabb = aabb.merge(child_aabb)
				else:
					aabb = child_aabb
					found = true
	if not found:
		aabb = AABB(node.global_position - Vector3(0.5, 0.5, 0.5), Vector3(1, 1, 1))
	return aabb


## Calculate a camera Transform3D that frames the given AABB nicely.
## elevation_deg: camera elevation (0 = level, 90 = directly above). Default 25.
## azimuth_deg: camera azimuth (0 = front, 90 = right side). Default 30.
## padding: distance multiplier for breathing room (1.2 = tight, 2.5 = context). Default 1.2.
func _frame_transform_for_aabb(aabb: AABB, fov_degrees: float = 75.0, elevation_deg: float = 25.0, azimuth_deg: float = 30.0, padding: float = 1.2) -> Transform3D:
	var center := aabb.get_center()
	var radius := aabb.size.length() * 0.5
	var fov_rad := deg_to_rad(fov_degrees)
	var distance := radius / tan(fov_rad * 0.5) * padding
	distance = maxf(distance, radius * 2.0)
	var elev := deg_to_rad(elevation_deg)
	var azim := deg_to_rad(azimuth_deg)
	var cam_pos := center + Vector3(
		distance * cos(elev) * sin(azim),
		distance * sin(elev),
		distance * cos(elev) * cos(azim),
	)
	var xform := Transform3D(Basis.IDENTITY, cam_pos)
	## At ~90° elevation the view direction is parallel to Vector3.UP — use
	## FORWARD as the up hint so looking_at doesn't degenerate.
	var up := Vector3.FORWARD if elevation_deg > 85.0 else Vector3.UP
	return xform.looking_at(center, up)


func get_performance_monitors(params: Dictionary) -> Dictionary:
	var filter: Array = params.get("monitors", [])
	var result := {}

	if filter.is_empty():
		for key in MONITORS:
			result[key] = Performance.get_monitor(MONITORS[key])
	else:
		for key in filter:
			if MONITORS.has(key):
				result[key] = Performance.get_monitor(MONITORS[key])

	return {
		"data": {
			"monitors": result,
			"monitor_count": result.size(),
		}
	}


func clear_logs(_params: Dictionary) -> Dictionary:
	var count := _log_buffer.total_count()
	_log_buffer.clear()
	return {
		"data": {
			"cleared_count": count,
		}
	}


func reload_plugin(_params: Dictionary) -> Dictionary:
	_log_buffer.log("reload_plugin requested, reloading next frame")
	(func():
		EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
		EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)
	).call_deferred()
	return {"data": {"status": "reloading", "message": "Plugin reload initiated"}}


func quit_editor(_params: Dictionary) -> Dictionary:
	_log_buffer.log("quit_editor requested, quitting next frame")
	## Defer the quit so the response is sent back before the editor exits.
	EditorInterface.get_base_control().get_tree().call_deferred("quit")
	return {"data": {"status": "quitting", "message": "Editor quit initiated"}}
