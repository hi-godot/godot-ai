from __future__ import annotations

import os
import shutil
import subprocess
import zipfile
from importlib.machinery import SourceFileLoader
from pathlib import Path, PurePosixPath
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT = ROOT / "plugin" / "addons" / "godot_ai"
SCRIPT = ROOT / "script" / "local-self-update-smoke"

TEST_ZIP_DIR = "_test_update_zip"
TEST_ZIP_NAME = "godot-ai-plugin.zip"
TEST_ZIP_RES_PATH = f"res://{TEST_ZIP_DIR}/{TEST_ZIP_NAME}"
TEST_TEMP_DIR = "user://godot_ai_self_update_upgrade_test/"
TEST_HTTP_PORT = 18100
TEST_WS_PORT = 19600

PARSE_ERROR_PATTERNS = (
    "SCRIPT ERROR: Parse Error",
    "ERROR: Failed to load script",
    "Could not resolve script",
)


def load_smoke_script() -> ModuleType:
    loader = SourceFileLoader("local_self_update_smoke_for_tests", str(SCRIPT))
    module = ModuleType(loader.name)
    module.__file__ = str(SCRIPT)
    loader.exec_module(module)
    return module


def godot_bin_or_skip() -> str:
    godot_bin = os.environ.get("GODOT_BIN", "")
    if not godot_bin:
        pytest.skip("GODOT_BIN is not set; skipping Godot self-update integration test")
    candidate = Path(godot_bin).expanduser()
    if candidate.exists() or candidate.is_absolute() or "/" in godot_bin or "\\" in godot_bin:
        resolved = candidate
    else:
        found = shutil.which(godot_bin)
        resolved = Path(found) if found is not None else None
    if resolved is None or not resolved.exists():
        pytest.skip(f"GODOT_BIN does not resolve to an executable: {godot_bin}")
    return str(resolved)


def read_plugin_version(plugin_cfg: Path) -> str:
    smoke = load_smoke_script()
    return smoke.read_plugin_version(plugin_cfg)


def prepare_project_shell(project_dir: Path) -> None:
    smoke = load_smoke_script()
    project_dir.mkdir(parents=True)
    smoke.write_project_files(project_dir)
    append_driver_autoload(project_dir / "project.godot")
    (project_dir / TEST_ZIP_DIR).mkdir()


def append_driver_autoload(project_file: Path) -> None:
    text = project_file.read_text(encoding="utf-8")
    text += '\n[autoload]\n_SelfUpdateRunnerDriver="*res://_test_runner_driver.gd"\n'
    project_file.write_text(text, encoding="utf-8")


def copy_addon_tree(source: Path, target: Path) -> None:
    smoke = load_smoke_script()
    shutil.copytree(source, target, ignore=smoke.copy_ignore)


def patch_fixture_addon(
    addon_dir: Path,
    *,
    version: str,
    server_version: str,
    next_version: str,
    skip_server_start: bool,
) -> None:
    smoke = load_smoke_script()
    smoke.patch_fixture_plugin(
        addon_dir,
        version=version,
        server_version=server_version,
        http_port=TEST_HTTP_PORT,
        ws_port=TEST_WS_PORT,
        force_local_update=False,
        next_version=next_version,
    )
    if skip_server_start:
        patch_server_start_noop(addon_dir / "plugin.gd")


def patch_server_start_noop(plugin_gd: Path) -> None:
    smoke = load_smoke_script()
    text = plugin_gd.read_text(encoding="utf-8")
    text = smoke.replace_function(
        text,
        "func _start_server() -> void:",
        """func _start_server() -> void:
\tprint("MCP | self-update upgrade test: server start skipped")""",
    )
    plugin_gd.write_text(text, encoding="utf-8")


def create_plugin_zip(addon_dir: Path, zip_path: Path) -> None:
    smoke = load_smoke_script()
    smoke.create_plugin_zip(addon_dir, zip_path)


def write_forward_driver(project_dir: Path) -> None:
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
\t# `prime_class_cache()` sets this env var so its `--headless --import` /
\t# `--headless --editor` pass populates `.godot/global_script_class_cache.cfg`
\t# without triggering the runner. The actual editor pass that DOES want to
\t# drive the runner runs without this env var, even when also headless.
\tif OS.get_environment("_SELF_UPDATE_DRIVER_SKIP") == "1":
\t\tqueue_free()
\t\treturn
\tset_process(true)


func _process(_delta: float) -> void:
\tif _finished:
\t\treturn
\t_frames += 1
\tif not _started and _frames >= START_AFTER_FRAMES:
\t\t_start_runner()
\t\treturn
\tif _started:
\t\tif not is_instance_valid(_runner):
\t\t\t_validate_install()
\t\t\treturn
\t\tif _frames > MAX_FRAMES:
\t\t\tpush_error("SELF_UPDATE_TEST | runner timed out")
\t\t\t_finished = true
\t\t\tget_tree().quit(10)


func _start_runner() -> void:
\t_started = true
\tprint("SELF_UPDATE_TEST | starting runner")
\tvar Runner := load("res://addons/godot_ai/update_reload_runner.gd")
\tif Runner == null:
\t\tpush_error("SELF_UPDATE_TEST | failed to load runner")
\t\t_finished = true
\t\tget_tree().quit(11)
\t\treturn
\t_runner = Runner.new()
\tget_tree().root.add_child(_runner)
\t_runner.start(ZIP_PATH, TEMP_DIR, null)


func _validate_install() -> void:
\t_finished = true
\tvar Handler := load(
\t\t"res://addons/godot_ai/handlers/self_update_synthetic_next.gd"
\t)
\tif Handler == null:
\t\tpush_error("SELF_UPDATE_TEST | synthetic handler failed to load")
\t\tget_tree().quit(12)
\t\treturn
\tvar marker: String = Handler.marker()
\tprint("SELF_UPDATE_TEST | synthetic handler marker %s" % marker)
\tget_tree().quit(0)
""",
        encoding="utf-8",
    )


def prime_class_cache(project_dir: Path, godot_bin: str, timeout: int = 60) -> None:
    """Headless `--import` pass to populate `.godot/global_script_class_cache.cfg`.

    Without this, the editor pass starts with an empty class registry, the
    editor's first scan happens concurrently with the autoload kicking off
    the runner, and the registry-skew window the historical-constraint test
    relies on never opens.

    Sets `_SELF_UPDATE_DRIVER_SKIP=1` so the autoload skips its runner work
    during this warmup pass. The real editor pass that follows leaves the
    env var unset, so the autoload runs normally there.
    """
    env = os.environ.copy()
    env["_SELF_UPDATE_DRIVER_SKIP"] = "1"
    proc = subprocess.run(
        [godot_bin, "--headless", "--import", "--path", str(project_dir)],
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=timeout,
    )
    assert proc.returncode == 0, proc.stdout


def run_godot_editor(
    project_dir: Path,
    godot_bin: str,
    *,
    allow_headless: bool,
    headless: bool = True,
) -> str:
    env = os.environ.copy()
    if allow_headless:
        env["GODOT_AI_ALLOW_HEADLESS"] = "1"
    else:
        env.pop("GODOT_AI_ALLOW_HEADLESS", None)
    command = [godot_bin]
    if headless:
        command.append("--headless")
    command.extend(["--path", str(project_dir), "--editor"])
    # MERGE stderr into stdout at the kernel level so the captured `output`
    # is a single chronologically-ordered stream. `capture_output=True` would
    # produce SEPARATE stdout/stderr buffers; concatenating them yields an
    # "all-stdout-then-all-stderr" string with no time-ordering. The window
    # markers below (`MCP | update runner disabling old plugin`,
    # `MCP | plugin loaded`) are stdout-only, so a marker-bracketed window
    # against an unmerged buffer can never see stderr-routed parse errors
    # like `SCRIPT ERROR: Parse Error` (emitted via `OS::print_error`). The
    # forward regression test in `test_self_update_upgrade_paths.py` would
    # then silently pass while a reverted-to-two-phase runner shipped parse
    # errors. Same reason existing CI scripts (.github/workflows/ci.yml)
    # use `> log 2>&1`. Do not change without also fixing those scans.
    proc = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=90,
    )
    output = proc.stdout
    assert proc.returncode == 0, output
    return output


def assert_no_update_parse_errors(log: str) -> None:
    start = log.find("MCP | update runner disabling old plugin")
    assert start >= 0, log
    end = log.find("MCP | plugin loaded", start)
    assert end >= 0, log
    window = log[start:end]
    offenders = [pattern for pattern in PARSE_ERROR_PATTERNS if pattern in window]
    assert not offenders, (
        f"Unexpected parse/load errors during self-update window {offenders}:\n{window}"
    )


def extract_addon_from_zip(zip_path: Path, target_addon: Path) -> None:
    target_addon.mkdir(parents=True)
    target_resolved = target_addon.resolve()
    with zipfile.ZipFile(zip_path) as zf:
        for info in zf.infolist():
            if not info.filename.startswith("addons/godot_ai/") or info.is_dir():
                continue
            raw_filename = getattr(info, "orig_filename", info.filename)
            # ZIP spec uses POSIX-style forward-slash separators; parsing the
            # member name as PurePosixPath stops a Windows host from
            # reinterpreting an entry like "addons/godot_ai/C:evil.txt" as a
            # drive component (which would make `target_addon / rel` discard
            # the prefix and write outside the fixture).
            if "\\" in raw_filename or "\\" in info.filename:
                raise ValueError(f"Refusing unsafe zip entry {raw_filename!r}: contains backslash")
            rel = PurePosixPath(info.filename).relative_to("addons/godot_ai")
            if rel.is_absolute() or any(part in ("", ".", "..") for part in rel.parts):
                raise ValueError(
                    f"Refusing unsafe zip entry {info.filename!r}: relative path "
                    f"{rel!s} contains absolute or traversal segments"
                )
            out = target_addon.joinpath(*rel.parts)
            # Belt-and-suspenders containment: if the resolved output path
            # would escape target_addon (e.g. an OS-specific path-parsing
            # quirk we didn't anticipate), refuse the entry.
            candidate = out if out.exists() else target_resolved / Path(*rel.parts)
            resolved = candidate.resolve()
            if not resolved.is_relative_to(target_resolved):
                raise ValueError(
                    f"Refusing unsafe zip entry {info.filename!r}: resolved "
                    f"output {resolved!s} escapes target {target_resolved!s}"
                )
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes(zf.read(info.filename))


def release_zip_from_cache(cache_dir: Path, tag: str) -> Path | None:
    candidates = [
        cache_dir / tag / TEST_ZIP_NAME,
        cache_dir / f"{tag}.zip",
        cache_dir / f"godot-ai-plugin-{tag}.zip",
        cache_dir / f"{tag}-godot-ai-plugin.zip",
    ]
    return next((path for path in candidates if path.is_file()), None)
