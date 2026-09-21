"""Real EditorSettings and sockets exercise the optional major-upgrade endpoint pair."""

import json
import shutil
import socket
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
const Config := preload("res://addons/godot_ai/client_configurator.gd")
const Reservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")
const Ports := preload("res://addons/godot_ai/utils/port_resolver.gd")
var failures: Array[String] = []
var checks := 0

func _ready() -> void:
    if Engine.is_editor_hint():
        run.call_deferred()

func check(value: bool, message: String) -> void:
    checks += 1
    if not value:
        failures.append(message)

func run() -> void:
    var es := EditorInterface.get_editor_settings()
    var old_http := int(OS.get_environment("OLD_HTTP_PORT"))
    var old_ws := int(OS.get_environment("OLD_WS_PORT"))
    es.set_setting("godot_ai/http_port", old_http)
    es.set_setting("godot_ai/ws_port", old_ws)
    es.erase(Config.SETTING_V4_ENDPOINT_PORTS)
    Config.ensure_settings_registered()
    check(not es.has_setting(Config.SETTING_V4_ENDPOINT_PORTS),
        "registration must not seed an override")
    check(Config.http_port() == old_http and Config.ws_port() == old_ws,
        "historical custom pair retained")
    var queries := Reservation.netsh_query_count()
    for versions in [["4.0.4", "4.0.5"], ["", "4.0.4"], ["invalid", "4.0.4"], ["3.2.5", "3.2.6"]]:
        var unchanged := Config.prepare_major_upgrade_endpoints(versions[0], versions[1])
        check(unchanged.ok and not unchanged.changed, "non-major migration is inert")
    check(Reservation.netsh_query_count() == queries,
        "non-major migration does not query reservations")
    check(not es.has_setting(Config.SETTING_V4_ENDPOINT_PORTS),
        "non-major migration does not write override")
    var legacy_edit := Config.apply_endpoint_settings({"http_port": old_http})
    check(legacy_edit.ok and not es.has_setting(Config.SETTING_V4_ENDPOINT_PORTS),
        "ordinary legacy edits stay legacy")

    for invalid in [null, {}, [], {"http_port": old_http},
        {"http_port": old_http, "ws_port": old_ws, "extra": 1},
        {"http_port": true, "ws_port": old_ws},
        {"http_port": 1500.5, "ws_port": old_ws},
        {"http_port": NAN, "ws_port": old_ws},
        {"http_port": 0, "ws_port": old_ws},
        {"http_port": 65536, "ws_port": old_ws},
        {"http_port": old_http, "ws_port": old_http}]:
        es.set_setting(Config.SETTING_V4_ENDPOINT_PORTS, invalid)
        # EditorSettings removes a setting assigned null; absence is intentional.
        if not es.has_setting(Config.SETTING_V4_ENDPOINT_PORTS):
            continue
        var status := Config.v4_endpoint_ports_status()
        check(not status.ok and status.present and not str(status.error).is_empty(),
            "invalid present pair has explicit error")
        check(Config.http_port() == 0 and Config.ws_port() == 0, "invalid pair must not fall back")
        var refused := Config.prepare_major_upgrade_endpoints("3.2.5", "4.0.4")
        check(not refused.ok, "major upgrade refuses invalid stored override")
    check(Reservation.netsh_query_count() == queries, "invalid stored pair must not query OS")
    es.erase(Config.SETTING_V4_ENDPOINT_PORTS)
    var selected := Config.prepare_major_upgrade_endpoints("3.2.5", "4.0.4")
    check(selected.ok and selected.get("changed", false),
        "major migration selects a pair despite occupied legacy ports")
    if selected.ok:
        var pair: Dictionary = es.get_setting(Config.SETTING_V4_ENDPOINT_PORTS)
        check(pair.size() == 2 and pair.http_port != pair.ws_port,
            "one complete distinct pair is stored")
        for port in [pair.http_port, pair.ws_port]:
            check(port not in [old_http, old_ws], "both new ports exclude both legacy ports")
            check(Ports.can_bind_local_port(port), "selected new port is bindable")
        check(Config.http_port() == pair.http_port and Config.ws_port() == pair.ws_port,
            "effective reads use selected pair")
        queries = Reservation.netsh_query_count()
        var repeated := Config.prepare_major_upgrade_endpoints("3.2.5", "4.0.4")
        check(repeated.ok and not repeated.changed, "repeated migration reuses persisted choice")
        check(Reservation.netsh_query_count() == queries, "reuse does not probe or reallocate")
        var changed := Config.apply_endpoint_settings({"http_port": old_http})
        check(changed.ok and Config.http_port() == old_http and Config.ws_port() == pair.ws_port,
            "port delta merges effective pair")
        var before: Dictionary = es.get_setting(Config.SETTING_V4_ENDPOINT_PORTS).duplicate()
        var refused := Config.apply_endpoint_settings({"ws_port": old_http})
        check(not refused.ok and es.get_setting(Config.SETTING_V4_ENDPOINT_PORTS) == before,
            "equal-port edit is atomic refusal")
        var other := Config.apply_endpoint_settings({"telemetry_enabled": false})
        check(other.ok and es.get_setting(Config.SETTING_V4_ENDPOINT_PORTS) == before,
            "non-port edit does not change pair")
    check(int(es.get_setting("godot_ai/http_port")) == old_http
        and int(es.get_setting("godot_ai/ws_port")) == old_ws,
        "major migration and override edits leave legacy settings intact")
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify({"checks": checks, "failures": failures}))
    get_tree().quit()
'''


def test_optional_v4_endpoint_pair_preserves_legacy_and_refuses_malformed(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "endpoint-settings"
    shutil.copytree(PLUGIN_ROOT, project / "addons" / "godot_ai")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Endpoint settings test"\n'
        '[autoload]\nEndpointDriver="*res://driver.gd"\n', encoding="utf-8",
    )
    (project / "driver.gd").write_text(DRIVER, encoding="utf-8")
    environment = {
        "APPDATA": str(tmp_path / "roaming"), "LOCALAPPDATA": str(tmp_path / "local"),
        "XDG_CONFIG_HOME": str(tmp_path / "config"), "HOME": str(tmp_path / "home"),
        "GODOT_AI_DISABLE_TELEMETRY": "true",
    }
    for key in ("APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "HOME"):
        Path(environment[key]).mkdir()
    with socket.socket() as http_socket, socket.socket() as ws_socket:
        http_socket.bind(("127.0.0.1", 0))
        ws_socket.bind(("127.0.0.1", 0))
        http_socket.listen()
        ws_socket.listen()
        environment.update(OLD_HTTP_PORT=str(http_socket.getsockname()[1]),
                           OLD_WS_PORT=str(ws_socket.getsockname()[1]))
        log = run_godot_editor(project, godot, allow_headless=False, timeout=90,
                               environment=environment)
    assert "SCRIPT ERROR:" not in log
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    assert result["failures"] == [], result
    assert result["checks"] >= 45, result


@pytest.mark.skipif(sys.platform != "win32", reason="Windows reservation query")
@pytest.mark.parametrize("query_fails,bindable", [
    pytest.param(False, True, id="reserved-range"),
    pytest.param(True, False, id="failed-query-occupied"),
    pytest.param(True, True, id="failed-query-two-free"),
])
def test_major_upgrade_skips_reserved_ranges_without_repeated_failed_queries(
    tmp_path: Path,
    query_fails: bool,
    bindable: bool,
) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "reserved-range"
    addon = project / "addons/godot_ai"
    shutil.copytree(PLUGIN_ROOT, addon)
    reservation = addon / "utils/windows_port_reservation.gd"
    source = reservation.read_text(encoding="utf-8")
    source = source.replace(
        'return OS.execute("netsh", NETSH_ARGS, output, true)',
        "return 1"
        if query_fails
        else 'output.append(OS.get_environment("EXCLUDED_TABLE"))\n\treturn 0',
    )
    reservation.write_text(source, encoding="utf-8")
    driver = """@tool
extends Node
const Config := preload("res://addons/godot_ai/client_configurator.gd")
const Reservation := preload("res://addons/godot_ai/utils/windows_port_reservation.gd")
func _ready() -> void:
    if Engine.is_editor_hint(): run.call_deferred()
func run() -> void:
    var base := int(OS.get_environment("PORT_BASE"))
    var settings := EditorInterface.get_editor_settings()
    settings.set_setting("godot_ai/http_port", base)
    settings.set_setting("godot_ai/ws_port", base + 103)
    settings.erase(Config.SETTING_V4_ENDPOINT_PORTS)
    Reservation._clear_cache_for_tests()
    var before := Reservation.netsh_query_count()
    var result := Config.prepare_major_upgrade_endpoints("3.2.5", "4.0.4")
    result["queries"] = Reservation.netsh_query_count() - before
    result["present"] = settings.has_setting(Config.SETTING_V4_ENDPOINT_PORTS)
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(result))
    get_tree().quit()
"""
    (project / "driver.gd").write_text(driver, encoding="utf-8")
    (project / "project.godot").write_text(
        'config_version=5\n[autoload]\nDriver="*res://driver.gd"\n',
        encoding="utf-8",
    )
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA", "HOME", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    held: list[socket.socket] = []
    try:
        for base in range(23000, 50000, 107):
            try:
                for port in range(base, base + 104):
                    probe = socket.socket()
                    held.append(probe)
                    probe.bind(("127.0.0.1", port))
                    probe.listen()
                break
            except OSError:
                for probe in held:
                    probe.close()
                held.clear()
        else:
            pytest.fail("No free test port range available")
        if bindable:
            # The failed query still reaches the final recheck of both ports.
            held[1].close()
            held[2 if query_fails else 102].close()
        environment.update(PORT_BASE=str(base), EXCLUDED_TABLE=f"{base + 2} {base + 101}")
        log = run_godot_editor(
            project,
            godot,
            allow_headless=True,
            timeout=90,
            environment=environment,
        )
    finally:
        for probe in held:
            probe.close()
    assert "SCRIPT ERROR" not in log, log
    result = json.loads((project / "result.json").read_bytes())
    if not bindable:
        assert not result["ok"] and not result["present"], result
    else:
        assert result["ok"] and result["present"], result
        expected_pair = (base + 1, base + (2 if query_fails else 102))
        assert (result["http_port"], result["ws_port"]) == expected_pair, result
    assert result["queries"] == 1, result


def test_client_port_suite_restores_absent_valid_and_malformed_v4_settings(tmp_path: Path) -> None:
    project = tmp_path / "client-port-suite"
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    shutil.copyfile(
        PLUGIN_ROOT.parents[2] / "test_project/tests/test_clients.gd", project / "client_suite.gd",
    )
    (project / "project.godot").write_text(
        'config_version=5\n[autoload]\nDriver="*res://driver.gd"\n', encoding="utf-8",
    )
    (project / "driver.gd").write_text('''@tool
extends Node
const Suite = preload("res://client_suite.gd")
const Config = preload("res://addons/godot_ai/client_configurator.gd")
func _ready() -> void:
    if Engine.is_editor_hint(): run.call_deferred()
func run() -> void:
    var settings := EditorInterface.get_editor_settings()
    var rows := []
    for seed in [null, {"http_port": 18231, "ws_port": 19231},
            {"http_port": "malformed", "nested": [1, 2]}]:
        if seed == null:
            settings.erase(Config.SETTING_V4_ENDPOINT_PORTS)
        else:
            settings.set_setting(Config.SETTING_V4_ENDPOINT_PORTS, seed.duplicate(true))
        var suite = Suite.new()
        suite.suite_setup({})
        if seed != null:
            var live: Dictionary = settings.get_setting(Config.SETTING_V4_ENDPOINT_PORTS)
            live["http_port"] = 18299
        suite.test_http_port_defaults_when_setting_absent()
        suite.test_ws_port_defaults_when_setting_absent()
        suite.test_http_port_reads_configured_value()
        suite.test_ws_port_reads_configured_value()
        suite.suite_teardown()
        var present := settings.has_setting(Config.SETTING_V4_ENDPOINT_PORTS)
        rows.append({"seed": seed, "present": present,
            "restored": settings.get_setting(Config.SETTING_V4_ENDPOINT_PORTS) if present else null,
            "failed": suite._failed, "message": suite._message,
            "assertions": suite._assertion_count})
    var file := FileAccess.open("res://result.json", FileAccess.WRITE)
    file.store_string(JSON.stringify(rows))
    file.close()
    get_tree().quit()
''', encoding="utf-8")
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA", "HOME", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    log = run_godot_editor(
        project, godot_bin_or_skip(), allow_headless=True, environment=environment,
    )
    assert "SCRIPT ERROR" not in log, log
    rows = json.loads((project / "result.json").read_bytes())
    assert len(rows) == 3, rows
    for row in rows:
        assert not row["failed"] and row["assertions"] >= 6, row
        assert row["present"] == (row["seed"] is not None), row
        assert row["restored"] == row["seed"], row
