@tool
extends RefCounted

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const MAX_TRIANGLES := 2048
const MAX_VERTICES := 6144
const MAX_SURFACES := 32


static func estimate(mesh: Mesh) -> Dictionary:
	if mesh.get_script() != null:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Scripted meshes cannot be bounded before geometry extraction; use an ArrayMesh without a script")
	var triangles := 0
	var vertices := 0
	if mesh is ArrayMesh:
		var array_mesh := mesh as ArrayMesh
		var surface_count := array_mesh.get_surface_count()
		if surface_count > MAX_SURFACES:
			return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
				"Geometry extraction supports at most %d mesh surfaces; found %d" % [MAX_SURFACES, surface_count])
		for surface in surface_count:
			var vertex_count := array_mesh.surface_get_array_len(surface)
			vertices += vertex_count
			if array_mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var index_count := array_mesh.surface_get_array_index_len(surface)
			triangles += int((index_count if index_count > 0 else vertex_count) / 3)
		return {"triangles": triangles, "vertices": vertices}
	# PrimitiveMesh surface counters can generate the entire mesh on first use.
	if mesh is BoxMesh:
		var box := mesh as BoxMesh
		var x := mini(box.subdivide_width, MAX_TRIANGLES) + 1
		var y := mini(box.subdivide_height, MAX_TRIANGLES) + 1
		var z := mini(box.subdivide_depth, MAX_TRIANGLES) + 1
		triangles = 4 * (x * y + x * z + y * z)
	elif mesh is PlaneMesh:
		var plane := mesh as PlaneMesh
		triangles = 2 * (mini(plane.subdivide_width, MAX_TRIANGLES) + 1) * (mini(plane.subdivide_depth, MAX_TRIANGLES) + 1)
	elif mesh is SphereMesh or mesh is CylinderMesh or mesh is CapsuleMesh:
		var radial := mini(int(mesh.get("radial_segments")), MAX_TRIANGLES)
		var rings := mini(int(mesh.get("rings")), MAX_TRIANGLES)
		triangles = 2 * radial * (rings + 2)
		if mesh is CapsuleMesh:
			triangles *= 3
	elif mesh is PointMesh:
		return {"triangles": 0, "vertices": 1}
	else:
		return ErrorCodes.make(ErrorCodes.VALUE_OUT_OF_RANGE,
			"Mesh class %s has no bounded geometry preflight; use ArrayMesh, BoxMesh, PlaneMesh, SphereMesh, CylinderMesh or CapsuleMesh" % mesh.get_class())
	return {"triangles": triangles, "vertices": triangles * 3}
