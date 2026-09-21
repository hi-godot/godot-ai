"""Real-editor evidence for the documented preload freshness limit (#938)."""
from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import godot_bin_or_skip, run_godot_editor

## Needs a real Godot editor (GODOT_BIN); skipped without one and excluded
## from the iteration loop by `pytest -m "not editor"`.
pytestmark = pytest.mark.editor

ROOT = Path(__file__).resolve().parents[2]


def test_rerun_warns_about_stale_preload_and_fresh_editor_observes_edit(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "preload-cache"
    (project / "tests").mkdir(parents=True)
    shutil.copytree(ROOT / "plugin/addons/godot_ai", project / "addons/godot_ai")
    config = project / "project.godot"
    config.write_text('config_version=5\n[application]\nconfig/name="Preload cache regression"\n')
    (project / "tests/helper.gd").write_text(
        '@tool\nextends RefCounted\nstatic func value() -> String:\n\treturn "old"\n'
    )
    (project / "expected.txt").write_text("old")
    (project / "tests/test_cache.gd").write_text('''@tool
extends McpTestSuite
const Helper = preload("res://tests/helper.gd")
func suite_name() -> String:
    return "cache"
func test_value() -> void:
    assert_eq(Helper.value(), FileAccess.get_file_as_string("res://expected.txt"))
''')
    imported = subprocess.run(
        [godot, "--headless", "--editor", "--path", str(project), "--import"],
        capture_output=True, text=True, timeout=90, check=False,
    )
    assert imported.returncode == 0, imported.stdout + imported.stderr
    (project / "driver.gd").write_text('''@tool
extends Node
var frames := 15
var retained: GDScript
func _process(_delta: float) -> void:
    if not Engine.is_editor_hint():
        return
    frames -= 1
    if frames != 0:
        return
    set_process(false)
    retained = load("res://tests/test_cache.gd")
    var handler = load("res://addons/godot_ai/handlers/test_handler.gd").new(null, null)
    if FileAccess.file_exists("res://before.json"):
        write_json("res://fresh.json", handler.run_tests({"suite": "cache"}))
    else:
        write_json("res://before.json", handler.run_tests({"suite": "cache"}))
        var helper = FileAccess.open("res://tests/helper.gd", FileAccess.WRITE)
        helper.store_string('@tool\\nextends RefCounted\\n'
            + 'static func value() -> String:\\n\\treturn "new"\\n')
        helper.close()
        var expected = FileAccess.open("res://expected.txt", FileAccess.WRITE)
        expected.store_string("new")
        expected.close()
        EditorInterface.get_resource_filesystem().update_file("res://tests/helper.gd")
        write_json("res://rerun.json", handler.run_tests({"suite": "cache"}))
        write_json("res://saved.json", handler.get_test_results({}))
    get_tree().quit(0)
func write_json(path: String, data: Dictionary) -> void:
    var file = FileAccess.open(path, FileAccess.WRITE)
    file.store_string(JSON.stringify(data))
    file.close()
''')
    config.write_text(config.read_text(encoding="utf-8") + '[autoload]\nDriver="*res://driver.gd"\n')
    run_godot_editor(project, godot, allow_headless=False, timeout=90)
    before = json.loads((project / "before.json").read_text(encoding="utf-8"))["data"]
    rerun = json.loads((project / "rerun.json").read_text(encoding="utf-8"))["data"]
    saved = json.loads((project / "saved.json").read_text(encoding="utf-8"))["data"]
    assert before["passed"] == 1 and before["failed"] == 0
    assert 'return "new"' in (project / "tests/helper.gd").read_text(encoding="utf-8")
    assert rerun["failed"] == 1, rerun
    assert "Restart the editor" in rerun["cache_warning"]
    assert saved["cache_warning"] == rerun["cache_warning"]
    run_godot_editor(project, godot, allow_headless=False, timeout=90)
    fresh = json.loads((project / "fresh.json").read_text(encoding="utf-8"))["data"]
    assert fresh["passed"] == 1 and fresh["failed"] == 0, fresh
