@tool
class_name McpJsonStrategy
extends RefCounted

## Read–merge–write strategy for JSON-backed MCP clients.
## All knobs come from the McpClient descriptor as plain data — no Callables.
## See `_base.gd` for why descriptors are data-only.


static func configure(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty():
		return {"status": "error", "message": "Could not resolve config path for %s on this OS" % client.display_name}

	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to overwrite %s: %s. Fix or move the file, then re-run Configure." % [path, read["error"]]}
	var config: Dictionary = read["data"]
	var holder := _ensure_path(config, client.server_key_path)
	## Pass the existing entry through so `build_entry` can preserve user-mutable
	## state (auto-approval lists, `disabled` toggles) instead of resetting it
	## to descriptor defaults on every Configure click. See `entry_initial_fields`
	## docs in `_base.gd`.
	var existing: Variant = holder.get(server_name, null)
	holder[server_name] = build_entry(client, server_url, existing)

	if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
		return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configured (HTTP: %s)" % [client.display_name, server_url]}


static func check_status(client: McpClient, server_name: String, server_url: String) -> McpClient.Status:
	return check_status_details(client, server_name, server_url).get("status", McpClient.Status.NOT_CONFIGURED)


## Detailed variant feeding the dock's error_msg plumbing (#711): a config
## file that EXISTS but can't be read or parsed is Status.ERROR carrying the
## read/parse error, not NOT_CONFIGURED — the write path refuses to touch
## such a file (see `_read_or_init`), so the status dot must say "broken
## file", not "click Configure".
static func check_status_details(client: McpClient, server_name: String, server_url: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": McpClient.Status.ERROR, "error_msg": String(read["error"])}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, client.server_key_path)
	if not (holder is Dictionary) or not holder.has(server_name):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	var entry = holder[server_name]
	if not (entry is Dictionary):
		return {"status": McpClient.Status.NOT_CONFIGURED, "error_msg": ""}
	## An entry under `server_name` exists — if the URL doesn't match,
	## that's drift (the user changed the port and the client config is stale),
	## not "never configured". The dock surfaces that as an amber banner.
	if verify_entry(client, entry, server_url):
		return {"status": McpClient.Status.CONFIGURED, "error_msg": ""}
	return {"status": McpClient.Status.CONFIGURED_MISMATCH, "error_msg": ""}


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var path := client.resolved_config_path()
	if path.is_empty() or not FileAccess.file_exists(path):
		return {"status": "ok", "message": "Not configured"}
	var read := _read_or_init(path)
	if not read["ok"]:
		return {"status": "error", "message": "Refusing to rewrite %s: %s." % [path, read["error"]]}
	var config: Dictionary = read["data"]
	var holder := _walk_path(config, client.server_key_path)
	if holder is Dictionary and holder.has(server_name):
		holder.erase(server_name)
		if not McpAtomicWrite.write(path, JSON.stringify(_narrow_integral_numbers(config), "\t", false)):
			return {"status": "error", "message": "Cannot write to %s" % path}
	return {"status": "ok", "message": "%s configuration removed" % client.display_name}


## Synthesize the entry dict the strategy will write under
## `server_key_path[server_name]`. For non-bridge clients this is the
## existing entry (if any) with `entry_url_field` + every
## `entry_extra_fields` key force-set (the verified type pins) and every
## `entry_initial_fields` key set ONLY when absent (preserves user state
## like `alwaysAllow`/`autoApprove` arrays). For bridge clients (Claude
## Desktop) it composes the uvx + mcp-proxy command shape unconditionally
## — the bridge form has no user-mutable surface.
static func build_entry(client: McpClient, server_url: String, existing: Variant = null) -> Dictionary:
	match client.entry_uvx_bridge:
		McpClient.UvxBridge.FLAT:
			return {
				"command": McpClient.resolve_uvx_path(),
				"args": McpClient.mcp_proxy_bridge_args(server_url),
				"env": _merge_bridge_env(existing),
			}
	var entry: Dictionary = (existing as Dictionary).duplicate() if existing is Dictionary else {}
	entry[client.entry_url_field] = server_url
	for k in client.entry_extra_fields:
		entry[k] = client.entry_extra_fields[k]
	for k in client.entry_initial_fields:
		if not entry.has(k):
			entry[k] = client.entry_initial_fields[k]
	return entry


## Default verifier for a stored entry. For bridge clients, recognise the
## bridge form (and, for `flat`, the future url-style form too — keeps the
## tolerance Claude Desktop has had since the npx-bridge migration).
##
## For non-bridge clients: assert `entry[entry_url_field] == url` AND every
## key in `entry_extra_fields` matches verbatim. Type-pinning for Cline /
## Roo / Kilo (`type: "streamable-http"` etc.) falls out of this — pre-fix
## entries that lack the type field fail verification and surface as drift.
static func verify_entry(client: McpClient, entry: Dictionary, server_url: String) -> bool:
	match client.entry_uvx_bridge:
		McpClient.UvxBridge.FLAT:
			# Future url-style entry: accept if Claude Desktop ever speaks HTTP natively.
			if entry.get(client.entry_url_field, "") == server_url:
				return true
			var cmd = entry.get("command", "")
			if not (cmd is String and _command_is_uvx_like(cmd as String)):
				return false
			if not _bridge_args_are_valid(entry.get("args", []), server_url):
				return false
			return _bridge_env_matches(entry)
	if entry.get(client.entry_url_field, "") != server_url:
		return false
	for k in client.entry_extra_fields:
		if entry.get(k) != client.entry_extra_fields[k]:
			return false
	return true


## Pre-fix entries lack `env.UV_LINK_MODE=copy` and hit the Windows uvx
## hard-link race documented in `utils/uv_cache_cleanup.gd`. Flag them as
## drift so the dock surfaces an amber banner and a Configure-click
## rewrites the entry with the env pin. Every key in `bridge_env_for_uvx()`
## must match verbatim — extra user keys are tolerated so a hand-added
## `PYTHONUNBUFFERED=1` etc. doesn't trigger drift forever.
static func _bridge_env_matches(entry: Dictionary) -> bool:
	var env = entry.get("env", null)
	if not (env is Dictionary):
		return false
	var pin := McpClient.bridge_env_for_uvx()
	for k in pin:
		if env.get(k) != pin[k]:
			return false
	return true


## Configure rewrites the bridge entry wholesale (the bridge form is
## identity-defined by command+args+env), but the verifier tolerates extra
## user-added env keys like `HTTP_PROXY` / `PYTHONUNBUFFERED`. Without
## merging, a Configure click on a CONFIGURED_MISMATCH entry would silently
## drop those keys — so layer the UV_LINK_MODE pin over whatever env block
## already exists on disk. New entries with no prior env get just the pin.
static func _merge_bridge_env(existing: Variant) -> Dictionary:
	var pin := McpClient.bridge_env_for_uvx()
	if not (existing is Dictionary):
		return pin
	var existing_env = (existing as Dictionary).get("env", null)
	if not (existing_env is Dictionary):
		return pin
	var merged: Dictionary = (existing_env as Dictionary).duplicate()
	for k in pin:
		merged[k] = pin[k]
	return merged


## Basename match for `uvx` / `uvx.exe`, accepting both the bare-name
## fallback and an absolute path resolved by `McpCliFinder`. Used by the
## FLAT bridge verifier — the only place we ever inspect a stored bridge
## command/path.
static func _command_is_uvx_like(cmd: String) -> bool:
	var basename := cmd.get_file()
	return basename == "uvx" or basename == "uvx.exe"


## Strict bridge-argv check: the args array must include the pinned
## `mcp-proxy` package spec, the `--transport streamablehttp` selector, and
## the expected URL. Pre-fix `args.has(url)` was lenient — entries with the
## wrong transport (`--transport sse`) or a different package would still
## verify CONFIGURED, hiding the broken bridge. Match `mcp-proxy` by prefix
## so a future MCP_PROXY_VERSION bump doesn't churn the verifier.
static func _bridge_args_are_valid(args: Variant, server_url: String) -> bool:
	if not (args is Array):
		return false
	var has_mcp_proxy := false
	for a in args:
		if a is String and (a as String).begins_with("mcp-proxy"):
			has_mcp_proxy = true
			break
	if not has_mcp_proxy:
		return false
	if not (args.has("--transport") and args.has("streamablehttp") and args.has(server_url)):
		return false
	return true


## Returns {"ok": true, "data": Dictionary} when the file is absent or parses
## cleanly, and {"ok": false, "error": String} when the file exists with
## non-empty content we cannot safely round-trip. Callers must NOT fall back
## to an empty dict on the error path — doing so blows away the user's other
## MCP entries on the next write.
static func _read_or_init(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": true, "data": {}}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		var err := FileAccess.get_open_error()
		return {"ok": false, "error": "could not open for reading (error %d)" % err}
	var content := file.get_as_text()
	file.close()
	# Strip a UTF-8 BOM if present — some editors (notably on Windows) save
	# JSON with a leading ﻿, which Godot's JSON.parse rejects outright.
	# Previously this landed on the "unparseable → wipe" path.
	if content.begins_with("﻿"):
		content = content.substr(1)
	if content.strip_edges().is_empty():
		return {"ok": true, "data": {}}
	var json := JSON.new()
	if json.parse(content) != OK:
		var msg := "JSON parse error on line %d: %s" % [json.get_error_line(), json.get_error_message()]
		push_warning("MCP | %s in %s" % [msg, path])
		return {"ok": false, "error": msg}
	if not (json.data is Dictionary):
		return {"ok": false, "error": "top-level value is %s, expected object" % type_string(typeof(json.data))}
	return {"ok": true, "data": json.data}


## Walk a key path, creating intermediate Dicts as needed. Returns the leaf Dict.
static func _ensure_path(root: Dictionary, key_path: PackedStringArray) -> Dictionary:
	var cur := root
	for key in key_path:
		var next = cur.get(key)
		if not (next is Dictionary):
			next = {}
			cur[key] = next
		cur = next
	return cur


## Walk a key path, returning the leaf Dict if all hops exist; else null.
static func _walk_path(root: Dictionary, key_path: PackedStringArray) -> Variant:
	var cur: Variant = root
	for key in key_path:
		if not (cur is Dictionary) or not cur.has(key):
			return null
		cur = cur[key]
	return cur


## Godot's JSON.parse turns every JSON number into a float, so a later
## JSON.stringify re-emits the user's integer fields as "8080.0" — which strict
## consumers (Go's encoding/json into an int field, etc.) reject, and which
## needlessly rewrites every number across the user's *other* entries. Re-narrow
## exactly-representable integral floats back to int so they serialize without
## the ".0". Walks dicts/arrays in place and returns the (same) value.
##
## Integers above 2^53 already lost precision when Godot parsed them to double,
## so they're left as the float Godot produced rather than faking exactness —
## byte-perfect preservation would require not parsing the file at all, and such
## magnitudes don't occur in MCP client configs.
static func _narrow_integral_numbers(value: Variant) -> Variant:
	match typeof(value):
		TYPE_FLOAT:
			if is_finite(value) and value == floor(value) and absf(value) <= 9007199254740992.0:
				return int(value)
		TYPE_DICTIONARY:
			for k in value:
				value[k] = _narrow_integral_numbers(value[k])
		TYPE_ARRAY:
			for i in value.size():
				value[i] = _narrow_integral_numbers(value[i])
	return value
