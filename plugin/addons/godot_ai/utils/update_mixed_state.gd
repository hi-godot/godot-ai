@tool
extends RefCounted

## Scanner that detects whether `addons/godot_ai/` is in a half-installed
## state left behind by a self-update whose rollback couldn't restore the
## previous addon contents (`UpdateReloadRunner.InstallStatus.FAILED_MIXED`).
##
## Without this surface the user sees "plugin won't start" with no actionable
## context, re-runs the update, and compounds the mismatch (issue #354 /
## audit-v2 #10). The dock paints a banner from `diagnose()` and
## `editor_handler.gd::get_editor_state` includes the same Dictionary so an
## MCP agent can see and report the state.

const ADDON_DIR := "res://addons/godot_ai/"
const BACKUP_SUFFIX := ".update_backup"
## Cap so a runaway addons tree (someone parented the wrong dir, an old
## crashed install left thousands of artifacts) can't blow the
## `editor_state` payload size or freeze the editor on first paint.
const MAX_BACKUP_RESULTS := 200


## Walk `dir` recursively and return every `res://`-relative path that ends
## in `.update_backup`, sorted ascending. Empty when the addons tree is
## clean. Truncates at `MAX_BACKUP_RESULTS` — the truncation flag is exposed
## via `diagnose()`.
static func find_backups(dir: String = ADDON_DIR) -> Array:
	var results: Array = []
	if not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(dir)):
		return results
	var stack: Array = [dir]
	while not stack.is_empty():
		if results.size() >= MAX_BACKUP_RESULTS:
			break
		var current: String = stack.pop_back()
		var d := DirAccess.open(current)
		if d == null:
			continue
		d.list_dir_begin()
		while true:
			var entry := d.get_next()
			if entry.is_empty():
				break
			if entry == "." or entry == "..":
				continue
			var full := current.path_join(entry)
			if d.current_is_dir():
				stack.append(full)
			elif entry.ends_with(BACKUP_SUFFIX):
				results.append(full)
				if results.size() >= MAX_BACKUP_RESULTS:
					break
		d.list_dir_end()
	results.sort()
	return results


## Build the structured diagnostic Dictionary surfaced via `editor_state`
## and the dock banner. Empty Dictionary when the addons tree is clean —
## callers gate banner visibility / response field on `is_empty()`.
##
## Returned shape:
##   addon_dir: String        ## "res://addons/godot_ai/"
##   backup_files: Array[String]
##   backup_count: int
##   truncated: bool          ## true when the cap was hit
##   message: String          ## one-sentence operator hint
static func diagnose(dir: String = ADDON_DIR) -> Dictionary:
	var backups := find_backups(dir)
	if backups.is_empty():
		return {}
	return {
		"addon_dir": dir,
		"backup_files": backups,
		"backup_count": backups.size(),
		"truncated": backups.size() >= MAX_BACKUP_RESULTS,
		"message": (
			"Self-update rollback failed; addons/godot_ai/ contains a mix of"
			+ " old and new files. Restore the addon from your VCS or a fresh"
			+ " release ZIP, then delete the listed *.update_backup files."
		),
	}
