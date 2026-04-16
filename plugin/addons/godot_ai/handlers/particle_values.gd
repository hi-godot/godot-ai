@tool
class_name ParticleValues
extends RefCounted

## Value coercion + gradient/curve builders for particle properties.


const _EMISSION_SHAPES := {
	"point": ParticleProcessMaterial.EMISSION_SHAPE_POINT,
	"sphere": ParticleProcessMaterial.EMISSION_SHAPE_SPHERE,
	"sphere_surface": ParticleProcessMaterial.EMISSION_SHAPE_SPHERE_SURFACE,
	"box": ParticleProcessMaterial.EMISSION_SHAPE_BOX,
	"points": ParticleProcessMaterial.EMISSION_SHAPE_POINTS,
	"directed_points": ParticleProcessMaterial.EMISSION_SHAPE_DIRECTED_POINTS,
	"ring": ParticleProcessMaterial.EMISSION_SHAPE_RING,
}


## Resolve a shape name to the int enum, or return null.
static func resolve_emission_shape(value: Variant) -> Variant:
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String:
		var key := String(value).to_lower()
		if _EMISSION_SHAPES.has(key):
			return _EMISSION_SHAPES[key]
	return null


static func emission_shape_names() -> Array:
	return _EMISSION_SHAPES.keys()


## Build a Gradient from {stops: [{time, color}]} dict.
static func build_gradient(value: Variant) -> Variant:
	if value is Gradient:
		return value
	if value is GradientTexture1D:
		return (value as GradientTexture1D).gradient
	if not (value is Dictionary):
		return null
	var d: Dictionary = value
	if not d.has("stops"):
		return null
	var stops_array = d.get("stops")
	if not (stops_array is Array):
		return null
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for stop in stops_array:
		if not (stop is Dictionary):
			return null
		offsets.append(float(stop.get("time", 0.0)))
		var c = MaterialValues.parse_color(stop.get("color"))
		if c == null:
			return null
		colors.append(c)
	var grad := Gradient.new()
	grad.offsets = offsets
	grad.colors = colors
	return grad


## Build a GradientTexture1D wrapping a Gradient (what ParticleProcessMaterial.color_ramp wants).
static func build_gradient_texture(value: Variant) -> Variant:
	if value is GradientTexture1D:
		return value
	var grad = build_gradient(value)
	if grad == null:
		return null
	var tex := GradientTexture1D.new()
	tex.gradient = grad
	return tex


## Build a Curve from [{time, value}] or {points: [...]} (float-over-time).
static func build_curve(value: Variant) -> Variant:
	if value is Curve:
		return value
	if value is CurveTexture:
		return (value as CurveTexture).curve
	var points_array: Variant = null
	if value is Array:
		points_array = value
	elif value is Dictionary and value.has("points"):
		points_array = value["points"]
	if not (points_array is Array):
		return null
	var curve := Curve.new()
	for pt in points_array:
		if not (pt is Dictionary):
			return null
		var t := float(pt.get("time", 0.0))
		var v := float(pt.get("value", 0.0))
		curve.add_point(Vector2(t, v))
	return curve


static func build_curve_texture(value: Variant) -> Variant:
	if value is CurveTexture:
		return value
	var curve = build_curve(value)
	if curve == null:
		return null
	var tex := CurveTexture.new()
	tex.curve = curve
	return tex


## Coerce a particle property value to the appropriate type.
## Handles: Vector3/gravity/direction, Color, float, int, bool, enum strings.
## For color_ramp returns a GradientTexture1D; for *_curve returns CurveTexture.
static func coerce(property: String, value: Variant, target_type: int) -> Dictionary:
	# Special-cased properties.
	if property == "emission_shape":
		var shape = resolve_emission_shape(value)
		if shape == null:
			return {
				"ok": false,
				"error": "Invalid emission_shape '%s'. Valid: %s" % [
					value, ", ".join(emission_shape_names())
				],
			}
		return {"ok": true, "value": int(shape)}

	if property == "color_ramp" or property == "color_initial_ramp":
		var tex = build_gradient_texture(value)
		if tex == null:
			return {"ok": false, "error": "Invalid gradient for %s (expected {stops: [{time, color}]})" % property}
		return {"ok": true, "value": tex}

	if property == "color" and value is Dictionary and not (value as Dictionary).has("stops"):
		# color is a single Color, not a ramp.
		var c = MaterialValues.parse_color(value)
		if c == null:
			return {"ok": false, "error": "Invalid color"}
		return {"ok": true, "value": c}

	if property.ends_with("_curve"):
		var tex = build_curve_texture(value)
		if tex == null:
			return {"ok": false, "error": "Invalid curve for %s (expected [{time, value}])" % property}
		return {"ok": true, "value": tex}

	# Fall through to the material coercer (handles Color/Vec3/Vec2/float/int/bool/enum).
	return MaterialValues.coerce_material_value(property, value, target_type)


## Build a StandardMaterial3D suitable for GPUParticles3D draw-pass rendering.
##
## Godot's default Mesh has no material, which means ParticleProcessMaterial's
## color_ramp (which drives the COLOR varying) gets ignored and particles
## render as flat white squares that don't face the camera. A correct default
## must have vertex_color_use_as_albedo=true, billboard=particles, unshaded,
## and alpha transparency so the gradient actually modulates the pixels.
##
## Config is an optional dict that overrides individual properties. Supported
## keys match BaseMaterial3D properties (plus enum-by-name via MaterialValues):
##   blend_mode: "mix" | "add" | "sub" | "mul"
##   transparency: "disabled" | "alpha" | "alpha_scissor" | "alpha_hash" | "alpha_depth_pre_pass"
##   shading_mode: "unshaded" | "per_pixel" | "per_vertex"
##   billboard_mode: "disabled" | "enabled" | "fixed_y" | "particles"
##   vertex_color_use_as_albedo: bool
##   emission_enabled: bool
##   emission: Color
##   emission_energy_multiplier: float
##   albedo_color: Color
##   albedo_texture: res:// path
##   (anything else accepted by BaseMaterial3D.set())
static func build_draw_material(config: Dictionary) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	# Sensible defaults for particle draw-pass rendering.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.billboard_keep_scale = true
	# Configure from dict overrides.
	for key in config:
		var prop_name := String(key)
		var prop_type := _object_property_type(mat, prop_name)
		if prop_type == TYPE_NIL:
			continue
		var coerce_result := MaterialValues.coerce_material_value(
			prop_name, config[prop_name], prop_type
		)
		if coerce_result.ok:
			mat.set(prop_name, coerce_result.value)
	return mat


static func _object_property_type(obj: Object, name: String) -> int:
	if obj == null:
		return TYPE_NIL
	for prop in obj.get_property_list():
		if prop.name == name:
			return int(prop.get("type", TYPE_NIL))
	return TYPE_NIL


## Serialize for response.
static func serialize(value: Variant) -> Variant:
	if value == null:
		return null
	if value is GradientTexture1D:
		var grad := (value as GradientTexture1D).gradient
		if grad == null:
			return {"type": "GradientTexture1D", "stops": []}
		var stops: Array = []
		for i in grad.offsets.size():
			var c: Color = grad.colors[i]
			stops.append({
				"time": grad.offsets[i],
				"color": {"r": c.r, "g": c.g, "b": c.b, "a": c.a},
			})
		return {"type": "GradientTexture1D", "stops": stops}
	if value is CurveTexture:
		var curve := (value as CurveTexture).curve
		if curve == null:
			return {"type": "CurveTexture", "points": []}
		var points: Array = []
		for i in curve.get_point_count():
			var p := curve.get_point_position(i)
			points.append({"time": p.x, "value": p.y})
		return {"type": "CurveTexture", "points": points}
	return MaterialValues.serialize_value(value)
