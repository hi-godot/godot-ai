@tool
extends McpTestSuite

const RUNNER_PATH := "res://addons/godot_ai/utils/update_activation_runner.gd"
const PLUGIN_CFG := "res://addons/godot_ai/plugin.cfg"


func suite_name() -> String:
	return "update_activation"


func test_file_backed_runner_cannot_disable_the_editor_plugin() -> void:
	var runner: Node = load(RUNNER_PATH).new()
	Engine.get_main_loop().root.add_child(runner)
	var enabled := EditorInterface.is_plugin_enabled(PLUGIN_CFG)
	var accepted: bool = runner.call("start", _package())
	assert_false(accepted, "a runner whose source can be replaced must refuse activation")
	assert_eq(EditorInterface.is_plugin_enabled(PLUGIN_CFG), enabled)
	runner.free()


func test_incomplete_handoff_leaves_the_live_plugin_untouched() -> void:
	var script := GDScript.new()
	script.source_code = FileAccess.get_file_as_string(RUNNER_PATH)
	var error := script.reload()
	assert_eq(error, OK, "independent activation source must compile")
	if error != OK:
		return
	var enabled := EditorInterface.is_plugin_enabled(PLUGIN_CFG)
	var wrong_path := _package()
	wrong_path.stage_root = "res://addons/other_plugin"
	var missing_hash := _package()
	missing_hash.record.erase("expected_tree_sha256")
	var wrong_authority_type := _package()
	wrong_authority_type.record.replace_owned_mismatches = "true"
	for package in [{}, wrong_path, missing_hash, wrong_authority_type]:
		var runner: Node = script.new()
		Engine.get_main_loop().root.add_child(runner)
		assert_false(runner.call("start", package), "incomplete handoff must be refused")
		assert_eq(EditorInterface.is_plugin_enabled(PLUGIN_CFG), enabled)
		runner.free()


func test_failure_dismissal_preserves_the_native_progress_dialog() -> void:
	var root := EditorInterface.get_base_control().get_tree().root
	var dialogs := root.find_children("*", "ProgressDialog", true, false)
	assert_eq(dialogs.size(), 1, "the live editor must have one shared native progress dialog")
	if dialogs.size() != 1:
		return
	var progress: Node = dialogs[0]
	if bool(progress.call("is_visible")):
		skip("the editor is currently using its shared progress dialog")
		return
	var script := GDScript.new()
	script.source_code = FileAccess.get_file_as_string(RUNNER_PATH)
	var error := script.reload()
	assert_eq(error, OK, "the dismissal callback must compile without a resource path")
	if error != OK:
		return
	var runner: Node = script.new()
	root.add_child(runner)
	var dialog := AcceptDialog.new()
	runner.add_child(dialog)
	var progress_id := progress.get_instance_id()
	var dialog_id := dialog.get_instance_id()
	progress.reparent(dialog)
	var adopted := progress.get_parent() == dialog
	runner.call("_dismiss_failure")
	var released := progress.get_parent() == root
	var queued := runner.is_queued_for_deletion()
	## Rescue independently before destroying the fixture even if dismissal failed.
	if progress.get_parent() != root:
		progress.reparent(root)
	runner.free()
	assert_true(adopted, "the failure dialog must own the borrowed native progress object")
	assert_true(released, "dismissal must return the shared dialog before queuing deletion")
	assert_true(queued, "dismissal must still dispose of the failure runner")
	assert_true(is_instance_id_valid(progress_id), "the same native object must survive dismissal")
	assert_eq(progress.get_instance_id(), progress_id)
	assert_eq(progress.get_parent(), root)
	assert_false(is_instance_id_valid(dialog_id), "the failure dialog must be destroyed")


func _package() -> Dictionary:
	return {
		"stage_root": "res://addons/.godot_ai_update/stage/addons/godot_ai",
		"record": {
			"from_version": "4.0.4", "to_version": "4.0.5",
			"manifest_sha256": "0".repeat(64), "expected_tree_sha256": "0".repeat(64),
			"editor_nonce": "test", "replace_owned_mismatches": false,
		},
	}
