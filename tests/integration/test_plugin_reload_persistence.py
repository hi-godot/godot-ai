"""Exercise ordinary reload persistence with real editor enable/disable callbacks."""

import json
import shutil
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

PLUGIN = '''@tool
extends EditorPlugin

func _enter_tree() -> void:
    Engine.set_meta("reload_enters", int(Engine.get_meta("reload_enters", 0)) + 1)
    var fail_save := OS.get_environment("RELOAD_CASE") == "save-failure"
    if FileAccess.file_exists("res://armed") and fail_save:
        assert(DirAccess.rename_absolute("res://project.godot", "res://saved-project") == OK)
        assert(DirAccess.make_dir_absolute("res://project.godot") == OK)
    else:
        assert(ProjectSettings.save() == OK)

func _disable_plugin() -> void:
    assert(ProjectSettings.save() == OK)
    if OS.get_environment("RELOAD_CASE") == "enable-failure":
        assert(DirAccess.rename_absolute(
            "res://addons/godot_ai/plugin.cfg", "res://saved-plugin") == OK)
'''

DRIVER = '''@tool
extends Node

const Reload := preload("res://plugin_reload.gd")
const COMPANION := "res://addons/companion/plugin.cfg"
var _frames := 0

func _process(_delta: float) -> void:
    if not Engine.is_editor_hint():
        return
    _frames += 1
    if _frames != 45:
        return
    set_process(false)
    var mode := OS.get_environment("RELOAD_CASE")
    var result := OK
    var expected := OK
    if not FileAccess.file_exists("res://result.json"):
        var armed := FileAccess.open("res://armed", FileAccess.WRITE)
        assert(armed != null)
        armed.close()
        result = Reload.reload_enabled_plugin()
        if mode == "disabled":
            expected = ERR_UNAVAILABLE
        elif mode == "enable-failure":
            expected = FAILED
            assert(DirAccess.rename_absolute("res://saved-plugin", Reload.PLUGIN_CFG) == OK)
        elif mode == "save-failure":
            expected = ERR_FILE_CANT_OPEN
            assert(DirAccess.remove_absolute("res://project.godot") == OK)
            assert(DirAccess.rename_absolute("res://saved-project", "res://project.godot") == OK)
    var saved := ConfigFile.new()
    assert(saved.load("res://project.godot") == OK)
    var enabled: PackedStringArray = saved.get_value(
        "editor_plugins", "enabled", PackedStringArray())
    var output_path := "res://reopened.json" if FileAccess.file_exists("res://result.json") else "res://result.json"
    var output := FileAccess.open(output_path, FileAccess.WRITE)
    assert(output != null)
    output.store_string(JSON.stringify({
        "expected_result": result == expected,
        "result": result,
        "enabled": EditorInterface.is_plugin_enabled(Reload.PLUGIN_CFG),
        "saved_enabled": Reload.PLUGIN_CFG in enabled,
        "companion_live": EditorInterface.is_plugin_enabled(COMPANION),
        "companion_saved": COMPANION in enabled,
    }))
    output.close()
    get_tree().quit(0)
'''


def _reload_project(tmp_path: Path, mode: str, driver: str = DRIVER) -> Path:
    project = tmp_path / mode
    for name in ("godot_ai", "companion"):
        addon = project / "addons" / name
        addon.mkdir(parents=True)
        (addon / "plugin.cfg").write_text(
            f'[plugin]\nname="{name}"\ndescription="Reload test"\n'
            'author="test"\nversion="1"\nscript="plugin.gd"\n', encoding="utf-8",
        )
        (addon / "plugin.gd").write_text(
            PLUGIN if name == "godot_ai" else "@tool\nextends EditorPlugin\n", encoding="utf-8",
        )
    enabled = '"res://addons/companion/plugin.cfg"'
    if mode != "disabled":
        enabled += ', "res://addons/godot_ai/plugin.cfg"'
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Reload persistence test"\n'
        f'[editor_plugins]\nenabled=PackedStringArray({enabled})\n'
        '[autoload]\nReloadDriver="*res://driver.gd"\n', encoding="utf-8",
    )
    shutil.copyfile(PLUGIN_ROOT / "utils/plugin_reload.gd", project / "plugin_reload.gd")
    utils = project / "addons/godot_ai/utils"
    utils.mkdir()
    shutil.copyfile(PLUGIN_ROOT / "utils/script_work.gd", utils / "script_work.gd")
    (project / "driver.gd").write_text(driver, encoding="utf-8")
    return project


@pytest.mark.parametrize("mode", ["success", "disabled", "enable-failure", "save-failure"])
def test_real_editor_reload_persists_only_after_enable_completes(tmp_path: Path, mode: str) -> None:
    godot = godot_bin_or_skip()
    project = _reload_project(tmp_path, mode)
    log = run_godot_editor(
        project, godot, allow_headless=False, timeout=60, environment={"RELOAD_CASE": mode},
    )
    assert "SCRIPT ERROR:" not in log
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    assert result["expected_result"], result
    assert result["companion_live"] and result["companion_saved"], result
    assert result["enabled"] == (mode in {"success", "save-failure"}), result
    assert result["saved_enabled"] == (mode != "disabled"), result
    if mode == "success":
        run_godot_editor(project, godot, allow_headless=False, timeout=60, phase="reopened")
        reopened = json.loads((project / "reopened.json").read_text(encoding="utf-8"))
        assert reopened == result


SCAN_DRIVER = '''@tool
extends Node

const Reload := preload("res://plugin_reload.gd")
const Work := preload("res://addons/godot_ai/utils/script_work.gd")

class Filesystem extends RefCounted:
    signal filesystem_changed
    var scans := 0
    func scan() -> void:
        scans += 1

class Deadline extends RefCounted:
    signal timeout

var _frames := 0
var _done := false
var _started_ms := Time.get_ticks_msec()

func _process(_delta: float) -> void:
    _frames += 1
    if _frames == 45:
        _exercise()
    if Time.get_ticks_msec() - _started_ms > 15000 and not _done:
        get_tree().quit(40)

func _exercise() -> void:
    var mode := OS.get_environment("RELOAD_CASE")
    assert(int(Engine.get_meta("reload_enters")) == 1)
    var filesystem := Filesystem.new()
    var timer := Deadline.new()
    var work := Work.begin("test reload")
    var started := Time.get_ticks_msec()
    if mode == "actual-scan":
        Work.finish(work)
        var path := "res://addons/godot_ai/plugin.gd"
        var source := FileAccess.get_file_as_string(path)
        var changed := FileAccess.open(path, FileAccess.WRITE)
        assert(changed != null)
        changed.store_string(source + "\\n# changed before a real filesystem scan\\n")
        changed.close()
        Reload.reload_after_scan()
    else:
        if mode == "native-timeout":
            Engine.time_scale = 0.0
            Reload._start_scan(filesystem, null, work)
        else:
            Reload._start_scan(filesystem, timer, work)
        assert(filesystem.scans == 1)
        assert(not Work.quiescence().ok)
        assert(int(Engine.get_meta("reload_enters")) == 1,
            "scan request cannot disable or re-enable early")
        if mode == "duplicate":
            var duplicate_fs := Filesystem.new()
            Reload._start_scan(duplicate_fs, Deadline.new(), Work.begin("duplicate"))
            assert(duplicate_fs.scans == 0)
            assert(Work._active.size() == 1)
            filesystem.filesystem_changed.emit()
        elif mode == "timeout":
            timer.timeout.emit()
            filesystem.filesystem_changed.emit()
            Reload._finish_scan(work, false)
        elif mode == "stale":
            timer.timeout.emit()
            var replacement_work := Work.begin("replacement")
            Reload._start_scan(filesystem, timer, replacement_work)
            Reload._finish_scan(work, false)
            Reload._finish_scan(work, true)
            assert(Reload._pending_scan.work == replacement_work)
            assert(int(Engine.get_meta("reload_enters")) == 1)
            filesystem.filesystem_changed.emit()
        elif mode == "cancel-direct":
            assert(Reload.reload_enabled_plugin() == OK)
            filesystem.filesystem_changed.emit()
            timer.timeout.emit()
            Reload._finish_scan(work, false)
        elif mode == "disabled-during-scan":
            EditorInterface.set_plugin_enabled(Reload.PLUGIN_CFG, false)
            # Model an explicitly saved user disable; the reload refusal must
            # preserve it rather than claiming to persist someone else's action.
            assert(ProjectSettings.save() == OK)
            filesystem.filesystem_changed.emit()
        elif mode == "native-timeout":
            pass # Real five-second timer must settle this uncompleted scan.
        elif mode == "notification":
            filesystem.filesystem_changed.emit()
            assert(int(Engine.get_meta("reload_enters")) == 1,
                "completion must be deferred until resource notifications unwind")
        else:
            assert(false, "unknown case")
    var deadline := Time.get_ticks_msec() + 10000
    while not Work.quiescence().ok and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    assert(Work.quiescence().ok, "reload work must settle")
    if mode == "native-timeout":
        Engine.time_scale = 1.0
        assert(Time.get_ticks_msec() - started >= 4500)
        assert(Time.get_ticks_msec() - started < 8000)
    assert(Reload._pending_scan.is_empty())
    assert(filesystem.filesystem_changed.get_connections().is_empty())
    assert(timer.timeout.get_connections().is_empty())
    # Late notifications/timeout after completion must not cause a second reload.
    filesystem.filesystem_changed.emit()
    timer.timeout.emit()
    Reload._finish_scan(work, false)
    await get_tree().process_frame
    var expected := 1 if mode in ["timeout", "native-timeout", "disabled-during-scan"] else 2
    assert(int(Engine.get_meta("reload_enters")) == expected)
    assert(EditorInterface.is_plugin_enabled(Reload.PLUGIN_CFG) == (mode != "disabled-during-scan"))
    assert(EditorInterface.is_plugin_enabled("res://addons/companion/plugin.cfg"))
    var saved := ConfigFile.new()
    assert(saved.load("res://project.godot") == OK)
    var enabled: PackedStringArray = saved.get_value("editor_plugins", "enabled")
    assert((Reload.PLUGIN_CFG in enabled) == (mode != "disabled-during-scan"))
    assert("res://addons/companion/plugin.cfg" in enabled)
    var result := FileAccess.open("res://scan-result.json", FileAccess.WRITE)
    result.store_string(JSON.stringify({"mode": mode, "enters": expected, "settled": true}))
    result.close()
    _done = true
    get_tree().quit(0)
'''


@pytest.mark.parametrize("mode", [
    "notification", "timeout", "stale", "duplicate", "cancel-direct",
    "disabled-during-scan", "actual-scan", "native-timeout",
])
def test_real_editor_scan_completion_has_bounded_once_only_ownership(
    tmp_path: Path, mode: str,
) -> None:
    godot = godot_bin_or_skip()
    project = _reload_project(tmp_path, mode, SCAN_DRIVER)
    log = run_godot_editor(
        project, godot, allow_headless=False, timeout=60, environment={"RELOAD_CASE": mode},
    )
    assert "SCRIPT ERROR:" not in log
    result = json.loads((project / "scan-result.json").read_text(encoding="utf-8"))
    assert result == {
        "mode": mode,
        "enters": 1 if mode in {"timeout", "native-timeout", "disabled-during-scan"} else 2,
        "settled": True,
    }
