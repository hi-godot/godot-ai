#!/usr/bin/env python3
"""Serve the MCP dev server using *this worktree's* src/godot_ai.

Cross-platform replacement for the bash `serve-this-worktree` (#509/#514): it
resolves the shared `.venv` interpreter (`.venv/bin/python` on POSIX,
`.venv\\Scripts\\python.exe` on Windows), prepends this worktree's `src/` to
PYTHONPATH so `import godot_ai` resolves to the worktree source (not the root
repo's editable install), frees the HTTP port, and launches the server with
`--reload` and **both** `--port` and `--ws-port` so it matches an editor using
non-default port overrides.

Run it with any Python on PATH; the shared helpers and the spawned server both
resolve the venv interpreter:

    python script/serve_worktree.py --port 8000 --ws-port 9500
    python script/serve_worktree.py --port 18130 --ws-port 19630   # editor overrides

Extra arguments are passed through to `python -m godot_ai`.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import _dev_env  # noqa: E402

DEFAULT_PORT = 8000
DEFAULT_WS_PORT = 9500


def main() -> int:
    passthrough = sys.argv[1:]

    worktree = _dev_env.worktree_root()
    root = _dev_env.root_repo(worktree)

    venv_py = _dev_env.venv_python(root / ".venv")
    if not venv_py.is_file():
        sys.exit(
            f"error: {venv_py} not found — run script/setup-dev "
            "(or setup-dev.ps1 on Windows) in the root repo first"
        )

    src = _dev_env.worktree_src(worktree)
    if not src.is_dir():
        sys.exit(f"error: {src} not found")

    # Pull the ports out so we can free the HTTP port and re-emit both
    # canonically; fail fast on a malformed value rather than starting on the
    # wrong port.
    try:
        port, rest = _dev_env.extract_int_flag(passthrough, "--port", DEFAULT_PORT)
        ws_port, rest = _dev_env.extract_int_flag(rest, "--ws-port", DEFAULT_WS_PORT)
    except ValueError as exc:
        sys.exit(f"error: {exc}")

    _dev_env.free_port(port)

    cmd = [str(venv_py), "-m", "godot_ai"]
    # Default the transport/reload, but let explicit passthrough args win.
    if not _dev_env.has_flag(rest, "--transport"):
        cmd += ["--transport", "streamable-http"]
    cmd += ["--port", str(port), "--ws-port", str(ws_port)]
    if not _dev_env.has_flag(rest, "--reload"):
        cmd += ["--reload"]
    cmd += rest

    env = dict(os.environ)
    existing = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = str(src) + (os.pathsep + existing if existing else "")

    print(f"Serving worktree: {worktree}")
    print(f"Using venv:       {root / '.venv'}")
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
