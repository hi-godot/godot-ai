@tool
extends RefCounted

## Configure alone grants ownership. Grant and verify mutation authority only under MutationLock.
const MutationLock := preload("res://addons/godot_ai/utils/client_mutation_lock.gd")
const MAX_RECORD_BYTES := 65536
const TOML_MAX_BYTES := 1024 * 1024
const TOML_TIMEOUT_MS := 3000
const TOML_VALIDATOR := """import sys
if sys.version_info < (3, 11):
    print('unavailable')
    raise SystemExit(0)
try:
    import tomllib
    with open(sys.argv[1], 'rb') as source:
        content = source.read(%d)
    if len(content) > %d:
        raise ValueError('size')
    tomllib.loads(content.decode('utf-8'))
except Exception:
    print('invalid')
else:
    print('valid')
"""


static func target(client: McpClient, server_name: String, roots: PackedStringArray, external_cwd: String = "") -> Dictionary:
	if not client.automatic_config_edits or client.command_shape == McpClient.CommandShape.NONE:
		return {}
	## Non-user CLI scopes and layered YAML cannot be proved from a single file.
	## They retain explicit Configure until their effective-entry contract exists.
	if client.config_type not in ["json", "toml"]:
		if client.config_type != "cli" or not client.has_json_fallback() or McpSettings.client_scope() != McpSettings.DEFAULT_CLIENT_SCOPE:
			return {}
	var resolution := client.resolved_config_path_details()
	if not str(resolution.get("error", "")).is_empty():
		return {}
	var path := str(resolution.get("path", ""))
	if client.config_type == "cli":
		var config := McpJsonStrategy._read_file_text(path, true)
		if not bool(config.get("ok", false)):
			return {}
		var data: Dictionary = config.get("data", {})
		var projects: Variant = data.get("projects", {})
		if not projects is Dictionary or not projects.is_empty() or data.has("disabledMcpServers") or data.has("enabledMcpServers"):
			return {}
	if client.config_type == "json" and McpJsonStrategy._uses_merge_tiers(client):
		if not client.config_merge_project_paths.is_empty():
			var external := external_cwd.strip_edges().simplify_path()
			if external.is_empty() or not external.is_absolute_path() or not DirAccess.dir_exists_absolute(external) or not roots.has(external):
				return {}
		if not McpJsonStrategy._scope_ambiguity_error(client).is_empty():
			return {}
		var project := McpJsonStrategy._load_project_definitions(client, server_name, roots, true)
		if not bool(project.get("ok", false)) or not project.get("tiers", []).is_empty():
			return {}
		path = McpJsonStrategy.authoritative_tier_path(client, server_name, roots)
	if path.is_empty():
		return {}
	return {"client_id": client.id, "path": path.simplify_path(), "scope": "user", "server_name": server_name}


static func record_path(target_value: Dictionary) -> String:
	var identity := JSON.stringify([
		target_value.get("client_id"), target_value.get("path"),
		target_value.get("scope"), target_value.get("server_name"),
	])
	return MutationLock.lock_path().get_base_dir().path_join("client-repair-" + identity.sha256_text() + ".json")


static func read(target_value: Dictionary) -> Dictionary:
	if target_value.is_empty():
		return {}
	var path := record_path(target_value)
	if MutationLock._is_link(path):
		return {}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	if file.get_length() > MAX_RECORD_BYTES:
		file.close()
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary or parsed.get("schema") != 1 or parsed.get("target") != target_value:
		return {}
	if not parsed.get("launch") is Dictionary or not parsed.get("project") is String:
		return {}
	return parsed


static func record(target_value: Dictionary, project: String, launch: Dictionary) -> bool:
	if target_value.is_empty() or project.is_empty() or not bool(launch.get("ok", false)):
		return false
	var path := record_path(target_value)
	if MutationLock._is_link(path):
		return false
	var body := JSON.stringify({"schema": 1, "target": target_value, "project": project, "launch": launch})
	if body.to_utf8_buffer().size() > MAX_RECORD_BYTES:
		return false
	return McpAtomicWrite.write(path, body) and not read(target_value).is_empty()


static func enabled(client: McpClient, target_value: Dictionary) -> bool:
	var path := str(target_value.get("path", ""))
	if not FileAccess.file_exists(path):
		return false
	if client.config_type in ["json", "cli"]:
		var read_result := McpJsonStrategy._read_file_text(path, true)
		if not bool(read_result.get("ok", false)):
			return false
		var data: Dictionary = read_result.get("data", {})
		var holder: Variant = McpJsonStrategy._walk_path(data, McpJsonStrategy.select_server_key_path(data, client))
		if not holder is Dictionary:
			return false
		var entry: Variant = holder.get(str(target_value.server_name))
		if not entry is Dictionary:
			return false
		return _is_false(entry.get("disabled", false)) and _is_true(entry.get("enabled", true)) and (client.config_enabled_key.is_empty() or _is_true(entry.get(client.config_enabled_key, true)))
	var read_result := McpTomlStrategy._read_or_init(path)
	if not bool(read_result.get("ok", false)):
		return false
	var lines := McpTomlStrategy._split_lines(str(read_result.data))
	var section := McpTomlStrategy._find_section(lines, McpTomlStrategy._all_headers(client))
	if section.is_empty():
		return false
	for item in McpTomlStrategy._value_items(lines, int(section.start) + 1, int(section.end)):
		var key := str(item.get("key", ""))
		if key in ["enabled", "disabled"]:
			var value := McpTomlStrategy._item_value(item).strip_edges()
			if (key == "enabled" and value != "true") or (key == "disabled" and value != "false"):
				return false
	return true


static func _is_false(value: Variant) -> bool:
	return (value is bool and not value) or (value is String and value.to_lower() in ["false", "0"])


static func _is_true(value: Variant) -> bool:
	return (value is bool and value) or (value is String and value.to_lower() in ["true", "1"])


## Fixed code, isolated CPython and a single path argument; never imports client config.
static func validate_toml(
	path: String, cancelled: Callable = Callable(),
	find_python: Callable = Callable(), run_python: Callable = Callable(),
) -> Dictionary:
	var seen := {}
	for executable in ["python3", "python"]:
		if cancelled.is_valid() and cancelled.call():
			return {"status": "cancelled", "message": "Automatic repair cancelled before TOML validation."}
		var python: String = find_python.call(executable) if find_python.is_valid() else McpCliFinder.find([executable])
		if python.is_empty() or seen.has(python):
			continue
		if cancelled.is_valid() and cancelled.call():
			return {"status": "cancelled", "message": "Automatic repair cancelled before TOML validation."}
		seen[python] = true
		var args := ["-I", "-S", "-c", TOML_VALIDATOR % [TOML_MAX_BYTES + 1, TOML_MAX_BYTES], path]
		var result: Dictionary = (
			run_python.call(python, args, TOML_TIMEOUT_MS, cancelled)
			if run_python.is_valid()
			else McpCliExec.run(python, args, TOML_TIMEOUT_MS, true, cancelled)
		)
		if bool(result.get("termination_failed", false)):
			return {"status": "error", "termination_failed": true, "message": MutationLock.recovery_message()}
		if bool(result.get("cancelled", false)):
			return {"status": "cancelled", "message": "Automatic repair cancelled during TOML validation."}
		var output := str(result.get("stdout", "")).strip_edges()
		if result.get("exit_code") == 0 and output == "valid":
			return {}
		if result.get("exit_code") == 0 and output == "invalid":
			return {"status": "skipped", "message": "Automatic repair refused invalid or oversized TOML (maximum 1 MiB); review it and use Configure."}
	return {"status": "skipped", "message": "Automatic repair needs an available Python 3.11+ TOML parser; use Configure."}
