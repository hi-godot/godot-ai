@tool
extends McpTestSuite

const Coordinator := preload("res://addons/godot_ai/utils/update_coordinator.gd")
const QualificationBarrier := preload(
	"res://addons/godot_ai/utils/update_qualification_barrier.gd"
)

var _scratch_dir := ""
var _saved_environment: Dictionary = {}


class _SpawnFailureCoordinator extends Coordinator:
	var enabled_calls: Array[bool] = []

	func _create_actor_process(_program: String, _args: Array[String]) -> int:
		return -1

	func _set_plugin_enabled(enabled: bool) -> void:
		enabled_calls.append(enabled)

	func _plugin_is_enabled() -> bool:
		return false


func suite_name() -> String:
	return "update_coordinator"


func suite_setup(_ctx: Dictionary) -> void:
	_scratch_dir = OS.get_user_data_dir().path_join("update_qualification_barrier_tests")
	DirAccess.make_dir_recursive_absolute(_scratch_dir)
	for name in [
		QualificationBarrier.TOKEN_ENV,
		QualificationBarrier.EFFECT_ENV,
		QualificationBarrier.WHEN_ENV,
		QualificationBarrier.TIMEOUT_ENV,
		QualificationBarrier.OCCURRENCE_ENV,
	]:
		_saved_environment[name] = OS.get_environment(name) if OS.has_environment(name) else null
	_clear_qualification_environment()


func suite_teardown() -> void:
	_clear_qualification_environment()
	for name in _saved_environment:
		if _saved_environment[name] == null:
			OS.unset_environment(name)
		else:
			OS.set_environment(name, str(_saved_environment[name]))
	assert_eq(_remove_dir_recursive(_scratch_dir), OK)


func _remove_dir_recursive(path: String) -> Error:
	for file_name in DirAccess.get_files_at(path):
		var file_error := DirAccess.remove_absolute(path.path_join(file_name))
		if file_error != OK:
			return file_error
	for dir_name in DirAccess.get_directories_at(path):
		var dir_error := _remove_dir_recursive(path.path_join(dir_name))
		if dir_error != OK:
			return dir_error
	return DirAccess.remove_absolute(path)


func test_spawn_failure_reenables_old_plugin_and_leaves_bounded_recovery() -> void:
	expect_script_error_containing("could not launch transaction actor")
	var coordinator := _SpawnFailureCoordinator.new()
	coordinator.start({
		"from_version": "4.0.0",
		"install_root": "/fixture/project/addons/godot_ai",
		"manifest_sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		"project_root": "/fixture/project",
		"recovery_root": "/fixture/recovery",
		"stage_root": "/fixture/recovery/stages/transaction/addons/godot_ai",
		"to_version": "4.0.1",
		"transaction": "transaction-0123456789",
	}, ["/fixture/python", "-m", "godot_ai.update_transaction"], "editor-0123456789")

	coordinator._process(0.0)
	coordinator._process(0.0)

	assert_eq(coordinator.enabled_calls, [false, true])
	assert_eq(OS.get_environment(Coordinator.UPDATE_TRANSACTION_ENV), "")
	assert_eq(OS.get_environment(Coordinator.UPDATE_ACTOR_HANDOFF_ENV), "")


func test_qualification_barrier_is_inert_without_complete_process_capability() -> void:
	_clear_qualification_environment()
	var barrier := QualificationBarrier.new()
	assert_true(barrier.configure(_prepared_fixture()))
	assert_false(barrier.begin("coordinator_disable_request", "before"))

	OS.set_environment(QualificationBarrier.TOKEN_ENV, "")
	barrier = QualificationBarrier.new()
	assert_false(barrier.configure(_prepared_fixture()))
	assert_true(barrier.error.contains("incomplete"),
		"a present-empty variable is not equivalent to an absent capability")
	_clear_qualification_environment()
	for name in [
		QualificationBarrier.TOKEN_ENV,
		QualificationBarrier.EFFECT_ENV,
		QualificationBarrier.WHEN_ENV,
		QualificationBarrier.TIMEOUT_ENV,
	]:
		OS.set_environment(name, "")
	barrier = QualificationBarrier.new()
	assert_false(barrier.configure(_prepared_fixture()))
	assert_true(barrier.error.contains("token"),
		"an all-present empty tuple must fail before the plugin is disabled")
	_clear_qualification_environment()

	OS.set_environment(QualificationBarrier.TOKEN_ENV, "ab".repeat(32))
	barrier = QualificationBarrier.new()
	assert_false(barrier.configure(_prepared_fixture()))
	assert_true(barrier.error.contains("incomplete"))
	_clear_qualification_environment()


func test_qualification_barrier_rejects_and_preserves_stale_decision() -> void:
	_clear_qualification_environment()
	var token := "ab".repeat(32)
	OS.set_environment(QualificationBarrier.TOKEN_ENV, token)
	OS.set_environment(QualificationBarrier.EFFECT_ENV, "coordinator_disable_request")
	OS.set_environment(QualificationBarrier.WHEN_ENV, "before")
	OS.set_environment(QualificationBarrier.TIMEOUT_ENV, "5")
	var first := QualificationBarrier.new()
	assert_true(first.configure(_prepared_fixture()))
	assert_true(first.begin("coordinator_disable_request", "before"))
	var barrier_path := _scratch_dir.path_join(QualificationBarrier.BARRIER_NAME)
	var capability_path := _scratch_dir.path_join(QualificationBarrier.CAPABILITY_NAME)
	var decision_path := _scratch_dir.path_join(QualificationBarrier.DECISION_NAME)
	var decision: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(barrier_path))
	decision.record = "coordinator_failpoint_decision"
	decision.action = "continue"
	decision.mac = _decision_mac(token, decision)
	var file := FileAccess.open(decision_path, FileAccess.WRITE)
	file.store_string(JSON.stringify(decision))
	file.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(decision_path, 384)
	## Simulate a coordinator crash after the controller publishes its decision.
	DirAccess.remove_absolute(barrier_path)
	DirAccess.remove_absolute(capability_path)
	var before := FileAccess.get_file_as_string(decision_path)
	var retry := QualificationBarrier.new()
	assert_true(retry.configure(_prepared_fixture()))
	assert_false(retry.begin("coordinator_disable_request", "before"))
	assert_true(retry.error.contains("stale"))
	assert_eq(FileAccess.get_file_as_string(decision_path), before,
		"a retry must preserve stale signed evidence rather than replay or erase it")
	DirAccess.remove_absolute(decision_path)
	_clear_qualification_environment()


func test_qualification_barrier_preserves_invalid_observed_decision() -> void:
	_clear_qualification_environment()
	OS.set_environment(QualificationBarrier.TOKEN_ENV, "ab".repeat(32))
	OS.set_environment(QualificationBarrier.EFFECT_ENV, "coordinator_disable_request")
	OS.set_environment(QualificationBarrier.WHEN_ENV, "before")
	OS.set_environment(QualificationBarrier.TIMEOUT_ENV, "5")
	var barrier := QualificationBarrier.new()
	assert_true(barrier.configure(_prepared_fixture()))
	assert_true(barrier.begin("coordinator_disable_request", "before"))
	var decision_path := _scratch_dir.path_join(QualificationBarrier.DECISION_NAME)
	var file := FileAccess.open(decision_path, FileAccess.WRITE)
	file.store_string('{"record":"foreign-evidence"}')
	file.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(decision_path, 384)
	assert_eq(barrier.poll(), QualificationBarrier.INVALID)
	assert_true(FileAccess.file_exists(decision_path),
		"invalid or foreign decision evidence must never be deleted")
	assert_false(FileAccess.file_exists(
		_scratch_dir.path_join(QualificationBarrier.BARRIER_NAME)))
	assert_false(FileAccess.file_exists(
		_scratch_dir.path_join(QualificationBarrier.CAPABILITY_NAME)))
	DirAccess.remove_absolute(decision_path)
	_clear_qualification_environment()


func test_qualification_barrier_rejects_unknown_effects_and_ambiguous_timeouts() -> void:
	for invalid in ["+1", "01", "1e2", ".5", "1.", "0", "301", "nan", "inf"]:
		_clear_qualification_environment()
		OS.set_environment(QualificationBarrier.TOKEN_ENV, "ab".repeat(32))
		OS.set_environment(QualificationBarrier.EFFECT_ENV, "intent_commit")
		OS.set_environment(QualificationBarrier.WHEN_ENV, "before")
		OS.set_environment(QualificationBarrier.TIMEOUT_ENV, invalid)
		var barrier := QualificationBarrier.new()
		assert_false(barrier.configure(_prepared_fixture()), "must reject timeout %s" % invalid)
	_clear_qualification_environment()
	OS.set_environment(QualificationBarrier.TOKEN_ENV, "ab".repeat(32))
	OS.set_environment(QualificationBarrier.EFFECT_ENV, "typo_effect")
	OS.set_environment(QualificationBarrier.WHEN_ENV, "before")
	OS.set_environment(QualificationBarrier.TIMEOUT_ENV, "5")
	var barrier := QualificationBarrier.new()
	assert_false(barrier.configure(_prepared_fixture()))
	assert_true(barrier.error.contains("unknown"))
	_clear_qualification_environment()


func test_qualification_barrier_requires_authenticated_exact_decision() -> void:
	_clear_qualification_environment()
	var token := "ab".repeat(32)
	OS.set_environment(QualificationBarrier.TOKEN_ENV, token)
	OS.set_environment(QualificationBarrier.EFFECT_ENV, "coordinator_disable_request")
	OS.set_environment(QualificationBarrier.WHEN_ENV, "before")
	OS.set_environment(QualificationBarrier.TIMEOUT_ENV, "5")
	var barrier := QualificationBarrier.new()
	var prepared := _prepared_fixture()
	assert_true(barrier.configure(prepared))
	assert_true(barrier.begin("coordinator_disable_request", "before"))
	var barrier_path := _scratch_dir.path_join(QualificationBarrier.BARRIER_NAME)
	var decision_path := _scratch_dir.path_join(QualificationBarrier.DECISION_NAME)
	var observed: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(barrier_path))
	var decision := observed.duplicate(true)
	decision.record = "coordinator_failpoint_decision"
	decision.action = "continue"
	decision.mac = _decision_mac(token, decision)
	assert_eq(decision.mac, barrier._decision_mac("continue"), "controller and actor MACs differ")
	assert_eq(decision.size(), 12, "decision schema must remain exact")
	var expected_identity := barrier._identity("coordinator_failpoint_barrier", true)
	for key in expected_identity:
		if key == "record":
			continue
		assert_eq(decision.get(key), expected_identity[key], "identity differs at %s" % key)
	assert_true(barrier._valid_decision(decision), "in-memory decision must validate")
	var file := FileAccess.open(decision_path, FileAccess.WRITE)
	var canonicalish := JSON.stringify(decision)
	var record_field := '"record":"coordinator_failpoint_decision"'
	var duplicate_record := '%s,%s' % [record_field, record_field]
	file.store_string(canonicalish.replace(record_field, duplicate_record))
	file.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(decision_path, 384)
	assert_true(barrier._read_bounded_record(decision_path).is_empty(),
		"duplicate JSON keys must fail closed before Godot collapses them")
	file = FileAccess.open(decision_path, FileAccess.WRITE)
	var escaped_record := '"\\u0072ecord":"coordinator_failpoint_decision"'
	file.store_string(canonicalish.replace(record_field, '%s,%s' % [record_field, escaped_record]))
	file.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(decision_path, 384)
	assert_true(barrier._read_bounded_record(decision_path).is_empty(),
		"JSON-equivalent escaped duplicate keys must fail closed")
	file = FileAccess.open(decision_path, FileAccess.WRITE)
	file.store_string(canonicalish)
	file.close()
	var reread := barrier._read_bounded_record(decision_path)
	assert_eq(reread.size(), 12, "published decision schema must remain exact")
	assert_true(barrier._valid_decision(reread), "published decision must validate")
	assert_eq(barrier.poll(), QualificationBarrier.CONTINUE, barrier.error)
	assert_false(FileAccess.file_exists(barrier_path))
	assert_false(FileAccess.file_exists(decision_path))
	assert_false(FileAccess.file_exists(_scratch_dir.path_join(QualificationBarrier.CAPABILITY_NAME)))
	_clear_qualification_environment()


func test_qualification_barrier_selects_second_occurrence() -> void:
	_clear_qualification_environment()
	var token := "cd".repeat(32)
	OS.set_environment(QualificationBarrier.TOKEN_ENV, token)
	OS.set_environment(QualificationBarrier.EFFECT_ENV, "coordinator_filesystem_scan")
	OS.set_environment(QualificationBarrier.WHEN_ENV, "after")
	OS.set_environment(QualificationBarrier.TIMEOUT_ENV, "5")
	OS.set_environment(QualificationBarrier.OCCURRENCE_ENV, "2")
	var barrier := QualificationBarrier.new()
	assert_true(barrier.configure(_prepared_fixture()))
	assert_false(barrier.begin("coordinator_enable", "after"))
	assert_false(barrier.begin("coordinator_filesystem_scan", "before"))
	assert_false(barrier.begin("coordinator_filesystem_scan", "after"))
	var barrier_path := _scratch_dir.path_join(QualificationBarrier.BARRIER_NAME)
	assert_false(FileAccess.file_exists(barrier_path))
	assert_true(barrier.begin("coordinator_filesystem_scan", "after"))
	var decision: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(barrier_path))
	assert_eq(decision.sequence, 2)
	decision.record = "coordinator_failpoint_decision"
	decision.action = "continue"
	decision.mac = _decision_mac(token, decision)
	assert_true(QualificationBarrier._write_new(
		_scratch_dir.path_join(QualificationBarrier.DECISION_NAME), decision))
	assert_eq(barrier.poll(), QualificationBarrier.CONTINUE)
	assert_false(barrier.begin("coordinator_filesystem_scan", "after"))
	assert_false(FileAccess.file_exists(barrier_path))
	barrier.clear_environment()
	assert_false(OS.has_environment(QualificationBarrier.OCCURRENCE_ENV))


func test_external_actor_barriers_remain_actor_owned() -> void:
	for effect in ["intent_temporary_write", "journal_temporary_write", "terminal_temporary_write",
		"migration_complete", "migration_complete_temporary_write", "repair_claim"]:
		_clear_qualification_environment()
		OS.set_environment(QualificationBarrier.TOKEN_ENV, "ab".repeat(32))
		OS.set_environment(QualificationBarrier.EFFECT_ENV, effect)
		OS.set_environment(QualificationBarrier.WHEN_ENV, "after")
		OS.set_environment(QualificationBarrier.TIMEOUT_ENV, "5")
		var barrier := QualificationBarrier.new()
		assert_true(barrier.configure(_prepared_fixture()), barrier.error)
		assert_false(barrier.is_coordinator_effect())
		assert_false(barrier.begin(effect, "after"), "the editor must not steal an actor barrier")
		assert_eq(OS.get_environment(QualificationBarrier.EFFECT_ENV), effect,
			"the complete tuple remains available for actor launch")
		assert_false(FileAccess.file_exists(_scratch_dir.path_join(QualificationBarrier.BARRIER_NAME)))
		barrier.clear_environment()
		assert_false(OS.has_environment(QualificationBarrier.TOKEN_ENV))
	_clear_qualification_environment()


func test_qualification_barrier_rejects_invalid_occurrence() -> void:
	for value in ["", "0", "-1", "01", "1.0", "10000", "9".repeat(400)]:
		_clear_qualification_environment()
		OS.set_environment(QualificationBarrier.TOKEN_ENV, "ab".repeat(32))
		OS.set_environment(QualificationBarrier.EFFECT_ENV, "journal_commit")
		OS.set_environment(QualificationBarrier.WHEN_ENV, "after")
		OS.set_environment(QualificationBarrier.TIMEOUT_ENV, "5")
		OS.set_environment(QualificationBarrier.OCCURRENCE_ENV, value)
		var barrier := QualificationBarrier.new()
		assert_false(barrier.configure(_prepared_fixture()))
		assert_true(barrier.error.contains("occurrence"))
	_clear_qualification_environment()
	OS.set_environment(QualificationBarrier.OCCURRENCE_ENV, "2")
	var incomplete := QualificationBarrier.new()
	assert_false(incomplete.configure(_prepared_fixture()))
	assert_true(incomplete.error.contains("incomplete"))
	_clear_qualification_environment()


func _prepared_fixture() -> Dictionary:
	return {
		"from_version": "4.0.0",
		"install_root": _scratch_dir.path_join("project/addons/godot_ai"),
		"manifest_sha256": "a".repeat(64),
		"project_root": _scratch_dir.path_join("project"),
		"recovery_root": _scratch_dir,
		"stage_root": _scratch_dir.path_join("stages/transaction/addons/godot_ai"),
		"to_version": "4.0.1",
		"transaction": "transaction-0123456789",
	}


func _decision_mac(token: String, decision: Dictionary) -> String:
	var message := (
		"godot-ai-coordinator-failpoint-v1\n%s\n%s\n%s\n%s\n%s\n%s\n%d\n%s\n"
		% [
			decision.transaction,
			decision.project_root,
			decision.install_root,
			decision.recovery_root,
			decision.effect,
			decision.when,
			decision.sequence,
			decision.action,
		]
	)
	var context := HMACContext.new()
	context.start(HashingContext.HASH_SHA256, token.hex_decode())
	context.update(message.to_utf8_buffer())
	return context.finish().hex_encode()


func _clear_qualification_environment() -> void:
	for name in [
		QualificationBarrier.TOKEN_ENV,
		QualificationBarrier.EFFECT_ENV,
		QualificationBarrier.WHEN_ENV,
		QualificationBarrier.TIMEOUT_ENV,
		QualificationBarrier.OCCURRENCE_ENV,
	]:
		OS.unset_environment(name)
