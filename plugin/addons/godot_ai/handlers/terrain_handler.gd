@tool
extends RefCounted

## Terrain authoring — create and regenerate deterministic heightmap
## terrain meshes (FastNoiseLite) with optional trimesh collision.
##
## terrain_create builds a Node3D container holding a "TerrainMesh"
## MeshInstance3D (ArrayMesh, height-tinted vertex colors) and an optional
## "TerrainCollision" StaticBody3D (ConcavePolygonShape3D from the same
## triangles). The same seed + params always produce the same mesh, so
## agents can iterate on seeds and compare screenshots honestly.
##
## terrain_regenerate rebuilds an existing container in place with new
## params; one undo action restores the previous mesh/collision state.
## Holes and carved detail are CSG territory (csg_manage) — composition,
## not duplication.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")

const MIN_SIZE := 4
const MAX_SIZE := 128
const MESH_CHILD := "TerrainMesh"
const COLLISION_CHILD := "TerrainCollision"

const NOISE_TYPES := {
	"simplex": FastNoiseLite.TYPE_SIMPLEX,
	"simplex_smooth": FastNoiseLite.TYPE_SIMPLEX_SMOOTH,
	"perlin": FastNoiseLite.TYPE_PERLIN,
	"ridged": FastNoiseLite.TYPE_PERLIN,
	"value": FastNoiseLite.TYPE_VALUE,
}

var _undo_redo: EditorUndoRedoManager


func _init(undo_redo: EditorUndoRedoManager) -> void:
	_undo_redo = undo_redo


## Create a heightmap terrain under a Node3D parent.
## params: {parent_path, name="", size=48, cell_size=2.0, seed=1337,
##          noise_type="simplex", frequency=0.05, octaves=3,
##          height_scale=8.0, base_height=0.0, generate_collision=true}
## Returns: {path, name, size, vertices, triangles, generate_collision, undoable}
func create(params: Dictionary) -> Dictionary:
	var parent_path: String = params.get("parent_path", "")
	var scene_file: String = params.get("scene_file", "")
	var checked := _validate_params(params)
	if checked.has("error"):
		return checked
	var p: Dictionary = checked.params
	var has_collision := bool(params.get("generate_collision", true))

	var scene_check := McpScenePath.require_edited_scene(scene_file)
	if scene_check.has("error"):
		return scene_check
	var scene_root: Node = scene_check.node

	var parent: Node = scene_root
	if not parent_path.is_empty():
		parent = McpScenePath.resolve(parent_path, scene_root)
		if parent == null:
			return ErrorCodes.make(ErrorCodes.NODE_NOT_FOUND,
				McpScenePath.format_parent_error(parent_path, scene_root))
	if not parent is Node3D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Terrain parent must be a Node3D (got %s)" % parent.get_class())

	var built := _build_surface(p)
	var container := Node3D.new()
	var name: String = params.get("name", "")
	if name.is_empty():
		name = "Terrain"
	container.name = name
	_build_children(container, built, has_collision, scene_root)

	_undo_redo.create_action("MCP: Create %s" % container.name)
	_undo_redo.add_do_method(parent, "add_child", container, true)
	_undo_redo.add_do_method(container, "set_owner", scene_root)
	_undo_redo.add_do_reference(container)
	_undo_redo.add_undo_method(parent, "remove_child", container)
	_undo_redo.commit_action()

	return {"data": {
		"path": McpScenePath.from_node(container, scene_root),
		"name": container.name,
		"size": p.size,
		"vertices": built.vertices,
		"triangles": built.triangle_count,
		"generate_collision": has_collision,
		"undoable": true,
	}}


## Rebuild an existing terrain container in place with new params.
## params: {path, size, cell_size, seed, noise_type, frequency, octaves,
##          height_scale, base_height, generate_collision}
## Returns: {path, vertices, triangles, generate_collision, undoable}
func regenerate(params: Dictionary) -> Dictionary:
	var resolved := McpNodeValidator.resolve_or_error(
		params.get("path", ""), "path", params.get("scene_file", ""))
	if resolved.has("error"):
		return resolved
	var node: Node = resolved.node
	if not node is Node3D:
		return ErrorCodes.make(ErrorCodes.WRONG_TYPE,
			"Node is not a Node3D: %s" % params.get("path", ""))
	var container: Node3D = node
	var checked := _validate_params(params)
	if checked.has("error"):
		return checked
	var p: Dictionary = checked.params
	var has_collision := bool(params.get("generate_collision", true))
	var prev := _capture_mesh_state(container)
	var built := _build_surface(p)

	## First callback targets the node so the action lands in the scene
	## undo history (first-target routing); the rebuild and restore run on
	## the handler.
	_undo_redo.create_action("MCP: Terrain regenerate")
	_undo_redo.add_do_method(container, "set_meta", "_mcp_terrain_rebuild", true)
	_undo_redo.add_do_method(self, "_apply_rebuild", container, p, has_collision)
	_undo_redo.add_undo_method(self, "_apply_mesh_state", container, prev)
	_undo_redo.commit_action()

	return {"data": {
		"path": McpScenePath.from_node(container, EditorInterface.get_edited_scene_root()),
		"vertices": built.vertices,
		"triangles": built.triangle_count,
		"generate_collision": has_collision,
		"undoable": true,
	}}


## Validate + normalize terrain params; returns {"params": {...}} or an
## error dict. Shared by create and regenerate.
func _validate_params(params: Dictionary) -> Dictionary:
	var size := int(params.get("size", 48))
	if size < MIN_SIZE or size > MAX_SIZE:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"size must be in %d..%d, got %d" % [MIN_SIZE, MAX_SIZE, size])
	var cell_size := float(params.get("cell_size", 2.0))
	if cell_size <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"cell_size must be > 0, got %s" % str(cell_size))
	var height_scale := float(params.get("height_scale", 8.0))
	if height_scale < 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"height_scale must be >= 0, got %s" % str(height_scale))
	var frequency := float(params.get("frequency", 0.05))
	if frequency <= 0.0:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"frequency must be > 0, got %s" % str(frequency))
	var octaves := int(params.get("octaves", 3))
	if octaves < 1 or octaves > 6:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"octaves must be in 1..6, got %d" % octaves)
	var noise_type: String = params.get("noise_type", "simplex")
	if not NOISE_TYPES.has(noise_type):
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Unknown noise_type: %s. Valid: %s" % [noise_type, ", ".join(NOISE_TYPES.keys())])
	return {"params": {
		"size": size,
		"cell_size": cell_size,
		"seed": int(params.get("seed", 1337)),
		"noise_type": noise_type,
		"frequency": frequency,
		"octaves": octaves,
		"height_scale": height_scale,
		"base_height": float(params.get("base_height", 0.0)),
	}}


func _build_surface(p: Dictionary) -> Dictionary:
	var noise := FastNoiseLite.new()
	noise.seed = p.seed
	noise.frequency = p.frequency
	noise.fractal_octaves = p.octaves
	noise.noise_type = NOISE_TYPES[p.noise_type]
	if p.noise_type == "ridged":
		noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED

	var n: int = p.size
	var half: float = (n - 1) * p.cell_size * 0.5
	var verts := PackedVector3Array()
	verts.resize(n * n)
	var normals := PackedVector3Array()
	normals.resize(n * n)
	var uvs := PackedVector2Array()
	uvs.resize(n * n)
	var cols := PackedColorArray()
	cols.resize(n * n)
	for y in n:
		for x in n:
			var h: float = p.base_height + noise.get_noise_2d(
				x * p.frequency, y * p.frequency) * p.height_scale
			verts[y * n + x] = Vector3(x * p.cell_size - half, h, y * p.cell_size - half)
			uvs[y * n + x] = Vector2(float(x) / float(n - 1), float(y) / float(n - 1))
			cols[y * n + x] = _height_color(h, p.height_scale, p.base_height)

	## Smooth normals: average adjacent face normals per vertex. Done by
	## hand instead of SurfaceTool.generate_normals(), which reindexes and
	## duplicates vertices — the vertex count must stay exactly n*n so the
	## mesh is deterministic and testable.
	for y in n - 1:
		for x in n - 1:
			var a := y * n + x
			var b := a + 1
			var c := (y + 1) * n + x
			var d := c + 1
			_accumulate_face_normal(normals, verts, a, c, b)
			_accumulate_face_normal(normals, verts, b, c, d)
	for i in normals.size():
		normals[i] = normals[i].normalized()

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	## Indexed emission: each unique vertex is added once, then triangles
	## reference it by index, so the mesh carries exactly n*n vertices.
	for i in verts.size():
		st.set_uv(uvs[i])
		st.set_color(cols[i])
		st.set_normal(normals[i])
		st.add_vertex(verts[i])
	var triangles := PackedVector3Array()
	for y in n - 1:
		for x in n - 1:
			var a := y * n + x
			var b := a + 1
			var c := (y + 1) * n + x
			var d := c + 1
			_emit_tri(st, triangles, verts, a, c, b)
			_emit_tri(st, triangles, verts, b, c, d)
	st.set_material(_make_material())
	return {
		"mesh": st.commit(),
		"triangles": triangles,
		"vertices": verts.size(),
		"triangle_count": triangles.size() / 3,
	}


func _accumulate_face_normal(
	normals: PackedVector3Array,
	verts: PackedVector3Array,
	i0: int,
	i1: int,
	i2: int,
) -> void:
	var face_normal := (verts[i1] - verts[i0]).cross(verts[i2] - verts[i0])
	normals[i0] += face_normal
	normals[i1] += face_normal
	normals[i2] += face_normal


func _emit_tri(
	st: SurfaceTool,
	triangles: PackedVector3Array,
	verts: PackedVector3Array,
	i0: int,
	i1: int,
	i2: int,
) -> void:
	triangles.append(verts[i0])
	triangles.append(verts[i1])
	triangles.append(verts[i2])
	st.add_index(i0)
	st.add_index(i1)
	st.add_index(i2)


func _height_color(h: float, height_scale: float, base_height: float) -> Color:
	var t := inverse_lerp(-height_scale, height_scale, h - base_height)
	t = clampf(t, 0.0, 1.0)
	if t < 0.25:
		return Color(0.62, 0.51, 0.32)
	if t < 0.55:
		return Color(0.36, 0.55, 0.25)
	if t < 0.8:
		return Color(0.45, 0.42, 0.4)
	return Color(0.92, 0.94, 0.97)


func _make_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.9
	return mat


func _build_children(container: Node3D, built: Dictionary, has_collision: bool, scene_root: Node) -> void:
	var mi := MeshInstance3D.new()
	mi.name = MESH_CHILD
	mi.mesh = built.mesh
	mi.owner = scene_root
	container.add_child(mi)
	if has_collision:
		var body := StaticBody3D.new()
		body.name = COLLISION_CHILD
		var cs := CollisionShape3D.new()
		var concave := ConcavePolygonShape3D.new()
		concave.set_faces(built.triangles)
		cs.shape = concave
		body.add_child(cs)
		cs.owner = scene_root
		body.owner = scene_root
		container.add_child(body)


## Rebuild the generated children of a terrain container (do-method for
## regenerate).
func _apply_rebuild(container: Node3D, p: Dictionary, has_collision: bool) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	_clear_generated(container)
	var built := _build_surface(p)
	_build_children(container, built, has_collision, scene_root)


## Restore a previously captured mesh/collision state (undo-method for
## regenerate).
func _apply_mesh_state(container: Node3D, prev: Dictionary) -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	_clear_generated(container)
	var mi := MeshInstance3D.new()
	mi.name = MESH_CHILD
	mi.mesh = prev.mesh
	mi.owner = scene_root
	container.add_child(mi)
	if prev.has_collision and prev.shape != null:
		var body := StaticBody3D.new()
		body.name = COLLISION_CHILD
		var cs := CollisionShape3D.new()
		cs.shape = prev.shape
		body.add_child(cs)
		cs.owner = scene_root
		body.owner = scene_root
		container.add_child(body)


func _capture_mesh_state(container: Node3D) -> Dictionary:
	var mi := _find_child(container, MESH_CHILD)
	var mesh: Mesh = mi.mesh if mi != null else null
	var body := _find_child(container, COLLISION_CHILD)
	var shape: Shape3D = null
	if body != null and body.get_child_count() > 0:
		var cs: CollisionShape3D = body.get_child(0) as CollisionShape3D
		shape = cs.shape
	return {"mesh": mesh, "shape": shape, "has_collision": body != null}


func _clear_generated(container: Node3D) -> void:
	for child in container.get_children():
		if child.name == MESH_CHILD or child.name == COLLISION_CHILD:
			container.remove_child(child)
			child.free()


func _find_child(parent: Node, name: String) -> Node:
	for child in parent.get_children():
		if child.name == name:
			return child
	return null
