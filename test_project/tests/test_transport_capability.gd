@tool
extends McpTestSuite

const HTTP := "hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh"
const WEBSOCKET := "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
const NONCE := "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

var _scratch_dir: String
var _record_path: String


func suite_name() -> String:
	return "transport_capability"


func suite_setup(_ctx: Dictionary) -> void:
	_scratch_dir = OS.get_user_data_dir().path_join("transport_capability_tests")
	DirAccess.make_dir_recursive_absolute(_scratch_dir)
	_record_path = _scratch_dir.path_join("http-8122.json")
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(
			_scratch_dir,
			FileAccess.UNIX_READ_OWNER
			| FileAccess.UNIX_WRITE_OWNER
			| FileAccess.UNIX_EXECUTE_OWNER,
		)


func suite_teardown() -> void:
	DirAccess.remove_absolute(_record_path)
	DirAccess.remove_absolute(_scratch_dir)


func test_reads_exact_private_record() -> void:
	_write(_canonical_record())
	var result := McpTransportCapability._read_path(_record_path)
	assert_eq(result.get("http", ""), HTTP)
	assert_eq(result.get("websocket", ""), WEBSOCKET)
	assert_eq(result.get("instance_nonce", ""), NONCE)


func test_captured_path_is_bound_to_the_requested_port() -> void:
	_write(_canonical_record())
	assert_eq(McpTransportCapability.read_for_http_port(8122, _record_path).http, HTTP)
	assert_true(McpTransportCapability.read_for_http_port(8123, _record_path).is_empty())


func test_only_canonical_sticky_temp_root_may_be_a_writable_ancestor() -> void:
	var writable := (
		FileAccess.UNIX_READ_OWNER
		| FileAccess.UNIX_WRITE_OWNER
		| FileAccess.UNIX_EXECUTE_OWNER
		| FileAccess.UNIX_READ_GROUP
		| FileAccess.UNIX_WRITE_GROUP
		| FileAccess.UNIX_EXECUTE_GROUP
		| FileAccess.UNIX_READ_OTHER
		| FileAccess.UNIX_WRITE_OTHER
		| FileAccess.UNIX_EXECUTE_OTHER
	)
	var sticky := writable | FileAccess.UNIX_RESTRICTED_DELETE
	assert_true(McpTransportCapability._safe_posix_ancestor_mode("/tmp", sticky))
	assert_true(McpTransportCapability._safe_posix_ancestor_mode("/private/tmp", sticky))
	assert_false(McpTransportCapability._safe_posix_ancestor_mode("/tmp", writable))
	assert_false(McpTransportCapability._safe_posix_ancestor_mode("/untrusted", sticky))


func test_rejects_ambiguous_or_partial_records() -> void:
	var invalid: Array[String] = [
		'{"version":1,"http":"%s","websocket":"%s"}' % [HTTP, WEBSOCKET],
		_canonical_record().replace('"version":1', '"version":1,"version":1'),
		_canonical_record().replace('"version":1', '"version":true'),
		_canonical_record().replace(WEBSOCKET, HTTP),
		_canonical_record().replace(NONCE, "not-hex"),
		_canonical_record().trim_suffix("}") + ',"extra":1}',
	]
	for raw in invalid:
		_write(raw)
		assert_true(
			McpTransportCapability._read_path(_record_path).is_empty(),
			"must reject %s" % raw,
		)


func test_rejects_non_ascii_and_oversize_records() -> void:
	for raw in ["café", "x".repeat(McpTransportCapability.MAX_RECORD_BYTES + 2)]:
		_write(raw)
		assert_true(McpTransportCapability._read_path(_record_path).is_empty())


func test_rejects_permissive_posix_mode() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX modes are unavailable on Windows")
		return
	_write(_canonical_record())
	FileAccess.set_unix_permissions(
		_record_path,
		FileAccess.UNIX_READ_OWNER
		| FileAccess.UNIX_WRITE_OWNER
		| FileAccess.UNIX_READ_GROUP
		| FileAccess.UNIX_READ_OTHER,
	)
	assert_true(McpTransportCapability._read_path(_record_path).is_empty())


func test_follows_a_link_below_a_closed_parent_on_posix() -> void:
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var real_dir := _scratch_dir + "_real"
	var real_record := _private_record_in(real_dir)
	## The link lives inside the suite's 0700 scratch directory: only its owner
	## or root could have placed it, so the walk follows it (#993).
	var linked_dir := _scratch_dir.path_join("closed-link")
	DirAccess.remove_absolute(linked_dir)
	if OS.execute("ln", ["-s", real_dir, linked_dir]) != 0:
		skip("could not create a POSIX symlink")
	else:
		var result := McpTransportCapability._read_path(linked_dir.path_join("http-8122.json"))
		assert_eq(
			result.get("http", ""),
			HTTP,
			"a link placed in a directory closed to group/other writes is followed",
		)
		assert_eq(
			McpTransportCapability._resolve_trusted_path(linked_dir.path_join("http-8122.json")),
			real_record,
		)
	DirAccess.remove_absolute(linked_dir)
	_remove_private_record_in(real_dir)


func test_follows_a_relative_link_target_on_posix() -> void:
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var real_dir := _scratch_dir + "_real"
	var real_record := _private_record_in(real_dir)
	## ostree writes `/home -> var/home`, a relative target; resolve it against
	## the already-walked parent, as the kernel does.
	var linked_dir := _scratch_dir.path_join("relative-link")
	DirAccess.remove_absolute(linked_dir)
	if OS.execute("ln", ["-s", "../" + real_dir.get_file(), linked_dir]) != 0:
		skip("could not create a POSIX symlink")
	else:
		assert_eq(
			McpTransportCapability._resolve_trusted_path(linked_dir.path_join("http-8122.json")),
			real_record,
		)
		assert_eq(
			McpTransportCapability._read_path(linked_dir.path_join("http-8122.json")).get("http", ""),
			HTTP,
		)
	DirAccess.remove_absolute(linked_dir)
	_remove_private_record_in(real_dir)


func test_rejects_a_link_below_a_writable_parent_on_posix() -> void:
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var real_dir := _scratch_dir + "_real"
	_private_record_in(real_dir)
	var open_dir := _scratch_dir.path_join("open")
	DirAccess.make_dir_recursive_absolute(open_dir)
	FileAccess.set_unix_permissions(open_dir, _WORLD_WRITABLE)
	var linked_dir := open_dir.path_join("link")
	DirAccess.remove_absolute(linked_dir)
	if OS.execute("ln", ["-s", real_dir, linked_dir]) != 0:
		skip("could not create a POSIX symlink")
	else:
		assert_true(
			McpTransportCapability._read_path(linked_dir.path_join("http-8122.json")).is_empty(),
			"a link that any account could have placed must fail closed",
		)
	FileAccess.set_unix_permissions(open_dir, _OWNER_ONLY)
	DirAccess.remove_absolute(linked_dir)
	DirAccess.remove_absolute(open_dir)
	_remove_private_record_in(real_dir)


func test_rejects_a_linked_record_file_on_posix() -> void:
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var real_dir := _scratch_dir + "_real"
	var real_record := _private_record_in(real_dir)
	var linked_record := _scratch_dir.path_join("http-8122.json")
	DirAccess.remove_absolute(linked_record)
	if OS.execute("ln", ["-s", real_record, linked_record]) != 0:
		skip("could not create a POSIX symlink")
	else:
		assert_true(
			McpTransportCapability._read_path(linked_record).is_empty(),
			"the record file itself is never followed",
		)
	DirAccess.remove_absolute(linked_record)
	_remove_private_record_in(real_dir)


func test_rejects_a_link_loop_on_posix() -> void:
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var first := _scratch_dir.path_join("loop-a")
	var second := _scratch_dir.path_join("loop-b")
	DirAccess.remove_absolute(first)
	DirAccess.remove_absolute(second)
	if OS.execute("ln", ["-s", second, first]) != 0 or OS.execute("ln", ["-s", first, second]) != 0:
		skip("could not create a POSIX symlink")
	else:
		assert_eq(
			McpTransportCapability._resolve_trusted_path(first.path_join("http-8122.json")),
			"",
			"a link chain past the hop bound must fail closed",
		)
	DirAccess.remove_absolute(first)
	DirAccess.remove_absolute(second)


func test_rejects_world_writable_posix_ancestor() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX ancestor modes are unavailable on Windows")
		return
	var unsafe_dir := _scratch_dir + "_unsafe"
	var private_dir := unsafe_dir.path_join("private")
	var unsafe_record := private_dir.path_join("http-8122.json")
	DirAccess.make_dir_recursive_absolute(private_dir)
	FileAccess.set_unix_permissions(
		private_dir,
		FileAccess.UNIX_READ_OWNER
		| FileAccess.UNIX_WRITE_OWNER
		| FileAccess.UNIX_EXECUTE_OWNER,
	)
	FileAccess.set_unix_permissions(
		unsafe_dir,
		FileAccess.UNIX_READ_OWNER
		| FileAccess.UNIX_WRITE_OWNER
		| FileAccess.UNIX_EXECUTE_OWNER
		| FileAccess.UNIX_READ_GROUP
		| FileAccess.UNIX_WRITE_GROUP
		| FileAccess.UNIX_EXECUTE_GROUP
		| FileAccess.UNIX_READ_OTHER
		| FileAccess.UNIX_WRITE_OTHER
		| FileAccess.UNIX_EXECUTE_OTHER,
	)
	var file := FileAccess.open(unsafe_record, FileAccess.WRITE)
	file.store_string(_canonical_record())
	file.close()
	FileAccess.set_unix_permissions(
		unsafe_record, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER
	)
	assert_true(
		McpTransportCapability._read_path(unsafe_record).is_empty(),
		"a private leaf below a writable ancestor must fail closed",
	)
	## Restore owner-only access before cleanup so the test never leaves a
	## permissive directory behind if the platform enforces deletion modes.
	FileAccess.set_unix_permissions(
		unsafe_dir,
		FileAccess.UNIX_READ_OWNER
		| FileAccess.UNIX_WRITE_OWNER
		| FileAccess.UNIX_EXECUTE_OWNER,
	)
	DirAccess.remove_absolute(unsafe_record)
	DirAccess.remove_absolute(private_dir)
	DirAccess.remove_absolute(unsafe_dir)


func test_windows_rejects_capability_directory_override() -> void:
	var before := OS.get_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	OS.set_environment(McpTransportCapability.CAPABILITY_DIR_ENV, _scratch_dir)
	var path := McpTransportCapability.path_for_http_port(8122)
	if before.is_empty():
		OS.unset_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	else:
		OS.set_environment(McpTransportCapability.CAPABILITY_DIR_ENV, before)
	if OS.get_name() == "Windows":
		assert_eq(path, "")
	else:
		assert_eq(path, _record_path)


func test_posix_rejects_relative_capability_directory_override() -> void:
	if OS.get_name() == "Windows":
		skip("Windows rejects every capability-directory override")
		return
	var before := OS.get_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	OS.set_environment(McpTransportCapability.CAPABILITY_DIR_ENV, "relative/capabilities")
	var path := McpTransportCapability.path_for_http_port(8122)
	if before.is_empty():
		OS.unset_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	else:
		OS.set_environment(McpTransportCapability.CAPABILITY_DIR_ENV, before)
	assert_eq(path, "")


func test_linux_rejects_relative_xdg_capability_directory() -> void:
	if OS.get_name() != "Linux":
		skip("XDG_CONFIG_HOME selects the capability directory only on Linux")
		return
	var before_override := OS.get_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	var before_xdg := OS.get_environment("XDG_CONFIG_HOME")
	OS.unset_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	OS.set_environment("XDG_CONFIG_HOME", "relative/config")
	var path := McpTransportCapability.path_for_http_port(8122)
	if before_override.is_empty():
		OS.unset_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	else:
		OS.set_environment(McpTransportCapability.CAPABILITY_DIR_ENV, before_override)
	if before_xdg.is_empty():
		OS.unset_environment("XDG_CONFIG_HOME")
	else:
		OS.set_environment("XDG_CONFIG_HOME", before_xdg)
	assert_eq(path, "")


func _write(raw: String) -> void:
	var file := FileAccess.open(_record_path, FileAccess.WRITE)
	file.store_string(raw)
	file.close()
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(
			_record_path,
			FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER,
		)


func _canonical_record() -> String:
	return (
		'{"version":1,"http":"%s","websocket":"%s","instance_nonce":"%s"}'
		% [HTTP, WEBSOCKET, NONCE]
	)


const _OWNER_ONLY := (
	FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER | FileAccess.UNIX_EXECUTE_OWNER
)
const _WORLD_WRITABLE := (
	_OWNER_ONLY
	| FileAccess.UNIX_READ_GROUP
	| FileAccess.UNIX_WRITE_GROUP
	| FileAccess.UNIX_EXECUTE_GROUP
	| FileAccess.UNIX_READ_OTHER
	| FileAccess.UNIX_WRITE_OTHER
	| FileAccess.UNIX_EXECUTE_OTHER
)


## A canonical record in a fresh 0700 directory; returns the record path.
func _private_record_in(directory: String) -> String:
	DirAccess.make_dir_recursive_absolute(directory)
	FileAccess.set_unix_permissions(directory, _OWNER_ONLY)
	var record := directory.path_join("http-8122.json")
	var file := FileAccess.open(record, FileAccess.WRITE)
	file.store_string(_canonical_record())
	file.close()
	FileAccess.set_unix_permissions(record, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	return record


func _remove_private_record_in(directory: String) -> void:
	DirAccess.remove_absolute(directory.path_join("http-8122.json"))
	DirAccess.remove_absolute(directory)


func test_directory_write_problem_is_empty_for_a_writable_directory() -> void:
	var directory := _scratch_dir.path_join("writable")
	assert_eq(McpTransportCapability.directory_write_problem_for(directory), "")
	assert_true(DirAccess.dir_exists_absolute(directory), "the probe creates the directory")
	assert_eq(DirAccess.get_files_at(directory).size(), 0, "the probe file is removed")
	DirAccess.remove_absolute(directory)


func test_directory_write_problem_names_the_directory_and_the_repair() -> void:
	## A regular file where the directory must go fails creation on every OS,
	## standing in for the Administrators-owned directory of #988.
	var blocker := _scratch_dir.path_join("godot-ai")
	var file := FileAccess.open(blocker, FileAccess.WRITE)
	file.store_string("x")
	file.close()
	var directory := blocker.path_join("capabilities")
	var problem := McpTransportCapability.directory_write_problem_for(directory)
	assert_true(problem.contains(directory), "names the directory: %s" % problem)
	assert_false(problem.contains("Remove-Item"), "never suggests deleting a named ancestor")
	assert_true(problem.contains("permissions"), "explains how to restore access")
	assert_true(problem.contains("elevated"), "explains the cause: %s" % problem)
	DirAccess.remove_absolute(blocker)


func test_windows_repair_hint_preserves_path_and_detail_without_deletion_advice() -> void:
	for directory in [
		"C:/workspace/godot-ai/.worktrees/project/custom/runtime",
		"C:/custom/runtime",
		"C:/Users/user/AppData/Local/godot-ai/capabilities",
	]:
		var problem := McpTransportCapability.windows_repair_hint(directory, "permission-detail")
		assert_true(problem.contains(directory), "names the actual inaccessible directory")
		assert_true(problem.contains("permission-detail"), "retains the underlying error detail")
		assert_true(problem.contains("permissions"), "offers directory-specific access guidance")
		assert_false(problem.contains("Remove-Item"), "managed, repository and custom paths are non-destructive")


func test_directory_write_problem_is_windows_only() -> void:
	if OS.get_name() == "Windows":
		skip("POSIX leaves capability directory creation to the server")
		return
	assert_eq(McpTransportCapability.directory_write_problem(8122), "")
