@tool
class_name EditorHandler
extends RefCounted

## Handles editor state, selection, log, screenshot, and performance commands.

var _log_buffer: McpLogBuffer
var _connection: Connection
var _debugger_plugin: McpDebuggerPlugin
var _game_log_buffer: GameLogBuffer
var _editor_log_buffer: EditorLogBuffer


func _init(log_buffer: McpLogBuffer, connection: Connection = null, debugger_plugin: McpDebuggerPlugin = null, game_log_buffer: GameLogBuffer = null, editor_log_buffer: EditorLogBuffer = null) -> void:
	_log_buffer = log_buffer
	_connection = connection
	_debugger_plugin = debugger_plugin
	_game_log_buffer = game_log_buffer
	_editor_log_buffer = editor_log_buffer


func get_editor_state(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	return {
		"data": {
			"godot_version": Engine.get_version_info().get("string", "unknown"),
			"project_name": ProjectSettings.get_setting("application/config/name", ""),
			"current_scene": scene_root.scene_file_path if scene_root else "",
			"is_playing": EditorInterface.is_playing_scene(),
			"readiness": Connection.get_readiness(),
			## True once the game subprocess autoload has beaconed mcp:hello;
			## false between Play→Stop cycles. Lets capture-source=game callers
			## poll for a real ready signal instead of guessing with sleep().
			"game_capture_ready": _debugger_plugin != null and _debugger_plugin._game_ready,
		}
	}


func get_selection(_params: Dictionary) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	var paths: Array[String] = []
	for node in selected:
		paths.append(ScenePath.from_node(node, scene_root))
	return {"data": {"selected_paths": paths, "count": paths.size()}}


const VALID_LOG_SOURCES := ["plugin", "game", "editor", "all"]


func get_logs(params: Dictionary) -> Dictionary:
	## Coerce defensively — MCP clients can send JSON numbers as floats or
	## stray `null` values that would otherwise fail the typed locals
	## before we ever reach the INVALID_PARAMS return below.
	var count: int = maxi(0, int(params.get("count", 50)))
	var offset: int = maxi(0, int(params.get("offset", 0)))
	var source: String = str(params.get("source", "plugin"))
	if not source in VALID_LOG_SOURCES:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"Invalid source '%s' — use 'plugin', 'game', 'editor', or 'all'" % source,
		)

	match source:
		"plugin":
			return _get_plugin_logs(count, offset)
		"game":
			return _get_game_logs(count, offset)
		"editor":
			return _get_editor_logs(count, offset)
		"all":
			return _get_all_logs(count, offset)
	return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Unreachable")


func _get_plugin_logs(count: int, offset: int) -> Dictionary:
	var all_lines := _log_buffer.get_recent(_log_buffer.total_count())
	var page: Array[Dictionary] = []
	var stop := mini(all_lines.size(), offset + count)
	for i in range(mini(offset, all_lines.size()), stop):
		page.append({"source": "plugin", "level": "info", "text": all_lines[i]})
	return {
		"data": {
			"source": "plugin",
			"lines": page,
			"total_count": all_lines.size(),
			"returned_count": page.size(),
			"offset": offset,
		}
	}


func _get_game_logs(count: int, offset: int) -> Dictionary:
	if _game_log_buffer == null:
		return {
			"data": {
				"source": "game",
				"lines": [],
				"total_count": 0,
				"returned_count": 0,
				"offset": offset,
				"run_id": "",
				"is_running": false,
				"dropped_count": 0,
			}
		}
	var page := _game_log_buffer.get_range(offset, count)
	return {
		"data": {
			"source": "game",
			"lines": page,
			"total_count": _game_log_buffer.total_count(),
			"returned_count": page.size(),
			"offset": offset,
			"run_id": _game_log_buffer.run_id(),
			"is_running": EditorInterface.is_playing_scene(),
			"dropped_count": _game_log_buffer.dropped_count(),
		}
	}


func _get_editor_logs(count: int, offset: int) -> Dictionary:
	## Editor-process script errors (parse errors, @tool runtime errors,
	## EditorPlugin errors, push_error/push_warning). Captured by
	## editor_logger.gd via OS.add_logger and gated on Godot 4.5+; on older
	## engines or before plugin enable the buffer is null/empty and we
	## return an empty page so callers can poll unconditionally.
	if _editor_log_buffer == null:
		return {
			"data": {
				"source": "editor",
				"lines": [],
				"total_count": 0,
				"returned_count": 0,
				"offset": offset,
				"dropped_count": 0,
			}
		}
	var page := _editor_log_buffer.get_range(offset, count)
	return {
		"data": {
			"source": "editor",
			"lines": page,
			"total_count": _editor_log_buffer.total_count(),
			"returned_count": page.size(),
			"offset": offset,
			"dropped_count": _editor_log_buffer.dropped_count(),
		}
	}


func _get_all_logs(count: int, offset: int) -> Dictionary:
	## Plugin lines have no timestamp, so we can't merge chronologically.
	## Concatenate plugin → editor → game and apply the offset/count window
	## over the combined list. The per-line `source` field tells callers
	## where each entry came from. Editor goes between plugin and game so
	## script errors stay grouped near the plugin recv/send traffic that
	## triggered them, with game runtime logs at the end.
	var combined: Array[Dictionary] = []
	for line in _log_buffer.get_recent(_log_buffer.total_count()):
		combined.append({"source": "plugin", "level": "info", "text": line})
	if _editor_log_buffer != null:
		for entry in _editor_log_buffer.get_range(0, _editor_log_buffer.total_count()):
			combined.append(entry)
	if _game_log_buffer != null:
		for entry in _game_log_buffer.get_range(0, _game_log_buffer.total_count()):
			combined.append(entry)
	var stop := mini(combined.size(), offset + count)
	var page: Array[Dictionary] = []
	for i in range(mini(offset, combined.size()), stop):
		page.append(combined[i])
	var run_id := ""
	var dropped := 0
	if _game_log_buffer != null:
		run_id = _game_log_buffer.run_id()
		dropped = _game_log_buffer.dropped_count()
	if _editor_log_buffer != null:
		dropped += _editor_log_buffer.dropped_count()
	return {
		"data": {
			"source": "all",
			"lines": page,
			"total_count": combined.size(),
			"returned_count": page.size(),
			"offset": offset,
			"run_id": run_id,
			"is_running": EditorInterface.is_playing_scene(),
			"dropped_count": dropped,
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
			## The game is always a separate OS process (embedded mode just
			## reparents its window into the editor). Reach the framebuffer
			## via the debugger channel: the `_mcp_game_helper` autoload
			## inside the game process replies with a PNG, and
			## McpDebuggerPlugin pushes the response back through our
			## WebSocket with the same request_id via Connection.send_deferred_response.
			if _debugger_plugin == null or _connection == null:
				return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Debugger bridge unavailable — plugin may not be fully initialised")
			var request_id: String = params.get("_request_id", "")
			if request_id.is_empty():
				return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Missing request_id — cannot correlate deferred response")
			_debugger_plugin.request_game_screenshot(request_id, max_resolution, _connection)
			return McpDispatcher.DEFERRED_RESPONSE
		"cinematic":
			return _take_cinematic_screenshot(max_resolution)
		_:
			return McpErrorCodes.make(McpErrorCodes.INVALID_PARAMS, "Invalid source '%s' — use 'viewport', 'cinematic', or 'game'" % source)

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


## Render the edited scene through its active Camera3D without running the
## game. Mirrors Godot's "Cinematic Preview" display mode but via a
## throwaway SubViewport, so the output has no editor gizmos, selection
## outlines, or grid lines.
func _take_cinematic_screenshot(max_resolution: int) -> Dictionary:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return McpErrorCodes.make(McpErrorCodes.EDITOR_NOT_READY, "No scene open")

	var scene_camera := _find_current_camera_3d(scene_root)
	if scene_camera == null:
		return McpErrorCodes.make(
			McpErrorCodes.INVALID_PARAMS,
			"No current Camera3D in scene — mark a Camera3D as `current` or add one to the scene",
		)

	## Default to a 16:9 HD capture; size is overridden by _finalize_image's
	## `max_resolution` downscale step when requested.
	var render_size := Vector2i(1920, 1080)
	var edit_vp := EditorInterface.get_editor_viewport_3d()
	if edit_vp != null:
		var vs := edit_vp.get_visible_rect().size
		if vs.x >= 1.0 and vs.y >= 1.0:
			render_size = Vector2i(int(vs.x), int(vs.y))

	var sub_vp := SubViewport.new()
	sub_vp.size = render_size
	sub_vp.own_world_3d = false
	sub_vp.transparent_bg = false
	sub_vp.render_target_update_mode = SubViewport.UPDATE_ONCE

	var cam := Camera3D.new()
	cam.fov = scene_camera.fov
	cam.near = scene_camera.near
	cam.far = scene_camera.far
	cam.projection = scene_camera.projection
	cam.size = scene_camera.size
	cam.keep_aspect = scene_camera.keep_aspect
	cam.cull_mask = scene_camera.cull_mask
	cam.environment = scene_camera.environment
	cam.attributes = scene_camera.attributes
	cam.current = true

	sub_vp.add_child(cam)
	scene_root.add_child(sub_vp)
	## global_transform is resolved against the ancestor Node3D chain, so it
	## must be set after parenting — otherwise the camera ends up at origin.
	cam.global_transform = scene_camera.global_transform

	RenderingServer.force_draw(false)
	var image: Image = sub_vp.get_texture().get_image()

	scene_root.remove_child(sub_vp)
	sub_vp.queue_free()

	if image == null or image.is_empty():
		return McpErrorCodes.make(McpErrorCodes.INTERNAL_ERROR, "Cinematic render produced an empty image")

	var result := _finalize_image(image, "cinematic", max_resolution)
	result.data["camera_path"] = ScenePath.from_node(scene_camera, scene_root)
	return result


## Return the Camera3D that would be active if the scene were running.
## Preference: a descendant with `current=true`, else the first Camera3D
## found in a depth-first walk.
func _find_current_camera_3d(root: Node) -> Camera3D:
	var first: Camera3D = null
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is Camera3D:
			if node.current:
				return node
			if first == null:
				first = node
		for child in node.get_children():
			stack.append(child)
	return first


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
## padding: distance multiplier for breathing room (1.2 = tight, 2.5 = context). Default 1.8.
func _frame_transform_for_aabb(aabb: AABB, fov_degrees: float = 75.0, elevation_deg: float = 25.0, azimuth_deg: float = 30.0, padding: float = 1.8) -> Transform3D:
	var center := aabb.get_center()
	var radius := aabb.size.length() * 0.5
	var fov_rad := deg_to_rad(fov_degrees)
	var distance := radius / tan(fov_rad * 0.5) * padding
	## Floor with an absolute offset so unit-scale AABBs don't place the camera
	## inside or against the target. `radius * 2.0` alone scales to zero as the
	## AABB shrinks; the +1.0 guarantees a minimum of ~1 world-unit of standoff.
	distance = maxf(distance, radius * 2.0 + 1.0)
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
	_do_reload_plugin.call_deferred()
	return {"data": {"status": "reloading", "message": "Plugin reload initiated"}}


## Force a filesystem rescan before toggling the plugin, so Godot's
## class-name registry picks up any .gd files added since the last scan
## (e.g. via git pull or an agent-driven sync). Without this, re-enable can
## fail with "Could not find type X" when new class_name scripts are on disk
## but not yet registered, leaving the plugin disabled with no recovery path
## short of killing the editor. See issue #83.
func _do_reload_plugin() -> void:
	var fs := EditorInterface.get_resource_filesystem()
	fs.scan()
	var tree := Engine.get_main_loop() as SceneTree
	# Cap the wait so a long scan (huge project) doesn't hang reload.
	var deadline_ms := Time.get_ticks_msec() + 5000
	while fs.is_scanning() and Time.get_ticks_msec() < deadline_ms:
		await tree.process_frame
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", false)
	EditorInterface.set_plugin_enabled("res://addons/godot_ai/plugin.cfg", true)


func quit_editor(_params: Dictionary) -> Dictionary:
	_log_buffer.log("quit_editor requested, quitting next frame")
	## Defer the quit so the response is sent back before the editor exits.
	EditorInterface.get_base_control().get_tree().call_deferred("quit")
	return {"data": {"status": "quitting", "message": "Editor quit initiated"}}
