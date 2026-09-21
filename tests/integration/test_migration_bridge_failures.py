"""Actual capsule coordinator/installer/activation handoff in an isolated editor."""

from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip, run_godot_editor

pytestmark = pytest.mark.editor

INSTALLER_SCRIPTS = (
    "release_verifier.gd",
    "update_installer.gd",
    "port_resolver.gd",
    "windows_port_reservation.gd",
    "update_activation_runner.gd",
)

PLUGIN = """@tool
extends EditorPlugin
const Handler := preload("res://addons/godot_ai/handler.gd")
var _loaded_plugin_version := "VERSION"
var handler = Handler.new()
func active_value() -> String: return handler.value()
func _exit_tree() -> void: handler = null
"""

DRIVER = """@tool
extends Node
const CONFIG := "res://addons/godot_ai/plugin.cfg"
const COMPANION := "res://addons/companion/plugin.cfg"
const UPDATE := "res://addons/.godot_ai_update"
const STAGE := UPDATE + "/stage/addons/godot_ai"
var frames := 0
var before := {}
var failure := ""
var started := 0
var done := false
var first_activation := {}
var first_value := ""
var first_state := {}
var second_started := false
var retained: WeakRef
var history: UndoRedo
var target: Node2D
var scan_completions: Array[Dictionary] = []
var unrelated_notifications := 0
var ordering_errors: Array[String] = []
func find_plugin(node: Node) -> Node:
    if node.get_script() != null and node.get_script().resource_path == "res://addons/godot_ai/plugin.gd":
        return node
    for child in node.get_children():
        var found := find_plugin(child)
        if found != null: return found
    return null
func _process(_delta: float) -> void:
    if not Engine.is_editor_hint() or done: return
    frames += 1
    if frames == 15 and OS.get_environment("BRIDGE_CASE") == "user-scene":
        EditorInterface.open_scene_from_path("res://user.tscn")
    if frames == 45: begin.call_deferred()
    if started > 0:
        check_unrelated_notification()
        if not failure.is_empty() or FileAccess.file_exists(UPDATE + "/activation.json"):
            if (failure.is_empty() and OS.get_environment("BRIDGE_CASE") == "success"
                    and not second_started):
                second_started = true
                started = 0
                next_activation.call_deferred()
            else:
                done = true
                finish.call_deferred()
        elif Time.get_ticks_msec() - started > 75000:
            failure = "test_deadline"
            done = true
            finish.call_deferred()
func disk_version() -> String:
    var config := ConfigFile.new()
    assert(config.load("res://addons/godot_ai/plugin.cfg") == OK)
    return str(config.get_value("plugin", "version"))
func on_scan_completed(_changed: bool) -> void:
    if started > 0 and not EditorInterface.is_plugin_enabled(CONFIG):
        scan_completions.append({"activation": 2 if second_started else 1,
            "version": disk_version()})
func check_unrelated_notification() -> void:
    if EditorInterface.is_plugin_enabled(CONFIG): return
    var before_version := disk_version()
    EditorInterface.get_resource_filesystem().filesystem_changed.emit()
    unrelated_notifications += 1
    if disk_version() != before_version or EditorInterface.is_plugin_enabled(CONFIG):
        ordering_errors.append("Generic filesystem notification advanced activation")
func begin() -> void:
    EditorInterface.get_resource_filesystem().sources_changed.connect(on_scan_completed)
    var plugin := find_plugin(get_tree().root)
    if plugin == null:
        failure = "initial_plugin_missing"
        done = true
        finish()
        return
    before = {"pid": OS.get_process_id(), "instance": plugin.get_instance_id(),
        "value": plugin.call("active_value"),
        "companion": EditorInterface.is_plugin_enabled(COMPANION)}
    target = Node2D.new()
    add_child(target)
    var handler = plugin.get("handler")
    handler.prepare_static()
    retained = weakref(handler)
    var undo = plugin.get_undo_redo()
    undo.create_action("Retained handler fixture", UndoRedo.MERGE_DISABLE, target)
    undo.add_do_property(target, "position", Vector2(42, 17))
    undo.add_do_method(handler, "record", target, "after")
    undo.add_undo_property(target, "position", Vector2.ZERO)
    undo.add_undo_method(handler, "record", target, "before")
    undo.commit_action()
    history = undo.get_history_undo_redo(undo.get_object_history_id(target))
    before["mark"] = target.get_meta("mark", "missing")
    before["state"] = handler.snapshot()
    var verifier = load("res://addons/godot_ai/utils/release_verifier.gd")
    var tree: Dictionary = verifier.hash_tree(STAGE)
    assert(tree.ok)
    var expected := str(tree.tree_sha256)
    var mode := OS.get_environment("BRIDGE_CASE")
    if mode == "wrong-hash": expected = "0".repeat(64)
    if mode == "backup-exists":
        assert(DirAccess.make_dir_recursive_absolute(UPDATE + "/backup/3.2.5") == OK)
    var coordinator = load("res://addons/godot_ai/migration_coordinator.gd").new()
    get_tree().root.add_child(coordinator)
    coordinator.state_changed.connect(on_state)
    coordinator.start({"from_version": "3.2.5", "to_version": "4.0.5",
        "manifest_sha256": "a".repeat(64), "expected_tree_sha256": expected,
        "stage_root": STAGE})
    started = Time.get_ticks_msec()
func next_activation() -> void:
    first_activation = JSON.parse_string(FileAccess.get_file_as_string(UPDATE + "/activation.json"))
    var plugin := find_plugin(get_tree().root)
    first_value = plugin.call("active_value")
    first_state = plugin.get("handler").snapshot()
    assert(DirAccess.rename_absolute(UPDATE + "/activation.json",
        UPDATE + "/first-activation.json") == OK)
    var made := DirAccess.make_dir_recursive_absolute(STAGE.get_base_dir())
    assert(made == OK, "prepare next stage: " + error_string(made))
    var moved := DirAccess.rename_absolute(UPDATE + "/next/addons/godot_ai", STAGE)
    assert(moved == OK, "move next stage: " + error_string(moved))
    var verifier = load("res://addons/godot_ai/utils/release_verifier.gd")
    var tree: Dictionary = verifier.hash_tree(STAGE)
    assert(tree.ok)
    var coordinator = load("res://addons/godot_ai/migration_coordinator.gd").new()
    get_tree().root.add_child(coordinator)
    coordinator.state_changed.connect(on_state)
    coordinator.start({"from_version": "4.0.5", "to_version": "4.0.6",
        "manifest_sha256": "b".repeat(64), "expected_tree_sha256": tree.tree_sha256,
        "stage_root": STAGE})
    started = Time.get_ticks_msec()
func on_state(message: String, failed: bool) -> void:
    if failed: failure = message
func finish() -> void:
    var plugin := find_plugin(get_tree().root)
    var activation := {}
    if FileAccess.file_exists(UPDATE + "/activation.json"):
        activation = JSON.parse_string(FileAccess.get_file_as_string(UPDATE + "/activation.json"))
    var saved := ConfigFile.new()
    var save_read := saved.load("res://project.godot")
    var result := {"before": before, "pid": OS.get_process_id(), "failure": failure,
        "enabled": EditorInterface.is_plugin_enabled(CONFIG),
        "companion": EditorInterface.is_plugin_enabled(COMPANION),
        "value": plugin.call("active_value") if plugin != null else "",
        "instance": plugin.get_instance_id() if plugin != null else 0,
        "activation": activation, "first_activation": first_activation,
        "scan_completions": scan_completions,
        "unrelated_notifications": unrelated_notifications, "ordering_errors": ordering_errors,
        "first_value": first_value, "first_state": first_state,
        "first_backup_exists": FileAccess.file_exists(UPDATE + "/backup/3.2.5/handler.gd"),
        "second_backup_exists": FileAccess.file_exists(UPDATE + "/backup/4.0.5/handler.gd"),
        "lock_present": FileAccess.file_exists(UPDATE + "/lock.json"),
        "retention_marker": get_tree().root.has_meta("godot_ai_retained_update_scripts"),
        "pending": FileAccess.file_exists(UPDATE + "/pending.json"),
        "stage_present": DirAccess.dir_exists_absolute(STAGE),
        "save_read": save_read,
        "saved_enabled": Array(saved.get_value("editor_plugins", "enabled",
            PackedStringArray())) if save_read == OK else []}
    var previous_handler = retained.get_ref() if retained != null else null
    result["retained_alive"] = previous_handler != null
    if previous_handler != null:
        result["retained_state"] = previous_handler.snapshot()
        result["retained_script_path"] = previous_handler.get_script().resource_path
    if plugin != null:
        result["new_state"] = plugin.get("handler").snapshot()
    if history != null:
        result["undo_ok"] = history.undo()
        result["undo_position"] = [target.position.x, target.position.y]
        result["undo_mark"] = target.get_meta("mark", "missing")
        result["redo_ok"] = history.redo()
        result["redo_position"] = [target.position.x, target.position.y]
        result["redo_mark"] = target.get_meta("mark", "missing")
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(result))
    file.close()
    get_tree().quit()
"""


def _project(tmp_path: Path, case: str) -> Path:
    project = tmp_path / case
    live = project / "addons/godot_ai"
    live.mkdir(parents=True)
    (live / "utils").mkdir()
    for name in INSTALLER_SCRIPTS:
        shutil.copy2(PLUGIN_ROOT / "utils" / name, live / "utils" / name)
    shutil.copy2(PLUGIN_ROOT.parents[2] / "migration_bridge/migration_coordinator.gd", live)
    (live / "plugin.cfg").write_text(
        '[plugin]\nname="Activation fixture"\nversion="3.2.5"\nscript="plugin.gd"\n',
        encoding="utf-8",
    )
    (live / "plugin.gd").write_text(PLUGIN.replace("VERSION", "3.2.5"), encoding="utf-8")
    (live / "handler.gd").write_text(
        '@tool\nextends RefCounted\nconst Leaf := preload("res://addons/godot_ai/leaf.gd")\n'
        'var storage: Dictionary = {"value": "A"}\n'
        'func value() -> String: return storage.value if Leaf.value() == "A" else "wrong"\n',
        encoding="utf-8",
    )
    (live / "leaf.gd").write_text(
        "@tool\nclass_name McpBridgeFixtureLeaf\nextends RefCounted\n"
        'static func value() -> String: return "A"\n',
        encoding="utf-8",
    )
    handler_methods = (
        "func record(target: Node, argument: String) -> void:\n"
        '    target.set_meta("mark", McpBridgeFixtureLeaf.value() + ":" + argument)\n'
        "func snapshot() -> Dictionary:\n"
        '    return {"type": typeof(storage), "value": storage, '
        '"static": McpBridgeFixtureLeaf.snapshot()}\n'
    )
    leaf_methods = (
        "static func snapshot() -> Dictionary:\n"
        '    return {"type": typeof(state), "value": state}\n'
    )
    with (live / "handler.gd").open("a", encoding="utf-8") as file:
        file.write(
            handler_methods + "func prepare_static() -> void:\n    McpBridgeFixtureLeaf.mutate()\n"
        )
    with (live / "leaf.gd").open("a", encoding="utf-8") as file:
        file.write(
            'static var state: Dictionary = {"marker": "initial-A"}\n'
            'static func mutate() -> void: state["marker"] = "mutated-A"\n' + leaf_methods
        )
    (live / "attached.gd").write_text("@tool\nextends Node\n", encoding="utf-8")
    stage = project / "addons/.godot_ai_update/stage/addons/godot_ai"
    shutil.copytree(live, stage)
    (project / "addons/.godot_ai_update/.gdignore").write_text("", encoding="utf-8")
    (stage / "plugin.gd").write_text(PLUGIN.replace("VERSION", "4.0.5"), encoding="utf-8")
    (stage / "plugin.cfg").write_text(
        (live / "plugin.cfg").read_text(encoding="utf-8").replace("3.2.5", "4.0.5"),
        encoding="utf-8",
    )
    (stage / "handler.gd").write_text(
        '@tool\nextends RefCounted\nconst Leaf := preload("res://addons/godot_ai/leaf.gd")\n'
        'var storage: Array[String] = ["B"]\n'
        "func value() -> String: return storage[0] + Leaf.added_api()\n",
        encoding="utf-8",
    )
    (stage / "leaf.gd").write_text(
        "@tool\nclass_name McpBridgeFixtureLeaf\nextends RefCounted\n"
        'static func value() -> String: return "B"\n'
        'static func added_api() -> String: return "-new-api"\n',
        encoding="utf-8",
    )
    with (stage / "handler.gd").open("a", encoding="utf-8") as file:
        file.write(handler_methods)
    with (stage / "leaf.gd").open("a", encoding="utf-8") as file:
        file.write('static var state: Array[String] = ["B-static"]\n' + leaf_methods)
    # Deliberately collide scanner timestamp seconds; source bytes still differ.
    for source in stage.rglob("*.gd"):
        timestamp = int((live / source.relative_to(stage)).stat().st_mtime)
        os.utime(source, (timestamp, timestamp))
    if case == "success":
        following = project / "addons/.godot_ai_update/next/addons/godot_ai"
        shutil.copytree(stage, following)
        for name in ("plugin.gd", "plugin.cfg", "handler.gd", "leaf.gd"):
            path = following / name
            text = path.read_text(encoding="utf-8")
            text = (
                text.replace("4.0.5", "4.0.6").replace('"B"', '"C"').replace("B-static", "C-static")
            )
            path.write_text(text, encoding="utf-8")
            timestamp = int((live / name).stat().st_mtime)
            os.utime(path, (timestamp, timestamp))
    if case == "missing-runner":
        (live / "utils/update_activation_runner.gd").unlink()
    companion = project / "addons/companion"
    companion.mkdir()
    (companion / "plugin.cfg").write_text(
        '[plugin]\nname="Companion"\nversion="1"\nscript="plugin.gd"\n', encoding="utf-8"
    )
    (companion / "plugin.gd").write_text("@tool\nextends EditorPlugin\n", encoding="utf-8")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Bridge activation"\n'
        '[autoload]\nDriver="*res://driver.gd"\n[editor_plugins]\n'
        'enabled=PackedStringArray("res://addons/companion/plugin.cfg", '
        '"res://addons/godot_ai/plugin.cfg")\n',
        encoding="utf-8",
    )
    (project / "user.tscn").write_text(
        "[gd_scene load_steps=2 format=3]\n"
        '[ext_resource type="Script" path="res://addons/godot_ai/attached.gd" id="1"]\n'
        '[node name="UserScene" type="Node"]\nscript = ExtResource("1")\n',
        encoding="utf-8",
    )
    (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
    return project


@pytest.mark.parametrize(
    "case", ["success", "missing-runner", "wrong-hash", "backup-exists", "user-scene"]
)
def test_bridge_actual_activation_preserves_companion_and_fails_closed(
    tmp_path: Path,
    case: str,
) -> None:
    godot = godot_bin_or_skip()
    project = _project(tmp_path, case)
    environment = {"BRIDGE_CASE": case, "GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA", "HOME", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    log = run_godot_editor(
        project, godot, allow_headless=True, timeout=200, environment=environment
    )
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "result.json").read_bytes())
    assert result["before"]["value"] == "A", result
    assert result["before"]["pid"] == result["pid"], result
    assert result["before"]["companion"] and result["companion"], result
    assert not result["lock_present"], result
    assert result["retention_marker"] == (case == "success"), result
    old_state = {
        "type": 27,
        "value": {"value": "A"},
        "static": {"type": 27, "value": {"marker": "mutated-A"}},
    }
    assert result["before"]["state"] == old_state, result
    assert result["retained_alive"] and result["retained_state"] == old_state, result
    assert result["before"]["mark"] == "A:after", result
    assert result["undo_ok"] and result["undo_position"] == [0, 0], result
    assert result["redo_ok"] and result["redo_position"] == [42, 17], result
    assert result["undo_mark"] == "A:before" and result["redo_mark"] == "A:after", result
    assert result["failure"] != "test_deadline", result
    if case == "missing-runner":
        assert "activation runner is missing or invalid" in result["failure"], result
        assert result["activation"] == {} and not result["pending"], result
        assert result["instance"] == result["before"]["instance"], result
        assert result["value"] == "A" and result["enabled"], result
        assert not result["stage_present"], result
    elif case == "user-scene":
        assert result["activation"] == {}, result
        assert "open scene or resource references addon script" in result["failure"], result
        assert "res://addons/godot_ai/attached.gd" in result["failure"], result
        assert result["instance"] == result["before"]["instance"], result
        assert result["value"] == "A" and result["enabled"], result
        assert not result["pending"] and not result["stage_present"], result
        assert result["retained_script_path"] == "res://addons/godot_ai/handler.gd", result
        assert 'path="res://addons/godot_ai/attached.gd"' in (project / "user.tscn").read_text(
            encoding="utf-8"
        )
    else:
        expected = {
            "success": "success",
            "wrong-hash": "rolled_back",
            "backup-exists": "previous_tree_retained",
        }[case]
        assert result["activation"]["status"] == expected, result
        assert result["instance"] != result["before"]["instance"], result
        assert result["enabled"], result
        assert result["value"] == ("C-new-api" if case == "success" else "A"), result
        assert result["save_read"] == 0, result
        assert set(result["saved_enabled"]) == {
            "res://addons/companion/plugin.cfg",
            "res://addons/godot_ai/plugin.cfg",
        }, result
        if case == "success":
            assert result["unrelated_notifications"] > 0, result
            assert result["ordering_errors"] == [], result
            for generation, old, new in [(1, "3.2.5", "4.0.5"), (2, "4.0.5", "4.0.6")]:
                versions = [
                    entry["version"]
                    for entry in result["scan_completions"]
                    if entry["activation"] == generation
                ]
                assert len(versions) >= 2 and versions[0] == old and versions[-1] == new, result
            assert result["first_activation"]["status"] == "success", result
            assert result["first_value"] == "B-new-api", result
            assert result["first_state"] == {
                "type": 28,
                "value": ["B"],
                "static": {"type": 28, "value": ["B-static"]},
            }, result
            assert result["first_backup_exists"] and result["second_backup_exists"], result
            assert result["new_state"] == {
                "type": 28,
                "value": ["C"],
                "static": {"type": 28, "value": ["C-static"]},
            }, result
            assert result["retained_script_path"].startswith(
                "res://addons/.godot_ai_update/backup/3.2.5/"
            ), result
            assert result["activation"]["error"] == "", result
            assert "update activation completed in editor PID" in log

REFUSAL_DRIVER = '''@tool
extends Node
const LIVE := "res://addons/godot_ai"
const RUNNER := LIVE + "/utils/update_activation_runner.gd"
const STAGE := "res://addons/.godot_ai_update/stage/addons/godot_ai"
var frames := 0
func find_plugin(node: Node) -> Node:
    if node.get_script() != null and node.get_script().resource_path == LIVE + "/plugin.gd":
        return node
    for child in node.get_children():
        var found := find_plugin(child)
        if found != null: return found
    return null
func _process(_delta: float) -> void:
    frames += 1
    if frames == 45:
        run()
func run() -> void:
    var verifier = load(LIVE + "/utils/release_verifier.gd")
    var before: Dictionary = verifier.hash_tree(LIVE)
    var original := find_plugin(get_tree().root)
    var original_id := original.get_instance_id()
    var results := {}
    for case in ["outside_tree", "busy", "file_backed", "stage_root", "record", "from_version",
        "to_version", "manifest_sha256", "expected_tree_sha256", "editor_nonce",
        "replace_owned_mismatches", "installer_api", "verifier_api", "lock"]:
        var code := FileAccess.get_file_as_string(RUNNER)
        if case == "installer_api":
            code = code.replace('const INSTALLER_PATH := LIVE_ROOT + "/utils/update_installer.gd"',
                'const INSTALLER_PATH := "res://empty_api.gd"')
        if case == "verifier_api":
            code = code.replace('const VERIFIER_PATH := LIVE_ROOT + "/utils/release_verifier.gd"',
                'const VERIFIER_PATH := "res://empty_api.gd"')
        var script := GDScript.new()
        script.source_code = code
        assert(script.reload() == OK)
        var runner = load(RUNNER).new() if case == "file_backed" else script.new()
        if case != "outside_tree": get_tree().root.add_child(runner)
        if case == "busy": runner._phase = 1
        var package := {"stage_root": STAGE, "record": {"from_version": "3.2.5",
            "to_version": "4.0.5", "manifest_sha256": "a", "expected_tree_sha256": "b",
            "editor_nonce": "c", "replace_owned_mismatches": false}}
        if case == "stage_root": package.stage_root = "res://wrong"
        elif case == "record": package.record = []
        elif package.record.has(case):
            package.record[case] = "" if case != "replace_owned_mismatches" else 1
        var accepted: bool = runner.start(package)
        results[case] = {"accepted": accepted, "reason": runner.refusal_reason}
        runner.free()
    var after: Dictionary = verifier.hash_tree(LIVE)
    var file := FileAccess.open("res://refusals.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"cases": results, "before": before, "after": after,
        "same_plugin": find_plugin(get_tree().root).get_instance_id() == original_id,
        "value": original.active_value(),
        "enabled": EditorInterface.is_plugin_enabled(LIVE + "/plugin.cfg"),
        "receipt": FileAccess.file_exists("res://addons/.godot_ai_update/activation.json")}))
    get_tree().quit()
'''


def test_activation_handoff_refusals_explain_prerequisite_without_mutating_runtime(
    tmp_path: Path,
) -> None:
    godot = godot_bin_or_skip()
    project = _project(tmp_path, "refusals")
    (project / "driver.gd").write_text(REFUSAL_DRIVER, encoding="utf-8")
    (project / "empty_api.gd").write_text("@tool\nextends RefCounted\n", encoding="utf-8")
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA", "HOME", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    log = run_godot_editor(project, godot, allow_headless=True, timeout=100,
                           environment=environment)
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "refusals.json").read_bytes())
    assert result["enabled"] and result["same_plugin"] and not result["receipt"], result
    assert result["value"] == "A", result
    assert result["before"]["ok"] and result["after"]["ok"], result
    assert result["before"]["tree_sha256"] == result["after"]["tree_sha256"], result
    reasons = {"outside_tree": "scene tree", "busy": "already", "file_backed": "source-free",
               "stage_root": "stage root", "record": "record", "installer_api": "swap",
               "verifier_api": "hash_tree", "lock": "lock"}
    for name, case in result["cases"].items():
        assert not case["accepted"], (name, case)
        assert reasons.get(name, name) in case["reason"], (name, case)


def test_mixed_state_scan_skips_linked_children_but_accepts_linked_root(tmp_path: Path) -> None:
    import subprocess

    godot = godot_bin_or_skip()
    project = tmp_path / "mixed-links"
    project.mkdir()
    shutil.copy2(PLUGIN_ROOT / "utils/update_mixed_state.gd", project / "scanner.gd")
    tree = project / "ordinary"
    (tree / "nested").mkdir(parents=True)
    (tree / "nested/normal.update_backup").write_text("normal", encoding="utf-8")
    external = project / "external"
    external.mkdir()
    (external / "outside.update_backup").write_text("external", encoding="utf-8")

    def directory_link(link: Path, target: Path) -> None:
        if os.name == "nt":
            environment = os.environ.copy()
            environment.update(TEST_LINK=str(link), TEST_TARGET=str(target))
            subprocess.run([
                "powershell.exe", "-NoProfile", "-NonInteractive", "-Command",
                "New-Item -ItemType Junction -Path $env:TEST_LINK "
                "-Target $env:TEST_TARGET -ErrorAction Stop | Out-Null",
            ], env=environment, check=True, capture_output=True, timeout=20)
        else:
            link.symlink_to(target, target_is_directory=True)

    directory_link(tree / "nested/ancestor", tree)
    directory_link(tree / "outside", external)
    directory_link(project / "linked-root", tree)
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Mixed state link scan"\n'
        '[autoload]\nDriver="*res://driver.gd"\n', encoding="utf-8")
    (project / "driver.gd").write_text('''@tool
extends Node
func _ready() -> void: run.call_deferred()
func run() -> void:
    var scanner = load("res://scanner.gd")
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"ordinary": scanner.find_backups("res://ordinary"),
        "linked_root": scanner.find_backups("res://linked-root")}))
    get_tree().quit()
''', encoding="utf-8")
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA", "HOME", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    log = run_godot_editor(project, godot, allow_headless=True, timeout=25,
                           environment=environment)
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "result.json").read_bytes())
    assert result == {
        "ordinary": ["res://ordinary/nested/normal.update_backup"],
        "linked_root": ["res://linked-root/nested/normal.update_backup"],
    }
