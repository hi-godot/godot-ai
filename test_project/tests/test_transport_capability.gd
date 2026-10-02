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
	var before_host := OS.get_environment("HOST_XDG_CONFIG_HOME")
	OS.unset_environment(McpTransportCapability.CAPABILITY_DIR_ENV)
	## A Flatpak editor that shares the home reads the host's variable instead.
	OS.set_environment("XDG_CONFIG_HOME", "relative/config")
	OS.set_environment("HOST_XDG_CONFIG_HOME", "relative/config")
	var path := McpTransportCapability.path_for_http_port(8122)
	_restore_environment(McpTransportCapability.CAPABILITY_DIR_ENV, before_override)
	_restore_environment("XDG_CONFIG_HOME", before_xdg)
	_restore_environment("HOST_XDG_CONFIG_HOME", before_host)
	assert_eq(path, "")


func test_flatpak_shares_home_only_with_a_read_write_home_grant() -> void:
	## Mirrors tests/unit/test_transport_capability.py: the server must publish
	## where this plugin reads.
	var cases := {
		"xdg-run/speech-dispatcher;host;": true,
		"home;": true,
		"home:create;xdg-run/speech-dispatcher;": true,
		"xdg-run/speech-dispatcher;host:create;": true,
		"host:rw;": true,
		"home:rw;": true,
		"home:ro;xdg-run/speech-dispatcher;host;": true,
		"home;xdg-run/speech-dispatcher;host:ro;": true,
		"xdg-run/speech-dispatcher;": false,
		"home:ro;xdg-run/speech-dispatcher;": false,
		"host:ro;": false,
		"!home;xdg-config/godot-ai;": false,
		"~/projects;host-os;host-etc;": false,
		"": false,
	}
	for filesystems in cases:
		assert_eq(
			McpTransportCapability.flatpak_shares_home(_flatpak_info(filesystems)),
			cases[filesystems],
			"filesystems=%s" % filesystems,
		)
	assert_false(McpTransportCapability.flatpak_shares_home(""), "not a Flatpak sandbox")
	assert_false(
		McpTransportCapability.flatpak_shares_home("[Context]\nshared=network;\n"),
		"an app that never had a filesystem entry has no such key",
	)
	assert_false(
		McpTransportCapability.flatpak_shares_home(
			"[Instance]\nfilesystems=host;\n\n[Context]\nfilesystems=xdg-run/app;\n"
		),
		"only the [Context] group lists the sandbox's grants",
	)


func test_linux_config_home_is_the_host_directory_when_flatpak_shares_home() -> void:
	var before_xdg := OS.get_environment("XDG_CONFIG_HOME")
	var before_host := OS.get_environment("HOST_XDG_CONFIG_HOME")
	var sharing_home := _flatpak_info("xdg-run/speech-dispatcher;host;")
	var no_home := _flatpak_info("xdg-run/speech-dispatcher;")
	OS.set_environment("XDG_CONFIG_HOME", "/sandbox/app/config")
	OS.unset_environment("HOST_XDG_CONFIG_HOME")
	var host_default := McpTransportCapability.linux_config_home(sharing_home)
	var sandbox_private := McpTransportCapability.linux_config_home(no_home)
	var native := McpTransportCapability.linux_config_home("")
	OS.set_environment("HOST_XDG_CONFIG_HOME", "/host/config")
	var host_named := McpTransportCapability.linux_config_home(sharing_home)
	var private_ignores_host := McpTransportCapability.linux_config_home(no_home)
	_restore_environment("XDG_CONFIG_HOME", before_xdg)
	_restore_environment("HOST_XDG_CONFIG_HOME", before_host)
	assert_eq(host_default, OS.get_environment("HOME").path_join(".config"))
	assert_eq(host_named, "/host/config")
	assert_eq(sandbox_private, "/sandbox/app/config")
	assert_eq(private_ignores_host, "/sandbox/app/config")
	assert_eq(native, "/sandbox/app/config")


func test_flatpak_shares_config_home_with_the_home_or_the_whole_xdg_config() -> void:
	## Mirrors tests/unit/test_transport_capability.py. A grant of the whole
	## `xdg-config` is mounted at the host's path only, so a sandbox holding it
	## must name the host's directory. An `xdg-config/<dir>` grant is mounted
	## inside the per-app directory too, where XDG_CONFIG_HOME finds it.
	var cases := {
		"xdg-run/speech-dispatcher;host;": true,
		"home:create;": true,
		"xdg-config;xdg-run/speech-dispatcher;": true,
		"xdg-config:create;": true,
		"xdg-config:rw;": true,
		"home:ro;xdg-config;": true,
		"xdg-config:ro;": false,
		"!xdg-config;": false,
		"xdg-config/godot-ai;": false,
		"xdg-config/godot-ai:create;xdg-config:ro;": false,
		"~/.config;": false,
		"xdg-data;xdg-cache;": false,
		"xdg-run/speech-dispatcher;": false,
		"": false,
	}
	for filesystems in cases:
		var info := _flatpak_info(filesystems)
		assert_eq(
			McpTransportCapability.flatpak_shares_config_home(info),
			cases[filesystems],
			"filesystems=%s" % filesystems,
		)
		assert_eq(
			McpTransportCapability.linux_config_home_variable(info),
			"HOST_XDG_CONFIG_HOME" if cases[filesystems] else "XDG_CONFIG_HOME",
			"filesystems=%s" % filesystems,
		)
	assert_false(McpTransportCapability.flatpak_shares_config_home(""), "not a Flatpak sandbox")


func test_flatpak_shares_a_path_through_the_narrowest_read_write_grant_over_it() -> void:
	## Each row was checked against the Flathub Godot build under Flatpak
	## 1.16.6: which of these the sandbox could write, and where.
	const HOME := "/var/home/dev"
	const CONFIG := "/var/home/dev/.config"
	var cursor := HOME + "/.cursor/mcp.json"
	var code := CONFIG + "/Code/User/mcp.json"
	var other_app := HOME + "/.var/app/com.visualstudio.code/config/Code/User/mcp.json"
	var cases := [
		## The home directory, through either grant.
		["xdg-run/speech-dispatcher;host;", cursor, HOME],
		["home;", cursor, HOME],
		["home:create;", cursor, HOME],
		["home:ro;", cursor, ""],
		["host:ro;", cursor, ""],
		["home:ro;xdg-run/speech-dispatcher;host;", cursor, HOME],
		["home;host:ro;", cursor, HOME],
		["xdg-run/speech-dispatcher;", cursor, ""],
		["", cursor, ""],
		## A directory or file granted by path.
		["~/.cursor;", cursor, HOME + "/.cursor"],
		["~/.cursor:create;", cursor, HOME + "/.cursor"],
		["~/.cursor:ro;", cursor, ""],
		["/var/home/dev/.cursor;", cursor, HOME + "/.cursor"],
		["~/.cursor/mcp.json;", cursor, cursor],
		["~/.curs;", cursor, ""],
		["~/.cursor;", HOME + "/.cursor", HOME + "/.cursor"],
		## The narrowest grant decides, in both directions.
		["home:ro;~/.cursor;", cursor, HOME + "/.cursor"],
		["home;~/.cursor:ro;", cursor, ""],
		["home;~/.cursor:ro;", code, HOME],
		## The host's config directory.
		["xdg-config/Code;", code, CONFIG + "/Code"],
		["xdg-config/Code:create;", code, CONFIG + "/Code"],
		["xdg-config/Code:ro;", code, ""],
		["xdg-config;", code, CONFIG],
		["xdg-config:ro;", code, ""],
		["xdg-config;xdg-config/Code:ro;", code, ""],
		["xdg-config:ro;xdg-config/Code;", code, CONFIG + "/Code"],
		["~/.config;", code, CONFIG],
		["xdg-config/Trae;", code, ""],
		["xdg-config/Cod;", code, ""],
		## Two spellings of one directory count only when both are writable.
		["xdg-config;~/.config:ro;", code, ""],
		## Under ~/.var/app the home grant brings nothing: another app's
		## directory is hidden, and the sandbox's own is shared without a grant.
		["host;", other_app, ""],
		["host;~/.var/app/com.visualstudio.code;", other_app, HOME + "/.var/app/com.visualstudio.code"],
		[
			"xdg-run/speech-dispatcher;",
			HOME + "/.var/app/org.godotengine.Godot/data/godot/app_userdata/x/mcp.json",
			HOME + "/.var/app/org.godotengine.Godot",
		],
		["host;", HOME + "/.var/app/org.godotengine.GodotSharp/config/mcp.json", ""],
		["host;", HOME + "/.var/app", ""],
		## Outside the home: `host` shares what its runtime does not occupy.
		["host;", "/opt/codex/config.toml", "/opt"],
		["host;", "/tmp/codex/config.toml", ""],
		["host;", "/var/lib/codex/config.toml", ""],
		["home;", "/opt/codex/config.toml", ""],
		["/opt/codex;", "/opt/codex/config.toml", "/opt/codex"],
		## Grants this cannot place share nothing.
		["xdg-documents/godot;xdg-data;host-os;host-etc;", HOME + "/Documents/godot/mcp.json", ""],
		## Denials are not written to /.flatpak-info, but parse as denials.
		["!home;", cursor, ""],
		["home;!~/.cursor;", cursor, ""],
	]
	for case in cases:
		assert_eq(
			_shared_root(
				_flatpak_info(case[0]), case[1], HOME, CONFIG
			),
			case[2],
			"filesystems=%s path=%s" % [case[0], case[1]],
		)
	assert_eq(_shared_root("", cursor, HOME, CONFIG), "",
		"outside Flatpak there are no grants to read")
	assert_eq(
		_shared_root(
			"[Context]\nfilesystems=host;\n", HOME + "/.var/app/org.godotengine.Godot/x.json", HOME, CONFIG
		),
		"",
		"with no app ID no directory under ~/.var/app is the sandbox's own",
	)
	assert_eq(
		_shared_root(
			_flatpak_info("host;"), ".cursor/mcp.json", HOME, CONFIG
		),
		"",
		"a relative path names nothing",
	)
	assert_eq(
		_shared_root(
			_flatpak_info("xdg-config/Code;"), "/custom/cfg/Code/User/mcp.json", HOME, "/custom/cfg"
		),
		"/custom/cfg/Code",
		"`xdg-config` is the host's config directory, wherever the host put it",
	)
	assert_eq(
		_shared_root(_flatpak_info("xdg-config/Code;home;"), code, "", ""),
		"",
		"with no home directory neither grant can be placed",
	)
	for unplaced in ["xdg-documents/godot", "xdg-data", "xdg-configs", "host-os", "home", "relative/dir"]:
		assert_eq(
			McpTransportCapability._flatpak_grant_path(unplaced, HOME, CONFIG),
			"",
			"%s names no directory this can place" % unplaced,
		)


func test_flatpak_grant_over_names_the_grant_that_has_to_change() -> void:
	## A refusal has to name a grant that would work. A read-only grant on the
	## client's own directory stays read-only under a writable home.
	const HOME := "/var/home/dev"
	const CONFIG := "/var/home/dev/.config"
	var cursor := HOME + "/.cursor/mcp.json"
	var code := CONFIG + "/Code/User/mcp.json"
	var cases := [
		["home;~/.cursor:ro;", cursor, {"root": HOME + "/.cursor", "location": "~/.cursor", "writable": false}],
		["home:ro;", cursor, {"root": HOME, "location": "home", "writable": false}],
		## `home` is enough inside the home even when the grant held is `host`.
		["host:ro;", cursor, {"root": HOME, "location": "home", "writable": false}],
		["host;", cursor, {"root": HOME, "location": "home", "writable": true}],
		["xdg-config:ro;", code, {"root": CONFIG, "location": "xdg-config", "writable": false}],
		["xdg-config;~/.config:ro;", code, {"root": CONFIG, "location": "~/.config", "writable": false}],
		["~/.config:ro;xdg-config;", code, {"root": CONFIG, "location": "~/.config", "writable": false}],
		["xdg-config/Code:create;", code, {"root": CONFIG + "/Code", "location": "xdg-config/Code", "writable": true}],
		["host:ro;", "/opt/codex/config.toml", {"root": "/opt", "location": "host", "writable": false}],
		["xdg-run/speech-dispatcher;", cursor, {}],
		["host;", HOME + "/.var/app/dev.zed.Zed/config/zed/settings.json", {}],
	]
	for case in cases:
		assert_eq(
			McpTransportCapability.flatpak_grant_over(_flatpak_info(case[0]), case[1], HOME, CONFIG),
			case[2],
			"filesystems=%s path=%s" % [case[0], case[1]],
		)


func test_flatpak_grant_spelled_through_the_home_link_covers_the_real_home() -> void:
	## ostree systems keep homes in /var/home behind a /home link. Flatpak
	## mounts a grant at the real directory and keeps the link, so the two
	## spellings name one place whichever of them HOME uses.
	var real_home := _shared_root(
		_flatpak_info("/home/dev/.cursor;"), "/var/home/dev/.cursor/mcp.json", "/var/home/dev", ""
	)
	var linked_home := _shared_root(
		_flatpak_info("/var/home/dev/.cursor;"), "/home/dev/.cursor/mcp.json", "/home/dev", ""
	)
	var unrelated := _shared_root(
		_flatpak_info("/home/dev/.cursor;"), "/srv/home/dev/.cursor/mcp.json", "/srv/home/dev", ""
	)
	assert_eq(real_home, "/var/home/dev/.cursor")
	assert_eq(linked_home, "/home/dev/.cursor")
	assert_eq(unrelated, "", "only the /home and /var/home pair is one directory")


func test_flatpak_grants_resolve_key_file_and_mode_escapes() -> void:
	## Flatpak escapes `:` and `\` for its mode syntax, and the key file then
	## escapes `;` and `\` again. Read as written by Flatpak 1.16.6 for
	## `~/a;b`, `~/with:colon`, `~/back\slash` and `~/My Dir`.
	var info := _flatpak_info(
		"~/a\\;b;~/with\\\\:colon:ro;~/back\\\\\\\\slash;~/My Dir;xdg-run/speech-dispatcher;"
	)
	assert_eq(
		McpTransportCapability._flatpak_filesystems(info),
		{
			"~/a;b": true,
			"~/with:colon": false,
			"~/back\\slash": true,
			"~/My Dir": true,
			"xdg-run/speech-dispatcher": true,
		},
	)
	assert_eq(
		McpTransportCapability._flatpak_filesystems(
			_flatpak_info("!host:reset;home:create;~/x:rw;~/y:future-mode;!~/z;")
		),
		{"home": true, "~/x": true, "~/y": false, "~/z": false},
		"a reset names no location, and an unknown mode is not taken for writable",
	)
	assert_eq(
		McpTransportCapability._flatpak_filesystems(
			_flatpak_info("~/\\sled;~/tab\\there;~/line\\nfeed;~/cr\\rhere;")
		),
		{"~/ led": true, "~/tab\there": true, "~/line\nfeed": true, "~/cr\rhere": true},
		"a key file writes leading spaces and control characters as \\s, \\t, \\n and \\r",
	)
	assert_eq(
		McpTransportCapability._flatpak_filesystems(
			"[Instance]\nfilesystems=host;\n\n[Context]\nshared=network;\n"
		),
		{},
		"only the [Context] group lists the sandbox's grants",
	)


func test_flatpak_application_id_is_the_name_in_the_application_group() -> void:
	assert_eq(
		McpTransportCapability.flatpak_application_id(_flatpak_info("host;")),
		"org.godotengine.Godot",
	)
	assert_eq(
		McpTransportCapability.flatpak_application_id(
			"[Instance]\nname=not-the-app\n\n[Application]\nname=org.example.Editor\nruntime=x\n"
		),
		"org.example.Editor",
		"only the [Application] group names the app",
	)
	assert_eq(McpTransportCapability.flatpak_application_id("[Context]\nfilesystems=host;\n"), "")
	assert_eq(McpTransportCapability.flatpak_application_id(""), "", "not a Flatpak sandbox")


## The mounts of a Flathub Godot 4.7.2 sandbox under Flatpak 1.16.6, cut down
## to the root, the runtime and what lies under the home directory. The first
## shares the home (`host`), with `~/.cursor` denied. The second does not, and
## was granted `~/.cursor` and `xdg-config/Code`.
const _MOUNTS_HOME_SHARED := """102 85 0:66 /newroot / rw,nosuid,nodev,relatime - tmpfs tmpfs rw,uid=1000,gid=1000
103 102 0:62 /var/home/dev/.local/share/flatpak/runtime/org.freedesktop.Sdk/files /usr ro,nosuid,nodev,relatime - overlay overlay rw,lowerdir=/l,upperdir=/u,workdir=/w
187 102 0:62 /var/home/dev/.var/app/org.godotengine.Godot/cache/tmp /var/tmp rw,nosuid,nodev,relatime - overlay overlay rw
214 102 0:62 /var/home /var/home rw,nosuid,nodev,relatime - overlay overlay rw
215 214 0:70 / /var/home/dev/.cursor rw,nosuid,nodev,relatime - tmpfs tmpfs rw,mode=755,uid=1000,gid=1000
216 214 0:71 / /var/home/dev/.local/share/flatpak rw,nosuid,nodev,relatime - tmpfs tmpfs rw,mode=755,uid=1000,gid=1000
217 214 0:72 / /var/home/dev/.var/app rw,nosuid,nodev,relatime - tmpfs tmpfs rw,mode=755,uid=1000,gid=1000
218 217 0:62 /var/home/dev/.var/app/org.godotengine.Godot /var/home/dev/.var/app/org.godotengine.Godot rw,nosuid,nodev,relatime - overlay overlay rw
"""
const _MOUNTS_HOME_PRIVATE := """102 85 0:66 /newroot / rw,nosuid,nodev,relatime - tmpfs tmpfs rw,uid=1000,gid=1000
103 102 0:62 /var/home/dev/.local/share/flatpak/runtime/org.freedesktop.Sdk/files /usr ro,nosuid,nodev,relatime - overlay overlay rw,lowerdir=/l,upperdir=/u,workdir=/w
207 102 0:62 /var/home/dev/.config/Code /var/home/dev/.config/Code rw,nosuid,nodev,relatime - overlay overlay rw
208 102 0:62 /var/home/dev/.cursor /var/home/dev/.cursor rw,nosuid,nodev,relatime shared:12 master:3 - overlay overlay rw
209 102 0:62 /var/home/dev/.var/app/org.godotengine.Godot /var/home/dev/.var/app/org.godotengine.Godot rw,nosuid,nodev,relatime - overlay overlay rw
211 209 0:62 /var/home/dev/.config/Code /var/home/dev/.var/app/org.godotengine.Godot/config/Code rw,nosuid,nodev,relatime - overlay overlay rw
212 102 0:62 /var/home/dev/My\\040Docs /var/home/dev/My\\040Docs ro,nosuid,nodev,relatime - overlay overlay rw
"""


func test_mountinfo_names_the_mount_that_holds_a_path() -> void:
	var shared := McpTransportCapability.parse_mountinfo(_MOUNTS_HOME_SHARED)
	var private := McpTransportCapability.parse_mountinfo(_MOUNTS_HOME_PRIVATE)
	assert_eq(shared.size(), 8)
	assert_eq(private.size(), 7)

	var home_bind := McpTransportCapability.mount_for_path(shared, "/var/home/dev/.codex/config.toml")
	assert_eq(home_bind.get("mount_point"), "/var/home")
	assert_eq(home_bind.get("fstype"), "overlay")
	assert_false(home_bind.get("read_only"))
	var denied := McpTransportCapability.mount_for_path(shared, "/var/home/dev/.cursor/mcp.json")
	assert_eq(denied.get("mount_point"), "/var/home/dev/.cursor")
	assert_eq(denied.get("fstype"), "tmpfs")
	assert_eq(denied.get("root"), "/", "a tmpfs Flatpak made is mounted whole")
	assert_eq(
		McpTransportCapability.mount_for_path(shared, "/var/home/dev/.cursorrules").get("mount_point"),
		"/var/home",
		"a mount point holds its own subtree, not names that merely start alike",
	)
	assert_eq(
		McpTransportCapability.mount_for_path(private, "/var/home/dev/.codex/config.toml").get("root"),
		"/newroot",
		"an ungranted path lies on the sandbox's own root",
	)
	## Optional fields sit between the options and the "-" separator.
	var granted := McpTransportCapability.mount_for_path(private, "/var/home/dev/.cursor/mcp.json")
	assert_eq(granted.get("mount_point"), "/var/home/dev/.cursor")
	assert_eq(granted.get("fstype"), "overlay")
	var spaced := McpTransportCapability.mount_for_path(private, "/var/home/dev/My Docs/mcp.json")
	assert_eq(spaced.get("mount_point"), "/var/home/dev/My Docs", "mountinfo escapes a space as \\040")
	assert_true(spaced.get("read_only"))
	assert_eq(McpTransportCapability.mount_for_path([] as Array[Dictionary], "/var/home/dev"), {})
	## The type follows the separator, and the mount source comes after it.
	var disk := McpTransportCapability.parse_mountinfo(
		"214 102 8:3 / /var/home rw,relatime shared:1 - ext4 /dev/sda3 rw\n"
	)
	assert_eq(disk.size(), 1)
	assert_eq(disk[0].get("fstype"), "ext4")
	assert_eq(disk[0].get("root"), "/")
	## A later mount on the same mount point lies on top of the earlier one.
	var stacked := McpTransportCapability.parse_mountinfo(
		"214 102 0:62 /var/home/dev/.cursor /var/home/dev/.cursor rw - overlay overlay rw\n"
		+ "215 214 0:70 / /var/home/dev/.cursor rw - tmpfs tmpfs rw\n"
	)
	assert_eq(
		McpTransportCapability.mount_for_path(stacked, "/var/home/dev/.cursor/mcp.json").get("fstype"),
		"tmpfs",
	)
	assert_eq(
		McpTransportCapability.parse_mountinfo("not a mount line\n102 85 0:66 / /\n\n"),
		[] as Array[Dictionary],
		"a line that does not parse is left out",
	)


func test_flatpak_mounts_block_a_write_the_grants_allow() -> void:
	## What `/.flatpak-info` cannot say: a denial under a wider grant, and a
	## granted directory Flatpak skipped because it did not exist at launch.
	const HOME := "/var/home/dev"
	var shared := McpTransportCapability.parse_mountinfo(_MOUNTS_HOME_SHARED)
	var private := McpTransportCapability.parse_mountinfo(_MOUNTS_HOME_PRIVATE)
	var cases := [
		[shared, HOME + "/.codex/config.toml", false, "the home is the host's"],
		[shared, HOME + "/.cursor/mcp.json", true, "--nofilesystem=~/.cursor hides it behind a tmpfs"],
		[shared, HOME + "/.var/app/dev.zed.Zed/config/zed/settings.json", true, "another app's directory"],
		[
			shared, HOME + "/.var/app/org.godotengine.Godot/config/godot-ai/x.json", false,
			"the app's own directory is mounted from the host",
		],
		[private, HOME + "/.cursor/mcp.json", false, "granted and mounted"],
		[private, HOME + "/.config/Code/User/mcp.json", false, "granted and mounted"],
		[private, HOME + "/.config/Trae/User/mcp.json", true, "granted, absent at launch, so not mounted"],
		[private, HOME + "/.codex/config.toml", true, "on the sandbox's own root"],
		[private, HOME + "/My Docs/mcp.json", true, "mounted read-only"],
	]
	for case in cases:
		assert_eq(
			not McpTransportCapability.flatpak_blocking_mount(case[0], case[1], HOME).is_empty(),
			case[2],
			"%s: %s" % [case[1], case[3]],
		)
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount(shared, HOME + "/.cursor/mcp.json", HOME)
			.get("mount_point"),
		HOME + "/.cursor",
		"the blocking mount is what the refusal names",
	)
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount([] as Array[Dictionary], HOME + "/.codex", HOME),
		{},
		"an unreadable mount list leaves the grant's answer standing",
	)
	## A home that is itself a tmpfs on the host (a live system, a kiosk) is
	## mounted whole at or above the home directory. That is not Flatpak hiding
	## anything, and refusing there would break a setup that works.
	var tmpfs_home := McpTransportCapability.parse_mountinfo(
		"102 85 0:66 /newroot / rw - tmpfs tmpfs rw\n"
		+ "214 102 0:40 / /home rw,nosuid,nodev - tmpfs tmpfs rw,size=8g\n"
	)
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount(tmpfs_home, "/home/dev/.cursor/mcp.json", "/home/dev"),
		{},
	)
	var tmpfs_user := McpTransportCapability.parse_mountinfo(
		"102 85 0:66 /newroot / rw - tmpfs tmpfs rw\n"
		+ "214 102 0:40 / /home/dev rw,nosuid,nodev - tmpfs tmpfs rw,size=8g\n"
	)
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount(tmpfs_user, "/home/dev/.cursor/mcp.json", "/home/dev"),
		{},
	)
	## A directory granted on such a host is bound from inside that tmpfs: its
	## root is the directory's own path there, not the whole filesystem.
	var tmpfs_grant := McpTransportCapability.parse_mountinfo(
		"102 85 0:66 /newroot / rw - tmpfs tmpfs rw\n"
		+ "208 102 0:40 /dev/.cursor /home/dev/.cursor rw,nosuid,nodev - tmpfs tmpfs rw,size=8g\n"
	)
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount(tmpfs_grant, "/home/dev/.cursor/mcp.json", "/home/dev"),
		{},
	)
	## A disk of the host's own, mounted whole inside the home, hides nothing.
	var nested_disk := McpTransportCapability.parse_mountinfo(
		"102 85 0:66 /newroot / rw - tmpfs tmpfs rw\n"
		+ "214 102 0:62 /var/home /var/home rw - overlay overlay rw\n"
		+ "220 214 8:17 / /var/home/dev/data rw,relatime - ext4 /dev/sdb1 rw\n"
	)
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount(
			nested_disk, "/var/home/dev/data/client/mcp.json", "/var/home/dev"
		),
		{},
	)
	## Outside the home the granted directory is the boundary.
	var outside := McpTransportCapability.parse_mountinfo(
		"102 85 0:66 /newroot / rw - tmpfs tmpfs rw\n"
		+ "214 102 0:62 /opt /opt rw - ext4 /dev/sda1 rw\n"
		+ "215 214 0:70 / /opt/codex/secret rw - tmpfs tmpfs rw\n"
	)
	assert_eq(McpTransportCapability.flatpak_blocking_mount(outside, "/opt/codex/config.toml", "/opt"), {})
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount(outside, "/opt/codex/secret/config.toml", "/opt")
			.get("mount_point"),
		"/opt/codex/secret",
	)
	assert_eq(
		McpTransportCapability.flatpak_blocking_mount(outside, "/srv/codex/config.toml", "/srv")
			.get("mount_point"),
		"/",
	)


func test_real_path_resolves_links_in_the_existing_part_of_a_path() -> void:
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var scratch := McpTransportCapability.real_path(_scratch_dir)
	var real_dir := scratch.path_join("real_path_target")
	var link := scratch.path_join("real_path_link")
	DirAccess.make_dir_recursive_absolute(real_dir.path_join("nested"))
	DirAccess.remove_absolute(link)
	var rc := OS.execute("ln", ["-s", "real_path_target", link])
	var directory := DirAccess.open(scratch)
	if rc != 0 or directory == null or not directory.is_link(link):
		skip("could not create a symlink on this platform")
		return
	var existing := McpTransportCapability.real_path(link.path_join("nested"))
	var missing := McpTransportCapability.real_path(link.path_join("not/there/yet.json"))
	var plain := McpTransportCapability.real_path(real_dir.path_join("nested"))
	DirAccess.remove_absolute(link)
	DirAccess.remove_absolute(real_dir.path_join("nested"))
	DirAccess.remove_absolute(real_dir)

	assert_eq(existing, real_dir.path_join("nested"), "a relative link target resolves beside the link")
	assert_eq(missing, real_dir.path_join("not/there/yet.json"),
		"components that do not exist yet are kept as written")
	assert_eq(plain, real_dir.path_join("nested"))
	assert_eq(McpTransportCapability.real_path("/"), "/")


func test_real_path_returns_a_link_loop_as_written() -> void:
	if OS.get_name() == "Windows":
		skip("creating POSIX symlinks is not portable on Windows")
		return
	var scratch := McpTransportCapability.real_path(_scratch_dir)
	var first := scratch.path_join("real_path_loop_a")
	var second := scratch.path_join("real_path_loop_b")
	DirAccess.remove_absolute(first)
	DirAccess.remove_absolute(second)
	if (
		OS.execute("ln", ["-s", "real_path_loop_b", first]) != 0
		or OS.execute("ln", ["-s", "real_path_loop_a", second]) != 0
	):
		skip("could not create a symlink on this platform")
	else:
		assert_eq(
			McpTransportCapability.real_path(first.path_join("mcp.json")),
			first.path_join("mcp.json"),
			"a chain past the hop bound resolves nothing",
		)
	DirAccess.remove_absolute(first)
	DirAccess.remove_absolute(second)


## The directory a read-write grant shares with the host and that holds
## `path`: "" when no grant covers it or the one that does is read-only.
func _shared_root(
	flatpak_info: String, path: String, home: String, host_config_home: String
) -> String:
	var grant := McpTransportCapability.flatpak_grant_over(flatpak_info, path, home, host_config_home)
	return str(grant["root"]) if grant.get("writable", false) else ""


func _flatpak_info(filesystems: String) -> String:
	return (
		"[Application]\nname=org.godotengine.Godot\n\n"
		+ "[Context]\nshared=network;ipc;\ndevices=all;\nfilesystems=%s\n\n"
		+ "[Instance]\nflatpak-version=1.16.6\n"
	) % filesystems


func _restore_environment(variable: String, value: String) -> void:
	if value.is_empty():
		OS.unset_environment(variable)
	else:
		OS.set_environment(variable, value)


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
