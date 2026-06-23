"""Shared cross-platform helpers for the dev scripts (stormtest, serve_worktree).

POSIX/Windows differences — the venv interpreter layout (``bin/python`` vs
``Scripts\\python.exe``) and port freeing (``lsof`` vs ``netstat``/``taskkill``)
— are resolved here so the *documented* commands are identical on every OS and
no script carries a hard ``bash``/``lsof`` dependency. See issue #509.

stdlib-only and side-effect-free on import, so it is safe to import from a test
or before a script re-execs into the venv.
"""

from __future__ import annotations

import os
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path


# --------------------------------------------------------------------------- #
# venv interpreter resolution
# --------------------------------------------------------------------------- #
def venv_python(venv_dir: Path, *, windows: bool | None = None) -> Path:
    """Interpreter path inside ``venv_dir`` for the target OS.

    ``windows`` defaults to the current platform; pass it explicitly to resolve
    the other layout (used by tests so the Windows branch is covered on POSIX CI).
    """
    if windows is None:
        windows = os.name == "nt"
    if windows:
        return venv_dir / "Scripts" / "python.exe"
    return venv_dir / "bin" / "python"


def _git(args: list[str], cwd: Path) -> str | None:
    """Run a read-only git command, returning trimmed stdout or ``None`` on error."""
    try:
        out = subprocess.run(
            ["git", "-C", str(cwd), *args],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    return out.stdout.strip() or None


def worktree_root(start: Path | None = None) -> Path:
    """Top of the current git worktree; falls back to this file's repo root."""
    start = start or Path.cwd()
    top = _git(["rev-parse", "--show-toplevel"], start)
    if top:
        return Path(top)
    # script/_dev_env.py -> repo root
    return Path(__file__).resolve().parent.parent


def _root_from_common_dir(worktree: Path, common_dir: str) -> Path:
    """Parent of the git common dir (the main repo that owns the shared .venv)."""
    common = Path(common_dir)
    if not common.is_absolute():
        common = (worktree / common).resolve()
    return common.parent


def root_repo(worktree: Path | None = None) -> Path:
    """Main repo dir holding the shared ``.venv`` (handles git worktrees).

    In a worktree the ``.venv`` lives in the main checkout, not the worktree, so
    ``git rev-parse --git-common-dir`` (whose parent is the main repo) is used to
    find it. On the main checkout this collapses to the worktree itself.
    """
    wt = worktree or worktree_root()
    common = _git(["rev-parse", "--git-common-dir"], wt)
    if common:
        return _root_from_common_dir(wt, common)
    return wt


def worktree_src(worktree: Path | None = None) -> Path:
    """The ``src/`` directory of the given (or current) worktree."""
    return (worktree or worktree_root()) / "src"


def find_venv_python(worktree: Path | None = None) -> Path | None:
    """The checkout's venv interpreter, or ``None`` if it isn't a real file.

    ``is_file()`` (not ``exists()``) so a directory sitting at the interpreter
    path is treated as "no venv" rather than handed to ``execv()``, which would
    crash with an OSError instead of cleanly falling through.
    """
    candidate = venv_python(root_repo(worktree) / ".venv")
    return candidate if candidate.is_file() else None


def reexec_into_venv(*, guard_env: str, opt_out_env: str | None = None) -> None:
    """Re-exec the current script under the project venv interpreter.

    No-op when: the venv is absent, we're already running it, ``guard_env`` is
    set (re-exec already happened, so we never loop), or ``opt_out_env`` is set.
    Lets a script's documented invocation be ``python <script>`` on every OS — it
    hops into the venv itself instead of the caller naming ``bin/python`` vs
    ``Scripts\\python.exe``.
    """
    if os.environ.get(guard_env):
        return
    if opt_out_env and os.environ.get(opt_out_env):
        return
    target = find_venv_python()
    if target is None:
        return
    try:
        if target.resolve() == Path(sys.executable).resolve():
            return
    except OSError:
        return
    os.environ[guard_env] = "1"
    os.execv(str(target), [str(target), *sys.argv])


# --------------------------------------------------------------------------- #
# argument parsing
# --------------------------------------------------------------------------- #
def extract_int_flag(argv: list[str], flag: str, default: int) -> tuple[int, list[str]]:
    """Pull ``<flag> N`` / ``<flag>=N`` out of ``argv``.

    Returns ``(value, remaining_args)`` with the flag removed, so a caller can
    read a port (and free it / re-emit it canonically) without leaving a
    duplicate in the passthrough args. Raises ``ValueError`` on a missing or
    non-integer value — fail fast rather than silently fall back to ``default``
    and act on the wrong value.
    """
    value = default
    rest: list[str] = []
    i = 0
    while i < len(argv):
        arg = argv[i]
        if arg == flag:
            if i + 1 >= len(argv):
                raise ValueError(f"{flag} requires an integer value")
            raw = argv[i + 1]
            i += 2
        elif arg.startswith(flag + "="):
            raw = arg.split("=", 1)[1]
            i += 1
        else:
            rest.append(arg)
            i += 1
            continue
        try:
            value = int(raw)
        except ValueError:
            raise ValueError(f"{flag} value must be an integer, got {raw!r}") from None
    return value, rest


def has_flag(argv: list[str], flag: str) -> bool:
    """True if ``flag`` (bare or ``flag=…``) appears in ``argv``."""
    return any(a == flag or a.startswith(flag + "=") for a in argv)


# --------------------------------------------------------------------------- #
# port freeing (replace a plugin-spawned server instead of stacking on it)
# --------------------------------------------------------------------------- #
def parse_lsof_pids(output: str) -> list[int]:
    """PIDs from ``lsof -ti`` output (one PID per line), de-duplicated in order."""
    return list(dict.fromkeys(int(tok) for tok in output.split() if tok.isdigit()))


def parse_netstat_pids(output: str, port: int) -> list[int]:
    """Listener PIDs for ``port`` from Windows ``netstat -ano`` output.

    Identifies listeners by a wildcard foreign address (``0.0.0.0:0`` / ``[::]:0``)
    rather than the literal ``LISTENING`` state — that state string is localized
    on non-English Windows (e.g. ``ABHÖREN``, ``ÉCOUTE``), so keying on it would
    silently miss listeners and leave the port un-freed. A bound-but-connected
    socket has a real foreign ``host:port``, so ``foreign == *:0`` is the stable,
    locale-independent listener signal.
    """
    needle = f":{port}"
    pids: list[int] = []
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 5:
            continue
        local, foreign, pid = parts[1], parts[2], parts[-1]
        if not foreign.endswith(":0"):  # wildcard foreign addr => listener
            continue
        if not local.endswith(needle):  # local addr, e.g. 0.0.0.0:8000 or [::]:8000
            continue
        if pid.isdigit():
            pids.append(int(pid))
    return list(dict.fromkeys(pids))


def _port_listening(port: int) -> bool:
    # Check both families: a dev server (esp. on Windows, where sockets are
    # commonly IPv6-only — see #511) may be bound to ::1 rather than 127.0.0.1.
    for family, host in ((socket.AF_INET, "127.0.0.1"), (socket.AF_INET6, "::1")):
        try:
            with socket.socket(family, socket.SOCK_STREAM) as sock:
                sock.settimeout(0.5)
                if sock.connect_ex((host, port)) == 0:
                    return True
        except OSError:
            continue
    return False


def _listener_pids(port: int) -> list[int]:
    try:
        if os.name == "nt":
            # No `-p tcp`: on Windows that filters to IPv4 only, missing IPv6
            # listeners on `::1` (which _port_listening probes for — #511). The
            # bare form reports tcp + tcpv6; parse_netstat_pids isolates the
            # listener rows for either family and skips the shorter UDP rows.
            out = subprocess.run(
                ["netstat", "-ano"],
                capture_output=True,
                text=True,
            ).stdout
            return parse_netstat_pids(out, port)
        out = subprocess.run(
            ["lsof", "-ti", f"tcp:{port}", "-sTCP:LISTEN"],
            capture_output=True,
            text=True,
        ).stdout
        return parse_lsof_pids(out)
    except (OSError, subprocess.SubprocessError):
        return []


def _kill_pid(pid: int) -> None:
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/F", "/PID", str(pid)], capture_output=True)
        else:
            os.kill(pid, signal.SIGTERM)
    except (OSError, subprocess.SubprocessError):
        pass


def free_port(port: int) -> None:
    """Best-effort: stop any process currently listening on ``port``.

    Cross-platform replacement for the bash ``lsof | xargs kill`` dance. Silent
    and non-fatal if the port is free or the listener can't be identified. Waits
    for the socket to actually release so the caller doesn't lose a bind race.
    """
    if not _port_listening(port):
        return
    print(f"Stopping existing listener on port {port}")
    for pid in _listener_pids(port):
        _kill_pid(pid)
    # Give the socket a moment to release before the caller binds it.
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        if not _port_listening(port):
            return
        time.sleep(0.2)
