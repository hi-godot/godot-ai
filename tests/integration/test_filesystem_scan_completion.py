"""Verify scan replies follow native script registration in a GUI editor."""

import shutil
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

pytestmark = pytest.mark.editor


def test_filesystem_scan_waits_for_native_completion(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "project"
    fixture = Path(__file__).parent / "fixtures" / "filesystem_scan"
    shutil.copytree(fixture, project)
    shutil.copytree(PLUGIN_ROOT, project / "addons" / "godot_ai")
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    log = run_godot_editor(
        project, godot, allow_headless=False, headless=False,
        timeout=120, environment=environment,
    )
    assert "SCAN_TEST_RESULT PASS" in log, log
    assert "SCAN_TEST FAILURE" not in log, log
    assert "SCRIPT ERROR" not in log, log
    assert "SCAN_TEST withheld completion returned timeout" in log, log
