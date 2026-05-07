@tool
extends RefCounted

## Read-only animation introspection + shared value-coercion / serialization.
##
## Holds:
##   - Static helpers used by both the write handler (track building, simple
##     composer) and the preset module (target/property resolution).
##   - Instance methods that back the read MCP ops: animation_list,
##     animation_get, animation_validate.
##
## The instance methods need the handler to resolve players / animations.
## To keep that without introducing a RefCounted cycle (the handler holds a
## strong ref to this module via `_values`), the back-pointer is a WeakRef.
## When the handler is freed during plugin teardown, _h() returns null and
## the (no-longer-routable) calls short-circuit to a generic editor-not-ready
## error — matches the dispatcher already being torn down at that point.


const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const PropertyErrors := preload("res://addons/godot_ai/handlers/_property_errors.gd")


const _NAMED_TRANSITIONS := {
	"linear": 1.0,
	"ease_in": 2.0,
	"ease_out": 0.5,
	"ease_in_out": -2.0,
}

## Component letters accepted on each aggregate base type, paired with the
## scalar Variant type the component resolves to. A subpath like `position:y`
## on a Vector3 maps to TYPE_FLOAT; on a Vector3i it maps to TYPE_INT.
const _SUBPATH_COMPONENTS := {
	TYPE_VECTOR2: ["xy", TYPE_FLOAT],
	TYPE_VECTOR3: ["xyz", TYPE_FLOAT],
	TYPE_VECTOR4: ["xyzw", TYPE_FLOAT],
	TYPE_QUATERNION: ["xyzw", TYPE_FLOAT],
	TYPE_COLOR: ["rgba", TYPE_FLOAT],
	TYPE_VECTOR2I: ["xy", TYPE_INT],
	TYPE_VECTOR3I: ["xyz", TYPE_INT],
	TYPE_VECTOR4I: ["xyzw", TYPE_INT],
}


var _handler_weak: WeakRef


func _init(handler) -> void:
	_handler_weak = weakref(handler)


func _h():
	return _handler_weak.get_ref()


# ============================================================================
# animation_list  (read)
# ============================================================================

func list_animations(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "AnimationHandler not available")
	var resolved: Dictionary = handler._resolve_player_read(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var animations: Array[Dictionary] = []
	for lib_name in player.get_animation_library_list():
		var lib: AnimationLibrary = player.get_animation_library(lib_name)
		for anim_name in lib.get_animation_list():
			var anim: Animation = lib.get_animation(anim_name)
			var display_name: String = anim_name if lib_name == "" else "%s/%s" % [lib_name, anim_name]
			animations.append({
				"name": display_name,
				"length": anim.length,
				"loop_mode": loop_mode_to_string(anim.loop_mode),
				"track_count": anim.get_track_count(),
			})

	return {
		"data": {
			"player_path": player_path,
			"animations": animations,
			"count": animations.size(),
		}
	}


# ============================================================================
# animation_get  (read)
# ============================================================================

func get_animation(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if anim_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: animation_name")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "AnimationHandler not available")
	var resolved: Dictionary = handler._resolve_player_read(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	var anim_resolved: Dictionary = handler._resolve_animation(player, anim_name)
	if anim_resolved.has("error"):
		return anim_resolved
	var anim: Animation = anim_resolved.animation

	var tracks: Array[Dictionary] = []
	for i in anim.get_track_count():
		var track_type := anim.track_get_type(i)
		var type_name := track_type_to_string(track_type)
		var keys: Array[Dictionary] = []
		for k in anim.track_get_key_count(i):
			var key_val = anim.track_get_key_value(i, k)
			keys.append({
				"time": anim.track_get_key_time(i, k),
				"value": serialize_value(key_val),
				"transition": anim.track_get_key_transition(i, k),
			})
		tracks.append({
			"index": i,
			"type": type_name,
			"path": str(anim.track_get_path(i)),
			"interpolation": interp_to_string(anim.track_get_interpolation_type(i)),
			"key_count": keys.size(),
			"keys": keys,
		})

	return {
		"data": {
			"player_path": player_path,
			"name": anim_name,
			"length": anim.length,
			"loop_mode": loop_mode_to_string(anim.loop_mode),
			"track_count": anim.get_track_count(),
			"tracks": tracks,
		}
	}


# ============================================================================
# animation_validate  (read-only)
# ============================================================================

func validate_animation(params: Dictionary) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var anim_name: String = params.get("animation_name", "")

	if player_path.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: player_path")
	if anim_name.is_empty():
		return ErrorCodes.make(ErrorCodes.MISSING_REQUIRED_PARAM, "Missing required param: animation_name")

	var handler = _h()
	if handler == null:
		return ErrorCodes.make(ErrorCodes.EDITOR_NOT_READY, "AnimationHandler not available")
	var resolved: Dictionary = handler._resolve_player_read(player_path)
	if resolved.has("error"):
		return resolved
	var player: AnimationPlayer = resolved.player

	if not player.has_animation(anim_name):
		return ErrorCodes.make(ErrorCodes.PROPERTY_NOT_ON_CLASS,
			"Animation '%s' not found on player at %s" % [anim_name, player_path])

	var anim: Animation = player.get_animation(anim_name)

	var root_node := player_root_node(player)

	var broken_tracks: Array[Dictionary] = []
	var valid_count := 0

	for i in anim.get_track_count():
		var track_path_str := str(anim.track_get_path(i))
		# Split on the FIRST colon (node↔property boundary), not the last.
		# Godot's get_node_or_null strips the ":property" tail natively, so
		# the valid/broken classification is the same either way — but for
		# BROKEN tracks the broken_tracks[].node_path field is what callers
		# read to diagnose the missing node, and rfind would surface
		# "MissingTarget:modulate" instead of "MissingTarget" for subpath
		# tracks like the "Target:modulate:a" shape preset_fade emits.
		var colon := track_path_str.find(":")
		var node_part: String
		if colon >= 0:
			node_part = track_path_str.substr(0, colon)
		else:
			node_part = track_path_str

		var target_node: Node = null
		if root_node != null:
			target_node = root_node.get_node_or_null(node_part)

		if target_node == null:
			broken_tracks.append({
				"index": i,
				"path": track_path_str,
				"type": track_type_to_string(anim.track_get_type(i)),
				"issue": "node_not_found",
				"node_path": node_part,
			})
		else:
			valid_count += 1

	return {
		"data": {
			"player_path": player_path,
			"animation_name": anim_name,
			"track_count": anim.get_track_count(),
			"valid_count": valid_count,
			"broken_count": broken_tracks.size(),
			"broken_tracks": broken_tracks,
			"valid": broken_tracks.is_empty(),
		}
	}


# ============================================================================
# Static helpers — shared with handler + presets
# ============================================================================

## Resolve the effective root node an AnimationPlayer animates against.
## Falls back to the player's parent when the explicit root_node NodePath is
## empty or unresolvable. Returns null when the player isn't in the tree.
##
## Mirrors the resolution Godot does at playback time so the validator,
## preset target resolver, and track-property coercer all see the same root.
static func player_root_node(player: AnimationPlayer) -> Node:
	if not player.is_inside_tree():
		return null
	var rn := player.root_node
	if rn != NodePath():
		var n := player.get_node_or_null(rn)
		if n != null:
			return n
	return player.get_parent()


## Coerce a JSON value to match the expected Godot type for the given
## track_path. Returns {"ok": value} or {"error": msg}.
## Passes the raw value through when the target node isn't in the scene
## yet (authoring-time path). Errors when the target exists but the
## property doesn't, or when parsing a typed value (Color/Vector2/Vector3)
## clearly fails — better to reject than silently store garbage.
## `override_root_node` lets callers supply the root to resolve target paths
## against when the player isn't in the tree yet (auto-create flow) — the
## player's future parent stands in for the root the AnimationPlayer will
## eventually use.
static func coerce_value_for_track(value: Variant, track_path: String, player: AnimationPlayer, override_root_node: Node = null) -> Dictionary:
	var ctx := resolve_track_prop_context(track_path, player, override_root_node)
	if ctx.has("error"):
		return {"error": ctx.error}
	return coerce_with_context(value, ctx)


## Resolve a track_path's target property type once, so callers coercing many
## keyframes avoid walking `get_property_list()` on every one. Returns:
##   {pass_through: true}                   — no resolution / authoring-time
##   {pass_through: false, prop_type, prop_name}  — coerce against this type
##   {error: msg}                           — property not found on target
##
## Supports Godot's native NodePath subpath form `property:sub` (e.g.
## `position:y`, `modulate:a`) — splits on the FIRST colon (node↔property
## boundary), resolves the base property on the target, and for known
## scalar subpaths (x/y/z/w on vectors, r/g/b/a on Color) narrows the
## coerce target to TYPE_FLOAT so JSON numbers land as floats, not dicts.
static func resolve_track_prop_context(track_path: String, player: AnimationPlayer, override_root_node: Node = null) -> Dictionary:
	var colon := track_path.find(":")
	if colon < 0:
		return {"pass_through": true}

	var node_part := track_path.substr(0, colon)
	var prop_full := track_path.substr(colon + 1)

	# Property may include a subpath: "position:y", "modulate:a", etc.
	var sub_colon := prop_full.find(":")
	var prop_base := prop_full if sub_colon < 0 else prop_full.substr(0, sub_colon)
	var prop_sub := "" if sub_colon < 0 else prop_full.substr(sub_colon + 1)

	var root_node: Node = override_root_node
	if root_node == null:
		root_node = player_root_node(player)
	if root_node == null:
		return {"pass_through": true}

	var target: Node = root_node.get_node_or_null(node_part)
	if target == null:
		# Target node isn't in the scene yet — authoring-time path. Pass through.
		return {"pass_through": true}

	for p in target.get_property_list():
		if p.name == prop_base:
			var base_type: int = p.get("type", TYPE_NIL)
			var coerce_type := base_type
			if not prop_sub.is_empty():
				var sub_type := subpath_component_type(base_type, prop_sub)
				if sub_type == TYPE_NIL:
					# Unknown subpath component — pass through so Godot's own
					# NodePath resolution raises at playback if it's truly bogus,
					# rather than fabricating a coerce error for a valid-but-
					# uncommon form (e.g. Transform3D subpaths).
					return {"pass_through": true}
				coerce_type = sub_type
			return {
				"pass_through": false,
				"prop_type": coerce_type,
				"prop_name": prop_full,
			}

	# Target exists but the property doesn't. Reject loudly — silently storing
	# the raw value here produces garbage keyframes at playback time.
	return {"error":
		"%s (target path: '%s')" %
		[PropertyErrors.build_message(target, prop_base), node_part]}


## Map a `property:sub` subpath to its scalar component type. Returns
## TYPE_NIL when the base type / subkey pair isn't one we recognise —
## callers pass-through in that case rather than mis-coerce.
static func subpath_component_type(base_type: int, sub: String) -> int:
	var entry = _SUBPATH_COMPONENTS.get(base_type)
	if entry == null or sub.length() != 1:
		return TYPE_NIL
	return entry[1] if (entry[0] as String).contains(sub) else TYPE_NIL


static func coerce_with_context(value: Variant, ctx: Dictionary) -> Dictionary:
	if ctx.get("pass_through", false):
		return {"ok": value}
	return coerce_for_type(value, ctx.prop_type, ctx.prop_name)


## Coerce a single value to the given Godot variant type. Returns
## {"ok": coerced} or {"error": msg}. Unknown types pass through.
static func coerce_for_type(value: Variant, prop_type: int, prop_name: String) -> Dictionary:
	match prop_type:
		TYPE_COLOR:
			if value is Color:
				return {"ok": value}
			if value is String:
				var s := value as String
				var a := Color.from_string(s, Color(0, 0, 0, 0))
				var b := Color.from_string(s, Color(1, 1, 1, 1))
				if a == b:
					return {"ok": a}
				return {"error": "Cannot parse '%s' as Color for property '%s'" % [s, prop_name]}
			if value is Dictionary and value.has("r") and value.has("g") and value.has("b"):
				return {"ok": Color(float(value.r), float(value.g), float(value.b), float(value.get("a", 1.0)))}
			return {"error": "Cannot coerce value to Color for property '%s' (expected string, {r,g,b}, or Color)" % prop_name}
		TYPE_VECTOR2:
			if value is Vector2:
				return {"ok": value}
			if value is Dictionary and value.has("x") and value.has("y"):
				return {"ok": Vector2(float(value.x), float(value.y))}
			if value is Array and value.size() >= 2:
				return {"ok": Vector2(float(value[0]), float(value[1]))}
			return {"error": "Cannot coerce value to Vector2 for property '%s' (expected {x,y}, [x,y], or Vector2)" % prop_name}
		TYPE_VECTOR3:
			if value is Vector3:
				return {"ok": value}
			if value is Dictionary and value.has("x") and value.has("y") and value.has("z"):
				return {"ok": Vector3(float(value.x), float(value.y), float(value.z))}
			return {"error": "Cannot coerce value to Vector3 for property '%s' (expected {x,y,z} or Vector3)" % prop_name}
		TYPE_FLOAT:
			if value is int or value is float:
				return {"ok": float(value)}
		TYPE_INT:
			if value is float or value is int:
				return {"ok": int(value)}
		TYPE_BOOL:
			if value is int or value is float or value is bool:
				return {"ok": bool(value)}
	return {"ok": value}


# ============================================================================
# Static helpers — parsing + serializing
# ============================================================================

## Parse a transition value: named string or raw float.
## Named values live in `_NAMED_TRANSITIONS` so the mapping has a single source.
static func parse_transition(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	if v is String:
		var key: String = (v as String).to_lower()
		if _NAMED_TRANSITIONS.has(key):
			return float(_NAMED_TRANSITIONS[key])
	return 1.0


## Map an Animation.TrackType enum to a stable string. Unknown types report
## as "unknown" rather than being silently coerced to "method" — callers that
## only produce value/method tracks can ignore the others; clients that want
## to round-trip bezier/audio/etc. get an honest label to key off.
static func track_type_to_string(track_type: int) -> String:
	match track_type:
		Animation.TYPE_VALUE: return "value"
		Animation.TYPE_METHOD: return "method"
		Animation.TYPE_POSITION_3D: return "position_3d"
		Animation.TYPE_ROTATION_3D: return "rotation_3d"
		Animation.TYPE_SCALE_3D: return "scale_3d"
		Animation.TYPE_BLEND_SHAPE: return "blend_shape"
		Animation.TYPE_BEZIER: return "bezier"
		Animation.TYPE_AUDIO: return "audio"
		Animation.TYPE_ANIMATION: return "animation"
		_: return "unknown"


static func loop_mode_to_string(mode: int) -> String:
	match mode:
		Animation.LOOP_LINEAR: return "linear"
		Animation.LOOP_PINGPONG: return "pingpong"
		_: return "none"


static func interp_to_string(mode: int) -> String:
	match mode:
		Animation.INTERPOLATION_NEAREST: return "nearest"
		Animation.INTERPOLATION_CUBIC: return "cubic"
		_: return "linear"


## Convert a Godot Variant to a JSON-safe value.
static func serialize_value(value: Variant) -> Variant:
	if value == null:
		return null
	match typeof(value):
		TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING:
			return value
		TYPE_STRING_NAME:
			return str(value)
		TYPE_VECTOR2:
			return {"x": value.x, "y": value.y}
		TYPE_VECTOR3:
			return {"x": value.x, "y": value.y, "z": value.z}
		TYPE_COLOR:
			return {"r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_NODE_PATH:
			return str(value)
		TYPE_ARRAY:
			var arr: Array = []
			for item in value:
				arr.append(serialize_value(item))
			return arr
		TYPE_DICTIONARY:
			var out := {}
			for k in value:
				out[str(k)] = serialize_value(value[k])
			return out
	return str(value)
