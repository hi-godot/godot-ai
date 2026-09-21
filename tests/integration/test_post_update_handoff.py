"""Exercise post-update retry timers outside the synchronous Godot test runner."""

import json
import shutil
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    PLUGIN_ROOT,
    godot_bin_or_skip,
    run_godot_editor,
)

pytestmark = pytest.mark.editor


def test_post_update_handoff_timer_consumption_exhaustion_and_stop(tmp_path: Path) -> None:
    godot = godot_bin_or_skip()
    project = tmp_path / "handoff"
    shutil.copytree(PLUGIN_ROOT, project / "addons" / "godot_ai")
    shutil.copyfile(Path(__file__).with_name("_post_update_handoff.gd"), project / "driver.gd")
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Post-update handoff timers"\n'
        '[autoload]\nDriver="*res://driver.gd"\n',
        encoding="utf-8",
    )
    environment = {"GODOT_AI_DISABLE_TELEMETRY": "true"}
    for key in ("HOME", "USERPROFILE", "APPDATA", "LOCALAPPDATA", "XDG_CONFIG_HOME"):
        directory = tmp_path / key.lower()
        directory.mkdir()
        environment[key] = str(directory)
    log = run_godot_editor(
        project, godot, allow_headless=False, timeout=60, environment=environment,
    )
    assert "SCRIPT ERROR:" not in log, log
    result = json.loads((project / "result.json").read_text(encoding="utf-8"))
    assert result["scheduled"]["episode"] > 0, result
    assert result["scheduled"]["remaining"] == 0, result
    assert result["scheduled"]["amber"] is True, result
    assert result["scheduled"]["blocked"] is True, result
    assert result["scheduled"]["transport"] == {}, result
    assert result["consumed"] == {
        "episode": 0, "phase": "PROBE", "fresh_episode": True,
        "blocked": True, "transport": {},
    }, result
    assert result["exhausted"] == {
        "episode": 0, "red": True, "state": "BLOCKED", "unchanged": True,
    }, result
    assert result["stop_scheduled"] is True, result
    assert result["stopped"] == {
        "episode": 0, "unchanged": True, "blocked": True, "transport": {},
    }, result
