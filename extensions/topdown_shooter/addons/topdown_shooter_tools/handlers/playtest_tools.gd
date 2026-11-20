@tool
extends RefCounted

## Handler for raid_playtest: plays a raid automatically and reports.
##
## The bot itself lives in the game: raid_playtest_agent.gd is copied into
## the project and registered as the RaidPlaytest autoload. It stays inert
## unless this handler leaves a fresh request file in user://raid_playtest/
## right before starting the game, so normal play is untouched. Driving the
## bot from inside the game (rather than sending input over the debugger
## once per step) keeps aim, movement and timing frame-accurate.
##
## Flow of op="run": install the agent if needed -> stop a running game ->
## write the request -> play the scene -> poll for report.json -> stop the
## game -> reply (deferred) with the report and a verdict.

const Util := preload("res://addons/topdown_shooter_tools/handlers/scaffold_util.gd")

const DEFAULT_SCRIPT_DIR := "res://scripts/topdown"
const AGENT_TEMPLATE := "raid_playtest_agent.gd.tmpl"
const AGENT_FILE := "raid_playtest_agent.gd"
const AUTOLOAD_NAME := "RaidPlaytest"
const DIR := "user://raid_playtest/"
const REQUEST_PATH := DIR + "request.json"
const REPORT_PATH := DIR + "report.json"
const OPS := ["run", "report", "stop", "install", "uninstall"]
## Seconds of tool budget kept back for starting the game and replying.
const STARTUP_MARGIN_SEC := 15.0
## The custom tool spec's timeout (McpCustomToolSpec.MAX_TIMEOUT_MS).
const TOOL_BUDGET_SEC := 120.0
const MAX_WAIT_DURATION := TOOL_BUDGET_SEC - STARTUP_MARGIN_SEC

var _active_token := ""


func quiesce_for_script_swap() -> Dictionary:
	return {"ok": _active_token.is_empty()}


func raid_playtest(params: Dictionary, ctx = null) -> Dictionary:
	var op: Variant = Util.text(params, "op", "run")
	if Util.is_error(op):
		return op
	if not OPS.has(op):
		return Util.error(Util.INVALID_PARAMS, "'op' must be one of %s, got '%s'" % [", ".join(OPS), op])
	match op:
		"report":
			return _op_report(params)
		"stop":
			var was_playing := EditorInterface.is_playing_scene()
			if was_playing:
				EditorInterface.stop_playing_scene()
			return {"data": {"stopped": was_playing}}
		"install":
			var script_dir: Variant = _script_dir(params)
			if Util.is_error(script_dir):
				return script_dir
			var overwrite: Variant = Util.boolean(params, "overwrite_scripts", false)
			if Util.is_error(overwrite):
				return overwrite
			return _install(script_dir, overwrite)
		"uninstall":
			return _uninstall()
	return _op_run(params, ctx)


# --- run ----------------------------------------------------------------------

func _op_run(params: Dictionary, ctx) -> Dictionary:
	var p: Variant = read_run_params(params)
	if Util.is_error(p):
		return p
	if not _active_token.is_empty():
		return Util.error(Util.EDITOR_NOT_READY, "a playtest is already running (token %s); wait for it or call op='stop'" % _active_token)
	var scene: Variant = _resolve_scene(p.scene)
	if Util.is_error(scene):
		return scene
	if p.wait and p.duration / p.time_scale > MAX_WAIT_DURATION:
		return Util.error(Util.INVALID_PARAMS, "'duration' / 'time_scale' can be at most %d real seconds with wait=true (the tool must reply within %d s); raise time_scale, or use wait=false and op='report'" % [int(MAX_WAIT_DURATION), int(TOOL_BUDGET_SEC)])
	if ctx == null or not ctx.has_method("send_deferred"):
		return Util.error(Util.INTERNAL_ERROR, "raid_playtest needs a deferred call context")

	var install := _install(p.script_dir, p.overwrite_scripts)
	if Util.is_error(install):
		return install

	var token := "%x%x" % [Time.get_ticks_usec(), randi()]
	_active_token = token
	_run(p, scene, token, install.data, ctx)
	return {"_deferred": true}


## Validates op="run" params. Returns a dictionary or an error.
static func read_run_params(params: Dictionary) -> Variant:
	var allowed := [
		"op", "scene", "duration", "wait", "time_scale", "crates", "loot", "fight", "hunt",
		"extract", "explore", "max_crates", "engage_range", "loot_radius", "invulnerable",
		"min_fps", "screenshots", "screenshot_interval", "max_screenshots", "show_hud",
		"stop_after", "seed", "script_dir", "overwrite_scripts", "hideout_loop", "redeploy",
	]
	for key in params:
		if not allowed.has(key):
			return Util.error(Util.INVALID_PARAMS, "unknown parameter '%s'" % key)
	var p := {}
	var specs := [
		["duration", "num", 60.0, 5.0, 600.0],
		["time_scale", "num", 1.0, 0.25, 4.0],
		["engage_range", "num", 14.0, 1.0, 100.0],
		["loot_radius", "num", 10.0, 0.0, 100.0],
		["min_fps", "num", 30.0, 1.0, 1000.0],
		["screenshot_interval", "num", 0.0, 0.0, 600.0],
		["max_crates", "int", -1, -1, 1000],
		["max_screenshots", "int", 8, 0, 50],
		["seed", "int", 1, -2147483648, 2147483647],
		["wait", "bool", true],
		["crates", "bool", true],
		["loot", "bool", true],
		["fight", "bool", true],
		["hunt", "bool", false],
		["extract", "bool", true],
		["explore", "bool", false],
		["invulnerable", "bool", false],
		["screenshots", "bool", true],
		["show_hud", "bool", true],
		["stop_after", "bool", true],
		["hideout_loop", "bool", true],
		["redeploy", "bool", true],
		["overwrite_scripts", "bool", false],
		["scene", "text", ""],
	]
	for s in specs:
		var value: Variant
		match s[1]:
			"num":
				value = Util.num(params, s[0], s[2], s[3], s[4])
			"int":
				value = Util.integer(params, s[0], s[2], s[3], s[4])
			"bool":
				value = Util.boolean(params, s[0], s[2])
			_:
				value = Util.text(params, s[0], s[2])
		if Util.is_error(value):
			return value
		p[s[0]] = value
	var script_dir: Variant = _script_dir(params)
	if Util.is_error(script_dir):
		return script_dir
	p["script_dir"] = script_dir
	return p


## The request the in-game agent reads (keys match its DEFAULTS).
static func build_request(p: Dictionary, token: String) -> Dictionary:
	var request := {"token": token, "created_unix": Time.get_unix_time_from_system()}
	for key in [
		"duration", "time_scale", "crates", "loot", "fight", "hunt", "extract", "explore",
		"max_crates", "engage_range", "loot_radius", "invulnerable", "min_fps", "screenshots",
		"screenshot_interval", "max_screenshots", "show_hud", "seed", "hideout_loop", "redeploy",
	]:
		request[key] = p[key]
	## The editor stops the game after reading the report; when it does not
	## wait, the game closes itself.
	request["quit_on_finish"] = true
	return request


func _run(p: Dictionary, scene: String, token: String, install: Dictionary, ctx) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	var started_msec := Time.get_ticks_msec()
	var restarted := false
	if EditorInterface.is_playing_scene():
		restarted = true
		EditorInterface.stop_playing_scene()
		while EditorInterface.is_playing_scene() and Time.get_ticks_msec() - started_msec < 5000:
			await tree.create_timer(0.1).timeout
		await tree.create_timer(0.3).timeout

	var write_err := _write_request(build_request(p, token))
	if write_err != "":
		_active_token = ""
		ctx.send_deferred(Util.error(Util.INTERNAL_ERROR, write_err))
		return
	if scene.is_empty():
		EditorInterface.play_main_scene()
	else:
		EditorInterface.play_custom_scene(scene)

	var base := {
		"token": token,
		"scene": scene if not scene.is_empty() else str(ProjectSettings.get_setting("application/run/main_scene", "")),
		"agent": install,
		"restarted_running_game": restarted,
		"report_path": ProjectSettings.globalize_path(REPORT_PATH),
	}

	## Wait for the game to come up.
	var launch_deadline := Time.get_ticks_msec() + 10000
	while not EditorInterface.is_playing_scene() and Time.get_ticks_msec() < launch_deadline:
		await tree.create_timer(0.1).timeout
	if not EditorInterface.is_playing_scene():
		_active_token = ""
		_remove(REQUEST_PATH)
		ctx.send_deferred(Util.error(Util.INTERNAL_ERROR, "the game did not start (check the Output panel for errors)"))
		return

	if not p.wait:
		_active_token = ""
		base["status"] = "running"
		base["hint"] = "the raid plays for up to %d s, then the game closes itself; call raid_playtest op='report' for the result" % int(p.duration / p.time_scale)
		ctx.send_deferred({"data": base})
		return

	## Leave time to reply before the tool budget runs out.
	var budget_end := started_msec + int(TOOL_BUDGET_SEC * 1000.0) - 4000
	if "deadline_msec" in ctx and int(ctx.deadline_msec) > 0:
		budget_end = mini(budget_end, int(ctx.deadline_msec) - 4000)
	var report: Variant = null
	var game_exited := false
	var exited_at := 0
	while Time.get_ticks_msec() < budget_end:
		await tree.create_timer(0.25).timeout
		report = read_report(token)
		if report != null:
			break
		if not EditorInterface.is_playing_scene():
			## The agent writes the report before quitting; give the file a
			## moment after the window closes.
			if exited_at == 0:
				exited_at = Time.get_ticks_msec()
			elif Time.get_ticks_msec() - exited_at > 1500:
				game_exited = true
				break

	_active_token = ""
	if report == null:
		if game_exited:
			_remove(REQUEST_PATH)
			base["status"] = "game_exited"
			base["verdict"] = "fail"
			base["issues"] = ["게임이 보고서를 남기지 않고 종료됨 (충돌, 수동 종료, 또는 %s 자동 로드가 없음). Output 패널의 오류를 확인하세요." % AUTOLOAD_NAME]
		else:
			base["status"] = "still_running"
			base["hint"] = "no report within the tool time limit; the game keeps running. Call raid_playtest op='report' later, or op='stop'."
		ctx.send_deferred({"data": base})
		return
	if p.stop_after and EditorInterface.is_playing_scene():
		EditorInterface.stop_playing_scene()
	ctx.send_deferred({"data": summarize(report, base)})


## Adds verdict and a short summary to the agent's report.
static func summarize(report: Dictionary, base: Dictionary = {}) -> Dictionary:
	var out := base.duplicate()
	var issues: Array = report.get("issues", [])
	out["status"] = "finished"
	out["verdict"] = "pass" if issues.is_empty() else "issues"
	out["result"] = report.get("result", "")
	out["issues"] = issues
	var combat: Dictionary = report.get("combat", {})
	var loot: Dictionary = report.get("loot", {})
	var perf: Dictionary = report.get("performance", {})
	var errors: Dictionary = report.get("errors", {})
	out["summary"] = "%s after %.1f s: crates %d/%d, items %d (value %d), kills %d/%d, shots %d (hits %d), damage taken %.0f, FPS avg %.0f / min %.0f, errors %d" % [
		report.get("result", "?"), float(report.get("game_time", 0.0)),
		int(loot.get("crates_opened", 0)), int(loot.get("crates_total", 0)),
		int(loot.get("items_picked", 0)), int(loot.get("inventory_value", 0)),
		int(combat.get("enemies_killed", 0)), int(combat.get("enemies_total", 0)),
		int(combat.get("shots", 0)), int(combat.get("hits", 0)),
		float(report.get("player", {}).get("damage_taken", 0.0)),
		float(perf.get("fps_avg", 0.0)), float(perf.get("fps_min", 0.0)),
		int(errors.get("count", 0)),
	]
	var hideout: Dictionary = report.get("hideout", {})
	if bool(hideout.get("linked", false)) and hideout.has("raid_result"):
		var redeploy: Dictionary = hideout.get("redeploy", {})
		out["hideout"] = "returned in %.1f s, stash value %d, missing %d, save %s%s" % [
			float(hideout.get("seconds_to_hideout", -1.0)), int(hideout.get("stash_value", 0)),
			hideout.get("missing", {}).size(), "ok" if bool(hideout.get("save_matches", false)) else "MISMATCH",
			"" if redeploy.is_empty() else ", redeploy %s" % ("ok" if bool(redeploy.get("ok", false)) else "FAILED"),
		] if bool(hideout.get("returned", false)) else "did not return to the hideout (%s)" % hideout.get("error", "?")
	out["screenshots"] = report.get("screenshots", [])
	out["report"] = report
	return out


static func read_report(token: String = "") -> Variant:
	if not FileAccess.file_exists(REPORT_PATH):
		return null
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(REPORT_PATH))
	if not data is Dictionary:
		return null
	if not token.is_empty() and str(data.get("token", "")) != token:
		return null
	return data


func _op_report(params: Dictionary) -> Dictionary:
	for key in params:
		if key != "op":
			return Util.error(Util.INVALID_PARAMS, "op='report' takes no other parameters (got '%s')" % key)
	var report: Variant = read_report()
	var playing := EditorInterface.is_playing_scene()
	if report == null:
		return {"data": {"status": "running" if playing else "no_report", "game_running": playing, "report_path": ProjectSettings.globalize_path(REPORT_PATH)}}
	var out := summarize(report, {"report_path": ProjectSettings.globalize_path(REPORT_PATH)})
	out["game_running"] = playing
	return {"data": out}


func _write_request(request: Dictionary) -> String:
	var err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	if err != OK and err != ERR_ALREADY_EXISTS:
		return "cannot create %s: %s" % [DIR, error_string(err)]
	_remove(REPORT_PATH)
	var file := FileAccess.open(REQUEST_PATH, FileAccess.WRITE)
	if file == null:
		return "cannot write %s: %s" % [REQUEST_PATH, error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify(request))
	file.close()
	return ""


static func _remove(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _resolve_scene(scene: String) -> Variant:
	if scene.is_empty():
		var root := Util.edited_root()
		if root != null and not root.scene_file_path.is_empty():
			return root.scene_file_path
		if str(ProjectSettings.get_setting("application/run/main_scene", "")).is_empty():
			return Util.error(Util.INVALID_PARAMS, "no scene to play: open the raid scene, pass 'scene', or set a main scene")
		return ""
	if not scene.begins_with("res://") or scene.get_extension() not in ["tscn", "scn"]:
		return Util.error(Util.INVALID_PARAMS, "'scene' must be a res:// .tscn path, got '%s'" % scene)
	if not ResourceLoader.exists(scene):
		return Util.error(Util.NODE_NOT_FOUND, "scene %s does not exist" % scene)
	return scene


static func _script_dir(params: Dictionary) -> Variant:
	var value: Variant = Util.text(params, "script_dir", DEFAULT_SCRIPT_DIR)
	if Util.is_error(value):
		return value
	var dir := Util.clean_dir(value)
	var reason := Util.check_res_path(dir + "/x.gd", "gd")
	if not reason.is_empty():
		return Util.error(Util.INVALID_PARAMS, "'script_dir': " + reason)
	return dir


# --- autoload -------------------------------------------------------------------

static func autoload_key() -> String:
	return "autoload/" + AUTOLOAD_NAME


## Copies the agent script (kept when present) and registers the autoload
## (one undo step in the editor's global history). Returns {"data": {...}}.
func _install(script_dir: String, overwrite: bool) -> Dictionary:
	var path := script_dir + "/" + AGENT_FILE
	var copied := Util.install_script(AGENT_TEMPLATE, path, overwrite)
	if Util.is_error(copied):
		return copied
	if copied.status != "kept":
		Util.refresh_filesystem([path])
	var key := autoload_key()
	var value := "*" + path
	var previous: Variant = ProjectSettings.get_setting(key) if ProjectSettings.has_setting(key) else null
	var autoload_status := "kept"
	if previous != value:
		autoload_status = "added" if previous == null else "updated"
		var ur := EditorInterface.get_editor_undo_redo()
		ur.create_action("Raid playtest: register %s autoload" % AUTOLOAD_NAME, UndoRedo.MERGE_DISABLE, ProjectSettings)
		ur.add_do_method(ProjectSettings, &"set_setting", key, value)
		ur.add_do_method(ProjectSettings, &"save")
		ur.add_undo_method(ProjectSettings, &"set_setting", key, previous)
		ur.add_undo_method(ProjectSettings, &"save")
		ur.commit_action()
		if ProjectSettings.get_setting(key, null) != value:
			return Util.error(Util.INTERNAL_ERROR, "could not register the %s autoload in project.godot" % AUTOLOAD_NAME)
	return {"data": {"script": path, "script_status": copied.status, "autoload": AUTOLOAD_NAME, "autoload_status": autoload_status}}


func _uninstall() -> Dictionary:
	var key := autoload_key()
	if not ProjectSettings.has_setting(key):
		return {"data": {"autoload": AUTOLOAD_NAME, "removed": false}}
	var previous: Variant = ProjectSettings.get_setting(key)
	var ur := EditorInterface.get_editor_undo_redo()
	ur.create_action("Raid playtest: remove %s autoload" % AUTOLOAD_NAME, UndoRedo.MERGE_DISABLE, ProjectSettings)
	ur.add_do_method(ProjectSettings, &"set_setting", key, null)
	ur.add_do_method(ProjectSettings, &"save")
	ur.add_undo_method(ProjectSettings, &"set_setting", key, previous)
	ur.add_undo_method(ProjectSettings, &"save")
	ur.commit_action()
	return {"data": {"autoload": AUTOLOAD_NAME, "removed": true, "script_kept": str(previous).trim_prefix("*")}}
