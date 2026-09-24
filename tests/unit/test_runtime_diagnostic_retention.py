"""Retain failed real-child diagnostics through both production update boundaries."""

import json
import os
import subprocess
import sys
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import pytest

from script import release_predecessor as predecessor
from script import release_support as support
from script import runtime_qualification as runtime

PRIVATE = (
    "release-canary",
    "http://127.0.0.1/index-capability/",
    "index-capability",
    runtime.ORIGIN,
)


@pytest.fixture
def boundary(monkeypatch, tmp_path):
    bridge_state = SimpleNamespace(stopped=False, enter_error=None, exit_error=None)

    class Bridge:
        def __init__(self, *args):
            self.path = args[-1]

        def __enter__(self):
            self.path.write_text("bridge entered\n", encoding="utf-8")
            if bridge_state.enter_error:
                raise bridge_state.enter_error
            return self

        def __exit__(self, *_args):
            self.path.write_text("bridge stopped\n", encoding="utf-8")
            bridge_state.stopped = True
            if bridge_state.exit_error:
                raise bridge_state.exit_error

    records = {
        name: {"version": version, "tag": "v" + version, "source": "a" * 40}
        for name, version in [("a", "4.2.2"), ("b", "4.2.3")]
    }
    monkeypatch.setattr(support, "verify_candidate", lambda _path, name: records[name])
    monkeypatch.setattr(support, "inventory", lambda _path: {})
    monkeypatch.setattr(runtime.engine, "verify_executable", lambda *_: {"path": sys.executable})
    monkeypatch.setattr(runtime, "_validate_godot_version", lambda *_: "4.7.0")
    monkeypatch.setattr(runtime, "_free_port", lambda *_: True)
    monkeypatch.setattr(runtime, "_tls_material", lambda path: (path / "cert", path / "key"))
    monkeypatch.setattr(runtime, "retained_index", lambda *_: nullcontext((PRIVATE[1], [])))
    environment = {**os.environ, "CODEX_HOME": str(tmp_path / "client")}
    monkeypatch.setattr(runtime, "_isolated_environment", lambda *_: dict(environment))
    monkeypatch.setattr(predecessor, "isolated_environment", lambda *_: dict(environment))
    monkeypatch.setattr(runtime.shutil, "which", lambda *_args, **_kwargs: sys.executable)
    monkeypatch.setattr(runtime, "_write_client_pin", lambda *_: None)
    monkeypatch.setattr(runtime, "_execute_sensitive", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(runtime, "_manifest_tree", lambda *_: {})
    monkeypatch.setattr(runtime, "_write_project", lambda *_: None)
    monkeypatch.setattr(runtime, "_capability_directory", lambda *_: tmp_path / "capabilities")
    monkeypatch.setattr(runtime, "AttachedBridge", Bridge)
    origin = SimpleNamespace(token=PRIVATE[0], proxy_port=1, environment=lambda: {})
    monkeypatch.setattr(
        runtime, "private_release_origin", lambda *_args, **_kwargs: nullcontext(origin)
    )
    monkeypatch.setattr(predecessor, "retain_predecessor_dependencies", lambda *_: [])
    monkeypatch.setattr(predecessor, "merge_dependency_files", lambda *_: None)
    monkeypatch.setattr(predecessor, "offline_preflight", lambda *_: {})
    monkeypatch.setattr(runtime.qualification, "dependency_inventory", lambda *_: [])

    def invoke(
        kind,
        *,
        timeout=False,
        missing=False,
        stdout="editor output",
        stderr="editor error",
        exit_code=41,
    ):
        def command(_executable, project):
            code = "from pathlib import Path; import sys,time; "
            if not missing:
                result_path = str(project / "runtime-result.json")
                payload = json.dumps({"error": "driver timed out"})
                code += f"Path({result_path!r}).write_text({payload!r}, encoding='utf-8'); "
            code += f"print({stdout!r},flush=True); print({stderr!r},file=sys.stderr,flush=True); "
            code += "time.sleep(20)" if timeout else f"raise SystemExit({exit_code})"
            return [sys.executable, "-c", code]

        monkeypatch.setattr(runtime, "_editor_command", command)
        monkeypatch.setattr(runtime, "TIMEOUT_SECONDS", 1 if timeout else 10)
        output = tmp_path / "output"
        if kind == "predecessor":
            output.mkdir()
            previous = {"version": "4.2.1", "tag": "v4.2.1", "source": "b" * 40}
            predecessor.run_update(
                tmp_path / "candidate",
                tmp_path / "python-row",
                [],
                tmp_path / "previous",
                previous,
                records["a"],
                sys.executable,
                "4.7.0",
                output,
            )
        else:
            runtime.exact_a_to_b(
                tmp_path / "candidates", tmp_path / "packages", [], sys.executable, "4.7.0", output
            )

    return invoke, tmp_path / "output", bridge_state


@pytest.mark.parametrize("kind", ["predecessor", "a-to-b"])
def test_failed_editor_retains_written_files_after_bridge_exit(boundary, kind):
    invoke, output, bridge = boundary
    with pytest.raises(support.ReleaseError, match="update failed"):
        invoke(kind)
    assert bridge.stopped
    assert (output / "attached-bridge.log").read_text(encoding="utf-8") == "bridge stopped\n"
    assert json.loads((output / "runtime-result.json").read_text(encoding="utf-8")) == {
        "error": "driver timed out"
    }
    assert "editor output" in (output / "godot.log").read_text(encoding="utf-8")
    assert "editor error" in (output / "godot.log").read_text(encoding="utf-8")
    statuses = json.loads((output / "runtime-diagnostics.json").read_text(encoding="utf-8"))
    assert statuses["runtime-progress.json"] == "absent"
    assert statuses["runtime-result.json"] == "retained"


@pytest.mark.parametrize("kind", ["predecessor", "a-to-b"])
def test_missing_result_is_reported_as_absent(boundary, kind):
    invoke, output, _ = boundary
    with pytest.raises(support.ReleaseError, match="update failed"):
        invoke(kind, missing=True)
    statuses = json.loads((output / "runtime-diagnostics.json").read_text(encoding="utf-8"))
    assert statuses["runtime-result.json"] == "absent"
    assert not (output / "runtime-result.json").exists()


@pytest.mark.parametrize("kind", ["predecessor", "a-to-b"])
@pytest.mark.parametrize("private", [None, *PRIVATE])
def test_timeout_retains_partial_output_without_leaking(boundary, kind, private):
    invoke, output, bridge = boundary
    with pytest.raises(subprocess.TimeoutExpired):
        invoke(kind, timeout=True, stdout=private or "partial stdout", stderr="partial stderr")
    assert bridge.stopped
    log = (output / "godot.log").read_text(encoding="utf-8")
    if private:
        assert log == "qualification output withheld: private capability leaked\n"
    else:
        assert "partial stdout" in log and "partial stderr" in log
    for path in output.iterdir():
        if path.is_file():
            assert all(value not in path.read_text(encoding="utf-8") for value in PRIVATE)


@pytest.mark.parametrize("stage", ["enter", "exit"])
@pytest.mark.parametrize("kind", ["predecessor", "a-to-b"])
def test_bridge_exception_is_preserved_with_available_diagnostics(boundary, stage, kind):
    invoke, output, bridge = boundary
    original = RuntimeError("bridge boundary failure")
    setattr(bridge, stage + "_error", original)
    with pytest.raises(RuntimeError) as raised:
        invoke(kind)
    assert raised.value is original
    if stage == "exit":
        assert isinstance(original.__context__, support.ReleaseError)
    assert (output / "attached-bridge.log").read_text(
        encoding="utf-8"
    ) == f"bridge {'entered' if stage == 'enter' else 'stopped'}\n"


def test_manifest_write_failure_does_not_replace_primary(boundary, monkeypatch):
    invoke, _, _ = boundary
    write = Path.write_bytes

    def refuse(path, data):
        if path.name == "runtime-diagnostics.json":
            raise OSError("manifest disk failure")
        return write(path, data)

    monkeypatch.setattr(Path, "write_bytes", refuse)
    with pytest.raises(support.ReleaseError, match="public predecessor update failed") as raised:
        invoke("predecessor")
    assert raised.value.__notes__ == [
        "runtime diagnostic retention failed; inspect retained file statuses"
    ]


@pytest.mark.parametrize("kind", ["directory", "oversized", "symlink"])
def test_diagnostic_reads_reject_unsafe_sources(tmp_path, monkeypatch, kind):
    path = tmp_path / "input"
    if kind == "directory":
        path.mkdir()
        expected = "invalid_type"
    elif kind == "oversized":
        monkeypatch.setattr(support, "MAX_JSON_BYTES", 4)
        path.write_bytes(b"12345")
        expected = "too_large"
    else:
        target = tmp_path / "target"
        target.write_text("must not be read", encoding="utf-8")
        try:
            path.symlink_to(target)
        except OSError:
            pytest.skip("file symlinks unavailable on this host")
        expected = "invalid_type"
    assert runtime._read_runtime_diagnostic(path) == (expected, None)


def test_retention_failure_fails_otherwise_successful_execution(tmp_path):
    project = tmp_path / "project"
    output = tmp_path / "output"
    project.mkdir()
    output.mkdir()
    (project / "runtime-result.json").write_text(PRIVATE[2], encoding="utf-8")
    with pytest.raises(support.ReleaseError, match="runtime diagnostic retention failed"):
        runtime._retain_runtime_diagnostics(
            project, tmp_path / "missing", output, PRIVATE, b"ok", None
        )
    assert (output / "runtime-result.json").read_text(
        encoding="utf-8"
    ) == "qualification output withheld: private capability leaked\n"
    assert (
        json.loads((output / "runtime-diagnostics.json").read_text(encoding="utf-8"))[
            "runtime-result.json"
        ]
        == "withheld_private_value"
    )


@pytest.mark.parametrize("kind", ["predecessor", "a-to-b"])
def test_successful_child_secret_is_refused_before_wait(boundary, monkeypatch, kind):
    invoke, output, bridge = boundary
    waited = []
    monkeypatch.setattr(runtime, "_wait_for_runtime_result", lambda *_: waited.append(True))
    with pytest.raises(support.ReleaseError, match="process printed a private capability"):
        invoke(kind, stdout=PRIVATE[2], exit_code=0)
    assert not waited
    assert bridge.stopped
    assert PRIVATE[2] not in (output / "godot.log").read_text(encoding="utf-8")


@pytest.mark.parametrize("private", PRIVATE)
def test_timeout_stderr_secret_is_withheld(boundary, private):
    invoke, output, _ = boundary
    with pytest.raises(subprocess.TimeoutExpired):
        invoke("predecessor", timeout=True, stderr=private)
    assert (output / "godot.log").read_text(encoding="utf-8") == (
        "qualification output withheld: private capability leaked\n"
    )


@pytest.mark.parametrize(
    "name", ["attached-bridge.log", "runtime-result.json", "runtime-progress.json"]
)
@pytest.mark.parametrize("private", PRIVATE)
def test_each_retained_file_checks_every_private_value(tmp_path, name, private):
    project, output = tmp_path / "project", tmp_path / "output"
    project.mkdir()
    output.mkdir()
    bridge_log = tmp_path / "attached-bridge.log"
    source = bridge_log if name == bridge_log.name else project / name
    source.write_text(private, encoding="utf-8")
    primary = RuntimeError("original failure")
    runtime._retain_runtime_diagnostics(project, bridge_log, output, PRIVATE, None, primary)
    assert (output / name).read_text(
        encoding="utf-8"
    ) == "qualification output withheld: private capability leaked\n"
    statuses = json.loads((output / "runtime-diagnostics.json").read_text(encoding="utf-8"))
    assert statuses[name] == "withheld_private_value"
    assert primary.__notes__ == [
        "runtime diagnostic retention failed; inspect retained file statuses"
    ]


def test_failed_bridge_log_write_does_not_drop_driver_result(tmp_path, monkeypatch):
    project, output = tmp_path / "project", tmp_path / "output"
    project.mkdir()
    output.mkdir()
    bridge_log = tmp_path / "attached-bridge.log"
    bridge_log.write_text("bridge output", encoding="utf-8")
    (project / "runtime-result.json").write_text('{"error":"timeout"}', encoding="utf-8")
    write = runtime._write_secret_free_log

    def refuse(path, data, values):
        if path.name == "attached-bridge.log":
            raise OSError("private diagnostic must not be reported")
        write(path, data, values)

    monkeypatch.setattr(runtime, "_write_secret_free_log", refuse)
    primary = RuntimeError("original failure")
    runtime._retain_runtime_diagnostics(project, bridge_log, output, PRIVATE, None, primary)
    statuses = json.loads((output / "runtime-diagnostics.json").read_text(encoding="utf-8"))
    assert statuses["attached-bridge.log"] == "write_error"
    assert statuses["runtime-result.json"] == "retained"
    assert json.loads((output / "runtime-result.json").read_text(encoding="utf-8")) == {
        "error": "timeout"
    }
    assert "private diagnostic" not in str(statuses) + str(primary.__notes__)


def test_reparse_file_is_rejected_without_opening(tmp_path, monkeypatch):
    path = tmp_path / "diagnostic.log"
    monkeypatch.setattr(
        Path,
        "lstat",
        lambda _: SimpleNamespace(st_mode=0o100600, st_file_attributes=0x400, st_size=1),
    )
    opened = []
    monkeypatch.setattr(runtime.os, "open", lambda *_: opened.append(True))
    assert runtime._read_runtime_diagnostic(path) == ("invalid_type", None)
    assert not opened


def test_read_failure_is_not_absence(tmp_path, monkeypatch):
    path = tmp_path / "runtime-result.json"

    def refuse(_):
        raise PermissionError("private diagnostic")

    monkeypatch.setattr(Path, "lstat", refuse)
    assert runtime._read_runtime_diagnostic(path) == ("read_error", None)


def test_logs_use_artifact_bound_and_json_uses_smaller_bound(tmp_path, monkeypatch):
    monkeypatch.setattr(support, "MAX_JSON_BYTES", 4)
    monkeypatch.setattr(support, "MAX_FILE_BYTES", 8)
    log, result = tmp_path / "godot.log", tmp_path / "runtime-result.json"
    log.write_bytes(b"12345")
    result.write_bytes(b"12345")
    assert runtime._read_runtime_diagnostic(log) == ("read", b"12345")
    assert runtime._read_runtime_diagnostic(result) == ("too_large", None)
    log.write_bytes(b"123456789")
    assert runtime._read_runtime_diagnostic(log) == ("too_large", None)


def test_manifest_failure_fails_without_a_primary_error(tmp_path, monkeypatch):
    project, output = tmp_path / "project", tmp_path / "output"
    project.mkdir()
    output.mkdir()
    (output / "runtime-diagnostics.json").mkdir()
    with pytest.raises(support.ReleaseError, match="runtime diagnostic retention failed"):
        runtime._retain_runtime_diagnostics(
            project, tmp_path / "missing", output, PRIVATE, None, None
        )


def test_empty_diagnostics_remain_inventory_compatible(tmp_path):
    project, output = tmp_path / "project", tmp_path / "output"
    project.mkdir()
    output.mkdir()
    (project / "runtime-result.json").write_bytes(b"")
    runtime._retain_runtime_diagnostics(project, tmp_path / "missing", output, PRIVATE, b"", None)
    statuses = json.loads((output / "runtime-diagnostics.json").read_text(encoding="utf-8"))
    assert statuses["godot.log"] == statuses["runtime-result.json"] == "empty"
    assert (output / "runtime-result.json").read_text(
        encoding="utf-8"
    ) == "qualification diagnostic was empty\n"
    files = support.inventory(output)
    assert files["runtime-result.json"]["size"] > 0
    assert files["godot.log"]["size"] > 0


@pytest.mark.parametrize("kind", ["predecessor", "a-to-b"])
def test_oversized_editor_output_is_not_written(boundary, monkeypatch, kind):
    invoke, output, _ = boundary
    monkeypatch.setattr(support, "MAX_FILE_BYTES", 4)
    with pytest.raises(support.ReleaseError, match="output exceeds artifact size bound"):
        invoke(kind)
    assert not (output / "godot.log").exists()
    statuses = json.loads((output / "runtime-diagnostics.json").read_text(encoding="utf-8"))
    assert statuses["godot.log"] == "too_large"
