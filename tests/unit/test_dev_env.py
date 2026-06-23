"""Unit tests for ``script/_dev_env.py`` — cross-platform dev-script helpers (#509).

Covers the platform-branching logic (venv interpreter layout, port parsing) and
the venv re-exec decision so the Windows path is exercised on a POSIX CI runner
without needing a Windows host.
"""

from __future__ import annotations

import py_compile
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_DIR = REPO_ROOT / "script"
if str(SCRIPT_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIR))

import _dev_env  # noqa: E402


# --------------------------------------------------------------------------- #
# venv interpreter layout
# --------------------------------------------------------------------------- #
def test_venv_python_posix():
    # Explicit windows flag keeps the global os.name (and pathlib's flavour) untouched.
    assert _dev_env.venv_python(Path("/proj/.venv"), windows=False) == Path(
        "/proj/.venv/bin/python"
    )


def test_venv_python_windows():
    result = _dev_env.venv_python(Path("/proj/.venv"), windows=True)
    assert result.parts[-3:] == (".venv", "Scripts", "python.exe")


def test_find_venv_python_present(monkeypatch, tmp_path):
    # find_venv_python resolves the layout for the host it runs on.
    exe = _dev_env.venv_python(tmp_path / ".venv")
    exe.parent.mkdir(parents=True)
    exe.write_text("")
    monkeypatch.setattr(_dev_env, "root_repo", lambda worktree=None: tmp_path)
    assert _dev_env.find_venv_python() == exe


def test_find_venv_python_absent(monkeypatch, tmp_path):
    monkeypatch.setattr(_dev_env, "root_repo", lambda worktree=None: tmp_path)
    assert _dev_env.find_venv_python() is None


def test_find_venv_python_rejects_directory(monkeypatch, tmp_path):
    # A directory sitting at the interpreter path must read as "no venv", not be
    # handed to execv() — is_file() guards that (exists() would not).
    exe = _dev_env.venv_python(tmp_path / ".venv")
    exe.mkdir(parents=True)
    monkeypatch.setattr(_dev_env, "root_repo", lambda worktree=None: tmp_path)
    assert _dev_env.find_venv_python() is None


# --------------------------------------------------------------------------- #
# worktree / root-repo resolution
# --------------------------------------------------------------------------- #
def test_root_from_common_dir_absolute(tmp_path):
    common = tmp_path / "main-repo" / ".git"
    assert _dev_env._root_from_common_dir(tmp_path, str(common)) == tmp_path / "main-repo"


def test_root_from_common_dir_relative(tmp_path):
    worktree = tmp_path / "wt"
    (worktree / ".git").mkdir(parents=True)
    # A bare ".git" relative to the worktree resolves the root back to the worktree.
    assert _dev_env._root_from_common_dir(worktree, ".git") == worktree


def test_worktree_src():
    assert _dev_env.worktree_src(Path("/foo/bar")) == Path("/foo/bar/src")


# --------------------------------------------------------------------------- #
# arg parsing
# --------------------------------------------------------------------------- #
def test_extract_int_flag_space_separated():
    argv = ["--port", "18130", "--ws-port", "19630"]
    port, rest = _dev_env.extract_int_flag(argv, "--port", 8000)
    assert port == 18130
    assert rest == ["--ws-port", "19630"]


def test_extract_int_flag_equals():
    port, rest = _dev_env.extract_int_flag(["--port=8010", "--extra"], "--port", 8000)
    assert port == 8010
    assert rest == ["--extra"]


def test_extract_int_flag_default_when_absent():
    ws, rest = _dev_env.extract_int_flag(["--reload"], "--ws-port", 9500)
    assert ws == 9500
    assert rest == ["--reload"]


def test_extract_int_flag_chained_removes_both():
    # serve_worktree extracts --port then --ws-port from the remainder.
    port, rest = _dev_env.extract_int_flag(["--port", "1", "--ws-port", "2", "--x"], "--port", 8000)
    ws, rest = _dev_env.extract_int_flag(rest, "--ws-port", 9500)
    assert (port, ws) == (1, 2)
    assert rest == ["--x"]


def test_extract_int_flag_missing_value_raises():
    with pytest.raises(ValueError, match="requires an integer"):
        _dev_env.extract_int_flag(["--ws-port", "9000", "--port"], "--port", 8000)


def test_extract_int_flag_non_integer_raises():
    with pytest.raises(ValueError, match="must be an integer"):
        _dev_env.extract_int_flag(["--port", "80O0"], "--port", 8000)


def test_extract_int_flag_non_integer_equals_raises():
    with pytest.raises(ValueError, match="must be an integer"):
        _dev_env.extract_int_flag(["--port="], "--port", 8000)


def test_has_flag():
    assert _dev_env.has_flag(["--reload"], "--reload") is True
    assert _dev_env.has_flag(["--transport=streamable-http"], "--transport") is True
    assert _dev_env.has_flag(["--port", "8000"], "--reload") is False


# --------------------------------------------------------------------------- #
# port-output parsing
# --------------------------------------------------------------------------- #
def test_parse_lsof_pids():
    assert _dev_env.parse_lsof_pids("1234\n5678\n1234\n") == [1234, 5678]
    assert _dev_env.parse_lsof_pids("") == []


def test_parse_netstat_pids():
    out = (
        "  Proto  Local Address          Foreign Address        State           PID\n"
        "  TCP    0.0.0.0:8000           0.0.0.0:0              LISTENING       4321\n"
        "  TCP    127.0.0.1:9500         0.0.0.0:0              LISTENING       9999\n"
        "  TCP    [::]:8000              [::]:0                 LISTENING       4321\n"
        "  TCP    0.0.0.0:8000           1.2.3.4:55555          ESTABLISHED     1111\n"
        "  UDP    0.0.0.0:8000           *:*                                    2222\n"
    )
    # IPv4 + IPv6 listeners both counted; ESTABLISHED and UDP rows skipped.
    assert _dev_env.parse_netstat_pids(out, 8000) == [4321]
    assert _dev_env.parse_netstat_pids(out, 9500) == [9999]
    assert _dev_env.parse_netstat_pids(out, 1234) == []


def test_parse_netstat_pids_locale_independent():
    # Non-English Windows localizes the State column; listeners must still be
    # found via the wildcard foreign address (*:0), not the literal "LISTENING".
    out = (
        "  TCP    0.0.0.0:8000           0.0.0.0:0              ABHÖREN         4321\n"
        "  TCP    0.0.0.0:8000           1.2.3.4:55555          HERGESTELLT     1111\n"
    )
    assert _dev_env.parse_netstat_pids(out, 8000) == [4321]


# --------------------------------------------------------------------------- #
# venv re-exec decision
# --------------------------------------------------------------------------- #
def test_reexec_noop_when_guard_set(monkeypatch):
    monkeypatch.setenv("GUARD_X", "1")
    calls = []
    monkeypatch.setattr(_dev_env.os, "execv", lambda *a: calls.append(a))
    _dev_env.reexec_into_venv(guard_env="GUARD_X")
    assert calls == []


def test_reexec_noop_when_opt_out(monkeypatch):
    monkeypatch.delenv("GUARD_Y", raising=False)
    monkeypatch.setenv("OPT_OUT", "1")
    calls = []
    monkeypatch.setattr(_dev_env.os, "execv", lambda *a: calls.append(a))
    _dev_env.reexec_into_venv(guard_env="GUARD_Y", opt_out_env="OPT_OUT")
    assert calls == []


def test_reexec_noop_when_no_venv(monkeypatch):
    monkeypatch.delenv("GUARD_Z", raising=False)
    monkeypatch.setattr(_dev_env, "find_venv_python", lambda worktree=None: None)
    calls = []
    monkeypatch.setattr(_dev_env.os, "execv", lambda *a: calls.append(a))
    _dev_env.reexec_into_venv(guard_env="GUARD_Z")
    assert calls == []


def test_reexec_noop_when_already_in_venv(monkeypatch):
    monkeypatch.delenv("GUARD_W", raising=False)
    monkeypatch.setattr(_dev_env, "find_venv_python", lambda worktree=None: Path(sys.executable))
    calls = []
    monkeypatch.setattr(_dev_env.os, "execv", lambda *a: calls.append(a))
    _dev_env.reexec_into_venv(guard_env="GUARD_W")
    assert calls == []


def test_reexec_execs_into_venv(monkeypatch, tmp_path):
    monkeypatch.delenv("GUARD_V", raising=False)
    fake_python = tmp_path / "python"
    fake_python.write_text("")
    monkeypatch.setattr(_dev_env, "find_venv_python", lambda worktree=None: fake_python)
    monkeypatch.setattr(_dev_env.sys, "argv", ["script/stormtest.py", "--flag"])
    captured = {}

    def fake_execv(path, args):
        captured["path"] = path
        captured["args"] = args

    monkeypatch.setattr(_dev_env.os, "execv", fake_execv)
    try:
        _dev_env.reexec_into_venv(guard_env="GUARD_V")
        assert captured["path"] == str(fake_python)
        assert captured["args"] == [str(fake_python), "script/stormtest.py", "--flag"]
        # Guard is set so a re-execed process won't loop.
        assert _dev_env.os.environ.get("GUARD_V") == "1"
    finally:
        _dev_env.os.environ.pop("GUARD_V", None)


# --------------------------------------------------------------------------- #
# port listening probe
# --------------------------------------------------------------------------- #
def test_port_listening_detects_bound_socket():
    import socket

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as srv:
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        port = srv.getsockname()[1]
        assert _dev_env._port_listening(port) is True


# --------------------------------------------------------------------------- #
# scripts parse cleanly
# --------------------------------------------------------------------------- #
def test_dev_scripts_compile():
    for name in ("_dev_env.py", "stormtest.py", "serve_worktree.py"):
        py_compile.compile(str(SCRIPT_DIR / name), doraise=True)
