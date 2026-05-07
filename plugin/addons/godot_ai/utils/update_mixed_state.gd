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
## Producer is `update_reload_runner.gd::INSTALL_BACKUP_SUFFIX`. Inlined as a
## literal — not aliased — because module-level const initializers run at
## script-load and the alias re-introduces the self-update parse hazard
## (#398). `test_update_backup_suffix_stays_in_sync` guards against drift.
const BACKUP_SUFFIX := ".update_backup"
## Cap so a runaway addons tree (someone parented the wrong dir, an old
## crashed install left thousands of artifacts) can't blow the
## `editor_state` payload size or freeze the editor on first paint.
const MAX_BACKUP_RESULTS := 200
## TTL for the `diagnose()` cache. `editor_state` is one of the highest-
## traffic MCP tools (agents poll it constantly) and a recursive
## `DirAccess` walk on every call would put I/O on the 4ms `_process()`
## budget. Mixed-state is rare and persistent across editor restarts, so
## a few seconds of staleness is acceptable; the dock's Re-scan button
## bypasses the cache via `force=true` for immediate feedback.
const CACHE_TTL_MSEC := 5000

static var _cache_value: Dictionary = {}
static var _cache_timestamp_msec: int = -1


## Walk `dir` recursively and return every `res://`-relative path that ends
## in `.update_backup`, sorted ascending. Truncates at `MAX_BACKUP_RESULTS`
## — the truncation flag is exposed via `diagnose()`.
##
## Walk order is deterministic: entries within each directory are sorted
## alphabetically, subdirs pushed reverse-sorted so DFS pops them in
## ascending order. Without this two scans of the same mixed tree could
## return different 200-file slices when truncation kicks in (Godot's
## `list_dir` order isn't guaranteed stable across filesystems).
static func find_backups(dir: String = ADDON_DIR) -> Array:
	var results: Array = []
	var stack: Array = [dir]
	while not stack.is_empty():
		if results.size() >= MAX_BACKUP_RESULTS:
			break
		var current: String = stack.pop_back()
		var d := DirAccess.open(current)
		## Missing dir, permission error, or unreadable junction — skip
		## silently. A missing addons dir is the bare-clone case; mid-walk
		## errors stay quiet so a single permission glitch can't block the
		## diagnostic the rest of the scan would have produced.
		if d == null:
			continue
		var entries: Array = []
		d.list_dir_begin()
		while true:
			var entry := d.get_next()
			if entry.is_empty():
				break
			if entry == "." or entry == "..":
				continue
			entries.append({"name": entry, "is_dir": d.current_is_dir()})
		d.list_dir_end()
		entries.sort_custom(func(a, b): return a["name"] < b["name"])
		## Push subdirs reverse-sorted so the next outer iteration pops
		## them in ascending order — see method docstring for why this
		## determinism matters for the truncated case.
		for i in range(entries.size() - 1, -1, -1):
			var entry: Dictionary = entries[i]
			if entry["is_dir"]:
				stack.append(current.path_join(entry["name"]))
		for entry in entries:
			if entry["is_dir"]:
				continue
			if not String(entry["name"]).ends_with(BACKUP_SUFFIX):
				continue
			results.append(current.path_join(entry["name"]))
			if results.size() >= MAX_BACKUP_RESULTS:
				break
	results.sort()
	return results


## Build the structured diagnostic Dictionary surfaced via `editor_state`
## and the dock banner. Empty when the addons tree is clean — callers
## gate banner visibility / response field on `is_empty()`.
##
## Cached for `CACHE_TTL_MSEC` when scanning the default `ADDON_DIR` so
## per-`editor_state` polls don't re-walk the addons tree every frame.
## Tests passing a custom `dir` always see a fresh scan (cache only
## tracks the production path). `force=true` bypasses the cache — used
## by the dock's Re-scan button so a manual fix is reflected immediately.
static func diagnose(dir: String = ADDON_DIR, force: bool = false) -> Dictionary:
	var use_cache := dir == ADDON_DIR and not force
	if use_cache and _cache_timestamp_msec >= 0:
		if Time.get_ticks_msec() - _cache_timestamp_msec < CACHE_TTL_MSEC:
			return _cache_value.duplicate(true)

	var backups := find_backups(dir)
	var result: Dictionary = {}
	if not backups.is_empty():
		## Most commonly produced by `_rollback_paths_written` returning
		## FAILED_MIXED, but `_finalize_install_success` removes backups on
		## a best-effort basis so a successful install can also leave them
		## behind if the cleanup `remove_absolute` hit a permission error.
		## The recovery action — delete the *.update_backup files — is the
		## same in both cases, so the message acknowledges both
		## possibilities rather than asserting the alarming one.
		result = {
			"addon_dir": dir,
			"backup_files": backups,
			"backup_count": backups.size(),
			"truncated": backups.size() >= MAX_BACKUP_RESULTS,
			"message": (
				"Found .update_backup files in addons/godot_ai/. This usually"
				+ " means a self-update rollback couldn't restore the previous"
				+ " addon contents (FAILED_MIXED) — the plugin may load a mix"
				+ " of old and new files. Restore the addon from your VCS or a"
				+ " fresh release ZIP, then delete the listed *.update_backup"
				+ " files. If the plugin runs without issues these are likely"
				+ " stale from a successful install and safe to delete."
			),
		}
	if use_cache:
		_cache_value = result.duplicate(true)
		_cache_timestamp_msec = Time.get_ticks_msec()
	return result


## Reset the `diagnose()` cache. Tests that flip the addons-tree state
## between calls use this to avoid TTL-bound flakiness; the dock's
## Re-scan button uses `force=true` instead.
static func clear_cache() -> void:
	_cache_value = {}
	_cache_timestamp_msec = -1
