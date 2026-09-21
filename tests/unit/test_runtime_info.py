from __future__ import annotations

import atexit
import json
import os
from pathlib import Path

import pytest

from godot_ai import runtime_info
from godot_ai.runtime_info import install_pid_file, is_plugin_managed


@pytest.fixture
def _unregister_atexit(monkeypatch):
    """Capture atexit handlers registered during install_pid_file so the
    test can invoke them explicitly and unregister them cleanly. Also
    snapshots and restores the module-level _PID_FILE_PATH so a test
    that calls install_pid_file doesn't leak plugin-managed mode into
    other tests in the suite.
    """
    registered: list = []
    saved_path = runtime_info._PID_FILE_PATH

    real_register = atexit.register

    def fake_register(fn, *args, **kwargs):
        registered.append((fn, args, kwargs))
        return real_register(fn, *args, **kwargs)

    monkeypatch.setattr(atexit, "register", fake_register)
    yield registered
    for fn, _args, _kwargs in registered:
        atexit.unregister(fn)
    runtime_info._PID_FILE_PATH = saved_path


def test_install_pid_file_writes_pid(tmp_path, _unregister_atexit):
    pid_path = tmp_path / "godot_ai_server.pid"

    result = install_pid_file(pid_path)

    assert result == pid_path
    assert pid_path.read_text(encoding="utf-8").strip() == str(os.getpid())


def test_install_pid_file_none_is_noop(_unregister_atexit):
    assert install_pid_file(None) is None
    assert install_pid_file("") is None
    assert _unregister_atexit == []


def test_is_plugin_managed_tracks_pid_file_install(tmp_path, _unregister_atexit):
    """`is_plugin_managed()` is the editor_reload_plugin handler's signal
    that calling reload will kill its own server process (issue #393).
    It must flip True only after `install_pid_file` actually wrote a file,
    and flip back when a subsequent install_pid_file(None) drops the path."""
    assert is_plugin_managed() is False

    install_pid_file(None)
    assert is_plugin_managed() is False

    install_pid_file(tmp_path / "server.pid")
    assert is_plugin_managed() is True

    ## A later install_pid_file(None) (e.g. a programmatic caller
    ## leaving plugin-managed mode) must flip the flag back to False.
    install_pid_file(None)
    assert is_plugin_managed() is False


def test_install_pid_file_creates_parent_dir(tmp_path, _unregister_atexit):
    pid_path = tmp_path / "deep" / "nested" / "server.pid"

    install_pid_file(pid_path)

    assert pid_path.is_file()


def test_install_pid_file_overwrites_stale_file(tmp_path, _unregister_atexit):
    pid_path = tmp_path / "server.pid"
    pid_path.write_text("99999\n", encoding="utf-8")

    install_pid_file(pid_path)

    assert pid_path.read_text(encoding="utf-8").strip() == str(os.getpid())


def test_atexit_cleanup_unlinks_our_pid(tmp_path, _unregister_atexit):
    pid_path = tmp_path / "server.pid"

    install_pid_file(pid_path)
    assert pid_path.is_file()

    # atexit registers one handler; call it to simulate interpreter shutdown.
    assert len(_unregister_atexit) == 1
    cleanup_fn = _unregister_atexit[0][0]
    cleanup_fn()

    assert not pid_path.exists(), "atexit cleanup should have removed the file"


def test_atexit_cleanup_skips_if_file_overwritten(tmp_path, _unregister_atexit):
    ## Simulate: we wrote our PID, then a replacement server started
    ## up and overwrote the file with its own PID. Our atexit must not
    ## delete the replacement's file.
    pid_path = tmp_path / "server.pid"
    install_pid_file(pid_path)

    other_pid = os.getpid() + 1_000_000  # guaranteed not our PID
    pid_path.write_text(f"{other_pid}\n", encoding="utf-8")

    cleanup_fn = _unregister_atexit[0][0]
    cleanup_fn()

    assert pid_path.is_file(), "should preserve a file claimed by a different PID"
    assert pid_path.read_text(encoding="utf-8").strip() == str(other_pid)


def test_atexit_cleanup_tolerates_missing_file(tmp_path, _unregister_atexit):
    pid_path = tmp_path / "server.pid"
    install_pid_file(pid_path)

    pid_path.unlink()

    cleanup_fn = _unregister_atexit[0][0]
    cleanup_fn()  # must not raise


def test_install_pid_file_expands_user(tmp_path, monkeypatch, _unregister_atexit):
    ## `Path.expanduser()` reads different env vars per platform — Windows'
    ## `ntpath.expanduser` ignores HOME and consults USERPROFILE (falling
    ## back to HOMEDRIVE+HOMEPATH), while POSIX `posixpath.expanduser`
    ## reads HOME. Point whichever applies at the tmp_path so `~/server.pid`
    ## actually lands in the sandbox instead of the developer's real home.
    if os.name == "nt":
        monkeypatch.setenv("USERPROFILE", str(tmp_path))
        monkeypatch.delenv("HOMEDRIVE", raising=False)
        monkeypatch.delenv("HOMEPATH", raising=False)
    else:
        monkeypatch.setenv("HOME", str(tmp_path))

    path_arg = "~/server.pid"
    result = install_pid_file(path_arg)

    assert result == Path(path_arg).expanduser()
    assert result == tmp_path / "server.pid"
    assert result.is_file()


def test_main_plumbs_pid_file_into_runtime_info(monkeypatch, tmp_path):
    """End-to-end: `--pid-file` on the CLI should land in install_pid_file."""
    pid_path = tmp_path / "via_cli.pid"
    captured: dict[str, object] = {}

    def fake_install(path):
        captured["path"] = path
        return Path(path) if path else None

    monkeypatch.setattr("godot_ai.runtime_info.install_pid_file", fake_install)

    ## Stub out the actual server run so the test doesn't bind a port.
    class StubServer:
        def run(self, **kwargs):
            captured["run_kwargs"] = kwargs

    def _fake_create_server(**_kwargs):
        return StubServer()

    monkeypatch.setattr("godot_ai.server.create_server", _fake_create_server)

    import godot_ai
    from godot_ai import asgi

    monkeypatch.setattr(godot_ai, "preflight_check_port", lambda *_args, **_kwargs: None)

    ## Hermetic against an inherited GODOT_AI_HTTP_ACCESS_LOG in the test env.
    monkeypatch.delenv(asgi.HTTP_ACCESS_LOG_ENV, raising=False)

    godot_ai.main(
        [
            "--transport",
            "streamable-http",
            "--port",
            "8123",
            "--ws-port",
            "9555",
            "--pid-file",
            str(pid_path),
        ]
    )

    assert captured["path"] == str(pid_path)
    assert captured["run_kwargs"] == {
        "transport": "streamable-http",
        "port": 8123,
        "uvicorn_config": asgi.hardened_uvicorn_config(access_log=False),
    }


@pytest.fixture
def _reset_startup_report():
    saved = runtime_info._STARTUP_REPORT_PATH
    yield
    runtime_info._STARTUP_REPORT_PATH = saved


def test_startup_report_is_written_only_while_armed(tmp_path, _reset_startup_report):
    runtime_info.install_startup_report(None)
    assert runtime_info.report_startup_failure(RuntimeError("unarmed")) is None

    path = tmp_path / "startup.json"
    assert runtime_info.install_startup_report(path) == path
    assert runtime_info.report_startup_failure(PermissionError(13, "denied"), hint="fix") == path
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert payload["pid"] == os.getpid()
    assert payload["error"] == "PermissionError"
    assert "denied" in payload["message"]
    assert payload["hint"] == "fix"

    ## Published: later faults are runtime faults, never startup reports.
    runtime_info.disarm_startup_report()
    path.unlink()
    assert runtime_info.report_startup_failure(RuntimeError("late")) is None
    assert not path.exists()


def test_startup_report_is_bounded_and_never_masks_the_failure(tmp_path, _reset_startup_report):
    blocker = tmp_path / "not-a-directory"
    blocker.write_text("x", encoding="utf-8")
    runtime_info.install_startup_report(blocker / "report.json")
    assert runtime_info.report_startup_failure(RuntimeError("boom")) is None

    path = tmp_path / "report.json"
    runtime_info.install_startup_report(path)
    runtime_info.report_startup_failure(RuntimeError("m" * 5000))
    payload = json.loads(path.read_text(encoding="utf-8"))
    assert len(payload["message"]) == runtime_info._STARTUP_REPORT_MAX_CHARS


def test_main_reports_a_startup_failure_before_publication(
    monkeypatch, tmp_path, _reset_startup_report
):
    """A server that dies before its capability record is published tells the dock why."""
    report = tmp_path / "startup.json"

    def _explode(**_kwargs):
        raise RuntimeError("capability directory is not writable")

    monkeypatch.setattr("godot_ai.server.create_server", _explode)

    import godot_ai

    monkeypatch.setattr(godot_ai, "preflight_check_port", lambda *_args, **_kwargs: None)

    with pytest.raises(RuntimeError, match="not writable"):
        godot_ai.main(
            [
                "--transport",
                "streamable-http",
                "--port",
                "8123",
                "--ws-port",
                "9555",
                "--startup-report",
                str(report),
            ]
        )

    payload = json.loads(report.read_text(encoding="utf-8"))
    assert payload["error"] == "RuntimeError"
    assert "not writable" in payload["message"]


def test_first_startup_report_wins_and_system_exit_is_named(tmp_path, _reset_startup_report):
    path = tmp_path / "startup.json"
    runtime_info.install_startup_report(path)
    assert runtime_info.report_startup_failure(OSError(98, "WebSocket port in use")) == path
    ## The generic catch-all in main() must not overwrite the specific cause.
    assert runtime_info.report_startup_failure(SystemExit(98)) is None
    assert "WebSocket port in use" in json.loads(path.read_text(encoding="utf-8"))["message"]

    runtime_info.install_startup_report(path)
    runtime_info.report_startup_failure(SystemExit(98))
    assert json.loads(path.read_text(encoding="utf-8"))["message"] == "exited with code 98"


def test_startup_report_requires_an_http_transport(_reset_startup_report):
    import godot_ai

    with pytest.raises(SystemExit):
        godot_ai.main(["--transport", "stdio", "--startup-report", "x.json"])
