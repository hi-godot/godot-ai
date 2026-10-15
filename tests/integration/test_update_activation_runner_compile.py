"""Compiler-backed coverage for the self-update activation runner (#1158)."""

import shutil
import subprocess
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor

PROJECT_SETTINGS = """\
config_version=5

[application]
config/name="activation-runner-check"
{debug_section}"""

STRICT_DEBUG_SECTION = """
[debug]
gdscript/warnings/untyped_declaration=2
gdscript/warnings/unreachable_code=2
"""

# plugin.gd compiles the runner from source with no resource_path, so
# debug/gdscript/warnings/exclude_addons does not cover it and the project's
# warning levels apply to it as they do to the project's own scripts.
CHECK_SCRIPT = """\
extends SceneTree


func _initialize() -> void:
	var script := GDScript.new()
	script.source_code = FileAccess.get_file_as_string(
		"res://addons/godot_ai/utils/update_activation_runner.gd"
	)
	var error := script.reload()
	if error != OK:
		push_error("activation runner failed to compile: %d" % error)
	else:
		print("ACTIVATION_RUNNER_COMPILES")
	quit(0 if error == OK else 1)
"""


@pytest.mark.parametrize(
    "debug_section",
    [STRICT_DEBUG_SECTION, ""],
    ids=["strict_warnings_as_errors", "default_warnings"],
)
def test_activation_runner_compiles_source_free(tmp_path: Path, debug_section: str) -> None:
    """The runner must compile the way plugin.gd compiles it, in a project that
    treats untyped declarations as errors and in a default one."""
    godot = godot_bin_or_skip()
    project = tmp_path / "runner-project"
    project.mkdir()
    (project / "project.godot").write_text(
        PROJECT_SETTINGS.format(debug_section=debug_section), encoding="utf-8"
    )

    addons = project / "addons"
    addons.mkdir()
    shutil.copytree(PLUGIN_ROOT, addons / "godot_ai")

    (project / "check.gd").write_text(CHECK_SCRIPT, encoding="utf-8")

    result = subprocess.run(
        [godot, "--headless", "--path", str(project), "--script", "res://check.gd"],
        capture_output=True,
        text=True,
        timeout=60,
    )

    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "ACTIVATION_RUNNER_COMPILES" in result.stdout, output
