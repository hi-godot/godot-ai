"""Godot exercises Unix startup boundaries without an external backend or GUI."""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor


def run_probe(tmp_path: Path, body: str, *, environment: dict[str, str] | None = None) -> dict:
    project = tmp_path / "project"
    project.mkdir(mode=0o700, exist_ok=True)
    project.chmod(0o700)
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    (project / "driver.gd").write_text(
        "extends SceneTree\n"
        'const Proc := preload("res://addons/godot_ai/utils/linux_proc.gd")\n'
        'const Ports := preload("res://addons/godot_ai/utils/port_resolver.gd")\n'
        'const Capability := preload("res://addons/godot_ai/utils/transport_capability.gd")\n'
        "func _initialize() -> void:\n"
        "    var result := {}\n" + body + "\n"
        '    var output := FileAccess.open("res://result.json", FileAccess.WRITE)\n'
        "    output.store_string(JSON.stringify(result))\n"
        "    output.close()\n"
        "    quit()\n",
        encoding="utf-8",
    )
    completed = subprocess.run(
        [
            godot_bin_or_skip(),
            "--headless",
            "--path",
            str(project),
            "--script",
            "res://driver.gd",
            "--log-file",
            str(project / "probe.log"),
        ],
        env={**os.environ, "GODOT_AI_DISABLE_TELEMETRY": "true", **(environment or {})},
        capture_output=True,
        text=True,
        timeout=45,
    )
    log = completed.stdout + completed.stderr
    assert completed.returncode == 0 and "SCRIPT ERROR" not in log, log
    assert (project / "result.json").exists(), log
    return json.loads((project / "result.json").read_text(encoding="utf-8"))


def proc_stat(pid=123, state="S", parent=1, start=54321):
    return f"{pid} (name with ) and ( spaces) {state} {parent} " + "0 " * 17 + f"{start} 0\n"


def test_proc_parsers_and_snapshot_reject_ambiguous_evidence(tmp_path):
    project = tmp_path / "project"
    root = project / "proc"
    (root / "123").mkdir(parents=True)
    (root / "123/stat").write_text(proc_stat())
    (root / "123/cmdline").write_bytes(b"python\0-m\0godot_ai\0--transport\0http\0")
    (root / "789").mkdir()  # An existing PID with unreadable/missing stat is unknown.
    (root / "net").mkdir()
    header = (
        "  sl  local_address rem_address st tx_queue rx_queue "
        "tr tm->when retrnsmt uid timeout inode\n"
    )
    (root / "net/tcp").write_text(
        header + " 0: 0100007F:1F40 00000000:0000 0A 0:0 00:0 0 1000 0 222 1\n"
    )
    (root / "net/tcp6").write_text(
        header + " 0: 00000000000000000000000001000000:1F40 00000000000000000000000000000000:0000 "
        "0A 0:0 00:0 0 1000 0 333 1\n"
    )
    if os.name != "nt":
        (root / "123/fd").mkdir()
        (root / "123/fd/3").symlink_to("socket:[222]")
        (root / "123/fd/4").symlink_to("socket:[333]")
    body = """    var root := ProjectSettings.globalize_path("res://proc")
    var raw := FileAccess.get_file_as_string(root.path_join("123/stat"))
    result["stat"] = Proc.parse_stat(raw, 123)
    result["wrong_pid"] = Proc.parse_stat(raw, 124)
    result["truncated"] = Proc.parse_stat("123 (name) S 1", 123)
    result["zombie"] = Proc.is_alive(Proc.parse_stat(raw.replace(") S ", ") Z "), 123))
    result["dead"] = Proc.is_alive(Proc.parse_stat(raw.replace(") S ", ") X "), 123))
    result["snapshot"] = Proc.process_snapshot(123, root)
    result["missing"] = Proc.process_snapshot(456, root)
    result["unknown"] = Proc.process_snapshot(789, root)
    result["missing_proc"] = Proc.process_snapshot(123, root.path_join("absent"))
    result["oversize"] = Proc.read_text(root.path_join("123/cmdline"), 4)
    result["tcp"] = Proc.listener_snapshot(root)
    result["pids"] = Proc.listener_pids(8000, result.tcp, root)
    result["other_port"] = Proc.listener_pids(18000, result.tcp, root)
    result["bad_table"] = Proc.parse_tcp("broken")
"""
    result = run_probe(tmp_path, body)
    assert result["stat"] == {"state": "S", "parent_pid": 1, "start": "54321"}
    assert result["wrong_pid"] == result["truncated"] == result["missing"] == {}
    assert result["unknown"] == result["missing_proc"] == {"capture_error": True}
    assert result["oversize"]["known"] is False
    assert result["zombie"] is False and result["dead"] is False
    row = result["snapshot"]["123"]
    assert row["identity"] == "linux:54321|python -m godot_ai --transport http"
    assert row["commandline"] == "python -m godot_ai --transport http"
    assert result["tcp"] == {"known": True, "listeners": {"8000": ["222", "333"]}}
    assert result["bad_table"]["known"] is False
    if os.name != "nt":
        assert result["pids"] == [123]
    assert result["other_port"] == []


@pytest.mark.skipif(os.name == "nt", reason="Unix permissions")
def test_permission_preflight_reports_all_ancestors_without_changing_them(tmp_path):
    home = tmp_path / "project/home"
    config = home / ".config"
    config.mkdir(parents=True)
    home.chmod(0o777)
    config.chmod(0o775)
    result = run_probe(
        tmp_path,
        """    var home := ProjectSettings.globalize_path("res://home")
    var config := home.path_join(".config")
    var directory := config.path_join("godot-ai/capabilities")
    result["problem"] = Capability.posix_directory_problem(directory)
    result["home_mode"] = FileAccess.get_unix_permissions(home)
    result["config_mode"] = FileAccess.get_unix_permissions(config)
    FileAccess.set_unix_permissions(home, 493)
    FileAccess.set_unix_permissions(config, 493)
    result["repaired"] = Capability.posix_directory_problem(directory)
""",
    )
    assert str(home) in result["problem"] and str(config) in result["problem"]
    assert "777" in result["problem"] and "775" in result["problem"]
    assert "chmod go-w" in result["problem"] and "recursively" in result["problem"]
    assert result["home_mode"] & 0o777 == 0o777
    assert result["config_mode"] & 0o777 == 0o775
    assert result["repaired"] == ""

