@tool
extends RefCounted

## One policy for every production uvx launch. Package identity JSON is a
## compatibility check, not authentication: production code is resolved only
## from the canonical PyPI index, with config files and installed tool envs
## disabled. The explicit process-local qualification switch is the sole path
## that leaves index selection to the qualification environment.

const PathTemplate := preload("res://addons/godot_ai/clients/_path_template.gd")
const PUBLIC_INDEX := "https://pypi.org/simple"
const PUBLIC_FLAT_INDEX := "https://pypi.org/simple/godot-ai/"
const QUALIFICATION_INDEX_ENV := "GODOT_AI_QUALIFICATION_PYTHON_INDEX"
## Oldest uv that accepts `--exclude-newer-package <name>=false` (#1242). uv
## 0.9.24 and earlier reject the value during argument parsing, before any
## resolution, so every production launch exits with code 2 on them.
const MIN_UV_VERSION := "0.9.25"
const _BASE_ARGS := [
	"--isolated",
	"--no-config",
	"--no-env-file",
	"--no-sources",
	"--no-build",
	"--index-strategy", "first-index",
	"--keyring-provider", "disabled",
]

## Known uv inputs capable of changing package source, candidate selection,
## interpreter, or cache. Production processes spawned by Godot temporarily
## clear them under the global process-spawn mutex; command-line policy remains
## pinned as a second boundary and for client-owned attach launches.
const _RESOLUTION_ENVIRONMENT := [
	"UV_INDEX", "UV_DEFAULT_INDEX", "UV_INDEX_URL", "UV_EXTRA_INDEX_URL",
	"UV_FIND_LINKS", "UV_INDEX_STRATEGY", "UV_KEYRING_PROVIDER",
	"UV_CONFIG_FILE", "UV_CONSTRAINT", "UV_BUILD_CONSTRAINT", "UV_OVERRIDE",
	"UV_NO_CONFIG", "UV_NO_SOURCES", "UV_NO_BUILD", "UV_NO_BINARY",
	"UV_NO_BINARY_PACKAGE", "UV_NO_VERIFY_HASHES", "UV_PRERELEASE",
	"UV_RESOLUTION", "UV_FORK_STRATEGY", "UV_EXCLUDE_NEWER",
	"UV_EXCLUDE_NEWER_PACKAGE", "UV_INSECURE_HOST", "UV_SYSTEM_CERTS",
	"UV_NATIVE_TLS", "UV_PYTHON", "UV_PYTHON_DOWNLOADS", "UV_PROJECT",
	"UV_WORKING_DIR", "UV_ENV_FILE", "UV_CACHE_DIR", "UV_TOOL_DIR",
	"UV_TOOL_BIN_DIR", "UV_LINK_MODE", "UV_REFRESH", "UV_REFRESH_PACKAGE",
	"UV_REINSTALL", "UV_REINSTALL_PACKAGE",
]


static func warm_environment() -> void:
	PathTemplate.warm_env_snapshot(PackedStringArray([QUALIFICATION_INDEX_ENV]))


static func qualification_authorized() -> bool:
	return PathTemplate.env_lookup(QUALIFICATION_INDEX_ENV) == "1"


static func args() -> Array[String]:
	var result: Array[String] = []
	result.assign(_BASE_ARGS)
	result.append_array([
		"--exclude-newer", dependency_cutoff(),
		"--exclude-newer-package", "godot-ai=false",
		## Without an explicit request uv picks its default interpreter, which
		## can be newer than this release supports. With --no-build, a
		## dependency that has no wheel for that interpreter fails resolution
		## outright instead of uv falling back to a compatible Python (#1244).
		"--python", python_request(),
	])
	if not qualification_authorized():
		result.append_array([
			"--index", PUBLIC_INDEX,
			"--default-index", PUBLIC_INDEX,
			"--find-links", PUBLIC_FLAT_INDEX,
		])
	return result


static func dependency_cutoff() -> String:
	var config := ConfigFile.new()
	if config.load("res://addons/godot_ai/plugin.cfg") == OK:
		var value := validated_cutoff(config.get_value("plugin", "dependency_cutoff", ""))
		if not value.is_empty():
			return value
	push_error("Godot AI plugin.cfg has no valid dependency_cutoff. Reinstall the plugin.")
	# uv rejects this value rather than silently resolving without the release bound.
	return "INVALID-DEPENDENCY-CUTOFF"


## The interpreter range this release supports, mirrored from pyproject's
## `requires-python` (tests/unit/test_dependency_cutoff.py locks the parity).
## Kept in plugin.cfg beside the cutoff so a retained backup proves whether the
## previous release passed --python at all.
static func python_request() -> String:
	var config := ConfigFile.new()
	if config.load("res://addons/godot_ai/plugin.cfg") == OK:
		var value := validated_python_request(config.get_value("plugin", "python_request", ""))
		if not value.is_empty():
			return value
	push_error("Godot AI plugin.cfg has no valid python_request. Reinstall the plugin.")
	# uv rejects this value rather than silently picking an unsupported interpreter.
	return "INVALID-PYTHON-REQUEST"


static func validated_python_request(value: Variant) -> String:
	if not value is String:
		return ""
	var expression := RegEx.new()
	expression.compile("^>=3\\.[0-9]{1,2},<3\\.[0-9]{1,2}$")
	return value if expression.search(value) != null else ""


## Parse the first line of `uv --version` / `uvx --version` ("uv 0.9.7",
## "uvx 0.11.32 (abc 2026-01-01)"). Empty when the text is not recognizable.
static func parse_uv_version(text: String) -> String:
	var expression := RegEx.new()
	expression.compile("^uvx?\\s+([0-9]+\\.[0-9]+\\.[0-9]+)")
	var found := expression.search(text.strip_edges())
	return found.get_string(1) if found != null else ""


## True only when the version is recognizable and older than MIN_UV_VERSION.
## An unparseable string is not evidence of an old uv, so it never blocks.
static func uv_version_too_old(text: String) -> bool:
	var version := parse_uv_version(text)
	if version.is_empty():
		return false
	var have := version.split(".")
	var need := MIN_UV_VERSION.split(".")
	for i in range(3):
		if int(have[i]) != int(need[i]):
			return int(have[i]) < int(need[i])
	return false


static func validated_cutoff(value: Variant) -> String:
	if not value is String or value.length() != 20:
		return ""
	var expression := RegEx.new()
	expression.compile("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
	if expression.search(value) == null or value.begins_with("0000-"):
		return ""
	var unix := Time.get_unix_time_from_datetime_string(value)
	if Time.get_datetime_string_from_unix_time(unix) + "Z" != value:
		return ""
	return value


## Read only the updater's retained previous tree. Missing metadata is not
## permission to strip policy flags from an arbitrary client entry.
static func previous_policy(outcome: Dictionary) -> Dictionary:
	var version: Variant = outcome.get("from_version", "")
	if not version is String:
		return {}
	if str(outcome.get("outcome", "")) != "success" or version.is_empty() or version.validate_filename() != version or version in [".", ".."]:
		return {}
	var expected: String = "res://addons/.godot_ai_update/backup/" + version
	if str(outcome.get("backup_root", "")) != expected:
		return {}
	var config := ConfigFile.new()
	if config.load(expected.path_join("plugin.cfg")) != OK:
		return {}
	return previous_policy_from_config(config, version)


static func previous_policy_from_config(config: ConfigFile, expected_version: String) -> Dictionary:
	var stored_version: Variant = config.get_value("plugin", "version", null)
	if not stored_version is String or expected_version.is_empty() or stored_version != expected_version:
		return {}
	## Releases before 4.4.2 carry no python_request and launched without
	## --python; a present but invalid value is never legacy absence.
	var python := ""
	if config.has_section_key("plugin", "python_request"):
		python = validated_python_request(config.get_value("plugin", "python_request"))
		if python.is_empty():
			return {}
	if not config.has_section_key("plugin", "dependency_cutoff"):
		return {"known": true, "cutoff": "", "python": python}
	var cutoff := validated_cutoff(config.get_value("plugin", "dependency_cutoff"))
	return {"known": true, "cutoff": cutoff, "python": python} if not cutoff.is_empty() else {}


## This is an expected-value builder for readback only. Actual process launches
## always use args() and the current release cutoff.
static func previous_launch_for_verification(launch: Dictionary, policy: Dictionary) -> Dictionary:
	if policy.is_empty() or launch.get("tier", "") != "uvx":
		return launch
	if not policy.get("known") is bool or not policy.known or not policy.get("cutoff") is String:
		return {}
	var cutoff: String = policy.cutoff
	if not cutoff.is_empty() and validated_cutoff(cutoff).is_empty():
		return {}
	if not policy.get("python") is String:
		return {}
	var python: String = policy.python
	if not python.is_empty() and validated_python_request(python).is_empty():
		return {}
	var previous := launch.duplicate(true)
	for field in ["args", "console_args"]:
		if not previous.has(field):
			continue
		if not previous[field] is Array:
			return {}
		var arguments: Array = previous[field].duplicate()
		for option in ["--exclude-newer", "--exclude-newer-package"]:
			var index := arguments.find(option)
			if index < 0 or index + 1 >= arguments.size() or arguments.count(option) != 1:
				return {}
			if cutoff.is_empty():
				arguments.remove_at(index + 1)
				arguments.remove_at(index)
			elif option == "--exclude-newer":
				arguments[index + 1] = cutoff
		var python_index := arguments.find("--python")
		if python_index < 0 or python_index + 1 >= arguments.size() or arguments.count("--python") != 1:
			return {}
		if python.is_empty():
			arguments.remove_at(python_index + 1)
			arguments.remove_at(python_index)
		else:
			arguments[python_index + 1] = python
		previous[field] = arguments
	return previous


static func is_production_command(command: Array) -> bool:
	if command.is_empty() or not str(command[0]).get_file().begins_with("uvx"):
		return false
	return (
		_option_equals(command, "--index", PUBLIC_INDEX)
		and _option_equals(command, "--default-index", PUBLIC_INDEX)
		and _option_equals(command, "--find-links", PUBLIC_FLAT_INDEX)
	)


## Call only while the process-spawn mutex is held. Qualification commands do
## not reach this function: their explicitly authorized UV_INDEX and credentials
## must remain process-local and are never rendered into persisted argv.
static func isolate_environment() -> Dictionary:
	var previous := {}
	for key in _RESOLUTION_ENVIRONMENT:
		previous[key] = {
			"present": OS.has_environment(key),
			"value": OS.get_environment(key),
		}
		OS.unset_environment(key)
	return previous


static func restore_environment(previous: Dictionary) -> void:
	for key in previous:
		if bool(previous[key].present):
			OS.set_environment(key, str(previous[key].value))
		else:
			OS.unset_environment(key)


static func _option_equals(command: Array, option: String, expected: String) -> bool:
	var index := command.find(option)
	return index >= 0 and index + 1 < command.size() and str(command[index + 1]) == expected
