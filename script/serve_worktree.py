#!/usr/bin/env python3
"""Serve the MCP dev server using *this worktree's* src/godot_ai.

Cross-platform replacement for the bash `serve-this-worktree` (#509/#514): it
resolves the shared `.venv` interpreter (`.venv/bin/python` on POSIX,
`.venv\\Scripts\\python.exe` on Windows), prepends this worktree's `src/` to
PYTHONPATH so `import godot_ai` resolves to the worktree source (not the root
repo's editable install), frees the HTTP port, and launches the server with
`--reload` and **both** `--port` and `--ws-port` so it matches an editor using
non-default port overrides.

Run it with any Python on PATH — it re-launches the resolved venv interpreter:

    python script/serve_worktree.py --port 8000 --ws-port 9500
    python script/serve_worktree.py --port 18130 --ws-port 19630   # editor overrides

Extra arguments are passed through to `python -m godot_ai`.
"""

from __future__ import annotations

import os
import platform
import subprocess
import sys
import time

DEFAULT_PORT = 8000
DEFAULT_WS_PORT = 9500


def _run(cmd: list[str]) -> str:
    """Best-effort subprocess capture; '' if the tool is missing or errors."""
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, check=False
        ).stdout
    except (FileNotFoundError, OSError):
        return ""


def _git(args: list[str], cwd: str | None = None) -> str:
    return _run(["git", *args] if cwd is None else ["git", "-C", cwd, *args]).strip()


def _resolve_roots() -> tuple[str, str]:
    """Return (worktree_root, root_repo). The `.venv` and editable install live
    in the main repo's common dir, not the worktree, so resolve both."""
    worktree = _git(["rev-parse", "--show-toplevel"])
    if not worktree:
        sys.exit("error: not inside a git repository")
    common = _git(["rev-parse", "--git-common-dir"], cwd=worktree)
    # --git-common-dir may be relative to the worktree root.
    if not os.path.isabs(common):
        common = os.path.abspath(os.path.join(worktree, common))
    root_repo = os.path.dirname(common)
    return worktree, root_repo


def _venv_python(root_repo: str) -> str:
    if platform.system() == "Windows":
        return os.path.join(root_repo, ".venv", "Scripts", "python.exe")
    return os.path.join(root_repo, ".venv", "bin", "python")


def _pids_on_port(port: int) -> set[str]:
    """LISTENING PIDs on `port`, via the OS's own tooling (no psutil dep)."""
    if platform.system() == "Windows":
        pids: set[str] = set()
        for line in _run(["netstat", "-ano", "-p", "tcp"]).splitlines():
            parts = line.split()
            # proto  local-addr  foreign-addr  STATE  pid
            if len(parts) >= 5 and parts[3].upper() == "LISTENING":
                if parts[1].rsplit(":", 1)[-1] == str(port):
                    pids.add(parts[4])
        return pids
    out = _run(["lsof", "-i", f":{port}", "-sTCP:LISTEN", "-t"])
    return {p.strip() for p in out.split() if p.strip()}


def _free_port(port: int) -> None:
    """Best-effort: stop whatever is LISTENING on `port` so we replace the
    plugin-spawned server rather than stack on top of it."""
    pids = _pids_on_port(port)
    if not pids:
        return
    print(f"Stopping existing listener(s) on port {port}: {', '.join(sorted(pids))}")
    for pid in pids:
        if platform.system() == "Windows":
            _run(["taskkill", "/F", "/PID", pid])
        else:
            try:
                os.kill(int(pid), 15)
            except (ProcessLookupError, ValueError, PermissionError):
                pass
    # The socket can stay bound briefly after the owner dies; wait for it to
    # actually free so the new server doesn't lose a bind race. Bounded so a
    # stubborn listener doesn't hang the launcher — we proceed and let the
    # server's own bind error surface if it never releases.
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline:
        if not _pids_on_port(port):
            return
        time.sleep(0.2)


def _extract_int_flag(args: list[str], name: str, default: int) -> int:
    """Read --name <v> / --name=v from a passthrough arg list (no removal).

    Exits on a present-but-malformed flag rather than silently using the
    default — otherwise a typo'd `--port` would free/echo the default port
    while the doomed bad value still passes through to the server, leaving the
    editor with no server.
    """
    for i, a in enumerate(args):
        if a == name:
            if i + 1 >= len(args):
                sys.exit(f"error: {name} requires an integer value")
            raw = args[i + 1]
        elif a.startswith(name + "="):
            raw = a.split("=", 1)[1]
        else:
            continue
        try:
            return int(raw)
        except ValueError:
            sys.exit(f"error: {name} value {raw!r} is not an integer")
    return default


def _has_flag(args: list[str], name: str) -> bool:
    return any(a == name or a.startswith(name + "=") for a in args)


def main() -> int:
    passthrough = sys.argv[1:]
    worktree, root_repo = _resolve_roots()

    venv_py = _venv_python(root_repo)
    if not os.path.isfile(venv_py):
        sys.exit(
            f"error: {venv_py} not found — run script/setup-dev "
            "(or setup-dev.ps1 on Windows) in the root repo first"
        )

    src = os.path.join(worktree, "src")
    if not os.path.isdir(src):
        sys.exit(f"error: {src} not found")

    port = _extract_int_flag(passthrough, "--port", DEFAULT_PORT)
    ws_port = _extract_int_flag(passthrough, "--ws-port", DEFAULT_WS_PORT)

    _free_port(port)

    # Default the transport/ports/reload, but let explicit passthrough args win.
    cmd = [venv_py, "-m", "godot_ai"]
    if not _has_flag(passthrough, "--transport"):
        cmd += ["--transport", "streamable-http"]
    if not _has_flag(passthrough, "--port"):
        cmd += ["--port", str(port)]
    if not _has_flag(passthrough, "--ws-port"):
        cmd += ["--ws-port", str(ws_port)]
    if not _has_flag(passthrough, "--reload"):
        cmd += ["--reload"]
    cmd += passthrough

    env = dict(os.environ)
    sep = os.pathsep
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = src + (sep + existing if existing else "")

    print(f"Serving worktree: {worktree}")
    print(f"Using venv:       {os.path.join(root_repo, '.venv')}")
    print(f"PYTHONPATH:       {src}")
    print(f"HTTP port:        {port}    WS port: {ws_port}")

    # subprocess (not os.exec*) for consistent Windows behavior; forward the
    # child's exit code and let Ctrl-C reach the server cleanly.
    try:
        return subprocess.run(cmd, env=env, check=False).returncode
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
