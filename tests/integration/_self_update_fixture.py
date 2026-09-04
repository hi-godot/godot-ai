from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path
from types import ModuleType
from typing import Callable

import pytest

ROOT = Path(__file__).resolve().parents[2]
PLUGIN_ROOT = ROOT / "plugin" / "addons" / "godot_ai"
SCRIPT = ROOT / "script" / "local-self-update-smoke"

LIVE_HTTP_PORT = 18210
LIVE_WS_PORT = 19710
POST_UPDATE_STATUS_FILE = "_test_post_update_status.json"
POST_UPDATE_TOOL_PROBE_FILE = "_test_post_update_tool_probe.done"
CLEAN_MAJOR_STATUS_FILE = "_test_clean_major_status.json"
CLEAN_MAJOR_TOOL_PROBE_FILE = "_test_clean_major_tool_probe.done"
CLEAN_MAJOR_MARKER_RELATIVE = Path("addons/.godot_ai_update/pending.json")
UPDATE_STATE_RELATIVE = Path("addons/.godot_ai_update")
POST_UPDATE_COMPLETE_FILE = "_test_post_update_complete.done"
INITIAL_EDITOR_RECEIPT = "_test_initial_editor.json"
RESTARTED_EDITOR_RECEIPT = "_test_restarted_editor.json"
PRE_INSTANCE_ID_FILE = "_test_pre_instance_id.txt"
RESTARTED_EDITOR_LOG = "_test_restarted_editor.log"

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


def _path_is_file(path: Path) -> bool:
    try:
        return path.is_file()
    except OSError:
        return False


def _is_windows() -> bool:
    """Host check isolated so tests can fake Windows without patching ``os.name``.

    ``os.name`` is the real ``os`` module attribute. Patching it on Linux makes
    ``pathlib.Path`` construct ``WindowsPath`` and crashes the pytest session
    (``NotImplementedError`` during report/cache writes).
    """
    return os.name == "nt"


def _windows_godot_fallbacks(name: str) -> Path | None:
    """Resolve ``GODOT_BIN=godot`` on Windows CI.

    chickensoft ``setup-godot`` adds ``~/bin`` to PATH and hard-links the
    real ``Godot_v*_win64.exe`` as an *extensionless* ``godot`` alias, then
    exports ``GODOT`` / ``GODOT4`` to that path. Git Bash can invoke
    ``godot``; ``shutil.which("godot")`` does not (PATHEXT is ``.exe``-only).
    Skipping would hide a missing engine (#917); failing without this
    lookup fails CI even when the engine is present.
    """
    names = [name]
    if not name.lower().endswith(".exe"):
        names.append(f"{name}.exe")

    for candidate in names:
        found = shutil.which(candidate)
        if found is not None:
            path = Path(found)
            if _path_is_file(path):
                return path

    # shutil.which skips extensionless files; walk PATH for the alias.
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        if not directory:
            continue
        folder = Path(directory)
        for candidate in names:
            hit = folder / candidate
            if _path_is_file(hit):
                return hit

    if name.lower() not in {"godot", "godot.exe"}:
        return None

    for key in ("GODOT", "GODOT4"):
        raw = os.environ.get(key, "")
        if not raw:
            continue
        env_path = Path(raw)
        if _path_is_file(env_path):
            return env_path
        exe = env_path.parent / "godot.exe"
        if _path_is_file(exe):
            return exe

    home = Path.home()
    for hit in (home / "bin" / "godot.exe", home / "bin" / "godot"):
        if _path_is_file(hit):
            return hit
    install = home / "godot"
    if install.is_dir():
        matches = sorted(install.rglob("Godot_v*.exe"))
        if matches:
            return matches[0]
    return None


def godot_bin_or_skip() -> str:
    godot_bin = os.environ.get("GODOT_BIN", "")
    if not godot_bin:
        pytest.skip("GODOT_BIN is not set; skipping Godot self-update integration test")
    candidate = Path(godot_bin).expanduser()
    if _path_is_file(candidate) or candidate.is_absolute() or "/" in godot_bin or "\\" in godot_bin:
        resolved = candidate if _path_is_file(candidate) else None
    else:
        found = shutil.which(godot_bin)
        resolved = Path(found) if found is not None else None
        if (resolved is None or not _path_is_file(resolved)) and _is_windows():
            resolved = _windows_godot_fallbacks(godot_bin)
    if resolved is None or not _path_is_file(resolved):
        # CI sets GODOT_BIN=godot. Skipping here would make pytest exit 0
        # with zero tests run and hide a missing engine (#917).
        pytest.fail(f"GODOT_BIN does not resolve to an executable: {godot_bin}")
    return str(resolved)


def read_plugin_version(plugin_cfg: Path) -> str:
    smoke = load_smoke_script()
    return smoke.read_plugin_version(plugin_cfg)


def prepare_signed_update_project(
    project_dir: Path,
    *,
    base_version: str,
    next_version: str,
    base_server_version: str,
    next_server_version: str,
    http_port: int,
    ws_port: int,
) -> None:
    """Build the same signed A -> B fixture as the interactive harness.

    The helper deliberately delegates release construction, frozen server
    commands, and the old-tree transaction actor to ``local-self-update-smoke``.
    Integration tests then add only an autoload that presses the production
    plugin handoff automatically; they do not carry a second updater model.
    """

    smoke = load_smoke_script()
    smoke.prepare_project(
        project_dir=project_dir,
        base_version=base_version,
        next_version=next_version,
        server_version=base_server_version,
        next_server_version=next_server_version,
        http_port=http_port,
        ws_port=ws_port,
        force=False,
        isolate_client_migration=True,
    )
    append_driver_autoload(project_dir / "project.godot")


def prepare_clean_major_migration_project(
    project_dir: Path,
    *,
    codex_home: Path,
    from_version: str,
    target_version: str,
    http_port: int,
    ws_port: int,
) -> tuple[list[str], Path]:
    """Prepare a synthetic pre-v4 project and locally signed clean v4 release."""
    smoke = load_smoke_script()
    project_dir.mkdir()
    smoke.write_project_files(project_dir)
    append_driver_autoload(project_dir / "project.godot")

    work = project_dir / ".clean-major-smoke"
    work.mkdir()
    fake_uvx = _write_fake_uvx_shim(work, smoke.smoke_python())
    server_command, runtime_source = smoke.prepare_local_server_runtime(
        work, "server-v4", target_version
    )
    private_key, public_key = smoke.prepare_smoke_signing_key(work)
    release_tree = work / "release-tree"
    shutil.copytree(PLUGIN_ROOT, release_tree, ignore=smoke.copy_ignore)
    smoke.patch_fixture_plugin(
        release_tree,
        version=target_version,
        server_version=target_version,
        http_port=http_port,
        ws_port=ws_port,
        force_local_update=False,
        next_version=target_version,
        server_command=server_command,
        isolate_client_migration=True,
        skip_client_prewarm=False,
    )
    configurator = release_tree / "client_configurator.gd"
    configurator_text = smoke.replace_function(
        configurator.read_text(encoding="utf-8"),
        "static func find_uvx() -> String:",
        f"static func find_uvx() -> String:\n\treturn {json.dumps(str(fake_uvx))}",
    )
    configurator_text = smoke.subn_once(
        configurator,
        configurator_text,
        r"const PREWARM_TIMEOUT_MS := \d+",
        "const PREWARM_TIMEOUT_MS := 1000",
        "clean-major prewarm timeout",
    )
    configurator.write_text(configurator_text, encoding="utf-8")
    bundle = work / "release"
    bundle.mkdir()
    smoke.create_signed_v4_bundle(release_tree, bundle, target_version, private_key, public_key)
    private_key.unlink()

    verifier_root = work / "verifier"
    _write_fixture_verifier(verifier_root, public_key)
    old_addon = project_dir / "addons" / "godot_ai"
    (old_addon / "legacy").mkdir(parents=True)
    (old_addon / "plugin.cfg").write_text(f'[plugin]\nversion="{from_version}"\n', encoding="utf-8")
    (old_addon / "old_only.gd").write_text("extends RefCounted\n", encoding="utf-8")
    (old_addon / "legacy" / "state.txt").write_text("retained pre-v4 state\n", encoding="utf-8")
    write_owned_codex_pin(
        codex_home,
        command=fake_uvx,
        version=from_version,
        http_port=http_port,
        ws_port=ws_port,
    )
    argv = clean_major_install_argv(
        smoke.smoke_python(),
        bundle=bundle,
        project_root=project_dir,
        target_version=target_version,
        source_commit=smoke.SMOKE_SOURCE,
    )
    return argv, verifier_root


def clean_major_install_argv(
    python: Path,
    *,
    bundle: Path,
    project_root: Path,
    target_version: str,
    source_commit: str,
) -> list[str]:
    """Return the documented closed-editor install argv."""
    return [
        str(python),
        "script/v4-release",
        "install",
        "--archive",
        str(bundle / "godot-ai-v4-plugin.zip"),
        "--manifest",
        str(bundle / "godot-ai-v4-plugin.manifest.json"),
        "--signature",
        str(bundle / "godot-ai-v4-plugin.manifest.sig"),
        "--expected-channel",
        "stable",
        "--expected-repository",
        "hi-godot/godot-ai",
        "--expected-tag",
        f"v{target_version}",
        "--expected-version",
        target_version,
        "--expected-source",
        source_commit,
        "--project-root",
        str(project_root),
    ]


def _write_fixture_verifier(verifier_root: Path, public_key: str) -> None:
    """Copy the standalone verifier and substitute only the synthetic test key."""
    script_dir = verifier_root / "script"
    source_dir = verifier_root / "src" / "godot_ai"
    script_dir.mkdir(parents=True)
    source_dir.mkdir(parents=True)
    shutil.copy2(ROOT / "script" / "v4-release", script_dir / "v4-release")
    source = (ROOT / "src" / "godot_ai" / "release_verify.py").read_text(encoding="utf-8")
    pem_start = source.index('PUBLIC_KEY_PEM = """')
    pem_end = source.index('"""\nPUBLIC_KEY_SPKI_SHA256', pem_start) + 3
    normalized_key = public_key.rstrip("\n") + "\n"
    source = source[:pem_start] + f'PUBLIC_KEY_PEM = """{normalized_key}"""' + source[pem_end:]
    der = subprocess.run(
        ["openssl", "pkey", "-pubin", "-outform", "DER"],
        input=normalized_key.encode("ascii"),
        check=True,
        capture_output=True,
    ).stdout
    fingerprint_start = source.index('PUBLIC_KEY_SPKI_SHA256 = "')
    fingerprint_end = source.index("\n", fingerprint_start)
    source = (
        source[:fingerprint_start]
        + f'PUBLIC_KEY_SPKI_SHA256 = "{hashlib.sha256(der).hexdigest()}"'
        + source[fingerprint_end:]
    )
    (source_dir / "release_verify.py").write_text(source, encoding="utf-8")


def write_owned_codex_pin(
    codex_home: Path,
    *,
    command: Path,
    version: str,
    http_port: int,
    ws_port: int,
) -> None:
    codex_home.mkdir(parents=True, exist_ok=True)
    args = [
        "--link-mode",
        "copy",
        "--from",
        f"godot-ai=={version}",
        "godot-ai",
        "attach",
        "--port",
        str(http_port),
        "--ws-port",
        str(ws_port),
    ]
    encoded_args = ", ".join(json.dumps(value) for value in args)
    (codex_home / "config.toml").write_text(
        (
            '[mcp_servers."godot-ai"]\n'
            f"command = {json.dumps(str(command))}\n"
            f"args = [{encoded_args}]\n"
            "enabled = true\n"
            "startup_timeout_sec = 60\n"
            "tool_timeout_sec = 360\n"
        ),
        encoding="utf-8",
    )


def _write_fake_uvx_shim(work: Path, python: Path) -> Path:
    """Answer the plugin's server-package prewarm without network or shared caches."""
    fake_bin = work / "fake-bin"
    fake_bin.mkdir()
    implementation = fake_bin / "fake_uvx.py"
    implementation.write_text(
        """import json
import os
import sys

args = sys.argv[1:]
try:
    from_index = args.index("--from")
except ValueError:
    raise SystemExit("unexpected fake uvx argv")
version = args[from_index + 1].partition("==")[2] if len(args) > from_index + 1 else ""
target = args[from_index + 2:]
if not version:
    raise SystemExit("unexpected fake uvx version")
if target == ["godot-ai", "--version"]:
    log = os.environ.get("CLEAN_MAJOR_PREWARM_LOG", "")
    if log:
        with open(log, "a", encoding="utf-8") as handle:
            record = json.dumps({"argv": args, "kind": "startup_prewarm"}, sort_keys=True)
            handle.write(record + "\\n")
    print(f"godot-ai {version}")
else:
    raise SystemExit("unexpected fake uvx target")
""",
        encoding="utf-8",
    )
    if _is_windows():
        wrapper = fake_bin / "uvx.cmd"
        wrapper.write_text(
            f'@echo off\r\n"{python}" "{implementation}" %*\r\n',
            encoding="utf-8",
        )
    else:
        wrapper = fake_bin / "uvx"
        wrapper.write_text(
            f"#!{python}\n" + implementation.read_text(encoding="utf-8"),
            encoding="utf-8",
        )
        wrapper.chmod(0o700)
    return wrapper.absolute()


def patch_restart_diagnostics(addon_root: Path, log_path: Path) -> None:
    """Forward a --log-file to the editor the installer restarts into.

    Godot does not forward --log-file on restart and Windows disconnects the
    replacement's stdout, so the harness would otherwise see nothing from the
    restarted editor. Only the diagnostics change; the restart itself is the
    production call.
    """
    installer = addon_root / "utils" / "update_installer.gd"
    text = installer.read_text(encoding="utf-8")
    assert "diagnostics_args" not in text, f"{installer} already forwards a restart log"
    old = "\t\tEditorInterface.restart_editor(true)\n"
    assert text.count(old) == 1, installer
    text = text.replace(
        old,
        old
        + "\t\tvar diagnostics_args := OS.get_restart_on_exit_arguments()\n"
        + '\t\tdiagnostics_args.append("--log-file")\n'
        + f"\t\tdiagnostics_args.append({json.dumps(str(log_path))})\n"
        + "\t\tOS.set_restart_on_exit(true, diagnostics_args)\n",
    )
    installer.write_text(text, encoding="utf-8")


def read_editor_receipts(project_dir: Path) -> tuple[dict, dict]:
    """The pid/display receipts the drivers write before and after a restart."""
    initial = json.loads((project_dir / INITIAL_EDITOR_RECEIPT).read_text(encoding="utf-8"))
    restarted = json.loads((project_dir / RESTARTED_EDITOR_RECEIPT).read_text(encoding="utf-8"))
    return initial, restarted


_RECEIPT_GDSCRIPT = f"""
func _write_receipt() -> bool:
\tvar initial := "res://{INITIAL_EDITOR_RECEIPT}"
\tvar restarted := FileAccess.file_exists(initial)
\tvar receipt := FileAccess.open(
\t\t"res://{RESTARTED_EDITOR_RECEIPT}" if restarted else initial, FileAccess.WRITE
\t)
\tif receipt == null:
\t\tget_tree().quit(43)
\t\treturn restarted
\treceipt.store_string(JSON.stringify({{
\t\t"pid": OS.get_process_id(), "display": DisplayServer.get_name(),
\t}}))
\treceipt.close()
\treturn restarted
"""


def write_post_restart_driver(
    project_dir: Path, *, http_port: int, expected_version: str
) -> None:
    """Wait through a plugin-initiated restart, then prove the live server.

    The initial process only writes its receipt: the plugin under test decides
    whether to restart. The restarted process waits for an owned READY server
    at ``expected_version``, writes the status snapshot, waits for the
    harness's authenticated probe, then writes the completion file and quits.
    """
    write_driver_support(project_dir)
    (project_dir / "_test_runner_driver.gd").write_text(
        f"""@tool
extends Node

const EXPECTED_VERSION := "{expected_version}"
const HTTP_PORT := {http_port}
const STATUS_PATH := "res://{POST_UPDATE_STATUS_FILE}"
const TOOL_PROBE_DONE_PATH := "res://{POST_UPDATE_TOOL_PROBE_FILE}"
const COMPLETE_PATH := "res://{POST_UPDATE_COMPLETE_FILE}"
const DriverSupport := preload("res://_test_self_update_driver_support.gd")
const DEADLINE_MSEC := 180000

var _restarted := false
var _deadline := 0
var _tool_probe_ready := false


func _ready() -> void:
\tif not Engine.is_editor_hint():
\t\tqueue_free()
\t\treturn
\t_restarted = _write_receipt()
\t_deadline = Time.get_ticks_msec() + DEADLINE_MSEC
\tset_process(true)


func _process(_delta: float) -> void:
\tif Time.get_ticks_msec() >= _deadline:
\t\tpush_error("POST_RESTART_TEST | timed out (restarted=%s)" % _restarted)
\t\tget_tree().quit(41)
\t\treturn
\tif not _restarted:
\t\treturn
\tif _tool_probe_ready:
\t\tif FileAccess.file_exists(TOOL_PROBE_DONE_PATH):
\t\t\tprint("POST_RESTART_TEST | authenticated tool probe completed")
\t\t\tvar complete := FileAccess.open(COMPLETE_PATH, FileAccess.WRITE)
\t\t\tif complete != null:
\t\t\t\tcomplete.store_string("complete\\n")
\t\t\t\tcomplete.close()
\t\t\tget_tree().quit(0)
\t\treturn
\tvar plugin := DriverSupport.find_godot_ai_plugin()
\tif plugin == null or not bool(plugin.get("_normal_start_released")):
\t\treturn
\tvar lifecycle := plugin.call("get_server_status") as Dictionary
\tif (
\t\tstr(lifecycle.get("episode_state", "")) != "READY"
\t\tor str(lifecycle.get("actual_version", "")) != EXPECTED_VERSION
\t):
\t\treturn
\tvar status := DriverSupport.fetch_status(HTTP_PORT)
\tif str(status.get("server_version", "")) != EXPECTED_VERSION:
\t\treturn
\tvar file := FileAccess.open(STATUS_PATH, FileAccess.WRITE)
\tif file == null:
\t\tget_tree().quit(42)
\t\treturn
\tfile.store_string(JSON.stringify(status))
\tfile.close()
\tprint("POST_RESTART_TEST | live server ready at version %s" % EXPECTED_VERSION)
\t_tool_probe_ready = true
{_RECEIPT_GDSCRIPT}""",
        encoding="utf-8",
    )


def append_driver_autoload(project_file: Path) -> None:
    text = project_file.read_text(encoding="utf-8")
    text += '\n[autoload]\n_SelfUpdateRunnerDriver="*res://_test_runner_driver.gd"\n'
    project_file.write_text(text, encoding="utf-8")


def write_configure_client_driver(
    project_dir: Path, *, http_port: int, version: str, reload_before_quit: bool = False
) -> None:
    """Configure Codex in a disposable editor process before the update run."""
    project_file = project_dir / "project.godot"
    project_file.write_text(
        project_file.read_text(encoding="utf-8")
        + '_SelfUpdateClientPrep="*res://_test_configure_client.gd"\n',
        encoding="utf-8",
    )
    (project_dir / "_test_configure_client.gd").write_text(
        f"""@tool
extends Node

const VERSION := "{version}"
const HTTP_PORT := {http_port}
const ClientConfigurator := preload("res://addons/godot_ai/client_configurator.gd")
const DriverSupport := preload("res://_test_self_update_driver_support.gd")
const OWNERSHIP_WAIT_MS := 120000
const RELOAD_BEFORE_QUIT := {str(reload_before_quit).lower()}

var _frames := 0
var _configured := false
var _ownership_wait_started_ms := 0


func _ready() -> void:
\tif not Engine.is_editor_hint() or OS.get_environment("_SELF_UPDATE_CONFIGURE_CLIENT") != "1":
\t\tqueue_free()
\t\treturn
\tset_process(true)


func _process(_delta: float) -> void:
\t_frames += 1
\tif _configured:
\t\tvar plugin := DriverSupport.find_godot_ai_plugin()
\t\tif plugin == null:
\t\t\treturn
\t\tif bool(plugin.call("has_managed_server")):
\t\t\tset_process(false)
\t\t\t_finish_prep()
\t\t\treturn
\t\tif _ownership_wait_started_ms == 0:
\t\t\t_ownership_wait_started_ms = Time.get_ticks_msec()
\t\t\treturn
\t\tif Time.get_ticks_msec() - _ownership_wait_started_ms > OWNERSHIP_WAIT_MS:
\t\t\tpush_error(
\t\t\t\t"SELF_UPDATE_TEST | managed server ownership was not established during client prep: %s"
\t\t\t\t% plugin.call("get_server_status")
\t\t\t)
\t\t\tget_tree().quit(32)
\t\treturn
\tif _frames < 45:
\t\treturn
\tvar context := ClientConfigurator.capture_launch_context()
\tvar result := ClientConfigurator.configure(
\t\t"codex",
\t\t"http://127.0.0.1:%d/mcp" % HTTP_PORT,
\t\tcontext,
\t)
\tif str(result.get("status", "error")) != "ok" or not _has_pin():
\t\tpush_error("SELF_UPDATE_TEST | production Codex A configuration failed: %s" % result)
\t\tget_tree().quit(31)
\t\treturn
\tprint("SELF_UPDATE_TEST | production-configured Codex command pin=%s" % VERSION)
\t_configured = true


func _finish_prep() -> void:
\tif RELOAD_BEFORE_QUIT:
\t\tvar handler = load("res://addons/godot_ai/handlers/editor_handler.gd")
\t\tvar old_plugin_id := DriverSupport.find_godot_ai_plugin().get_instance_id()
\t\thandler._do_reload_plugin()
\t\tvar deadline := Time.get_ticks_msec() + OWNERSHIP_WAIT_MS
\t\twhile Time.get_ticks_msec() < deadline:
\t\t\tvar plugin := DriverSupport.find_godot_ai_plugin()
\t\t\tif (plugin != null and plugin.get_instance_id() != old_plugin_id
\t\t\t\tand bool(plugin.call("has_managed_server"))):
\t\t\t\tvar saved := ConfigFile.new()
\t\t\t\tif saved.load("res://project.godot") != OK or not (
\t\t\t\t\t"res://addons/godot_ai/plugin.cfg" in saved.get_value(
\t\t\t\t\t\t"editor_plugins", "enabled", PackedStringArray())):
\t\t\t\t\tpush_error("SELF_UPDATE_TEST | reload did not persist plugin enablement")
\t\t\t\t\tget_tree().quit(33)
\t\t\t\t\treturn
\t\t\t\tprint("SELF_UPDATE_TEST | ordinary reload restored backend and persisted enablement")
\t\t\t\tget_tree().quit(0)
\t\t\t\treturn
\t\t\tawait get_tree().process_frame
\t\tpush_error("SELF_UPDATE_TEST | ordinary reload did not restore managed backend")
\t\tget_tree().quit(34)
\t\treturn
\tget_tree().quit(0)


func _has_pin() -> bool:
\tvar home := OS.get_environment("CODEX_HOME")
\tvar path := home.path_join("config.toml")
\treturn not home.is_empty() and FileAccess.file_exists(path) and FileAccess.get_file_as_string(
\t\tpath
\t).contains("godot-ai==%s" % VERSION)
""",
        encoding="utf-8",
    )


def remove_configure_client_driver(project_dir: Path) -> None:
    """Remove the prep-only autoload so it cannot pin A during the update run."""
    project_file = project_dir / "project.godot"
    autoload = '_SelfUpdateClientPrep="*res://_test_configure_client.gd"\n'
    text = project_file.read_text(encoding="utf-8")
    if text.count(autoload) != 1:
        raise AssertionError("expected exactly one self-update client prep autoload")
    project_file.write_text(text.replace(autoload, ""), encoding="utf-8")
    (project_dir / "_test_configure_client.gd").unlink()


def write_install_update_driver(
    project_dir: Path, *, http_port: int, base_version: str, next_version: str
) -> None:
    """Click Update in the base editor, then prove B live after the restart.

    The initial process records its receipt and the pre-update server
    instance, verifies the A pin, and presses the production update entry
    point; the plugin swaps and restarts the editor. The restarted process
    validates the installed tree, waits for the automatic repin and the new
    server, writes the status snapshot, waits for the harness's authenticated
    probe, then writes the completion file and quits.
    """
    write_driver_support(project_dir)
    (project_dir / "_test_runner_driver.gd").write_text(
        f"""@tool
extends Node

const BASE_VERSION := "{base_version}"
const NEXT_VERSION := "{next_version}"
const HTTP_PORT := {http_port}
const STATUS_PATH := "res://{POST_UPDATE_STATUS_FILE}"
const TOOL_PROBE_DONE_PATH := "res://{POST_UPDATE_TOOL_PROBE_FILE}"
const COMPLETE_PATH := "res://{POST_UPDATE_COMPLETE_FILE}"
const PRE_ID_PATH := "res://{PRE_INSTANCE_ID_FILE}"
const DriverSupport := preload("res://_test_self_update_driver_support.gd")
const START_AFTER_FRAMES := 45
const MAX_FRAMES := 1800
const STATUS_WAIT_MS := 120000

var _frames := 0
var _restarted := false
var _started := false
var _validated := false
var _repin_observed := false
var _tool_probe_ready := false
var _finished := false
var _status_wait_started_ms := 0
var _pre_instance_id := ""


func _ready() -> void:
\tif not Engine.is_editor_hint():
\t\tqueue_free()
\t\treturn
\tif OS.get_environment("_SELF_UPDATE_DRIVER_SKIP") == "1":
\t\tqueue_free()
\t\treturn
\t_restarted = _write_receipt()
\tif _restarted:
\t\t_pre_instance_id = FileAccess.get_file_as_string(PRE_ID_PATH).strip_edges()
\t\t_status_wait_started_ms = Time.get_ticks_msec()
\tset_process(true)


func _process(_delta: float) -> void:
\tif _finished:
\t\treturn
\t_frames += 1
\tif not _restarted:
\t\tif _started:
\t\t\tif _frames > MAX_FRAMES:
\t\t\t\t_fail(10, "signed install did not restart the editor")
\t\t\treturn
\t\tif _frames < START_AFTER_FRAMES:
\t\t\treturn
\t\tif _frames > MAX_FRAMES:
\t\t\t_fail(12, "pre-update /godot-ai/status timed out")
\t\t\treturn
\t\tvar pre := DriverSupport.fetch_status(HTTP_PORT)
\t\tvar pre_id := str(pre.get("instance_id", ""))
\t\tif pre_id.is_empty():
\t\t\treturn
\t\t_pre_instance_id = pre_id
\t\tvar pre_file := FileAccess.open(PRE_ID_PATH, FileAccess.WRITE)
\t\tif pre_file != null:
\t\t\tpre_file.store_string(pre_id)
\t\t\tpre_file.close()
\t\tif not _update_candidate_ready():
\t\t\treturn
\t\tprint("SELF_UPDATE_TEST | pre-update instance_id=%s" % _pre_instance_id)
\t\tif not DriverSupport.client_config_has_pin(BASE_VERSION):
\t\t\t_fail(14, "Codex config does not contain the A pin")
\t\t\treturn
\t\tprint("SELF_UPDATE_TEST | configured Codex command pin=%s" % BASE_VERSION)
\t\t_call_install()
\t\treturn
\tif not _validated:
\t\tif _try_validate_install():
\t\t\t_validated = true
\t\telif Time.get_ticks_msec() - _status_wait_started_ms > STATUS_WAIT_MS:
\t\t\t_fail(10, "restarted editor does not run the signed B tree")
\t\treturn
\tif not _repin_observed:
\t\t_observe_automatic_repin()
\t\tif not _repin_observed:
\t\t\tif Time.get_ticks_msec() - _status_wait_started_ms > STATUS_WAIT_MS:
\t\t\t\t_fail(15, "automatic Codex repin timed out")
\t\t\treturn
\tif not _tool_probe_ready and _try_write_status():
\t\t_tool_probe_ready = true
\t\treturn
\tif _tool_probe_ready and FileAccess.file_exists(TOOL_PROBE_DONE_PATH):
\t\tprint("SELF_UPDATE_TEST | authenticated read/write tool probe completed")
\t\tvar complete := FileAccess.open(COMPLETE_PATH, FileAccess.WRITE)
\t\tif complete != null:
\t\t\tcomplete.store_string("complete\\n")
\t\t\tcomplete.close()
\t\t_finished = true
\t\tget_tree().quit(0)
\t\treturn
\tif Time.get_ticks_msec() - _status_wait_started_ms > STATUS_WAIT_MS:
\t\t_fail(13, "post-update /godot-ai/status timed out")


func _fail(code: int, message: String) -> void:
\tpush_error("SELF_UPDATE_TEST | %s" % message)
\t_finished = true
\tget_tree().quit(code)


func _call_install() -> void:
\t_started = true
\tvar plugin := DriverSupport.find_godot_ai_plugin()
\tif plugin == null:
\t\t_fail(11, "failed to find Godot AI plugin")
\t\treturn
\tprint("SELF_UPDATE_TEST | requesting canonical signed install")
\tplugin.call("_on_dock_update_requested")


func _update_candidate_ready() -> bool:
\tvar plugin := DriverSupport.find_godot_ai_plugin()
\tif plugin == null:
\t\treturn false
\tvar manager: Variant = plugin.get("_update_manager")
\treturn manager != null and bool(manager.call("has_install_candidate"))


func _observe_automatic_repin() -> void:
\tif not DriverSupport.client_config_has_pin(NEXT_VERSION):
\t\treturn
\tprint("SELF_UPDATE_TEST | repinned Codex command pin=%s" % NEXT_VERSION)
\t_repin_observed = true


func _try_validate_install() -> bool:
\tvar child_path := "res://addons/godot_ai/utils/self_update_smoke_child.gd"
\tvar base_path := "res://addons/godot_ai/utils/self_update_smoke_base.gd"
\tif not FileAccess.file_exists(child_path) or not FileAccess.file_exists(base_path):
\t\treturn false
\tvar cfg := ConfigFile.new()
\tif cfg.load("res://addons/godot_ai/plugin.cfg") != OK:
\t\treturn false
\tif str(cfg.get_value("plugin", "version", "")) != NEXT_VERSION:
\t\treturn false
\tvar child_source := FileAccess.get_file_as_string(child_path)
\tvar base_source := FileAccess.get_file_as_string(base_path)
\tif not child_source.contains("extends McpSelfUpdateSmokeBase"):
\t\treturn false
\tif not base_source.contains("class_name McpSelfUpdateSmokeBase"):
\t\treturn false
\treturn true


func _try_write_status() -> bool:
\tvar payload := DriverSupport.fetch_status(HTTP_PORT)
\tif payload.get("name") != "godot-ai":
\t\treturn false
\tvar version := str(payload.get("server_version", ""))
\tif version != NEXT_VERSION:
\t\treturn false
\tvar post_id := str(payload.get("instance_id", ""))
\tif post_id.is_empty() or post_id == _pre_instance_id:
\t\treturn false
\tvar f := FileAccess.open(STATUS_PATH, FileAccess.WRITE)
\tif f == null:
\t\tpush_error("SELF_UPDATE_TEST | failed to write status snapshot")
\t\treturn false
\tf.store_string(JSON.stringify(payload))
\tf.close()
\tprint("SELF_UPDATE_TEST | signed topology files installed")
\tprint("SELF_UPDATE_TEST | status name=%s server_version=%s instance_id=%s" % [
\t\tpayload.get("name"),
\t\tversion,
\t\tpost_id,
\t])
\treturn true
{_RECEIPT_GDSCRIPT}""",
        encoding="utf-8",
    )

def write_driver_support(project_dir: Path) -> None:
    """Write shared authenticated status and plugin-discovery primitives."""
    (project_dir / "_test_self_update_driver_support.gd").write_text(
        """@tool
extends RefCounted

const MAX_STATUS_BYTES := 64 * 1024


static func fetch_status(port: int) -> Dictionary:
\tvar record := _read_capability(port)
\tif record.is_empty():
\t\treturn {}
\tvar http := HTTPClient.new()
\tif http.connect_to_host("127.0.0.1", port) != OK:
\t\treturn {}
\tvar deadline := Time.get_ticks_msec() + 2000
\twhile (
\t\thttp.get_status() == HTTPClient.STATUS_CONNECTING
\t\tor http.get_status() == HTTPClient.STATUS_RESOLVING
\t):
\t\thttp.poll()
\t\tif Time.get_ticks_msec() > deadline:
\t\t\treturn {}
\t\tOS.delay_msec(10)
\tif http.get_status() != HTTPClient.STATUS_CONNECTED:
\t\treturn {}
\tvar headers := PackedStringArray([
\t\t"Authorization: Bearer %s" % record["http"],
\t\t"Accept-Encoding: identity",
\t])
\tif http.request(HTTPClient.METHOD_GET, "/godot-ai/status", headers) != OK:
\t\treturn {}
\tdeadline = Time.get_ticks_msec() + 2000
\twhile http.get_status() == HTTPClient.STATUS_REQUESTING:
\t\thttp.poll()
\t\tif Time.get_ticks_msec() > deadline:
\t\t\treturn {}
\t\tOS.delay_msec(10)
\tif not http.has_response() or http.get_response_code() != 200:
\t\treturn {}
\tvar body := PackedByteArray()
\tdeadline = Time.get_ticks_msec() + 2000
\twhile http.get_status() == HTTPClient.STATUS_BODY:
\t\thttp.poll()
\t\tvar chunk := http.read_response_body_chunk()
\t\tif chunk.size() > 0:
\t\t\tif body.size() + chunk.size() > MAX_STATUS_BYTES:
\t\t\t\treturn {}
\t\t\tbody.append_array(chunk)
\t\telse:
\t\t\tOS.delay_msec(5)
\t\tif Time.get_ticks_msec() > deadline:
\t\t\treturn {}
\tvar parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
\tif typeof(parsed) != TYPE_DICTIONARY:
\t\treturn {}
\tif parsed.get("instance_id") != record["instance_nonce"]:
\t\treturn {}
\treturn parsed


static func _read_capability(port: int) -> Dictionary:
\tvar directory := OS.get_environment("GODOT_AI_CAPABILITY_DIR").strip_edges()
\tif OS.get_name() == "Windows":
\t\tdirectory = OS.get_environment("LOCALAPPDATA").path_join("godot-ai/capabilities")
\telif directory.is_empty() and OS.get_name() == "macOS":
\t\tdirectory = OS.get_environment("HOME").path_join(
\t\t\t"Library/Application Support/godot-ai/capabilities"
\t\t)
\telif directory.is_empty():
\t\tdirectory = OS.get_environment("XDG_CONFIG_HOME").strip_edges()
\t\tif directory.is_empty():
\t\t\tdirectory = OS.get_environment("HOME").path_join(".config")
\t\tdirectory = directory.path_join("godot-ai/capabilities")
\tvar path := directory.path_join("http-%d.json" % port)
\tif not path.is_absolute_path() or not FileAccess.file_exists(path):
\t\treturn {}
\tvar file := FileAccess.open(path, FileAccess.READ)
\tif file == null or file.get_length() < 1 or file.get_length() > 1025:
\t\treturn {}
\tvar parsed: Variant = JSON.parse_string(file.get_as_text())
\tif not parsed is Dictionary:
\t\treturn {}
\tfor key in ["http", "instance_nonce"]:
\t\tif not parsed.get(key) is String or str(parsed.get(key)).is_empty():
\t\t\treturn {}
\treturn parsed


static func client_config_has_pin(version: String) -> bool:
\tvar home := OS.get_environment("CODEX_HOME")
\tif home.is_empty():
\t\treturn false
\tvar path := home.path_join("config.toml")
\treturn FileAccess.file_exists(path) and FileAccess.get_file_as_string(path).contains(
\t\t"godot-ai==%s" % version
\t)


static func find_godot_ai_plugin() -> EditorPlugin:
\tvar tree := Engine.get_main_loop() as SceneTree
\tif tree == null:
\t\treturn null
\tvar found := _walk_plugin(tree.root)
\tif found != null:
\t\treturn found
\tvar base := EditorInterface.get_base_control()
\tif base == null:
\t\treturn null
\treturn _walk_plugin(base.get_parent())


static func _walk_plugin(node: Node) -> EditorPlugin:
\tif node is EditorPlugin and node.has_method("install_downloaded_update"):
\t\treturn node
\tfor child in node.get_children():
\t\tvar found := _walk_plugin(child)
\t\tif found != null:
\t\t\treturn found
\treturn null
""",
        encoding="utf-8",
    )


def write_clean_major_driver(
    project_dir: Path, *, http_port: int, from_version: str, target_version: str
) -> None:
    """Confirm the marker barrier, then prove the first v4 server and tools."""
    write_driver_support(project_dir)
    (project_dir / "_test_runner_driver.gd").write_text(
        f"""@tool
extends Node

const FROM_VERSION := "{from_version}"
const TARGET_VERSION := "{target_version}"
const HTTP_PORT := {http_port}
const MARKER_PATH := "res://{CLEAN_MAJOR_MARKER_RELATIVE.as_posix()}"
const STATUS_PATH := "res://{CLEAN_MAJOR_STATUS_FILE}"
const TOOL_PROBE_DONE_PATH := "res://{CLEAN_MAJOR_TOOL_PROBE_FILE}"
const DriverSupport := preload("res://_test_self_update_driver_support.gd")
const START_AFTER_FRAMES := 15
const STARTUP_WAIT_MS := 120000
const STATUS_WAIT_MS := 210000

var _frames := 0
var _migration_observed := false
var _tool_probe_ready := false
var _finished := false
var _startup_wait_started_ms := 0
var _status_wait_started_ms := 0


func _ready() -> void:
\tif not Engine.is_editor_hint():
\t\tqueue_free()
\t\treturn
\t_startup_wait_started_ms = Time.get_ticks_msec()
\tset_process(true)


func _process(_delta: float) -> void:
\tif _finished:
\t\treturn
\t_frames += 1
\tif _frames < START_AFTER_FRAMES:
\t\treturn
\tif (
\t\tnot _migration_observed
\t\tand Time.get_ticks_msec() - _startup_wait_started_ms > STARTUP_WAIT_MS
\t):
\t\t_fail(21, "clean-major first start timed out")
\t\treturn
\tvar plugin := DriverSupport.find_godot_ai_plugin()
\tif plugin == null:
\t\treturn
\tif not _migration_observed:
\t\t_observe_automatic_migration(plugin)
\t\treturn
\tif not _tool_probe_ready and _try_write_status(plugin):
\t\t_tool_probe_ready = true
\t\treturn
\tif _tool_probe_ready and FileAccess.file_exists(TOOL_PROBE_DONE_PATH):
\t\tprint("CLEAN_MAJOR_TEST | authenticated read/write tool probe completed")
\t\t_finished = true
\t\tget_tree().quit(0)
\t\treturn
\tif Time.get_ticks_msec() - _status_wait_started_ms > STATUS_WAIT_MS:
\t\t_fail(
\t\t\t22,
\t\t\t"post-migration authenticated server timed out; lifecycle=%s"
\t\t\t% str(plugin.call("get_server_status")),
\t\t)


func _observe_automatic_migration(plugin: EditorPlugin) -> void:
\tvar action := str(plugin.get("_post_update_action"))
\tif action == "retry":
\t\t_fail(23, "client migration requested retry")
\t\treturn
\tif not bool(plugin.get("_normal_start_released")):
\t\treturn
\tvar marker: Variant = JSON.parse_string(FileAccess.get_file_as_string(MARKER_PATH))
\tif not marker is Dictionary or str(marker.get("status", "")) != "success":
\t\t_fail(28, "update marker does not record success: %s" % str(marker))
\t\treturn
\tif not _installed_tree_is_target():
\t\t_fail(26, "installed add-on is not the clean v4 target")
\t\treturn
\tif (
\t\tnot DriverSupport.client_config_has_pin(TARGET_VERSION)
\t\tor DriverSupport.client_config_has_pin(FROM_VERSION)
\t):
\t\t_fail(27, "owned Codex entry was not repinned from pre-v4 to v4")
\t\treturn
\tprint("CLEAN_MAJOR_TEST | migration completed automatically")
\tprint("CLEAN_MAJOR_TEST | repinned owned Codex command pin=%s" % TARGET_VERSION)
\t_migration_observed = true
\t_status_wait_started_ms = Time.get_ticks_msec()


func _installed_tree_is_target() -> bool:
\tif FileAccess.file_exists("res://addons/godot_ai/old_only.gd"):
\t\treturn false
\tvar cfg := ConfigFile.new()
\treturn (
\t\tcfg.load("res://addons/godot_ai/plugin.cfg") == OK
\t\tand str(cfg.get_value("plugin", "version", "")) == TARGET_VERSION
\t)


func _try_write_status(plugin: EditorPlugin) -> bool:
\tvar lifecycle := plugin.call("get_server_status") as Dictionary
\tif (
\t\tstr(lifecycle.get("episode_state", "")) != "READY"
\t\tor str(lifecycle.get("ready_kind", "")) != "owned"
\t\tor str(lifecycle.get("actual_version", "")) != TARGET_VERSION
\t):
\t\treturn false
\tvar payload := DriverSupport.fetch_status(HTTP_PORT)
\tif (
\t\tpayload.get("name") != "godot-ai"
\t\tor str(payload.get("server_version", "")) != TARGET_VERSION
\t\tor str(payload.get("instance_id", "")).is_empty()
\t):
\t\treturn false
\tvar file := FileAccess.open(STATUS_PATH, FileAccess.WRITE)
\tif file == null:
\t\t_fail(29, "failed to write clean-major status snapshot")
\t\treturn false
\tfile.store_string(JSON.stringify(payload))
\tfile.close()
\tprint("CLEAN_MAJOR_TEST | status name=godot-ai server_version=%s" % TARGET_VERSION)
\treturn true


func _fail(code: int, message: String) -> void:
\tpush_error("CLEAN_MAJOR_TEST | %s" % message)
\t_finished = true
\tget_tree().quit(code)
""",
        encoding="utf-8",
    )


def _godot_log_path(project_dir: Path, phase: str) -> Path:
    return project_dir.parent / f".{project_dir.name}-{phase}.log"


def run_godot_editor(
    project_dir: Path,
    godot_bin: str,
    *,
    allow_headless: bool,
    headless: bool = True,
    timeout: int = 90,
    environment: dict[str, str] | None = None,
    live_probe: Callable[[], None] | None = None,
    probe_ready_file: str = POST_UPDATE_STATUS_FILE,
    probe_done_file: str = POST_UPDATE_TOOL_PROBE_FILE,
    phase: str = "editor",
    expected_exit_code: int = 0,
    restart_completion_file: str | None = None,
) -> str:
    env = os.environ.copy()
    if allow_headless:
        env["GODOT_AI_ALLOW_HEADLESS"] = "1"
    else:
        env.pop("GODOT_AI_ALLOW_HEADLESS", None)
    if environment is not None:
        env.update(environment)
    command = [godot_bin]
    if headless:
        # EditorInterface.restart_editor forwards the explicit display/audio
        # driver options, but not the --headless shorthand (Godot 4.7). Without
        # these, the replacement unexpectedly needs a desktop/GPU on CI.
        command.extend(["--display-driver", "headless", "--audio-driver", "Dummy"])
    command.extend(
        [
            "--path",
            str(project_dir),
            "--editor",
            "--log-file",
            str(_godot_log_path(project_dir, phase)),
        ]
    )
    # MERGE stderr into stdout at the kernel level so the captured `output`
    # is a single chronologically-ordered stream. `capture_output=True` would
    # produce SEPARATE stdout/stderr buffers; concatenating them yields an
    # "all-stdout-then-all-stderr" string with no time-ordering. The window
    # markers below (`MCP | update coordinator disabling old plugin`,
    # `MCP | plugin loaded`) are stdout-only, so a marker-bracketed window
    # against an unmerged buffer can never see stderr-routed parse errors
    # like `SCRIPT ERROR: Parse Error` (emitted via `OS::print_error`). The
    # forward regression test in `test_self_update_upgrade_paths.py` would
    # then silently pass while a reverted-to-two-phase runner shipped parse
    # errors. Same reason existing CI scripts (.github/workflows/ci.yml)
    # use `> log 2>&1`. Do not change without also fixing those scans.
    capture_path = project_dir.parent / f".{project_dir.name}-{phase}-combined.log"
    deadline = time.monotonic() + timeout
    next_progress = time.monotonic() + 15
    probe_ran = False
    crash_reports = load_smoke_script().diagnostic_reports_snapshot
    crash_baseline = crash_reports()
    failure: BaseException | None = None
    with capture_path.open("w+", encoding="utf-8") as capture:
        proc = subprocess.Popen(
            command,
            cwd=ROOT,
            env=env,
            text=True,
            stdout=capture,
            stderr=subprocess.STDOUT,
        )
        _godot_log_path(project_dir, f"{phase}-pid").write_text(f"{proc.pid}\n", encoding="utf-8")
        print(
            f"SELF_UPDATE_HARNESS | {project_dir.name}/{phase}: started editor pid={proc.pid}",
            flush=True,
        )
        try:
            completion_path = (
                project_dir / restart_completion_file
                if restart_completion_file is not None
                else None
            )
            while proc.poll() is None or (
                completion_path is not None and not completion_path.is_file()
            ):
                if (
                    live_probe is not None
                    and not probe_ran
                    and (project_dir / probe_ready_file).is_file()
                ):
                    live_probe()
                    (project_dir / probe_done_file).write_text(
                        "authenticated read/write probe passed\n", encoding="utf-8"
                    )
                    probe_ran = True
                now = time.monotonic()
                if now >= deadline:
                    raise subprocess.TimeoutExpired(command, timeout)
                if now >= next_progress:
                    state = "running" if proc.poll() is None else f"exited({proc.returncode})"
                    complete = completion_path.is_file() if completion_path else "n/a"
                    print(
                        f"SELF_UPDATE_HARNESS | {project_dir.name}/{phase}: "
                        f"initial editor {state}; authenticated_probe={probe_ran}; "
                        f"restart_complete={complete}; "
                        f"remaining={max(0, int(deadline - now))}s",
                        flush=True,
                    )
                    next_progress = now + 15
                time.sleep(0.05)
            if completion_path is not None:
                time.sleep(0.25)
            capture.flush()
            capture.seek(0)
            output = capture.read()
        except BaseException as exc:
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=5)
            capture.flush()
            capture.seek(0)
            output = capture.read()
            failure = exc
    restarted_log = project_dir / "_test_restarted_editor.log"
    if restarted_log.is_file():
        output += "\nSELF_UPDATE_HARNESS | replacement editor log:\n"
        output += restarted_log.read_text(encoding="utf-8", errors="replace")
    new_crashes = crash_reports() - crash_baseline
    assert not new_crashes, "Godot crash report(s) appeared during the isolated lane: " + ", ".join(
        map(str, sorted(new_crashes))
    )
    if failure is not None:
        raise AssertionError(f"{failure}\n{output}") from failure
    if live_probe is not None:
        assert probe_ran, output
    assert proc.returncode == expected_exit_code, output
    return output


def assert_no_update_parse_errors(log: str) -> None:
    """The swap window and the restarted editor must load no broken script."""
    window_start = log.find("MCP | update to ")
    window = log[window_start:] if window_start >= 0 else log
    for pattern in PARSE_ERROR_PATTERNS:
        assert pattern not in window, f"{pattern!r} during the update window:\n{window}"
