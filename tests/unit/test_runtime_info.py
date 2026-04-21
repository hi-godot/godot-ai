from __future__ import annotations

import atexit
import os
from pathlib import Path

import pytest

from godot_ai.runtime_info import install_pid_file


@pytest.fixture
def _unregister_atexit(monkeypatch):
    """Capture atexit handlers registered during install_pid_file so the
    test can invoke them explicitly and unregister them cleanly.
    """
    registered: list = []

    real_register = atexit.register

    def fake_register(fn, *args, **kwargs):
        registered.append((fn, args, kwargs))
        return real_register(fn, *args, **kwargs)

    monkeypatch.setattr(atexit, "register", fake_register)
    yield registered
    for fn, _args, _kwargs in registered:
        atexit.unregister(fn)


def test_install_pid_file_writes_pid(tmp_path, _unregister_atexit):
    pid_path = tmp_path / "godot_ai_server.pid"

    result = install_pid_file(pid_path)

    assert result == pid_path
    assert pid_path.read_text(encoding="utf-8").strip() == str(os.getpid())


def test_install_pid_file_none_is_noop(_unregister_atexit):
    assert install_pid_file(None) is None
    assert install_pid_file("") is None
    assert _unregister_atexit == []


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

    monkeypatch.setattr("godot_ai.server.create_server", lambda ws_port: StubServer())

    import godot_ai

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
    assert captured["run_kwargs"] == {"transport": "streamable-http", "port": 8123}
