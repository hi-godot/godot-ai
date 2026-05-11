from __future__ import annotations

import os
import shutil
from pathlib import Path

import pytest

from tests.integration._self_update_fixture import (
    TEST_TEMP_DIR,
    TEST_ZIP_NAME,
    TEST_ZIP_RES_PATH,
    extract_addon_from_zip,
    godot_bin_or_skip,
    patch_server_start_noop,
    prepare_project_shell,
    prime_class_cache,
    release_zip_from_cache,
    run_godot_editor,
)

pytestmark = pytest.mark.historical_constraint


def test_v232_runner_documents_v240_parse_errors(tmp_path: Path) -> None:
    """Documentation-only historical constraint.

    This is intentionally green when the old v2.3.2 two-phase runner emits
    the #398 parse errors while upgrading to v2.4.0. It is skipped by default
    because PRs in current source cannot retroactively fix already-shipped
    runners.
    """

    if os.environ.get("RUN_HISTORICAL_SELF_UPDATE") != "1":
        pytest.skip("set RUN_HISTORICAL_SELF_UPDATE=1 to run historical constraint test")

    godot_bin = godot_bin_or_skip()
    cache_dir = Path(
        os.environ.get("GODOT_AI_RELEASE_ZIP_CACHE", Path.cwd() / ".release-zip-cache")
    )
    base_zip = release_zip_from_cache(cache_dir, "v2.3.2")
    next_zip = release_zip_from_cache(cache_dir, "v2.4.0")
    if base_zip is None or next_zip is None:
        pytest.skip("cached v2.3.2 and v2.4.0 godot-ai-plugin.zip artifacts are required")

    project = tmp_path / "self-update-historical"
    prepare_project_shell(project)
    write_historical_driver(project)
    base_addon = project / "addons" / "godot_ai"
    extract_addon_from_zip(base_zip, base_addon)
    patch_server_start_noop(base_addon / "plugin.gd")
    shutil.copy2(next_zip, project / "_test_update_zip" / TEST_ZIP_NAME)

    # Warm `.godot/global_script_class_cache.cfg` against the v2.3.2 base so
    # the editor pass starts with the v2.3.2 McpErrorCodes registration in
    # place. Without this, the editor's first scan races the autoload-driven
    # runner and the registry-skew window the bug depends on never opens.
    prime_class_cache(project, godot_bin)

    log = run_godot_editor(project, godot_bin, allow_headless=True, headless=False)

    assert "SELF_UPDATE_HISTORICAL | runner finished" in log
    assert "SCRIPT ERROR: Parse Error" in log
    assert "Cannot find member" in log
    assert "McpErrorCodes" in log


def write_historical_driver(project_dir: Path) -> None:
    (project_dir / "_test_runner_driver.gd").write_text(
        f"""@tool
extends Node

const ZIP_PATH := "{TEST_ZIP_RES_PATH}"
const TEMP_DIR := "{TEST_TEMP_DIR}"
const START_AFTER_FRAMES := 15
const MAX_FRAMES := 900

var _frames := 0
var _started := false
var _finished := false
var _runner = null


func _ready() -> void:
\tif not Engine.is_editor_hint():
\t\tqueue_free()
\t\treturn
\t# Warmup passes set this so `prime_class_cache()` can populate the script
\t# class registry without triggering the runner. Real editor passes leave
\t# it unset, so the autoload runs even when --headless is in use.
\tif OS.get_environment("_SELF_UPDATE_DRIVER_SKIP") == "1":
\t\tqueue_free()
\t\treturn
\tset_process(true)


func _process(_delta: float) -> void:
\tif _finished:
\t\treturn
\t_frames += 1
\tif not _started and _frames >= START_AFTER_FRAMES:
\t\t_started = true
\t\tprint("SELF_UPDATE_HISTORICAL | starting runner")
\t\tvar Runner := load("res://addons/godot_ai/update_reload_runner.gd")
\t\tif Runner == null:
\t\t\tpush_error("SELF_UPDATE_HISTORICAL | failed to load runner")
\t\t\t_finished = true
\t\t\tget_tree().quit(11)
\t\t\treturn
\t\t_runner = Runner.new()
\t\tget_tree().root.add_child(_runner)
\t\t_runner.start(ZIP_PATH, TEMP_DIR, null)
\t\treturn
\tif _started:
\t\tif not is_instance_valid(_runner):
\t\t\t_finished = true
\t\t\tprint("SELF_UPDATE_HISTORICAL | runner finished")
\t\t\tget_tree().quit(0)
\t\t\treturn
\t\tif _frames > MAX_FRAMES:
\t\t\tpush_error("SELF_UPDATE_HISTORICAL | runner timed out")
\t\t\t_finished = true
\t\t\tget_tree().quit(10)
""",
        encoding="utf-8",
    )
