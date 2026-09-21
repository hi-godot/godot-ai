"""The generated updater driver publishes one stable pre-update receipt."""

import os
import re
import time
from pathlib import Path

import pytest

from tests.integration import _self_update_fixture as fixture

pytestmark = pytest.mark.editor


def test_pre_instance_receipt_is_stable_while_agent_gate_is_pending(tmp_path: Path):
    godot = fixture.godot_bin_or_skip()
    project = tmp_path / "project"
    project.mkdir()
    fixture.write_install_update_driver(
        project, http_port=18969, base_version="4.0.4", next_version="4.1.0",
        agent_gate=True,
    )
    support = project / "_test_self_update_driver_support.gd"
    source = support.read_text(encoding="utf-8")
    source, replaced = re.subn(
        r'static func fetch_status\([^\n]+\n.*?(?=\nstatic func |\Z)',
        'static func fetch_status(_port: int) -> Dictionary:\n'
        '\treturn {"instance_id": "fixture-nonce"}\n\n',
        source, count=1, flags=re.DOTALL,
    )
    assert replaced == 1
    support.write_text(source, encoding="utf-8")
    (project / "observer.gd").write_text('''@tool
extends Node
var observed := 0
func _process(_delta: float) -> void:
    if FileAccess.file_exists("res://_test_pre_instance_id.txt"):
        observed += 1
    if observed >= 120 and FileAccess.file_exists("res://%s"):
        var result := FileAccess.open("res://observed.txt", FileAccess.WRITE)
        result.store_string(str(observed))
        result.close()
        get_tree().quit()
''' % fixture.POST_UPDATE_TOOL_PROBE_FILE, encoding="utf-8")
    (project / "project.godot").write_text('''config_version=5
[autoload]
Driver="*res://_test_runner_driver.gd"
Observer="*res://observer.gd"
''', encoding="utf-8")
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME", "XDG_DATA_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    observations = []

    def inspect_receipt():
        receipt = project / fixture.PRE_INSTANCE_ID_FILE
        assert receipt.read_text(encoding="utf-8") == "fixture-nonce"
        os.utime(receipt, ns=(1_000_000_000, 1_000_000_000))
        before = receipt.stat().st_mtime_ns
        time.sleep(0.5)
        assert receipt.stat().st_mtime_ns == before
        assert receipt.read_text(encoding="utf-8") == "fixture-nonce"
        assert not (project / fixture.AGENT_ATTACHED_FILE).exists()
        observations.append(True)

    log = fixture.run_godot_editor(
        project, godot, allow_headless=True, environment=environment,
        live_probe=inspect_receipt, probe_ready_file=fixture.PRE_INSTANCE_ID_FILE,
    )
    assert "SCRIPT ERROR" not in log, log
    assert observations == [True]
    assert int((project / "observed.txt").read_text(encoding="utf-8")) >= 120
