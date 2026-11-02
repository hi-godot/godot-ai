@tool
extends McpTestSuite

const ResourceHandler := preload("res://addons/godot_ai/handlers/resource_handler.gd")
const FILE := "res://tests/_resource_edit.tres"
const STAGE := "res://tests/._resource_edit_stage.tres"

func suite_name() -> String:
	return "resource_edit"

func suite_teardown() -> void:
	for path in [FILE, STAGE, "res://tests/_resource_edit_binary.res"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

func test_native_staging_preserves_live_parent_and_child() -> void:
	var original := Environment.new()
	original.background_mode = Environment.BG_COLOR
	original.background_color = Color.RED
	original.background_energy_multiplier = 3.0
	original.sky = Sky.new()
	original.sky.sky_material = ProceduralSkyMaterial.new()
	var child := original.sky
	var material := child.sky_material
	var stage := original.duplicate_deep(Resource.DEEP_DUPLICATE_NONE) as Environment
	assert_true(stage != original)
	assert_true(stage.sky == child, "omitted child retains identity")
	var error: Variant = ResourceHandler._apply_resource_properties(stage, {"background_color": "#00ff00", "missing_property": 1})
	assert_is_error(error)
	assert_eq(stage.background_color, Color.GREEN)
	assert_eq(original.background_color, Color.RED, "later validation failure leaves original parent unchanged")
	assert_eq(original.background_energy_multiplier, 3.0)
	assert_true(original.sky == child)
	assert_true(child.sky_material == material)
	assert_eq(material.sky_top_color, ProceduralSkyMaterial.new().sky_top_color)

func test_native_copy_and_staged_file_preserve_identity_uid_and_omissions() -> void:
	var original := Environment.new()
	original.background_mode = Environment.BG_COLOR
	original.background_color = Color.RED
	original.background_energy_multiplier = 3.0
	assert_eq(ResourceSaver.save(original, FILE), OK)
	assert_eq(McpResourceIO.ensure_uid(FILE, ResourceUID.INVALID_ID), OK)
	var uid := ResourceLoader.get_resource_uid(FILE)
	var held := load(FILE) as Environment
	var holder := WorldEnvironment.new()
	holder.environment = held
	var stage := held.duplicate_deep(Resource.DEEP_DUPLICATE_NONE) as Environment
	assert_eq(ResourceHandler._apply_resource_properties(stage, {"background_color": "#00ff00"}), null)
	assert_eq(held.background_color, Color.RED)
	assert_eq(ResourceSaver.save(stage, STAGE), OK)
	assert_eq(ResourceSaver.set_uid(STAGE, uid), OK)
	assert_eq(DirAccess.rename_absolute(ProjectSettings.globalize_path(STAGE), ProjectSettings.globalize_path(FILE)), OK)
	assert_eq(held.copy_from_resource(stage), OK)
	assert_true(holder.environment == held)
	assert_true(ResourceLoader.get_cached_ref(FILE) == held)
	assert_eq(held.resource_path, FILE)
	assert_eq(ResourceLoader.get_resource_uid(FILE), uid)
	EditorInterface.get_resource_filesystem().update_file(FILE)
	assert_eq(ResourceUID.get_id_path(uid), FILE)
	assert_true(load(ResourceUID.id_to_text(uid)) == held)
	assert_eq(held.background_color, Color.GREEN)
	assert_eq(held.background_energy_multiplier, 3.0, "omitted nondefault field survives")
	var disk := ResourceLoader.load(FILE, "", ResourceLoader.CACHE_MODE_IGNORE) as Environment
	assert_eq(disk.background_color, Color.GREEN)
	assert_eq(disk.background_energy_multiplier, 3.0)
	holder.free()

func test_deep_none_isolates_containers_without_replacing_resource_elements() -> void:
	var frames := SpriteFrames.new()
	var texture := GradientTexture2D.new()
	frames.add_frame("default", texture)
	var stage := frames.duplicate_deep(Resource.DEEP_DUPLICATE_NONE) as SpriteFrames
	assert_true(stage.get_frame_texture("default", 0) == texture)
	stage.set_animation_speed("default", 12.0)
	stage.add_animation("extra")
	assert_eq(frames.get_animation_speed("default"), 5.0)
	assert_false(frames.has_animation("extra"))
	assert_true(frames.get_frame_texture("default", 0) == texture)
	assert_eq(frames.copy_from_resource(stage), OK)
	assert_eq(frames.get_animation_speed("default"), 12.0)
	assert_true(frames.get_frame_texture("default", 0) == texture)

func _saved_environment() -> Environment:
	var resource := Environment.new()
	resource.background_mode = Environment.BG_COLOR
	resource.background_color = Color.RED
	resource.background_energy_multiplier = 3.0
	resource.sky = Sky.new()
	resource.sky.sky_material = ProceduralSkyMaterial.new()
	resource.set_meta("keep", {"name": "retained", "values": [1, 2]})
	ResourceSaver.save(resource, FILE)
	McpResourceIO.ensure_uid(FILE, ResourceUID.INVALID_ID)
	return ResourceLoader.load(FILE, "", ResourceLoader.CACHE_MODE_REPLACE) as Environment

func test_set_properties_retains_metadata_nested_identity_and_disk_values() -> void:
	var held := _saved_environment()
	var child := held.sky
	var nested := child.sky_material
	var uid := ResourceLoader.get_resource_uid(FILE)
	var handler := ResourceHandler.new(null)
	var result := handler.set_resource_properties({"path": FILE, "properties": {"background_color": "#00ff00"}})
	assert_has_key(result, "data")
	assert_false(result.data.undoable)
	assert_true(result.data.live_refreshed)
	assert_eq(result.data.properties_applied, 1)
	assert_true(ResourceLoader.get_cached_ref(FILE) == held)
	assert_true(held.sky == child)
	assert_true(held.sky.sky_material == nested)
	assert_eq(held.get_meta("keep"), {"name": "retained", "values": [1, 2]})
	assert_eq(held.background_color, Color.GREEN)
	assert_eq(held.background_energy_multiplier, 3.0)
	assert_eq(ResourceLoader.get_resource_uid(FILE), uid)
	assert_eq(ResourceUID.get_id_path(uid), FILE)
	assert_true(load(ResourceUID.id_to_text(uid)) == held)
	var disk := ResourceLoader.load(FILE, "", ResourceLoader.CACHE_MODE_IGNORE) as Environment
	assert_eq(disk.background_color, Color.GREEN)
	assert_eq(disk.background_energy_multiplier, 3.0)
	assert_eq(disk.get_meta("keep"), held.get_meta("keep"))

func test_late_validation_failure_leaves_live_and_disk_unchanged() -> void:
	var held := _saved_environment()
	var bytes := FileAccess.get_file_as_bytes(FILE)
	var handler := ResourceHandler.new(null)
	var result := handler.set_resource_properties({"path": FILE, "properties": {"background_color": "#00ff00", "absent_property": 1}})
	assert_is_error(result)
	assert_eq(held.background_color, Color.RED)
	assert_eq(FileAccess.get_file_as_bytes(FILE), bytes)

func test_dynamic_count_then_invalid_index_does_not_mutate_original() -> void:
	var source := AudioStreamRandomizer.new()
	source.streams_count = 1
	source.set("stream_0/weight", 7.0)
	assert_eq(ResourceSaver.save(source, FILE), OK)
	assert_eq(McpResourceIO.ensure_uid(FILE, ResourceUID.INVALID_ID), OK)
	var held := load(FILE) as AudioStreamRandomizer
	var bytes := FileAccess.get_file_as_bytes(FILE)
	var handler := ResourceHandler.new(null)
	var result := handler.set_resource_properties({"path": FILE, "properties": {"streams_count": 2, "stream_9/weight": 2}})
	assert_is_error(result)
	assert_eq(held.streams_count, 1)
	assert_eq(held.get("stream_0/weight"), 7.0)
	assert_eq(FileAccess.get_file_as_bytes(FILE), bytes)

func test_rejected_native_setter_does_not_report_success() -> void:
	var held := _saved_environment()
	var bytes := FileAccess.get_file_as_bytes(FILE)
	var handler := ResourceHandler.new(null)
	var result := handler.set_resource_properties({"path": FILE, "properties": {"sky": {"__class__": "BoxMesh"}}})
	assert_is_error(result)
	assert_true(held.sky is Sky)
	assert_eq(FileAccess.get_file_as_bytes(FILE), bytes)

func test_native_only_graph_refuses_scripts_and_accepts_shared_children() -> void:
	var shared := Gradient.new()
	var value := Resource.new()
	value.set_meta("references", [shared, shared])
	assert_eq(ResourceHandler._edit_graph_error(value, {}), null)
	var script := GDScript.new()
	script.source_code = "extends Resource\n"
	assert_eq(script.reload(), OK)
	value.set_script(script)
	assert_is_error(ResourceHandler._edit_graph_error(value, {}))

func test_refuses_identity_changes_before_write() -> void:
	var held := _saved_environment()
	var bytes := FileAccess.get_file_as_bytes(FILE)
	var handler := ResourceHandler.new(null)
	for name in ["resource_path", "script"]:
		var result := handler.set_resource_properties({"path": FILE, "properties": {name: "res://elsewhere.tres"}})
		assert_is_error(result)
	assert_eq(held.resource_path, FILE)
	assert_eq(FileAccess.get_file_as_bytes(FILE), bytes)

func test_staging_save_failure_preserves_original_file() -> void:
	var bad_path := "res://tests/_resource_edit_probe.unsupported_format"
	var file := FileAccess.open(bad_path, FileAccess.WRITE)
	file.store_string("original bytes")
	file.close()
	var result := McpResourceIO.save_to_disk(Environment.new(), bad_path, true, "Resource", {}, null, true, true)
	assert_is_error(result)
	assert_eq(FileAccess.get_file_as_string(bad_path), "original bytes")
	assert_eq(DirAccess.remove_absolute(ProjectSettings.globalize_path(bad_path)), OK)

func test_binary_resource_patch_preserves_uid_and_omitted_size() -> void:
	var path := "res://tests/_resource_edit_binary.res"
	var source := BoxShape3D.new()
	source.size = Vector3(1, 2, 3)
	assert_eq(ResourceSaver.save(source, path), OK)
	assert_eq(McpResourceIO.ensure_uid(path, ResourceUID.INVALID_ID), OK)
	var held := load(path) as BoxShape3D
	var uid := ResourceLoader.get_resource_uid(path)
	var handler := ResourceHandler.new(null)
	var result := handler.set_resource_properties({"path": path, "properties": {"margin": 0.06}})
	assert_has_key(result, "data", str(result))
	if not result.has("data"):
		return
	assert_true(result.data.live_refreshed)
	assert_true(is_equal_approx(held.margin, 0.06))
	assert_eq(held.size, Vector3(1, 2, 3))
	assert_eq(ResourceLoader.get_resource_uid(path), uid)
	assert_true(load(ResourceUID.id_to_text(uid)) == held)
	assert_eq(DirAccess.remove_absolute(ProjectSettings.globalize_path(path)), OK)

func test_resource_cycles_are_refused_but_shared_children_are_accepted() -> void:
	var first := Resource.new()
	var second := Resource.new()
	first.set_meta("self", first)
	assert_is_error(ResourceHandler._edit_graph_error(first, {}))
	first.remove_meta("self")
	first.set_meta("next", second)
	second.set_meta("next", first)
	assert_is_error(ResourceHandler._edit_graph_error(first, {}))
	second.remove_meta("next")
	first.set_meta("again", second)
	assert_eq(ResourceHandler._edit_graph_error(first, {}), null)
	first.remove_meta("next")
	first.remove_meta("again")

func test_staged_replace_failure_restores_original() -> void:
	_assert_failed_replacement(false)

func test_staged_replace_restore_failure_retains_recovery_files() -> void:
	_assert_failed_replacement(true)

func _assert_failed_replacement(fail_restore: bool) -> void:
	var original := FileAccess.open(FILE, FileAccess.WRITE)
	original.store_string("original")
	original.close()
	var staged := FileAccess.open(STAGE, FileAccess.WRITE)
	staged.store_string("edited")
	staged.close()
	var state := {"moves": 0}
	var move := func(from: String, to: String) -> Error:
		state.moves += 1
		if state.moves == 2 or (fail_restore and state.moves == 3):
			return ERR_CANT_CREATE
		return DirAccess.rename_absolute(from, to)
	var result := McpResourceIO._replace_staged_file(STAGE, FILE, true, move)
	assert_is_error(result)
	assert_eq(state.moves, 3)
	assert_eq(FileAccess.get_file_as_string(STAGE), "edited")
	assert_false(result.error.data.disk_committed)
	assert_eq(result.error.data.restore_failed, fail_restore)
	if fail_restore:
		assert_false(FileAccess.file_exists(FILE))
		var backup: String = result.error.data.recovery_backup
		assert_eq(FileAccess.get_file_as_string(backup), "original")
		assert_eq(DirAccess.rename_absolute(ProjectSettings.globalize_path(backup), ProjectSettings.globalize_path(FILE)), OK)
	else:
		assert_eq(FileAccess.get_file_as_string(FILE), "original")

func test_staged_replace_backup_success_removes_backup() -> void:
	var original := FileAccess.open(FILE, FileAccess.WRITE)
	original.store_string("original")
	original.close()
	var staged := FileAccess.open(STAGE, FileAccess.WRITE)
	staged.store_string("edited")
	staged.close()
	var state := {"backup": ""}
	var move := func(from: String, to: String) -> Error:
		if state.backup.is_empty():
			state.backup = to
		return DirAccess.rename_absolute(from, to)
	assert_eq(McpResourceIO._replace_staged_file(STAGE, FILE, true, move), {})
	assert_eq(FileAccess.get_file_as_string(FILE), "edited")
	assert_false(FileAccess.file_exists(STAGE))
	assert_false(FileAccess.file_exists(state.backup))
