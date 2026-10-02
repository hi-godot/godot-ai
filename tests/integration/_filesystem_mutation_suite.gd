@tool
extends McpTestSuite
const FilesystemHandler := preload("res://addons/godot_ai/handlers/filesystem_handler.gd")
var _handler: FilesystemHandler
func suite_setup(_ctx: Dictionary) -> void:
	_handler = FilesystemHandler.new()
func suite_teardown() -> void:
	_mutation_cleanup()
const Mutation := preload("res://addons/godot_ai/handlers/filesystem_mutation.gd")
const MUTATION_ROOT := "res://tests/" + "_filesystem_mutation"


func _mutation_write(path: String, content: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	assert_true(file != null, "fixture must open: " + path)
	if file != null:
		file.store_string(content)
		file.close()


func _mutation_paths() -> Array[String]:
	return [MUTATION_ROOT + ".txt", MUTATION_ROOT + "_moved.txt", MUTATION_ROOT + ".gd", MUTATION_ROOT + "_moved.gd", MUTATION_ROOT + "_owner.gd"]


func _mutation_cleanup() -> void:
	for path in _mutation_paths():
		for suffix in ["", ".uid", ".import"]:
			if FileAccess.file_exists(path + suffix):
				DirAccess.remove_absolute(path + suffix)
		EditorInterface.get_resource_filesystem().update_file(path)


func _mutation_uid_script(path: String) -> int:
	_mutation_write(path, "extends RefCounted\n")
	EditorInterface.get_resource_filesystem().update_file(path)
	var uid := ResourceLoader.get_resource_uid(path)
	if uid == ResourceUID.INVALID_ID:
		uid = ResourceUID.create_id()
		_mutation_write(path + ".uid", ResourceUID.id_to_text(uid))
		ResourceUID.add_id(uid, path)
	return uid


func test_mutation_refuses_batch_without_a_deferred_request() -> void:
	var result := _handler.move_file({"path": MUTATION_ROOT + ".txt", "new_path": MUTATION_ROOT + "_moved.txt"})
	assert_is_error(result, "INVALID_PARAMS")
	assert_contains(result.error.message, "outside batch_execute")


func test_mutation_move_and_rename_preserve_bytes() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	_mutation_write(source, "original bytes")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_has_key(result, "data", str(result))
	assert_false(FileAccess.file_exists(source))
	assert_eq(FileAccess.get_file_as_string(destination), "original bytes")
	var renamed: Dictionary = await Mutation.new().run({"path": destination, "new_name": source.get_file()}, "rename")
	assert_has_key(renamed, "data", str(renamed))
	assert_eq(FileAccess.get_file_as_string(source), "original bytes")
	_mutation_cleanup()


func test_mutation_uid_script_owner_refuses_remove_and_survives_move() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".gd"
	var destination := MUTATION_ROOT + "_moved.gd"
	var uid := _mutation_uid_script(source)
	var owner := MUTATION_ROOT + "_owner.gd"
	_mutation_write(owner, "extends RefCounted\nconst Target = preload(\"%s\")\n" % ResourceUID.id_to_text(uid))
	var before := FileAccess.get_file_as_bytes(source)
	var refused: Dictionary = await Mutation.new().run({"path": source, "permanent": true}, "remove")
	assert_is_error(refused, "INVALID_PARAMS")
	assert_eq(refused.error.data.outcome, "unchanged")
	assert_eq(FileAccess.get_file_as_bytes(source), before)
	var moved: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_has_key(moved, "data", str(moved))
	assert_eq(ResourceUID.get_id_path(uid), destination)
	assert_eq(FileAccess.get_file_as_bytes(destination), before)
	assert_true(FileAccess.file_exists(destination + ".uid"))
	assert_true(ResourceLoader.load(ResourceUID.id_to_text(uid), "", ResourceLoader.CACHE_MODE_IGNORE) is Script)
	_mutation_cleanup()


func test_mutation_path_owner_blocks_move_without_rewriting() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".gd"
	_mutation_uid_script(source)
	var owner := MUTATION_ROOT + "_owner.gd"
	var owner_text := "extends RefCounted\nconst Target = preload(\"%s\")\n" % source
	_mutation_write(owner, owner_text)
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": MUTATION_ROOT + "_moved.gd"}, "move")
	assert_is_error(result, "INVALID_PARAMS")
	assert_contains(result.error.message, "dependency path rewrites")
	assert_eq(FileAccess.get_file_as_string(owner), owner_text)
	assert_true(FileAccess.file_exists(source))
	_mutation_cleanup()


func test_mutation_collision_preserves_both_files() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	_mutation_write(source, "source")
	_mutation_write(destination, "destination")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_is_error(result, "INVALID_PARAMS")
	assert_eq(FileAccess.get_file_as_string(source), "source")
	assert_eq(FileAccess.get_file_as_string(destination), "destination")
	_mutation_cleanup()


func test_mutation_sidecar_failure_rolls_primary_back() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	_mutation_write(source, "source")
	_mutation_write(source + ".uid", "fixture sidecar")
	var job := Mutation.new()
	var calls := [0]
	job._io = func(_op: String, from: String, to: String) -> int:
		calls[0] += 1
		return ERR_CANT_CREATE if calls[0] == 2 else DirAccess.rename_absolute(from, to)
	var result: Dictionary = await job.run({"path": source, "new_path": destination}, "move")
	assert_is_error(result, "INTERNAL_ERROR")
	assert_eq(result.error.data.outcome, "rolled_back")
	assert_eq(FileAccess.get_file_as_string(source), "source")
	assert_eq(FileAccess.get_file_as_string(source + ".uid"), "fixture sidecar")
	assert_false(FileAccess.file_exists(destination))
	_mutation_cleanup()


func test_mutation_failed_rollback_reports_real_partial_state() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	_mutation_write(source, "source")
	_mutation_write(source + ".uid", "fixture sidecar")
	var job := Mutation.new()
	var calls := [0]
	job._io = func(_op: String, from: String, to: String) -> int:
		calls[0] += 1
		return DirAccess.rename_absolute(from, to) if calls[0] == 1 else ERR_CANT_CREATE
	var result: Dictionary = await job.run({"path": source, "new_path": destination}, "move")
	assert_is_error(result, "INTERNAL_ERROR")
	assert_eq(result.error.data.outcome, "partial")
	assert_false(result.error.data.retry_safe)
	assert_eq(result.error.data.unrestored, [{"from": source, "to": destination}])
	assert_eq(FileAccess.get_file_as_string(destination), "source")
	assert_true(FileAccess.file_exists(source + ".uid"))
	_mutation_cleanup()


func test_mutation_cancel_before_commit_preserves_source() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "source")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": MUTATION_ROOT + "_moved.txt"}, "move", func() -> bool: return false)
	assert_is_error(result, "FILESYSTEM_DISCOVERY_FAILED")
	assert_eq(result.error.data.outcome, "unchanged")
	assert_eq(FileAccess.get_file_as_string(source), "source")
	_mutation_cleanup()


func test_mutation_permanent_directory_refused_without_deleting() -> void:
	var path := MUTATION_ROOT + "_directory"
	assert_eq(DirAccess.make_dir_absolute(path), OK)
	_mutation_write(path.path_join("sentinel.txt"), "keep")
	var result: Dictionary = await Mutation.new().run({"path": path, "permanent": true}, "remove")
	assert_is_error(result, "INVALID_PARAMS")
	assert_eq(FileAccess.get_file_as_string(path.path_join("sentinel.txt")), "keep")
	DirAccess.remove_absolute(path.path_join("sentinel.txt"))
	DirAccess.remove_absolute(path)


func test_mutation_remove_file_permanent_and_partial_sidecar_failure() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "source")
	var removed: Dictionary = await Mutation.new().run({"path": source, "permanent": true}, "remove")
	assert_has_key(removed, "data", str(removed))
	assert_false(FileAccess.file_exists(source))
	_mutation_write(source, "source")
	_mutation_write(source + ".uid", "fixture sidecar")
	var job := Mutation.new()
	job._io = func(_op: String, path: String, _to: String) -> int:
		return ERR_CANT_CREATE if path.ends_with(".uid") else DirAccess.remove_absolute(path)
	var partial: Dictionary = await job.run({"path": source, "permanent": true}, "remove")
	assert_is_error(partial, "INTERNAL_ERROR")
	assert_eq(partial.error.data.outcome, "partial")
	assert_eq(partial.error.data.removed, [source])
	assert_eq(partial.error.data.remaining, [source + ".uid"])
	assert_false(partial.error.data.retry_safe)
	assert_true(FileAccess.file_exists(source + ".uid"))
	_mutation_cleanup()


func test_mutation_project_setting_refused_even_with_force() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "keep")
	ProjectSettings.set_setting("filesystem_fixture/target", source)
	var result: Dictionary = await Mutation.new().run({"path": source, "permanent": true, "force": true}, "remove")
	assert_is_error(result, "INVALID_PARAMS")
	assert_eq(FileAccess.get_file_as_string(source), "keep")
	ProjectSettings.set_setting("filesystem_fixture/target", null)
	_mutation_cleanup()


func test_mutation_case_only_rename_keeps_resource_and_sidecar() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := source.get_base_dir().path_join(source.get_file().to_upper())
	_mutation_write(source, "case bytes")
	_mutation_write(source + ".uid", "sidecar bytes")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_has_key(result, "data", str(result))
	var directory := DirAccess.open(source.get_base_dir())
	assert_true(directory.get_files().has(destination.get_file()))
	assert_false(directory.get_files().has(source.get_file()))
	assert_eq(FileAccess.get_file_as_string(destination), "case bytes")
	assert_eq(FileAccess.get_file_as_string(destination + ".uid"), "sidecar bytes")
	DirAccess.remove_absolute(destination)
	DirAccess.remove_absolute(destination + ".uid")
	_mutation_cleanup()


func test_mutation_metadata_directory_refused() -> void:
	var result: Dictionary = await Mutation.new().run({"path": "res://.godot", "new_path": "res://metadata_moved"}, "move")
	assert_true(result.has("error"), str(result))
	assert_true(DirAccess.dir_exists_absolute("res://.godot"))
	assert_false(DirAccess.dir_exists_absolute("res://metadata_moved"))


func test_mutation_relative_script_owner_blocks_move() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".gd"
	_mutation_uid_script(source)
	var owner := MUTATION_ROOT + "_owner.gd"
	var owner_text := "extends RefCounted\nconst Target = preload(\"./%s\")\n" % source.get_file()
	_mutation_write(owner, owner_text)
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": MUTATION_ROOT + "_moved.gd"}, "move")
	assert_is_error(result, "INVALID_PARAMS")
	assert_contains(result.error.message, "dependency path rewrites")
	assert_eq(FileAccess.get_file_as_string(owner), owner_text)
	assert_true(FileAccess.file_exists(source))
	_mutation_cleanup()


class EditorStateRace:
	extends "res://addons/godot_ai/handlers/filesystem_mutation.gd"
	var after_revalidation: Callable
	func _revalidate() -> bool:
		var valid: bool = await super._revalidate()
		await (Engine.get_main_loop() as SceneTree).process_frame
		after_revalidation.call()
		return valid


func test_mutation_settings_added_after_revalidation_prevent_disk_effects() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "keep")
	var job := EditorStateRace.new()
	var invoked := [false]
	job.after_revalidation = func() -> void:
		invoked[0] = true
		ProjectSettings.set_setting("filesystem_fixture/late_target", source)
	var result: Dictionary = await job.run({"path": source, "new_path": MUTATION_ROOT + "_moved.txt"}, "move")
	assert_true(invoked[0], "change must happen after yielding revalidation")
	assert_is_error(result, "INVALID_PARAMS")
	assert_true(FileAccess.file_exists(source), "late setting prevents any rename")
	assert_false(FileAccess.file_exists(MUTATION_ROOT + "_moved.txt"))
	assert_eq(ProjectSettings.get_setting("filesystem_fixture/late_target"), source)
	ProjectSettings.set_setting("filesystem_fixture/late_target", null)
	_mutation_cleanup()


func test_mutation_uid_remapped_after_revalidation_prevents_disk_effects() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".gd"
	var uid := _mutation_uid_script(source)
	var owner := MUTATION_ROOT + "_owner.gd"
	_mutation_write(owner, "extends RefCounted\nconst Target = preload(\"%s\")\n" % ResourceUID.id_to_text(uid))
	var job := EditorStateRace.new()
	var invoked := [false]
	job.after_revalidation = func() -> void:
		invoked[0] = true
		ResourceUID.set_id(uid, owner)
	var result: Dictionary = await job.run({"path": source, "new_path": MUTATION_ROOT + "_moved.gd"}, "move")
	assert_true(invoked[0], "UID change must happen after yielding revalidation")
	assert_is_error(result, "INVALID_PARAMS")
	assert_true(FileAccess.file_exists(source), "late UID remap prevents any rename")
	assert_false(FileAccess.file_exists(MUTATION_ROOT + "_moved.gd"))
	assert_eq(ResourceUID.get_id_path(uid), owner, "refusal must not overwrite concurrent UID change")
	ResourceUID.set_id(uid, source)
	_mutation_cleanup()


func test_mutation_linked_entry_refused_without_touching_external_sentinel() -> void:
	_mutation_cleanup()
	var parked := OS.get_environment("FILESYSTEM_LINK_FIXTURE")
	var sentinel := OS.get_environment("FILESYSTEM_OUTSIDE_SENTINEL")
	var link := MUTATION_ROOT + "_linked"
	assert_eq(DirAccess.rename_absolute(parked, ProjectSettings.globalize_path(link)), OK)
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "inside")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": MUTATION_ROOT + "_moved.txt"}, "move")
	assert_is_error(result, "INVALID_PARAMS")
	assert_contains(result.error.message, "linked")
	assert_eq(FileAccess.get_file_as_string(source), "inside")
	assert_eq(FileAccess.get_file_as_string(sentinel), "outside sentinel")
	var remove_link: Dictionary = await Mutation.new().run({"path": link, "force": true}, "remove")
	assert_is_error(remove_link, "INVALID_PARAMS")
	assert_eq(FileAccess.get_file_as_string(sentinel), "outside sentinel")
	assert_eq(DirAccess.rename_absolute(ProjectSettings.globalize_path(link), parked), OK)
	_mutation_cleanup()


func test_mutation_default_trash_file_and_directory() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "trash fixture")
	var result: Dictionary = await Mutation.new().run({"path": source}, "remove")
	assert_has_key(result, "data", str(result))
	assert_true(result.data.trashed)
	assert_false(FileAccess.file_exists(source))
	var folder := MUTATION_ROOT + "_trash"
	assert_eq(DirAccess.make_dir_absolute(folder), OK)
	_mutation_write(folder.path_join("sentinel.txt"), "trash folder fixture")
	result = await Mutation.new().run({"path": folder}, "remove")
	assert_has_key(result, "data", str(result))
	assert_true(result.data.trashed)
	assert_true(result.data.scan_required)
	assert_false(DirAccess.dir_exists_absolute(folder))


func test_mutation_directory_move_preserves_uid_group() -> void:
	var folder := MUTATION_ROOT + "_group"
	var destination := folder + "_moved"
	assert_eq(DirAccess.make_dir_absolute(folder), OK)
	var source := folder.path_join("member.gd")
	var uid := _mutation_uid_script(source)
	var result: Dictionary = await Mutation.new().run({"path": folder, "new_path": destination}, "move")
	assert_has_key(result, "data", str(result))
	assert_true(result.data.scan_required)
	assert_eq(ResourceUID.get_id_path(uid), destination.path_join("member.gd"))
	assert_true(FileAccess.file_exists(destination.path_join("member.gd.uid")))
	assert_false(DirAccess.dir_exists_absolute(folder))
	assert_true(ResourceLoader.load(ResourceUID.id_to_text(uid), "", ResourceLoader.CACHE_MODE_IGNORE) is Script)
	DirAccess.remove_absolute(destination.path_join("member.gd"))
	DirAccess.remove_absolute(destination.path_join("member.gd.uid"))
	DirAccess.remove_absolute(destination)
	ResourceUID.remove_id(uid)


func test_mutation_large_tree_yields_and_cancels_before_disk_effects() -> void:
	_mutation_cleanup()
	var folder := MUTATION_ROOT + "_large"
	assert_eq(DirAccess.make_dir_absolute(folder), OK)
	for index in 512:
		_mutation_write(folder.path_join("entry_%04d.txt" % index), "fixture")
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "keep")
	var frames := [0]
	var tick := func() -> void: frames[0] += 1
	var tree := Engine.get_main_loop() as SceneTree
	tree.process_frame.connect(tick)
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": MUTATION_ROOT + "_moved.txt"}, "move", func() -> bool: return frames[0] == 0)
	tree.process_frame.disconnect(tick)
	assert_true(frames[0] > 0, "discovery must return control to a real process frame")
	assert_is_error(result, "FILESYSTEM_DISCOVERY_FAILED")
	assert_eq(result.error.data.outcome, "unchanged")
	assert_eq(FileAccess.get_file_as_string(source), "keep")
	assert_false(FileAccess.file_exists(MUTATION_ROOT + "_moved.txt"))
	for index in 512:
		DirAccess.remove_absolute(folder.path_join("entry_%04d.txt" % index))
	DirAccess.remove_absolute(folder)
	_mutation_cleanup()


func test_mutation_root_relative_loader_owner_blocks_move() -> void:
	_mutation_cleanup()
	var basename := "_filesystem_" + "root_relative.gd"
	var source := "res://" + basename
	var destination := "res://" + "_filesystem_" + "root_relative_moved.gd"
	var uid := _mutation_uid_script(source)
	var owner := MUTATION_ROOT + "_owner.gd"
	var owner_text := "extends RefCounted\nfunc target():\n\treturn ResourceLoader.load(\"%s\")\n" % basename
	_mutation_write(owner, owner_text)
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_is_error(result, "INVALID_PARAMS")
	assert_true(FileAccess.file_exists(source), "root-relative literal owner must prevent move")
	assert_false(FileAccess.file_exists(destination))
	assert_eq(FileAccess.get_file_as_string(owner), owner_text)
	for path in [source, destination]:
		for suffix in ["", ".uid"]:
			if FileAccess.file_exists(path + suffix):
				DirAccess.remove_absolute(path + suffix)
	ResourceUID.remove_id(uid)
	_mutation_cleanup()


func test_mutation_shader_include_owners_prevent_move() -> void:
	var source := MUTATION_ROOT + "_include.gdshaderinc"
	var destination := MUTATION_ROOT + "_include_moved.gdshaderinc"
	_mutation_write(source, "vec3 fixture_color() { return vec3(1.0); }\n")
	for extension: String in ["gdshader", "gdshaderinc"]:
		var owner := MUTATION_ROOT + "_owner." + extension
		var owner_text := "#include \"%s\"\n" % source
		if extension == "gdshader":
			owner_text = "shader_type spatial;\n" + owner_text
		_mutation_write(owner, owner_text)
		var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
		assert_is_error(result, "INVALID_PARAMS", extension)
		assert_true(FileAccess.file_exists(source), extension)
		assert_false(FileAccess.file_exists(destination), extension)
		assert_eq(FileAccess.get_file_as_string(owner), owner_text)
		DirAccess.remove_absolute(owner)
		if FileAccess.file_exists(destination):
			DirAccess.rename_absolute(destination, source)
	for path in [source, destination]:
		for suffix in ["", ".uid"]:
			if FileAccess.file_exists(path + suffix):
				DirAccess.remove_absolute(path + suffix)


func test_mutation_imported_png_preserves_uid_and_real_texture() -> void:
	var source := MUTATION_ROOT + "_asset.png"
	var destination := MUTATION_ROOT + "_asset_moved.png"
	var image := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.25, 0.5, 0.75))
	assert_eq(image.save_png(source), OK)
	var efs := EditorInterface.get_resource_filesystem()
	efs.scan()
	var imported := await _mutation_wait_import(source)
	assert_true(imported, "real importer creates a settled sidecar")
	if not imported:
		return
	var uid := ResourceLoader.get_resource_uid(source)
	assert_true(uid != ResourceUID.INVALID_ID)
	var before := ResourceLoader.load(source) as Texture2D
	assert_true(before != null and before.get_width() == 4)
	if before == null:
		return
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_has_key(result, "data", str(result))
	assert_false(FileAccess.file_exists(source))
	assert_true(FileAccess.file_exists(destination + ".import"))
	efs.scan()
	assert_true(await _mutation_wait_import(destination), "moved asset import settles")
	assert_eq(ResourceLoader.get_resource_uid(destination), uid)
	assert_eq(ResourceUID.get_id_path(uid), destination)
	var texture := ResourceLoader.load(destination, "", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	assert_true(texture != null and texture.get_width() == 4 and texture.get_height() == 4)
	assert_eq(before.resource_path, destination, "cached resource follows the successful move")
	var import_config := ConfigFile.new()
	assert_eq(import_config.load(destination + ".import"), OK)
	assert_eq(import_config.get_value("deps", "source_file"), destination)
	for path in [source, destination]:
		for suffix in ["", ".import"]:
			if FileAccess.file_exists(path + suffix):
				DirAccess.remove_absolute(path + suffix)
	ResourceUID.remove_id(uid)


func test_mutation_remove_open_scene_refused_even_with_force() -> void:
	var path := MUTATION_ROOT + "_open.tscn"
	_mutation_write(path, "[gd_scene format=3]\n\n[node name=\"Fixture\" type=\"Node\"]\n")
	EditorInterface.get_resource_filesystem().update_file(path)
	EditorInterface.open_scene_from_path(path)
	await (Engine.get_main_loop() as SceneTree).process_frame
	assert_true(EditorInterface.get_open_scenes().has(path), "real scene tab must be open")
	var result: Dictionary = await Mutation.new().run({"path": path, "permanent": true, "force": true}, "remove")
	assert_is_error(result, "INVALID_PARAMS")
	assert_true(FileAccess.file_exists(path), "open scene bytes remain intact")
	# This isolated editor quits immediately afterward; retain its open scene
	# fixture on disk rather than deleting the file under its live tab.


func _mutation_wait_import(path: String) -> bool:
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		var config := ConfigFile.new()
		if FileAccess.file_exists(path + ".import") and config.load(path + ".import") == OK:
			var imported_path: String = config.get_value("remap", "path", "")
			if config.get_value("deps", "source_file", "") == path and FileAccess.file_exists(imported_path) and not EditorInterface.get_resource_filesystem().is_scanning():
				return true
		await (Engine.get_main_loop() as SceneTree).create_timer(0.05).timeout
	return false


func test_mutation_binary_string_owner_is_not_cleared_by_dependencies() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".gd"
	var destination := MUTATION_ROOT + "_moved.gd"
	var owner_script := MUTATION_ROOT + "_owner.gd"
	var owner := MUTATION_ROOT + "_binary_owner.res"
	var uid := _mutation_uid_script(source)
	_mutation_write(owner_script, "@tool\nextends Resource\n@export var file_path: String = \"\"\n@export var file_uid: String = \"\"\n")
	var holder: Resource = load(owner_script).new()
	holder.set("file_path", source)
	holder.set("file_uid", ResourceUID.id_to_text(uid))
	assert_eq(ResourceSaver.save(holder, owner), OK, "binary String owner must save")
	var loaded: Resource = ResourceLoader.load(owner, "", ResourceLoader.CACHE_MODE_IGNORE)
	assert_true(loaded != null, "binary owner must load")
	if loaded != null:
		assert_eq(loaded.get("file_path"), source, "binary really stores the literal path")
		assert_eq(loaded.get("file_uid"), ResourceUID.id_to_text(uid), "binary really stores the literal UID")
	var names_target := false
	for dependency in ResourceLoader.get_dependencies(owner):
		for segment in dependency.split("::", false):
			names_target = names_target or segment == source or segment == ResourceUID.id_to_text(uid)
	assert_false(names_target, "dependency enumeration omits serialized String paths and UIDs")
	var refused: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_is_error(refused, "INVALID_PARAMS")
	if refused.has("error"):
		assert_contains(refused.error.message, "dependency path rewrites")
		assert_eq(refused.error.data.outcome, "unchanged")
	assert_true(FileAccess.file_exists(source), "unknown binary ownership must preserve source")
	assert_false(FileAccess.file_exists(destination), "unknown binary ownership must not move")
	for path in [owner, owner + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	EditorInterface.get_resource_filesystem().update_file(owner)
	_mutation_cleanup()


func test_mutation_unrelated_binary_owner_does_not_block_move() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	var owner := MUTATION_ROOT + "_unrelated.res"
	_mutation_write(source, "keep")
	var resource := Resource.new()
	resource.set_meta("fixture", "unrelated")
	assert_eq(ResourceSaver.save(resource, owner), OK, "unrelated binary owner must save")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_has_key(result, "data", str(result))
	assert_eq(FileAccess.get_file_as_string(destination), "keep")
	assert_false(FileAccess.file_exists(source))
	for path in [owner, owner + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_mutation_cleanup()


func test_mutation_large_unrelated_binary_owner_does_not_block_move() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	var owner := MUTATION_ROOT + "_large_binary_owner.res"
	_mutation_write(source, "keep")
	var resource := Resource.new()
	var blob := PackedByteArray()
	blob.resize(Mutation.MAX_FILE_BYTES + 1)
	resource.set_meta("blob", blob)
	assert_eq(ResourceSaver.save(resource, owner), OK, "large unrelated binary owner must save")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_has_key(result, "data", str(result))
	assert_eq(FileAccess.get_file_as_string(destination), "keep")
	assert_false(FileAccess.file_exists(source))
	for path in [owner, owner + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_mutation_cleanup()


func test_mutation_compressed_binary_string_owner_fails_closed() -> void:
	## The editor saves binary resources compressed by default, and a compressed
	## container shows none of its serialized paths to a raw byte scan.
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".gd"
	var destination := MUTATION_ROOT + "_moved.gd"
	var owner_script := MUTATION_ROOT + "_owner.gd"
	var owner := MUTATION_ROOT + "_compressed_owner.res"
	_mutation_uid_script(source)
	_mutation_write(owner_script, "@tool\nextends Resource\n@export var file_path: String = \"\"\n@export var file_uid: String = \"\"\n")
	var holder: Resource = load(owner_script).new()
	holder.set("file_path", source)
	assert_eq(ResourceSaver.save(holder, owner, ResourceSaver.FLAG_COMPRESS), OK, "compressed binary owner must save")
	var raw := FileAccess.get_file_as_bytes(owner)
	assert_eq(raw.slice(0, 4).get_string_from_ascii(), Mutation.COMPRESSED_MAGIC, "fixture must be a compressed container")
	assert_false(Mutation.new()._bytes_contains_ci(raw, source.to_utf8_buffer()), "the raw container hides the serialized path")
	var refused: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_is_error(refused, "INVALID_PARAMS")
	if refused.has("error"):
		assert_contains(refused.error.message, "dependency path rewrites")
		assert_eq(refused.error.data.outcome, "unchanged")
	assert_true(FileAccess.file_exists(source), "a compressed owner's reference must preserve source")
	assert_false(FileAccess.file_exists(destination), "a compressed owner's reference must not move")
	for path in [owner, owner + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	EditorInterface.get_resource_filesystem().update_file(owner)
	_mutation_cleanup()


func test_mutation_unrelated_compressed_binary_owner_does_not_block_move() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	var owner := MUTATION_ROOT + "_unrelated_compressed.res"
	_mutation_write(source, "keep")
	var resource := Resource.new()
	resource.set_meta("fixture", "unrelated")
	assert_eq(ResourceSaver.save(resource, owner, ResourceSaver.FLAG_COMPRESS), OK, "unrelated compressed owner must save")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_has_key(result, "data", str(result))
	assert_eq(FileAccess.get_file_as_string(destination), "keep")
	assert_false(FileAccess.file_exists(source))
	for path in [owner, owner + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_mutation_cleanup()


func test_mutation_binary_ext_resource_owner_blocks_move() -> void:
	## A binary ext_resource stores its UID as an integer. Once the stored
	## fallback path is stale, no byte scan can find the reference: only the
	## engine's dependency records still name the target.
	_mutation_cleanup()
	var stale := MUTATION_ROOT + "_stale.gd"
	var source := MUTATION_ROOT + ".gd"
	var destination := MUTATION_ROOT + "_moved.gd"
	var owner := MUTATION_ROOT + "_script_owner.res"
	_mutation_write(stale, "extends Resource\n")
	var uid := ResourceUID.create_id()
	_mutation_write(stale + ".uid", ResourceUID.id_to_text(uid))
	ResourceUID.add_id(uid, stale)
	var holder := Resource.new()
	holder.set_script(load(stale))
	assert_eq(ResourceSaver.save(holder, owner, ResourceSaver.FLAG_COMPRESS), OK, "script-owning binary must save")
	holder = null
	assert_eq(DirAccess.rename_absolute(stale, source), OK, "fixture script must move")
	assert_eq(DirAccess.rename_absolute(stale + ".uid", source + ".uid"), OK, "fixture sidecar must move")
	ResourceUID.set_id(uid, source)
	var job := Mutation.new()
	var payload: Variant = job._binary_scan_bytes(owner, FileAccess.get_file_as_bytes(owner))
	assert_true(payload is PackedByteArray and not payload.is_empty(), "owner payload must expand")
	if payload is PackedByteArray:
		assert_false(job._bytes_contains_ci(payload, source.to_utf8_buffer()), "the owner stores only the stale path")
		assert_false(job._bytes_contains_ci(payload, ResourceUID.id_to_text(uid).to_utf8_buffer()), "the owner stores no UID text")
	var refused: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_is_error(refused, "INVALID_PARAMS")
	if refused.has("error"):
		assert_contains(refused.error.message, "dependency path rewrites")
	assert_true(FileAccess.file_exists(source), "a binary ext_resource reference must preserve source")
	assert_false(FileAccess.file_exists(destination), "a binary ext_resource reference must not move")
	for path in [owner, owner + ".uid", stale, stale + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	EditorInterface.get_resource_filesystem().update_file(owner)
	_mutation_cleanup()


func test_mutation_compressed_container_expands_across_blocks() -> void:
	## Godot's own compressed writer produces the same container under a
	## different magic, which pins the block layout this parser assumes.
	var path := "user://_filesystem_mutation_container.bin"
	for size in [10000, 8192, 100]:
		var original := PackedByteArray()
		original.resize(size)
		for index in size:
			original[index] = (index * 31 + 7) % 251
		var file := FileAccess.open_compressed(path, FileAccess.WRITE, FileAccess.COMPRESSION_ZSTD)
		assert_true(file != null, "compressed fixture must open")
		if file == null:
			return
		file.store_buffer(original)
		file.close()
		var raw := FileAccess.get_file_as_bytes(path)
		DirAccess.remove_absolute(path)
		var magic := Mutation.COMPRESSED_MAGIC.to_ascii_buffer()
		for index in magic.size():
			raw[index] = magic[index]
		var job := Mutation.new()
		var expanded: Variant = job._binary_scan_bytes(path, raw)
		assert_true(expanded is PackedByteArray and expanded == original, "a %d-byte payload must expand intact" % size)
		assert_eq(job._fault, "", "a valid container sets no fault")
		if size == 10000:
			var truncated := Mutation.new()
			assert_true(truncated._binary_scan_bytes(path, raw.slice(0, raw.size() / 2)) == null, "a truncated container cannot be inspected")
			assert_eq(truncated._fault_code, "FILESYSTEM_DISCOVERY_FAILED")


func test_mutation_malformed_compressed_binary_owner_fails_discovery() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	var owner := MUTATION_ROOT + "_malformed.res"
	_mutation_write(source, "keep")
	_mutation_write(owner, Mutation.COMPRESSED_MAGIC + "not a container")
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_is_error(result, "FILESYSTEM_DISCOVERY_FAILED")
	if result.has("error"):
		assert_contains(result.error.message, "compressed binary owner")
	assert_true(FileAccess.file_exists(source), "an unreadable owner must preserve source")
	assert_false(FileAccess.file_exists(destination), "an unreadable owner must not move")
	for path in [owner, owner + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	_mutation_cleanup()


func test_mutation_large_text_owner_fails_closed() -> void:
	_mutation_cleanup()
	var source := MUTATION_ROOT + ".txt"
	var destination := MUTATION_ROOT + "_moved.txt"
	var owner := MUTATION_ROOT + "_large_text_owner.gd"
	_mutation_write(source, "keep")
	var file := FileAccess.open(owner, FileAccess.WRITE)
	assert_true(file != null, "large text owner fixture must open")
	if file != null:
		file.store_string("@tool\nextends RefCounted\nconst Target = \"%s\"\n" % source)
		for _index in 30000:
			file.store_string("# padding for the oversized-owner branch\n")
		file.close()
	EditorInterface.get_resource_filesystem().update_file(owner)
	var result: Dictionary = await Mutation.new().run({"path": source, "new_path": destination}, "move")
	assert_is_error(result, "FILESYSTEM_DISCOVERY_FAILED")
	assert_contains(result.error.message, "exceeds")
	assert_true(FileAccess.file_exists(source), "oversized text owner must preserve source")
	assert_false(FileAccess.file_exists(destination), "oversized text owner must not move")
	for path in [owner, owner + ".uid"]:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
	EditorInterface.get_resource_filesystem().update_file(owner)
	_mutation_cleanup()


func test_mutation_owner_scan_checks_cancellation_between_relative_hits() -> void:
	var job := Mutation.new()
	job._deadline = Time.get_ticks_msec() + 25000
	job._yield_at = Time.get_ticks_usec()
	var checks := [0]
	job._alive = func() -> bool:
		checks[0] += 1
		return checks[0] <= 2
	var targets := {}
	var owner := ""
	for index in 256:
		var path := "res://target_%03d.gd" % index
		targets[path] = {"uid": ResourceUID.INVALID_ID}
		owner += '\"target_%03d.gd\"\n' % index
	var hits: Array = await job._references("res://owner.gd", owner.to_utf8_buffer(), targets)
	assert_eq(checks[0], 3, "check cancellation before each target, including relative-path continue branches")
	assert_eq(hits.size(), 1, "cancelled owner scan must stop before processing the next target")
	assert_true(job._fault.contains("cancelled"), "cancellation must be reported to the mutation owner")


func test_mutation_frame_budget_follows_the_frame_gap() -> void:
	## A focused editor idles at ~6.9 ms per frame and keeps the floor. An
	## unfocused one sleeps ~100 ms per frame, where a fixed 2 ms slice left
	## discovery about half a second of work inside its 25 s deadline (#1120).
	assert_eq(Mutation._frame_budget(0), Mutation.BUDGET_MIN_USEC, "no observed gap keeps the floor")
	assert_eq(Mutation._frame_budget(4900), Mutation.BUDGET_MIN_USEC, "a focused editor keeps the floor")
	assert_true(Mutation._frame_budget(16700) <= 6000, "a 60 Hz frame gives up a few milliseconds at most")
	var throttled := Mutation._frame_budget(100000)
	assert_true(throttled >= 20000, "an unfocused editor's frame must carry tens of milliseconds, got %d" % throttled)
	assert_true(throttled <= 50000, "a slice stays well inside the frame it borrows from, got %d" % throttled)
	assert_eq(Mutation._frame_budget(10000000), Mutation.BUDGET_MAX_USEC, "a stalled editor cannot stretch one slice past the ceiling")


class PacedProbe:
	extends "res://addons/godot_ai/handlers/filesystem_mutation.gd"
	var yields := 0
	var away_usec := 0
	func _yield_if_needed() -> bool:
		var resumed := _yield_at
		var entered := Time.get_ticks_usec()
		var proceed: bool = await super._yield_if_needed()
		if _yield_at != resumed:
			yields += 1
			away_usec += _yield_at - entered
		return proceed


func test_mutation_throttled_frames_get_proportionate_slices() -> void:
	## Real frames at the unfocused editor's default cadence. Discovery has to
	## spend most of the work in slices sized to those frames, not in 2 ms ones.
	_mutation_cleanup()
	var folder := MUTATION_ROOT + "_paced"
	assert_eq(DirAccess.make_dir_absolute(folder), OK)
	var owner_text := "[gd_resource type=\"Resource\" format=3]\n\n[resource]\n"
	for line in 100:
		owner_text += "metadata/note_%03d = \"fixture padding for the paced owner scan %03d\"\n" % [line, line]
	for index in 200:
		_mutation_write(folder.path_join("owner_%03d.tres" % index), owner_text)
	var source := MUTATION_ROOT + ".txt"
	_mutation_write(source, "keep")
	var low_processor := OS.low_processor_usage_mode
	var sleep_usec := OS.low_processor_usage_mode_sleep_usec
	OS.low_processor_usage_mode = true
	OS.low_processor_usage_mode_sleep_usec = 100000
	var job := PacedProbe.new()
	var started := Time.get_ticks_usec()
	var result: Dictionary = await job.run({"path": source, "new_path": MUTATION_ROOT + "_moved.txt"}, "move")
	var elapsed := Time.get_ticks_usec() - started
	OS.low_processor_usage_mode = low_processor
	OS.low_processor_usage_mode_sleep_usec = sleep_usec
	assert_has_key(result, "data", str(result))
	assert_eq(FileAccess.get_file_as_string(MUTATION_ROOT + "_moved.txt"), "keep")
	assert_true(job.yields >= 2, "fixture must span several frames, got %d" % job.yields)
	if job.yields > 0:
		assert_true(job.away_usec / job.yields >= 50000, "frames must really be throttled, got %d usec between slices" % (job.away_usec / job.yields))
		# Two frames of slack: the first slice runs at the floor before any
		# frame gap is known, and the last one is partial.
		var work_usec := elapsed - job.away_usec
		assert_true(job.yields <= work_usec / 10000 + 2, "throttled frames must each carry far more than the floor, got %d frames for %d usec of work" % [job.yields, work_usec])
	for index in 200:
		DirAccess.remove_absolute(folder.path_join("owner_%03d.tres" % index))
	DirAccess.remove_absolute(folder)
	_mutation_cleanup()
