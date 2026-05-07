"""Write the server's runtime PID to a file so the Godot plugin can kill
the *real* Python process deterministically, even when a launcher (uvx,
pipx) spawned us and its own PID is stale or untrackable.

The plugin passes `--pid-file <absolute path>` and we write the integer
PID on startup, then `atexit`-unlink on clean shutdown. On SIGTERM /
`TerminateProcess` the file is left behind; the plugin already has the
PID from the file and doesn't care whether we cleaned up.
"""

from __future__ import annotations

import atexit
import os
from pathlib import Path

_PID_FILE_PATH: Path | None = None


def install_pid_file(path: str | os.PathLike[str] | None) -> Path | None:
    """Write `os.getpid()` to `path` and register an atexit unlink.

    Returns the resolved Path on success, None when `path` is falsy
    (caller did not pass `--pid-file`). Any write error falls through
    to the caller — we'd rather surface a broken install than silently
    continue with the plugin unable to find our PID.
    """
    global _PID_FILE_PATH
    if not path:
        return None

    pid_path = Path(path).expanduser()
    pid_path.parent.mkdir(parents=True, exist_ok=True)
    pid_path.write_text(f"{os.getpid()}\n", encoding="utf-8")
    _PID_FILE_PATH = pid_path

    def _cleanup() -> None:
        ## Only unlink if the file still holds *our* PID. Prevents a
        ## late atexit from racing a replacement server that already
        ## overwrote the file with its own PID.
        try:
            current = pid_path.read_text(encoding="utf-8").strip()
        except OSError:
            return
        if current == str(os.getpid()):
            try:
                pid_path.unlink()
            except OSError:
                pass

    atexit.register(_cleanup)
    return pid_path


def is_plugin_managed() -> bool:
    """True when this server was spawned by the Godot plugin.

    The plugin always passes `--pid-file <path>` when it spawns the
    Python server (see `plugin/addons/godot_ai/utils/server_lifecycle.gd`),
    and an externally launched `python -m godot_ai` does not. So a
    recorded pid-file path is a reliable signal that calling
    `editor_reload_plugin` will kill our own process.
    """
    return _PID_FILE_PATH is not None
