"""Configure all uses the real job owner and preserves unrelated client data."""

import json
import shutil
import sys
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

pytestmark = pytest.mark.editor

DRIVER = '''@tool
extends Node
const Plugin = preload("res://addons/godot_ai/plugin.gd")
const Owner = preload("res://addons/godot_ai/utils/client_job_owner.gd")
const Dock = preload("res://addons/godot_ai/mcp_dock.gd")
const Config = preload("res://addons/godot_ai/client_configurator.gd")
const Registry = preload("res://addons/godot_ai/clients/_registry.gd")
const Client = preload("res://addons/godot_ai/clients/_base.gd")
const Finder = preload("res://addons/godot_ai/clients/_cli_finder.gd")
const Lock = preload("res://addons/godot_ai/utils/client_mutation_lock.gd")
var failures: Array[String] = []
var results: Array[Dictionary] = []
var mcp_results: Array[Dictionary] = []
var cancellations: Array[Dictionary] = []
var checks := 0

func _ready() -> void:
    if Engine.is_editor_hint():
        run.call_deferred()

func check(value: bool, message: String) -> void:
    checks += 1
    if not value:
        failures.append(message)

func completed(id: String, action: String, result: Dictionary, _prewarm: Dictionary) -> void:
    var entry := {"id": id, "action": action, "result": result}
    if result.get("status") == "cancelled":
        cancellations.append(entry)
    else:
        results.append(entry)

func read_config(id: String) -> Dictionary:
    return JSON.parse_string(FileAccess.get_file_as_string("res://" + id + ".json"))

func run() -> void:
    var expected_config := OS.get_environment("APPDATA")
    if OS.get_name() == "macOS":
        expected_config = OS.get_environment("HOME").path_join("Library/Application Support")
    elif OS.get_name() != "Windows":
        expected_config = OS.get_environment("XDG_CONFIG_HOME")
    if OS.get_config_dir().simplify_path() != expected_config.simplify_path() or Lock.is_locked():
        push_error("fixture config environment is not isolated or has an existing claim")
        get_tree().quit(2)
        return
    Registry._instances.clear()
    Registry._by_id.clear()
    for id in ["fixture_a", "fixture_b"]:
        var client = Client.new()
        client.id = id
        client.display_name = id
        client.config_type = "json"
        var path := ProjectSettings.globalize_path("res://" + id + ".json")
        client.path_template = {"windows": path, "unix": path}
        client.server_key_path = PackedStringArray(["mcpServers"])
        Registry._instances.append(client)
        Registry._by_id[id] = client
    for executable in ["uvx", "uvx.exe", "godot-ai", "godot-ai.exe"]:
        Finder._searched[executable] = true
        Finder._cache[executable] = ""
    Config.capture_launch_context({"http_port": 18947, "ws_port": 19947,
        "excluded_domains": "", "allow_hosts": "", "telemetry_enabled": false})
    var owner = Owner.new()
    add_child(owner)
    owner.action_completed.connect(completed)
    owner.mcp_action_completed.connect(func(id: String, payload: Dictionary) -> void:
        mcp_results.append({"id": id, "payload": payload})
    )
    var dock = Dock.new()
    add_child(dock)
    var plugin := Plugin.new()
    plugin._client_jobs = owner
    plugin._dock = dock
    dock.client_action_requested.connect(plugin._on_dock_client_action_requested)
    dock.client_action_cancel_requested.connect(plugin._on_dock_client_action_cancel_requested)
    owner.snapshot_changed.connect(plugin._on_client_work_snapshot_changed)
    owner.action_completed.connect(plugin._on_client_action_completed)
    owner.activate()
    dock.present_client_work_snapshot(owner.snapshot())
    dock._on_configure_all_clients()
    check(owner._action_threads.size() == 1, "Configure all starts exactly one worker")
    check(owner.snapshot().action_phases.get("fixture_b") == "queued", "second row is queued")
    var queued_button: Button = dock._client_rows.fixture_b.configure_btn
    check(queued_button.text == "Cancel queued" and not queued_button.disabled,
        "queued operation exposes an enabled Cancel button")
    check(dock._client_rows.fixture_b.remove_btn.disabled, "opposite queued action stays disabled")
    dock._on_configure_all_clients()
    check(owner.snapshot().action_phases.get("fixture_b") == "queued",
        "Configure all again does not interpret queued entries as Cancel clicks")
    queued_button.pressed.emit()
    check(cancellations.size() == 1, "real queued button emits one cancellation")
    if cancellations.size() == 1:
        check(cancellations[0].id == "fixture_b" and cancellations[0].action == "configure",
            "cancelled result identifies the original pending action")
    check(not owner.snapshot().busy_actions.has("fixture_b"), "cancel removes queued entry")
    check(dock._client_rows.fixture_b.status == Client.Status.NOT_CONFIGURED,
        "cancellation preserves cached client status")
    check(not dock._client_rows.fixture_b.manual_panel.visible,
        "user cancellation does not show manual repair instructions")
    check(queued_button.text == "Configure" and not queued_button.disabled,
        "cancellation restores the action button")
    var stale := owner.snapshot()
    stale.action_phases["fixture_a"] = "queued"
    dock.present_client_work_snapshot(stale)
    dock._client_rows.fixture_a.configure_btn.pressed.emit()
    check(owner._action_threads.has("fixture_a"), "stale queued click leaves running worker owned")
    check(dock._client_work_snapshot.action_phases.get("fixture_a") != "queued"
        and dock._client_rows.fixture_a.configure_btn.disabled,
        "plugin cancel callback reconciles stale Dock state from the owner")
    var busy := owner.request_mcp_action("must-not-run", "fixture_a", "remove")
    check(not busy.ok and not busy.has("deferred_timeout_ms"),
        "competing MCP request is not deferred")
    var deadline := Time.get_ticks_msec() + 15000
    while results.is_empty() and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    for frame in range(5):
        await get_tree().process_frame
    check(results.size() == 1, "only the running action completes before intentional requeue")
    check(read_config("fixture_b") == {"unrelated": "preserve-fixture_b"},
        "cancelled client file remains byte-semantically untouched before requeue")
    queued_button.pressed.emit()
    deadline = Time.get_ticks_msec() + 15000
    while results.size() < 2 and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    check(results.size() == 2, "both Configure all actions completed")
    if results.size() == 2:
        check(results[0].id == "fixture_a" and results[1].id == "fixture_b",
            "UI queue preserves order")
        check(results[0].result.status == "ok" and results[1].result.status == "ok",
            "both actual writes verified")
    check(mcp_results.is_empty(), "rejected MCP write never gets a later completion")
    for id in ["fixture_a", "fixture_b"]:
        var stored := read_config(id)
        check(stored.unrelated == "preserve-" + id, "unrelated config value survives " + id)
        check(stored.mcpServers["godot-ai"].url == "http://127.0.0.1:18947/mcp",
            "expected URL stored " + id)
    check(not Lock.is_locked(), "successful queue releases its durable claim")
    var admitted := owner.request_mcp_action("remove-a", "fixture_a", "remove")
    check(admitted.ok and admitted.deferred_timeout_ms == 80000,
        "admitted MCP retains the existing budget")
    deadline = Time.get_ticks_msec() + 15000
    while mcp_results.is_empty() and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    check(mcp_results.size() == 1, "admitted MCP completes once")
    if mcp_results.size() == 1:
        check(mcp_results[0].id == "remove-a" and mcp_results[0].payload.has("data"),
            "admitted remove succeeded")
    var removed := read_config("fixture_a")
    check(not removed.get("mcpServers", {}).has("godot-ai"),
        "remove actually deleted the owned entry")
    check(removed.unrelated == "preserve-fixture_a", "remove preserved unrelated data")
    var claim := Lock.acquire("other-owner", "configure")
    check(claim.ok, "test owns a separate durable claim")
    var before := FileAccess.get_file_as_string("res://fixture_a.json")
    var result_count := results.size()
    check(owner.request_action("fixture_a", "configure"),
        "UI request is accounted for under an existing lock")
    check(results.size() == result_count + 1, "existing lock yields an explicit UI failure")
    check(results[-1].result.status == "error", "existing lock never reports success")
    check(FileAccess.get_file_as_string("res://fixture_a.json") == before,
        "existing lock prevents writes")
    check(Lock.release(claim), "only the exact test-owned claim is released")
    var drained := owner.quiesce()
    check(drained.ok and not Lock.is_locked(), "owner drains without stranded authority")
    plugin._client_jobs = null
    plugin._dock = null
    plugin._lifecycle = null
    plugin.free()
    dock.queue_free()
    owner.queue_free()
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures,
        "results": results, "cancellations": cancellations}))
    file.close()
    get_tree().quit(0 if failures.is_empty() else 1)
'''


@pytest.mark.skipif(
    sys.platform not in {"win32", "linux", "darwin"}, reason="desktop client configuration"
)
def test_configure_all_queues_real_client_mutations(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "project"
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    (project / "project.godot").write_text(
        'config_version=5\n[autoload]\nDriver="*res://driver.gd"\n', encoding="utf-8"
    )
    (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
    for client in ("fixture_a", "fixture_b"):
        (project / f"{client}.json").write_text(
            json.dumps({"unrelated": f"preserve-{client}"}), encoding="utf-8"
        )
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA", "USERPROFILE", "HOME", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = directory.as_posix()
    log = run_godot_editor(project, godot, allow_headless=False, environment=environment)
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    assert result["checks"] >= 20, result
    assert result["failures"] == [], result
    assert len(result["cancellations"]) == 1, result
    second = json.loads((project / "fixture_b.json").read_text(encoding="utf-8"))
    assert second == {
        "unrelated": "preserve-fixture_b",
        "mcpServers": {"godot-ai": {"url": "http://127.0.0.1:18947/mcp"}},
    }
