@tool
class_name McpCliStrategy
extends RefCounted

## Strategy for MCP clients that own their own state via a CLI (e.g.
## `claude mcp add`). Reads `cli_register_template` / `cli_unregister_template`
## / `cli_status_args` from the descriptor and substitutes `{name}` / `{url}`
## tokens. Command-shape descriptors additionally use the whole-element launch
## tokens `{command}` / `{args...}` (see `format_args`). No descriptor-supplied
## Callables — see `_base.gd` for why.
##
## Every shell-out goes through `McpCliExec.run`, which wraps the call in a
## wall-clock timeout. A hung CLI (e.g. `claude mcp list` under
## inter-Claude-Code contention) gets killed at the budget instead of
## locking up the caller forever — see issues #238 / #239.

## The descriptor token resolved from `godot_ai/mcp_client_scope` (#872).
## Only Claude Code takes it today; any `config_type = "cli"` descriptor can.
const SCOPE_TOKEN := "{scope}"

const _CONFIGURE_TIMEOUT_MS := 10000
const _REMOVE_TIMEOUT_MS := 10000
const _STATUS_TIMEOUT_MS := 6000


static func configure(
	client: McpClient,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
) -> Dictionary:
	## Fail closed before any subprocess runs: a command-shape client without a
	## verified attach launcher must not register anything (see
	## docs/client-configuration.md — an ERROR beats an entry known to be broken).
	var launch_error := command_launch_error(client, launch)
	if not launch_error.is_empty():
		return {"status": "error", "message": launch_error}
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s not found" % client.display_name}

	# Best-effort prior cleanup so re-configure is idempotent. Bounded to
	# the same budget — a hung unregister shouldn't block the configure
	# that follows.
	if not client.cli_unregister_template.is_empty():
		## #872: a `{scope}` descriptor sweeps EVERY scope, not just the
		## selected one. Flipping the setting user -> project and pressing
		## Configure would otherwise leave the old user-scope entry alive —
		## exactly the "loaded in every unrelated workspace" problem the
		## setting exists to fix. `mcp remove` on an absent entry is a no-op
		## and the result is discarded either way, so the extra passes are
		## safe; they cost one bounded subprocess per additional scope.
		for pre_scope in _cleanup_scopes(client):
			var pre_args := _format_args(
				client.cli_unregister_template, server_name, server_url, {}, pre_scope
			)
			McpCliExec.run(cli, pre_args, _REMOVE_TIMEOUT_MS)

	if client.cli_register_template.is_empty():
		return {"status": "error", "message": "%s descriptor missing cli_register_template" % client.display_name}
	var args := _format_args(client.cli_register_template, server_name, server_url, launch)
	var result := McpCliExec.run(cli, args, _CONFIGURE_TIMEOUT_MS)
	if result.get("timed_out", false):
		return {
			"status": "error",
			"message": "Configure %s timed out after %ds — see 'Run this manually' below to retry by hand" % [
				client.display_name, _CONFIGURE_TIMEOUT_MS / 1000,
			],
		}
	if result.get("spawn_failed", false):
		return {"status": "error", "message": "Failed to spawn %s" % client.display_name}
	if int(result.get("exit_code", -1)) == 0:
		return {"status": "ok", "message": McpClient.configured_message(client, server_url)}
	## `claude mcp add` writes its real failure diagnostics to stderr, so
	## prefer `output` (stdout + stderr) over `stdout` alone — otherwise
	## the user sees "exit code 1" instead of the actual error.
	var combined := str(result.get("output", "")).strip_edges()
	var err := combined if not combined.is_empty() else "exit code %d" % int(result.get("exit_code", -1))
	return {"status": "error", "message": "Failed to configure %s: %s" % [client.display_name, err]}


## Run the descriptor's `cli_status_args`, scan stdout for `server_name` and
## the expected target. The matching rule is the only sensible one for "list
## MCP entries" output across CLI clients we currently support: name AND
## target present → CONFIGURED; name only → MISMATCH; neither →
## NOT_CONFIGURED. For URL descriptors the target is `server_url`; for
## command-shape descriptors it is the resolved attach launcher path (the
## listing prints the registered command line, not a URL). Command-shape CLI
## clients with a JSON fallback file get exact drift detection via the JSON
## strategy instead — the configurator prefers that path and only lands here
## for CLI clients whose state isn't file-readable.
static func check_status(
	client: McpClient, server_name: String, server_url: String, launch: Dictionary = {}
) -> McpClient.Status:
	return check_status_with_cli_path(client, server_name, server_url, _resolve_cli(client), launch)


static func check_status_with_cli_path(
	client: McpClient, server_name: String, server_url: String, cli: String, launch: Dictionary = {}
) -> McpClient.Status:
	return check_status_details(client, server_name, server_url, cli, launch).get("status", McpClient.Status.NOT_CONFIGURED)


## Detailed variant used by the dock's refresh worker so it can surface a
## "probe timed out" badge on the affected row instead of silently
## conflating the timeout with NOT_CONFIGURED. Returns
## `{"status": Status, "error_msg": String}`. The caller plumbs
## `error_msg` straight into `_apply_row_status`.
static func check_status_details(
	client: McpClient, server_name: String, server_url: String, cli: String, launch: Dictionary = {}
) -> Dictionary:
	if cli.is_empty():
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	if client.cli_status_args.is_empty():
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	var expected_target := server_url
	if client.command_shape != McpClient.CommandShape.NONE:
		## Same fail-closed contract as configure: without a verified launcher
		## there is no target to compare against, and guessing would report a
		## broken entry as green.
		var launch_error := command_launch_error(client, launch)
		if not launch_error.is_empty():
			return _status_details(McpClient.Status.ERROR, launch_error)
		expected_target = str(launch.get("command", ""))
	var result := McpCliExec.run(
		cli,
		McpClient._array_from_packed(client.cli_status_args),
		_STATUS_TIMEOUT_MS,
		false
	)
	if result.get("timed_out", false):
		return _status_details(McpClient.Status.ERROR, "probe timed out")
	if result.get("spawn_failed", false):
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	if int(result.get("exit_code", -1)) != 0:
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	var text := str(result.get("stdout", ""))
	if text.find(server_name) < 0:
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	## Server registered, but pointing somewhere else — drift after a
	## port change. Surface as mismatch so the dock offers Reconfigure.
	if text.find(expected_target) < 0:
		return _status_details(McpClient.Status.CONFIGURED_MISMATCH)
	return _status_details(McpClient.Status.CONFIGURED)


## Empty string when this client's launch requirements are satisfied. A
## command-shape descriptor requires a successfully resolved attach launch;
## URL descriptors (`CommandShape.NONE`) never require one. Mirrors
## `McpJsonStrategy.command_launch_error` / the TOML equivalent.
static func command_launch_error(client: McpClient, launch: Dictionary) -> String:
	if client.command_shape == McpClient.CommandShape.NONE:
		return ""
	if not bool(launch.get("ok", false)):
		return str(launch.get("error", "No compatible attach launcher was found."))
	return ""


static func _status_details(status: McpClient.Status, error_msg: String = "") -> Dictionary:
	return {"status": status, "error_msg": error_msg}


static func remove(client: McpClient, server_name: String) -> Dictionary:
	var cli := _resolve_cli(client)
	if cli.is_empty():
		return {"status": "error", "message": "%s not found" % client.display_name}
	if client.cli_unregister_template.is_empty():
		return {"status": "error", "message": "%s descriptor missing cli_unregister_template" % client.display_name}
	var args := _format_args(client.cli_unregister_template, server_name, "")
	var result := McpCliExec.run(cli, args, _REMOVE_TIMEOUT_MS)
	if result.get("timed_out", false):
		return {
			"status": "error",
			"message": "Remove %s timed out after %ds — see 'Run this manually' below to retry by hand" % [
				client.display_name, _REMOVE_TIMEOUT_MS / 1000,
			],
		}
	if result.get("spawn_failed", false):
		return {"status": "error", "message": "Failed to spawn %s" % client.display_name}
	if int(result.get("exit_code", -1)) == 0:
		return {"status": "ok", "message": "%s configuration removed" % client.display_name}
	## `claude mcp add` writes its real failure diagnostics to stderr, so
	## prefer `output` (stdout + stderr) over `stdout` alone — otherwise
	## the user sees "exit code 1" instead of the actual error.
	var combined := str(result.get("output", "")).strip_edges()
	var err := combined if not combined.is_empty() else "exit code %d" % int(result.get("exit_code", -1))
	return {"status": "error", "message": "Failed to remove %s: %s" % [client.display_name, err]}


## Substitute `{name}` and `{url}` tokens in every template entry.
## Tokens match verbatim — `{name_suffix}` is NOT touched, so callers don't
## have to worry about partial-token collisions in their argv.
##
## Launch tokens are whole-element only: an element that is exactly
## `{command}` becomes the resolved attach launcher path, and an element that
## is exactly `{args...}` is spliced into the argv as one element per launch
## arg. Whole-element matching keeps a literal brace inside a path or flag
## from ever triggering an expansion.
##
## `scope_override` forces a specific `{scope}` value instead of the live
## setting; the configure pre-cleanup uses it to sweep the scopes the user is
## NOT currently on. Empty means "resolve from the setting".
static func format_args(
	template: PackedStringArray,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	scope_override: String = "",
) -> Array[String]:
	return _format_args(template, server_name, server_url, launch, scope_override)


static func _format_args(
	template: PackedStringArray,
	server_name: String,
	server_url: String,
	launch: Dictionary = {},
	scope_override: String = "",
) -> Array[String]:
	var scope := scope_override if not scope_override.is_empty() else McpSettings.client_scope()
	var out: Array[String] = []
	for arg in template:
		var s := String(arg)
		if s == "{command}":
			out.append(str(launch.get("command", "")))
			continue
		if s == "{args...}":
			for launch_arg in launch.get("args", []):
				out.append(str(launch_arg))
			continue
		s = s.replace("{name}", server_name)
		s = s.replace("{url}", server_url)
		## Resolved per-call rather than baked into the descriptor so the
		## setting can change without an editor restart, and so the manual
		## command shown in the dock always matches what Configure would run.
		s = s.replace(SCOPE_TOKEN, scope)
		out.append(s)
	return out


## Scope-aware status for descriptors that declare `cli_scope_status_template`.
## Returns the same `{"status", "error_msg"}` shape as check_status_details.
##
## Split from the subprocess call so the verdict is a pure function of what the
## CLI printed — `_scope_probe_verdict` is unit-tested against real recorded
## `claude mcp get` output rather than needing a `claude` binary on the runner.
static func check_scope_status_details(
	client: McpClient,
	server_name: String,
	server_url: String,
	cli: String,
	launch: Dictionary,
	expected_scope: String,
) -> Dictionary:
	if cli.is_empty() or client.cli_scope_status_template.is_empty():
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	var expected_target := server_url
	if client.command_shape != McpClient.CommandShape.NONE:
		## Same fail-closed contract as configure and the plain status probe.
		var launch_error := command_launch_error(client, launch)
		if not launch_error.is_empty():
			return _status_details(McpClient.Status.ERROR, launch_error)
		expected_target = str(launch.get("command", ""))
	var args := _format_args(client.cli_scope_status_template, server_name, server_url)
	var result := McpCliExec.run(cli, args, _STATUS_TIMEOUT_MS, false)
	if result.get("timed_out", false):
		return _status_details(McpClient.Status.ERROR, "probe timed out")
	if result.get("spawn_failed", false):
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	return _scope_probe_verdict(
		int(result.get("exit_code", -1)),
		str(result.get("stdout", "")),
		expected_scope,
		expected_target,
	)


## The `Scope:` label the probe printed, normalised to a CLIENT_SCOPES value,
## or "" when no line was recognisable. Matched on the first word after the
## label so the parenthetical blurb ("(shared via .mcp.json)") can change
## wording between CLI releases without breaking detection.
static func _scope_from_probe_output(text: String) -> String:
	for raw_line in text.split("\n"):
		var line := String(raw_line).strip_edges()
		var marker := line.find("Scope:")
		if marker < 0:
			continue
		var rest := line.substr(marker + 6).strip_edges().to_lower()
		for scope in McpSettings.CLIENT_SCOPES:
			var name := String(scope)
			if rest.begins_with(name):
				return name
	return ""


## Pure verdict for a scope probe. A non-zero exit is the CLI's "no such
## server" signal. An entry resolved from a scope other than the selected one
## is MISMATCH, not CONFIGURED: the dock offers Reconfigure, and Configure's
## all-scope pre-cleanup is what actually moves it. An unparseable Scope line
## degrades to the target check alone rather than reporting a false red.
static func _scope_probe_verdict(
	exit_code: int, text: String, expected_scope: String, expected_target: String
) -> Dictionary:
	if exit_code != 0:
		return _status_details(McpClient.Status.NOT_CONFIGURED)
	if not expected_target.is_empty() and text.find(expected_target) < 0:
		return _status_details(McpClient.Status.CONFIGURED_MISMATCH)
	var resolved := _scope_from_probe_output(text)
	if resolved.is_empty():
		return _status_details(McpClient.Status.CONFIGURED)
	if resolved != expected_scope:
		return _status_details(
			McpClient.Status.CONFIGURED_MISMATCH,
			"registered at %s scope, not %s" % [resolved, expected_scope],
		)
	return _status_details(McpClient.Status.CONFIGURED)


## True when the descriptor's register template takes `{scope}`, i.e. where
## its entry lands is decided by the `godot_ai/mcp_client_scope` setting rather
## than fixed by the descriptor. The configurator uses this to decide whether
## the JSON-fallback file is still a valid place to read status back from.
static func uses_scope_token(client: McpClient) -> bool:
	return client.cli_register_template.has(SCOPE_TOKEN)


## Scopes the configure pre-cleanup removes from. A descriptor without the
## `{scope}` token has exactly one place its entry can live, so it keeps the
## single pass it always had — "" means "resolve the scope normally".
static func _cleanup_scopes(client: McpClient) -> Array[String]:
	if not uses_scope_token(client):
		return [""]
	var scopes: Array[String] = []
	for scope in McpSettings.CLIENT_SCOPES:
		scopes.append(String(scope))
	return scopes


static func _resolve_cli(client: McpClient) -> String:
	return McpCliFinder.find(McpClient._array_from_packed(client.cli_names))


static func resolve_cli_path(client: McpClient) -> String:
	return _resolve_cli(client)
