# Animation recipes — bounce, orbit, sweep, drift

Part of the Godot AI agent guide — see [TOOLS.md](TOOLS.md) for the full tool
list.

These four motion effects are **recipes**, not built-in presets: each one is a
handful of keyframes built from the core animation primitives
(`animation_create` + `animation_manage(op="add_property_track")`). Keeping them
out of the tool surface keeps core focused on machinery (tracks, coercion,
undo); the content stays yours to tune. The typed-keyframe coercion accepts the
JSON shape of the target property's real type (Vector2/3, Color, Transform3D,
Quaternion, Rect2, AABB, Vector3i, NodePath, StringName), so keyframe values are
written as plain JSON.

Workflow: `animation_create` once, then one `add_property_track` per track.
`time`s are seconds; per-key `transition` is `linear | ease_in | ease_out |
ease_in_out`. `loop_mode` is set at clip creation.

**Controls:** scaling rotates around `pivot_offset` (default `0,0` — the
top-left corner). Recenter it before adding a scale recipe, in the same edit:

```json
{"path": "/Main/HUD/Button", "property": "pivot_offset", "value": {"x": 60, "y": 20}}
```

## Bounce — press feedback

Center-pivot scale overshoot with a settle-back. 4 keys on `scale`:

```json
{"op": "add_property_track", "params": {
  "player_path": "/Main/HUD", "animation_name": "press",
  "track_path": "Button:scale",
  "keyframes": [
    {"time": 0.00, "value": [1.00, 1.00], "transition": "linear"},
    {"time": 0.14, "value": [1.15, 1.15], "transition": "ease_out"},
    {"time": 0.26, "value": [0.96, 0.96], "transition": "ease_in_out"},
    {"time": 0.40, "value": [1.00, 1.00], "transition": "linear"}
  ]}}
```

Baseline note: the first/last keys are the target's **current** scale. If the
widget is already scaled (say `1.2`), write the keys relative to that baseline
instead of `1.0`.

## Orbit — circular position

A closed circle sampled densely enough that linear interpolation reads as round
(16 segments ≈ 2% chord error). 3D orbits the XZ plane; 2D/Control orbit in
screen space. Generate the keys (radius defaults: `1.0` for 3D, `100.0` for 2D):

```gdscript
const SEGMENTS := 16
var keys: Array = []
for i in SEGMENTS + 1:                      # +1 closes the loop
    var angle := TAU * float(i) / float(SEGMENTS)
    keys.append({
        "time": 2.0 * float(i) / float(SEGMENTS),
        "value": [cos(angle) * radius, 0.0, sin(angle) * radius],   # [x, y] in 2D
        "transition": "linear",
    })
```

```json
{"op": "add_property_track", "params": {
  "player_path": "/Main", "animation_name": "orbit",
  "track_path": "Marker:position", "keyframes": "<keys>"}}
```

Because the last key equals the first, `animation_create(..., loop_mode="linear")`
keeps it running seamlessly.

## Sweep — radar / cooldown ring

One full turn; `loop_mode="linear"` makes it a continuous sweep, `"none"` a
one-shot. Radians for both `rotation` (2D/Control, in-plane) and the 3D
`rotation:y` subpath:

```json
{"op": "add_property_track", "params": {
  "player_path": "/Main/HUD", "animation_name": "sweep",
  "track_path": "CooldownRing:rotation",
  "keyframes": [
    {"time": 0.0, "value": 0.0,        "transition": "linear"},
    {"time": 1.0, "value": 6.2831855,  "transition": "linear"}
  ]}}
```

Start the first key at the target's **current** rotation (add it to every key)
so the sweep does not snap the node upright when it starts.

## Drift — scanlines, marquee, conveyor

One-axis offset. 2 keys, then let the loop mode do the work:

```json
{"op": "add_property_track", "params": {
  "player_path": "/Main", "animation_name": "drift",
  "track_path": "Scanline:position:x",
  "keyframes": [
    {"time": 0.0, "value": 0.0,  "transition": "linear"},
    {"time": 1.0, "value": 40.0, "transition": "linear"}
  ]}}
```

The clip ends at a net offset, so use `loop_mode="pingpong"` (back-and-forth) or
`"none"` (one-shot). `"linear"` would snap the target back to the start each
cycle.

## Wrapping a recipe as a project custom tool

If a project reuses a recipe everywhere, ship it as a **custom tool** instead
of repeating the keyframe JSON: the addon registers a spec with the Godot AI
tool registry, and agents reach it through `custom_manage` (or a first-class
`custom_<name>` tool when `promoted = true`). The tool owns the content; core
still owns the tracks, coercion, and undo.

```ini
# res://addons/animation_recipes/plugin.cfg
[plugin]
name="Animation Recipes"
description="Project animation recipes as Godot AI custom tools"
author="you"
version="1.0"
script="plugin.gd"
```

```gdscript
# res://addons/animation_recipes/plugin.gd
@tool
extends EditorPlugin

## EditorPlugin instance created by the engine; the handler reads its
## undo_redo so custom-tool actions land in the same editor history.
static var undo_redo: EditorUndoRedoManager

const RECIPE_SCRIPT := "res://addons/animation_recipes/recipes.gd"
const SOURCE_CFG := "res://addons/animation_recipes/plugin.cfg"
const RECIPES := ["bounce", "orbit", "sweep", "drift"]


func _enter_tree() -> void:
	undo_redo = get_undo_redo()
	var registry := McpToolRegistry.get_instance()
	if registry == null:
		return
	# Re-register after a Godot AI reload: the registry drops specs and
	# re-emits registry_ready, and this callback is idempotent.
	registry.registry_ready.connect(_register_recipes)
	_register_recipes()


func _register_recipes() -> void:
	var registry := McpToolRegistry.get_instance()
	if registry == null:
		return
	var specs: Array[McpCustomToolSpec] = []
	for recipe in RECIPES:
		var spec := McpCustomToolSpec.new()
		spec.name = "animation_recipe_" + recipe
		spec.description = "Project animation recipe: %s" % recipe
		spec.params_schema = {
			"type": "object",
			"properties": {
				"player_path": {"type": "string"},
				"track_target": {
					"type": "string",
					"description": "Track path root relative to the player's root_node, e.g. 'Button'",
				},
			},
			"required": ["player_path", "track_target"],
		}
		spec.script_path = RECIPE_SCRIPT
		spec.method = StringName(recipe)
		spec.source_path = SOURCE_CFG
		spec.timeout_ms = 5000
		specs.append(spec)
	registry.batch_register(specs)
```

```gdscript
# res://addons/animation_recipes/recipes.gd
@tool
extends RefCounted

## Recipe handlers: build the keyframes here, commit them through the public
## animation handler (tracks + coercion + undo stay in core).

const AnimationHandler := preload("res://addons/godot_ai/handlers/animation_handler.gd")
const Plugin := preload("res://addons/animation_recipes/plugin.gd")


func bounce(params: Dictionary, _ctx: McpCallContext) -> Dictionary:
	var player_path: String = params.get("player_path", "")
	var track_target: String = params.get("track_target", "")
	if player_path.is_empty() or track_target.is_empty():
		return McpErrorCodes.make(McpErrorCodes.MISSING_REQUIRED_PARAM,
			"player_path and track_target are required")

	var handler := AnimationHandler.new(Plugin.undo_redo)
	var created := handler.create_animation({
		"player_path": player_path, "name": "press", "length": 0.4,
	})
	if created.has("error"):
		return created

	var added := handler.add_property_track({
		"player_path": player_path,
		"animation_name": "press",
		"track_path": "%s:scale" % track_target,
		"keyframes": [
			{"time": 0.00, "value": [1.0, 1.0], "transition": "linear"},
			{"time": 0.14, "value": [1.15, 1.15], "transition": "ease_out"},
			{"time": 0.26, "value": [0.96, 0.96], "transition": "ease_in_out"},
			{"time": 0.40, "value": [1.0, 1.0], "transition": "linear"},
		],
	})
	if added.has("error"):
		return added
	return {"data": {"recipe": "bounce", "animation_name": "press", "undoable": true}}
```

`orbit`, `sweep`, and `drift` follow the same shape — generate the keyframe
array (see the recipes above) and hand it to `add_property_track`.
