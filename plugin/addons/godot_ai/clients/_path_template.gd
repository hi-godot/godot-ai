@tool
class_name McpPathTemplate
extends RefCounted

## Expands ~ / $HOME / $APPDATA / $XDG_CONFIG_HOME / $LOCALAPPDATA / $USERPROFILE
## inside path templates so per-client descriptors can declare paths declaratively
## without hand-rolling per-OS lookups.


## Pick the right entry from a {"darwin": ..., "windows": ..., "linux": ...} map.
static func resolve(template_map: Dictionary) -> String:
	var key := _os_key()
	if not template_map.has(key):
		# Allow "unix" as a shorthand for both macOS and Linux.
		if (key == "darwin" or key == "linux") and template_map.has("unix"):
			key = "unix"
		else:
			return ""
	var template: String = template_map[key]
	return expand(template)


## Substitute env vars and ~ in a single template string.
static func expand(template: String) -> String:
	if template.is_empty():
		return ""
	var out := template
	if out.begins_with("~/") or out == "~":
		var home := _home()
		out = home if out == "~" else home.path_join(out.substr(2))
	# $HOME, $APPDATA, $LOCALAPPDATA, $USERPROFILE, $XDG_CONFIG_HOME
	for var_name in ["XDG_CONFIG_HOME", "LOCALAPPDATA", "USERPROFILE", "APPDATA", "HOME"]:
		var token := "$%s" % var_name
		if out.find(token) >= 0:
			var value := OS.get_environment(var_name)
			if value.is_empty() and var_name == "XDG_CONFIG_HOME":
				value = _home().path_join(".config")
			if value.is_empty() and var_name == "APPDATA":
				value = _home().path_join("AppData/Roaming")
			if value.is_empty() and var_name == "LOCALAPPDATA":
				value = _home().path_join("AppData/Local")
			out = out.replace(token, value)
	return out


static func _os_key() -> String:
	match OS.get_name():
		"macOS":
			return "darwin"
		"Windows":
			return "windows"
		_:
			return "linux"


static func _home() -> String:
	var h := OS.get_environment("HOME")
	if h.is_empty():
		h = OS.get_environment("USERPROFILE")
	return h
