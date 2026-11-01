@tool
extends McpTestSuite

const Filesystem := preload("res://addons/godot_ai/handlers/filesystem_handler.gd")
const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const TEXTURE := "res://tests/fixtures/reimport.svg"
const AUDIO := "res://tests/fixtures/import_settings.wav"
var _handler: Filesystem
var _original := {}
var _audio_bytes: PackedByteArray

func suite_name() -> String:
	return "import_settings"

func suite_setup(_ctx: Dictionary) -> void:
	_handler = Filesystem.new()
	for path in [TEXTURE, AUDIO]:
		_original[path] = FileAccess.get_file_as_string(path + ".import")
	_audio_bytes = FileAccess.get_file_as_bytes(AUDIO)

func suite_teardown() -> void:
	_restore()

func _restore() -> void:
	var source := FileAccess.open(AUDIO, FileAccess.WRITE)
	source.store_buffer(_audio_bytes)
	source.close()
	for path in _original:
		McpResourceIO.write_text_to_disk(path + ".import", _original[path])
	_handler.reimport({"paths": [TEXTURE, AUDIO]})

func test_read_reports_stored_types_and_native_validity() -> void:
	var result := _handler.import_get({"path": TEXTURE})
	assert_eq(result.data.importer, "texture")
	assert_eq(result.data.schema_source, "stored_import_config")
	assert_eq(result.data.option_types["svg/scale"], "float")
	assert_true(result.data.writable_options.has("svg/scale"))
	assert_eq(result.data.options["svg/scale"], 1.0)
	assert_true(result.data.import_valid)
	assert_eq(result.data.revision, FileAccess.get_sha256(TEXTURE + ".import"))
	assert_is_error(_handler.import_get({"path": "res://project.godot"}), ErrorCodes.RESOURCE_NOT_FOUND)

func test_texture_reimport_changes_native_dimensions_and_preserves_uid() -> void:
	var before: Dictionary = _handler.import_get({"path": TEXTURE}).data
	var original := ResourceLoader.load(TEXTURE, "", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	var uid := ResourceLoader.get_resource_uid(TEXTURE)
	var result := _handler.import_set({"path": TEXTURE, "options": {"svg/scale": 2.0}, "expected_revision": before.revision, "_request_id": "owned-request"})
	var disk := ResourceLoader.load(TEXTURE, "", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	assert_true(result.data.settings_committed)
	assert_true(result.data.import_attempted)
	assert_true(result.data.import_valid)
	assert_false(result.data.import_pending)
	assert_false(result.data.undoable)
	assert_eq(disk.get_width(), original.get_width() * 2)
	assert_eq(disk.get_height(), original.get_height() * 2)
	assert_eq(ResourceLoader.get_resource_uid(TEXTURE), uid)
	assert_eq(_handler.import_get({"path": TEXTURE}).data.options["mipmaps/generate"], before.options["mipmaps/generate"])
	_restore()

func test_audio_native_loop_properties_change() -> void:
	var result := _handler.import_set({"path": AUDIO, "options": {"edit/loop_mode": 2.0, "edit/loop_begin": 5, "edit/loop_end": 100}})
	var stream := ResourceLoader.load(AUDIO, "", ResourceLoader.CACHE_MODE_IGNORE) as AudioStreamWAV
	assert_true(result.data.import_valid)
	assert_eq(stream.loop_mode, AudioStreamWAV.LOOP_FORWARD)
	assert_eq(stream.loop_begin, 5)
	assert_eq(stream.loop_end, 100)
	_restore()

func test_settings_only_then_explicit_reimport() -> void:
	var original := ResourceLoader.load(AUDIO, "", ResourceLoader.CACHE_MODE_IGNORE) as AudioStreamWAV
	var result := _handler.import_set({"path": AUDIO, "options": {"edit/loop_mode": 2}, "reimport": false})
	assert_true(result.data.settings_committed)
	assert_false(result.data.import_attempted)
	assert_true(result.data.import_pending)
	var prior_output := ResourceLoader.load(AUDIO, "", ResourceLoader.CACHE_MODE_IGNORE) as AudioStreamWAV
	assert_eq(prior_output.loop_mode, original.loop_mode)
	var imported := _handler.reimport({"paths": [AUDIO]})
	assert_eq(imported.data.reimported, [AUDIO])
	assert_eq(imported.data.failed_imports, [])
	assert_true(imported.data.import_status[AUDIO])
	var changed := ResourceLoader.load(AUDIO, "", ResourceLoader.CACHE_MODE_IGNORE) as AudioStreamWAV
	assert_eq(changed.loop_mode, AudioStreamWAV.LOOP_FORWARD)
	_restore()

func test_invalid_options_and_stale_revision_leave_disk_unchanged() -> void:
	var revision := FileAccess.get_sha256(AUDIO + ".import")
	for options in [{"unknown": 1}, {"_subresources": {}}, {"edit/loop_mode": true}, {"edit/loop_mode": 2.5}, {"edit/loop_mode": 1e300}, {"force/max_rate": "bad"}, {"force/max_rate_hz": INF}]:
		var result := _handler.import_set({"path": AUDIO, "options": options})
		var expected_code: String = ErrorCodes.PROPERTY_NOT_ON_CLASS if options.has("unknown") else (ErrorCodes.VALUE_OUT_OF_RANGE if options.has("_subresources") else ErrorCodes.WRONG_TYPE)
		assert_is_error(result, expected_code)
		assert_false(result.error.data.settings_committed)
		assert_false(result.error.data.import_attempted)
		assert_eq(FileAccess.get_sha256(AUDIO + ".import"), revision)
	var stale := _handler.import_set({"path": AUDIO, "options": {"edit/loop_mode": 2}, "expected_revision": "stale"})
	assert_is_error(stale, ErrorCodes.INVALID_PARAMS)
	assert_false(stale.error.data.settings_committed)
	assert_eq(FileAccess.get_sha256(AUDIO + ".import"), revision)

func test_busy_scan_refuses_without_writing() -> void:
	var revision := FileAccess.get_sha256(AUDIO + ".import")
	var prior = Filesystem._active_scan
	Filesystem._active_scan = Filesystem.ScanCompletion.new()
	var result := _handler.import_set({"path": AUDIO, "options": {"edit/loop_mode": 2}})
	var reimport_result := _handler.reimport({"paths": [AUDIO]})
	Filesystem._active_scan = prior
	assert_is_error(result, ErrorCodes.EDITOR_NOT_READY)
	assert_false(result.error.data.settings_committed)
	assert_is_error(reimport_result, ErrorCodes.EDITOR_NOT_READY)
	assert_eq(FileAccess.get_sha256(AUDIO + ".import"), revision)

func test_native_reimport_preserves_nested_connection_pause() -> void:
	var connection := McpConnection.new()
	connection.pause()
	var observed: Array[int] = []
	var capture := func(_paths: PackedStringArray): observed.append(connection.pause_depth())
	var efs := EditorInterface.get_resource_filesystem()
	efs.resources_reimporting.connect(capture)
	var handler := Filesystem.new(connection)
	var result := handler.import_set({"path": AUDIO, "options": {"edit/loop_mode": 2}})
	efs.resources_reimporting.disconnect(capture)
	assert_true(result.data.import_valid)
	assert_gt(observed.size(), 0)
	for depth in observed:
		assert_eq(depth, 2)
	assert_eq(connection.pause_depth(), 1)
	connection.resume()
	assert_false(connection.pause_processing)
	connection.free()
	_restore()

func test_failed_native_import_reports_settings_already_committed() -> void:
	# Corrupt only this suite's owned source, then restore it before assertions.
	McpResourceIO.write_text_to_disk(AUDIO, "invalid wave fixture")
	var result := _handler.import_set({"path": AUDIO, "options": {"edit/loop_mode": 2}})
	var committed := _handler.import_get({"path": AUDIO})
	var failed_batch := _handler.reimport({"paths": [AUDIO]})
	var directory := EditorInterface.get_resource_filesystem().get_filesystem_path(AUDIO.get_base_dir())
	var native_valid := directory.get_file_import_is_valid(directory.find_file_index(AUDIO.get_file()))
	_restore()
	assert_is_error(result, ErrorCodes.INTERNAL_ERROR)
	assert_true(result.error.data.settings_committed)
	assert_true(result.error.data.import_attempted)
	assert_eq(result.error.data.import_valid, native_valid, "Report native validity even when the importer leaves it true after errors")
	assert_false(result.error.data.import_succeeded)
	assert_true(result.error.data.import_pending)
	assert_gt(result.error.data.import_error_count, 0)
	assert_true(result.error.data.import_diagnostics.any(func(entry): return "Not a WAV" in entry.text))
	assert_eq(committed.data.options["edit/loop_mode"], 2)
	assert_eq(committed.data.import_valid, native_valid, "Readback reports the actual native flag, not inferred success")
	assert_eq(failed_batch.data.reimported, [])
	if native_valid == true:
		assert_eq(failed_batch.data.unconfirmed_imports, [AUDIO])
	else:
		assert_eq(failed_batch.data.failed_imports, [AUDIO])
	assert_eq(failed_batch.data.import_status[AUDIO], native_valid)
	assert_gt(failed_batch.data.import_error_count, 0)

func test_rejects_switching_and_invalid_control_types_before_commit() -> void:
	var revision := FileAccess.get_sha256(AUDIO + ".import")
	for controls in [{"importer": "oggvorbis"}, {"subresources": {}}, {"reimport": "false"}, {"expected_revision": 2}]:
		var params := {"path": AUDIO, "options": {"edit/loop_mode": 2}}
		params.merge(controls)
		var result := _handler.import_set(params)
		assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE if controls.has("importer") or controls.has("subresources") else ErrorCodes.WRONG_TYPE)
		assert_false(result.error.data.settings_committed)
		assert_eq(FileAccess.get_sha256(AUDIO + ".import"), revision)

func test_complex_options_readable_but_read_only_and_sections_preserved() -> void:
	var config := ConfigFile.new()
	assert_eq(config.load(AUDIO + ".import"), OK)
	config.set_value("params", "_subresources", {"animations": {"Walk": {"loop_mode": 1}}})
	config.set_value("params", "complex", Vector3(1, 2, 3))
	config.set_value("metadata", "custom", "kept")
	assert_eq(config.save(AUDIO + ".import"), OK)
	var readback := _handler.import_get({"path": AUDIO})
	assert_eq(readback.data.options._subresources.animations.Walk.loop_mode, 1)
	assert_eq(readback.data.option_types.complex, "Vector3")
	assert_false(readback.data.writable_options.has("complex"))
	assert_false(readback.data.writable_options.has("_subresources"))
	var revision: String = readback.data.revision
	assert_is_error(_handler.import_set({"path": AUDIO, "options": {"complex": {"x": 4, "y": 5, "z": 6}}}))
	assert_eq(FileAccess.get_sha256(AUDIO + ".import"), revision)
	var changed := _handler.import_set({"path": AUDIO, "options": {"edit/loop_mode": 2}, "reimport": false})
	assert_true(changed.data.settings_committed)
	assert_eq(config.load(AUDIO + ".import"), OK)
	assert_eq(config.get_value("metadata", "custom"), "kept")
	assert_eq(config.get_value("params", "complex"), Vector3(1, 2, 3))
	assert_eq(config.get_value("params", "_subresources").animations.Walk.loop_mode, 1)
	_restore()
