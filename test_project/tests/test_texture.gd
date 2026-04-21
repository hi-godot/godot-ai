@tool
extends McpTestSuite

## Tests for TextureHandler — GradientTexture2D + NoiseTexture2D creation.

var _handler: TextureHandler
var _undo_redo: EditorUndoRedoManager


func suite_name() -> String:
	return "texture"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.get("undo_redo")
	_handler = TextureHandler.new(_undo_redo)


func _add_sprite_2d(name: String) -> Sprite2D:
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null:
		return null
	var s := Sprite2D.new()
	s.name = name
	scene_root.add_child(s)
	s.set_owner(scene_root)
	return s


func _remove_node(node: Node) -> void:
	if node == null:
		return
	if node.get_parent():
		node.get_parent().remove_child(node)
	node.queue_free()


# ----- gradient_texture_create validation -----

func test_gradient_requires_two_stops() -> void:
	var result := _handler.create_gradient_texture({
		"stops": [{"offset": 0.0, "color": {"r": 1, "g": 0, "b": 0, "a": 1}}],
		"path": "/Main/Line",
		"property": "texture",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_gradient_invalid_fill() -> void:
	var result := _handler.create_gradient_texture({
		"stops": [
			{"offset": 0.0, "color": "#ff0000"},
			{"offset": 1.0, "color": "#0000ff"},
		],
		"fill": "not_a_fill_mode",
		"path": "/Main/Line",
		"property": "texture",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_gradient_no_home_errors() -> void:
	var result := _handler.create_gradient_texture({
		"stops": [
			{"offset": 0.0, "color": "#ff0000"},
			{"offset": 1.0, "color": "#0000ff"},
		],
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_gradient_stop_missing_keys() -> void:
	var result := _handler.create_gradient_texture({
		"stops": [
			{"offset": 0.0},
			{"offset": 1.0, "color": "#0000ff"},
		],
		"path": "/Main/Line",
		"property": "texture",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_gradient_stop_wrong_shape_color_reports_keys() -> void:
	## Passing {x,y,z} where {r,g,b} is expected previously returned a
	## generic "could not be coerced to Color" — the migration adds the
	## prefix and the expected/got-keys breakdown so agents self-correct.
	var result := _handler.create_gradient_texture({
		"stops": [
			{"offset": 0.0, "color": {"x": 1, "y": 0, "z": 0}},
			{"offset": 1.0, "color": "#0000ff"},
		],
		"path": "/Main/Line",
		"property": "texture",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	var msg: String = result.error.message
	assert_contains(msg, "stops[0].color")
	assert_contains(msg, "Color")
	assert_contains(msg, "expected")  # pins the expected-vs-got keys diff
	assert_contains(msg, "got")
	assert_contains(msg, "r")  # expected-keys list includes 'r'


func test_gradient_stop_non_dict_non_string_color_is_rejected() -> void:
	## Non-Dict non-String inputs (int, array, etc.) must still error —
	## _check_dict_coerce_failed only fires on Dicts, so the type-fallback
	## check has to catch the rest.
	var result := _handler.create_gradient_texture({
		"stops": [
			{"offset": 0.0, "color": 42},
			{"offset": 1.0, "color": "#0000ff"},
		],
		"path": "/Main/Line",
		"property": "texture",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)
	assert_contains(result.error.message, "stops[0].color")


# ----- gradient_texture_create happy paths -----

func test_gradient_assigns_typed_gradient_and_colors() -> void:
	var s := _add_sprite_2d("TestGradSprite")
	if s == null:
		skip("No scene root")
		return
	var result := _handler.create_gradient_texture({
		"stops": [
			{"offset": 0.0, "color": {"r": 1, "g": 0, "b": 0, "a": 1}},
			{"offset": 1.0, "color": {"r": 0, "g": 0, "b": 1, "a": 1}},
		],
		"fill": "radial",
		"path": s.get_path(),
		"property": "texture",
	})
	assert_has_key(result, "data")
	assert_eq(result.data.stop_count, 2)
	assert_true(result.data.undoable)
	# Assert on stored Variant — per CLAUDE.md.
	assert_true(s.texture is GradientTexture2D)
	assert_true(s.texture.gradient is Gradient)
	var g: Gradient = s.texture.gradient
	assert_eq(g.offsets.size(), 2)
	assert_eq(g.offsets[0], 0.0)
	assert_eq(g.offsets[1], 1.0)
	# The assertion that matters per CLAUDE.md:
	# colors must remain Color, not a raw dict.
	assert_true(g.colors[0] is Color)
	assert_eq(g.colors[0].r, 1.0)
	assert_eq(g.colors[1].b, 1.0)
	assert_eq(s.texture.fill, GradientTexture2D.FILL_RADIAL)
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_true(s.texture == null)
	_remove_node(s)


func test_gradient_saves_to_disk() -> void:
	var out_path := "res://test_tmp_grad.tres"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var result := _handler.create_gradient_texture({
		"stops": [
			{"offset": 0.0, "color": "#ff0000"},
			{"offset": 1.0, "color": "#0000ff"},
		],
		"resource_path": out_path,
	})
	assert_has_key(result, "data")
	assert_false(result.data.undoable)
	assert_true(FileAccess.file_exists(out_path))
	var loaded := ResourceLoader.load(out_path)
	assert_true(loaded is GradientTexture2D)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))


# ----- noise_texture_create -----

func test_noise_invalid_type() -> void:
	var result := _handler.create_noise_texture({
		"noise_type": "not_a_noise",
		"path": "/Main/Foo",
		"property": "texture",
	})
	assert_is_error(result, McpErrorCodes.INVALID_PARAMS)


func test_noise_assigns_typed_chain() -> void:
	var s := _add_sprite_2d("TestNoiseSprite")
	if s == null:
		skip("No scene root")
		return
	var result := _handler.create_noise_texture({
		"noise_type": "perlin",
		"width": 64,
		"height": 64,
		"frequency": 0.05,
		"seed": 7,
		"fractal_octaves": 3,
		"path": s.get_path(),
		"property": "texture",
	})
	assert_has_key(result, "data")
	assert_true(result.data.undoable)
	assert_true(s.texture is NoiseTexture2D)
	assert_true(s.texture.noise is FastNoiseLite)
	var n: FastNoiseLite = s.texture.noise
	assert_eq(n.noise_type, FastNoiseLite.TYPE_PERLIN)
	assert_eq(n.seed, 7)
	assert_eq(n.fractal_octaves, 3)
	assert_true(editor_undo(_undo_redo), "undo should succeed")
	assert_true(s.texture == null)
	_remove_node(s)


func test_noise_saves_to_disk() -> void:
	var out_path := "res://test_tmp_noise.tres"
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
	var result := _handler.create_noise_texture({
		"noise_type": "simplex_smooth",
		"width": 32,
		"height": 32,
		"resource_path": out_path,
	})
	assert_has_key(result, "data")
	assert_true(FileAccess.file_exists(out_path))
	var loaded := ResourceLoader.load(out_path)
	assert_true(loaded is NoiseTexture2D)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(out_path))
