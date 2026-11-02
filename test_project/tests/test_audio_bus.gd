@tool
extends McpTestSuite

const Handler := preload("res://addons/godot_ai/handlers/audio_bus_handler.gd")
var _handler: Handler
var _undo_redo: EditorUndoRedoManager
var _history: UndoRedo
var _before: AudioBusLayout
const EXPORT_PATH := "res://tests/_audio_bus_export.tres"


func suite_name() -> String:
	return "audio_bus"


func suite_setup(ctx: Dictionary) -> void:
	_undo_redo = ctx.undo_redo
	_handler = Handler.new(_undo_redo)


func setup() -> void:
	_before = AudioServer.generate_bus_layout()
	AudioServer.set_bus_layout(AudioBusLayout.new())
	AudioServer.bus_layout_changed.emit()
	_history = _undo_redo.get_history_undo_redo(EditorUndoRedoManager.GLOBAL_HISTORY)


func teardown() -> void:
	AudioServer.set_bus_layout(_before)
	AudioServer.bus_layout_changed.emit()
	_before = null
	DirAccess.remove_absolute(EXPORT_PATH)
	DirAccess.remove_absolute(EXPORT_PATH + ".uid")


func _ok(result: Dictionary) -> Dictionary:
	assert_false(result.has("error"), str(result))
	assert_has_key(result, "data")
	return result.get("data", {})


func _add(name: String, send: String = "Master") -> void:
	_ok(_handler.bus_add({"name": name, "send": send}))


func test_bus_add_insert_order_routing_and_global_undo() -> void:
	_add("Music")
	_add("Voice", "Music")
	var before: Dictionary = _handler.bus_list({}).data
	var added := _ok(_handler.bus_add({"name": "Effects", "at_position": 1}))
	assert_eq(added.bus.name, "Effects")
	assert_eq(AudioServer.get_bus_name(1), "Effects")
	assert_eq(AudioServer.get_bus_name(2), "Music")
	assert_eq(String(AudioServer.get_bus_send(3)), "Music")
	assert_true(_history.undo())
	assert_eq(_handler.bus_list({}).data, before)
	assert_true(_history.redo())
	assert_eq(AudioServer.get_bus_name(1), "Effects")
	assert_eq(String(AudioServer.get_bus_send(3)), "Music")


func test_bus_set_is_atomic_and_restores_all_flags() -> void:
	_add("Music")
	_add("Effects")
	var before: Dictionary = _handler.bus_list({}).data
	_ok(_handler.bus_set({"name": "Effects", "volume_db": -12.0, "send": "Music", "mute": true, "solo": true, "bypass_effects": true}))
	assert_eq(AudioServer.get_bus_volume_db(2), -12.0)
	assert_eq(String(AudioServer.get_bus_send(2)), "Music")
	assert_true(AudioServer.is_bus_mute(2))
	assert_true(AudioServer.is_bus_solo(2))
	assert_true(AudioServer.is_bus_bypassing_effects(2))
	var changed: Dictionary = _handler.bus_list({}).data
	assert_true(_history.undo())
	assert_eq(_handler.bus_list({}).data, before)
	assert_true(_history.redo())
	assert_eq(_handler.bus_list({}).data, changed)
	var version := _history.get_version()
	assert_is_error(_handler.bus_set({"name": "Effects", "volume_db": -20.0, "mute": "false"}))
	assert_eq(_handler.bus_list({}).data, changed)
	assert_eq(_history.get_version(), version)


func test_bus_remove_undo_restores_full_state_and_effect_identity() -> void:
	_add("Music")
	_add("Effects", "Music")
	_add("Voice", "Music")
	_ok(_handler.bus_set({"name": "Effects", "volume_db": -7.0, "mute": true, "solo": true, "bypass_effects": true}))
	_ok(_handler.bus_effect_add({"bus": "Effects", "effect_class": "AudioEffectCompressor", "enabled": false, "properties": {"threshold": -18.0, "sidechain": "Voice"}}))
	var effect := AudioServer.get_bus_effect(2, 0)
	var before: Dictionary = _handler.bus_list({}).data
	assert_is_error(_handler.bus_remove({"name": "Voice"}), "INVALID_PARAMS", "referenced sidechains must be rerouted")
	assert_eq(_handler.bus_list({}).data, before)
	_ok(_handler.bus_remove({"name": "Effects"}))
	assert_eq(AudioServer.get_bus_name(2), "Voice")
	assert_eq(String(AudioServer.get_bus_send(2)), "Music")
	assert_true(_history.undo())
	assert_eq(_handler.bus_list({}).data, before)
	assert_eq(AudioServer.get_bus_effect(2, 0), effect)
	assert_false(AudioServer.is_bus_effect_enabled(2, 0))
	assert_true(_history.redo())
	assert_eq(AudioServer.get_bus_index("Effects"), -1)


func test_bus_refusals_do_not_mutate_or_create_undo() -> void:
	_add("Music")
	_add("Voice", "Music")
	var before: Dictionary = _handler.bus_list({}).data
	var version := _history.get_version()
	for params in [{"name": "Master"}, {"name": "Music"}, {"name": "New", "at_position": 0}, {"name": "New", "at_position": 1.5}, {"name": "New", "at_position": true}, {"name": "New", "send": "missing"}, {"name": "New", "at_position": 1, "send": "Voice"}]:
		assert_is_error(_handler.bus_add(params))
	assert_is_error(_handler.bus_remove({"name": "Master"}))
	assert_is_error(_handler.bus_remove({"name": "Music"}))
	assert_is_error(_handler.bus_remove({"name": "missing"}))
	for params in [{"name": "Master", "send": "Master"}, {"name": "Music", "send": "Voice"}, {"name": "Music", "volume_db": INF}, {"name": "Music", "volume_db": NAN}, {"name": "Music", "volume_db": true}, {"name": "Music", "solo": 1}, {"name": "Music"}]:
		assert_is_error(_handler.bus_set(params))
	assert_eq(_handler.bus_list({}).data, before)
	assert_eq(_history.get_version(), version)


func test_effect_add_edit_remove_and_undo_preserve_identity_and_order() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		skip("No scene open")
		return
	var scene_history := _undo_redo.get_history_undo_redo(_undo_redo.get_object_history_id(root))
	var scene_version := scene_history.get_version()
	_add("Music")
	_add("Voice")
	_ok(_handler.bus_effect_add({"bus": "Music", "effect_class": "AudioEffectCompressor", "properties": {"threshold": -18.0, "sidechain": "Voice"}, "enabled": false}))
	var compressor := AudioServer.get_bus_effect(1, 0)
	assert_true(compressor is AudioEffectCompressor)
	assert_eq(compressor.get("threshold"), -18.0)
	assert_eq(String(compressor.get("sidechain")), "Voice")
	assert_false(AudioServer.is_bus_effect_enabled(1, 0))
	assert_true(_history.undo())
	assert_eq(AudioServer.get_bus_effect_count(1), 0)
	assert_true(_history.redo())
	assert_eq(AudioServer.get_bus_effect(1, 0), compressor)
	_ok(_handler.bus_effect_add({"bus": "Music", "effect_class": "AudioEffectReverb", "at_position": 0}))
	var reverb := AudioServer.get_bus_effect(1, 0)
	assert_eq(AudioServer.get_bus_effect(1, 1), compressor)
	assert_false(AudioServer.is_bus_effect_enabled(1, 1))
	_ok(_handler.bus_effect_set({"bus": "Music", "index": 1, "properties": {"threshold": -24.0, "sidechain": ""}, "enabled": true}))
	assert_eq(AudioServer.get_bus_effect(1, 1), compressor)
	assert_eq(compressor.get("threshold"), -24.0)
	assert_eq(String(compressor.get("sidechain")), "")
	assert_true(AudioServer.is_bus_effect_enabled(1, 1))
	assert_true(_history.undo())
	assert_eq(compressor.get("threshold"), -18.0)
	assert_eq(String(compressor.get("sidechain")), "Voice")
	assert_false(AudioServer.is_bus_effect_enabled(1, 1))
	_ok(_handler.bus_effect_remove({"bus": "Music", "index": 1}))
	assert_eq(AudioServer.get_bus_effect(1, 0), reverb)
	assert_eq(AudioServer.get_bus_effect_count(1), 1)
	assert_true(_history.undo())
	assert_eq(AudioServer.get_bus_effect(1, 0), reverb)
	assert_eq(AudioServer.get_bus_effect(1, 1), compressor)
	assert_false(AudioServer.is_bus_effect_enabled(1, 1))
	assert_true(_history.redo())
	assert_eq(AudioServer.get_bus_effect_count(1), 1)
	assert_eq(scene_history.get_version(), scene_version, "audio effects belong only to global history")


func test_effect_invalid_properties_are_atomic() -> void:
	_add("Music")
	_ok(_handler.bus_effect_add({"bus": "Music", "effect_class": "AudioEffectCompressor"}))
	var before: Dictionary = _handler.bus_list({}).data
	var effect := AudioServer.get_bus_effect(1, 0)
	var version := _history.get_version()
	for properties in [{"threshold": -30.0, "missing": 1}, {"threshold": {}}, {"script": "res://tests/test_audio_bus.gd"}, {"sidechain": "missing"}, {"threshold": INF}, {"threshold": NAN}, {"threshold": 1.0e300}]:
		assert_is_error(_handler.bus_effect_set({"bus": "Music", "index": 0, "properties": properties}))
	for params in [{"effect_class": "Node"}, {"effect_class": "AudioEffect"}, {"effect_class": "Missing"}, {"effect_class": "AudioEffectReverb", "enabled": 1}, {"effect_class": "AudioEffectReverb", "at_position": 0.5}]:
		params.bus = "Music"
		assert_is_error(_handler.bus_effect_add(params))
	for index in [-1, 2, 0.5, true, INF]:
		assert_is_error(_handler.bus_effect_remove({"bus": "Music", "index": index}))
	assert_is_error(_handler.bus_effect_set({"bus": "Music", "index": 0, "enabled": "false"}))
	assert_eq(AudioServer.get_bus_effect(1, 0), effect)
	assert_eq(_handler.bus_list({}).data, before)
	assert_eq(_history.get_version(), version)


func test_layout_export_preserves_settings_live_state_and_undo() -> void:
	_add("Music")
	_ok(_handler.bus_set({"name": "Music", "volume_db": -9.0, "mute": true, "solo": true, "bypass_effects": true}))
	_ok(_handler.bus_effect_add({"bus": "Music", "effect_class": "AudioEffectCompressor", "enabled": false, "properties": {"threshold": -22.0}}))
	var before: Dictionary = _handler.bus_list({}).data
	var setting: Variant = ProjectSettings.get_setting("audio/buses/default_bus_layout")
	var version := _history.get_version()
	var saved := _ok(_handler.bus_layout_save({"path": EXPORT_PATH}))
	assert_false(saved.undoable)
	assert_eq(_handler.bus_list({}).data, before)
	assert_eq(ProjectSettings.get_setting("audio/buses/default_bus_layout"), setting)
	assert_eq(_history.get_version(), version)
	var bytes_before := FileAccess.get_file_as_bytes(EXPORT_PATH)
	assert_is_error(_handler.bus_layout_save({"path": EXPORT_PATH}))
	assert_eq(FileAccess.get_file_as_bytes(EXPORT_PATH), bytes_before)
	assert_is_error(_handler.bus_layout_save({"path": "res://project.godot", "overwrite": true}))
	var layout := ResourceLoader.load(EXPORT_PATH, "AudioBusLayout", ResourceLoader.CACHE_MODE_IGNORE) as AudioBusLayout
	assert_true(layout != null)
	assert_eq(layout.get("bus/1/name"), "Music")
	assert_eq(layout.get("bus/1/volume_db"), -9.0)
	assert_true(layout.get("bus/1/mute"))
	assert_true(layout.get("bus/1/solo"))
	assert_true(layout.get("bus/1/bypass_fx"))
	var effect: AudioEffect = layout.get("bus/1/effect/0/effect")
	assert_true(effect is AudioEffectCompressor)
	assert_eq(effect.get("threshold"), -22.0)
	assert_false(layout.get("bus/1/effect/0/enabled"))
	assert_true(_history.undo(), "export must preserve effect-add undo")
	assert_eq(AudioServer.get_bus_effect_count(1), 0)


func test_native_volume_overflow_is_rejected_before_mutation() -> void:
	_add("Music")
	AudioServer.set_bus_volume_db(1, 1.0e300)
	assert_false(is_finite(AudioServer.get_bus_volume_db(1)), "native float32 storage overflows a finite GDScript double")
	AudioServer.set_bus_volume_db(1, -8.0)
	var version := _history.get_version()
	for value in [1.0e300, -1.0e300]:
		assert_is_error(_handler.bus_set({"name": "Music", "volume_db": value}))
		assert_eq(AudioServer.get_bus_volume_db(1), -8.0)
	assert_eq(_history.get_version(), version)


func test_scripted_effect_is_refused_before_duplication_or_setters() -> void:
	_add("Music")
	var script := load("res://tests/fixtures/audio_scripted_effect.gd")
	var effect: AudioEffect = script.new()
	AudioServer.add_bus_effect(1, effect)
	var calls: int = script.setter_calls
	var version := _history.get_version()
	assert_is_error(_handler.bus_effect_set({"bus": "Music", "index": 0, "properties": {"custom_gain": 2.0}}), "WRONG_TYPE")
	assert_eq(script.setter_calls, calls)
	assert_eq(effect.get("custom_gain"), 1.0)
	assert_eq(AudioServer.get_bus_effect(1, 0), effect)
	assert_eq(_history.get_version(), version)


func test_native_bus_names_and_record_effect_are_preserved() -> void:
	var name := " Music/SFX:[main], ] Ω "
	var added := _ok(_handler.bus_add({"name": name}))
	assert_eq(added.bus.name, name)
	assert_eq(AudioServer.get_bus_name(1), name)
	_ok(_handler.bus_effect_add({"bus": name, "effect_class": "AudioEffectRecord", "properties": {"format": AudioStreamWAV.FORMAT_16_BITS}}))
	var effect := AudioServer.get_bus_effect(1, 0)
	assert_true(effect is AudioEffectRecord)
	_ok(_handler.bus_effect_set({"bus": name, "index": 0, "properties": {"format": AudioStreamWAV.FORMAT_8_BITS}}))
	assert_eq(AudioServer.get_bus_effect(1, 0), effect)
	assert_eq(effect.get("format"), AudioStreamWAV.FORMAT_8_BITS)
	assert_true(_history.undo())
	assert_eq(effect.get("format"), AudioStreamWAV.FORMAT_16_BITS)


func test_remove_undo_redo_refreshes_native_editor_bus_controls() -> void:
	_add("Music")
	var base := EditorInterface.get_base_control()
	assert_eq(base.find_children("*", "EditorAudioBus", true, false).size(), 2)
	_ok(_handler.bus_remove({"name": "Music"}))
	assert_eq(base.find_children("*", "EditorAudioBus", true, false).size(), 1)
	assert_true(_history.undo())
	assert_eq(AudioServer.get_bus_name(1), "Music")
	assert_eq(base.find_children("*", "EditorAudioBus", true, false).size(), 2, "undo must notify native bus controls")
	assert_true(_history.redo())
	assert_eq(AudioServer.bus_count, 1)
	assert_eq(base.find_children("*", "EditorAudioBus", true, false).size(), 1)
