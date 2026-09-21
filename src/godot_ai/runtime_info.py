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
import json
import os
from pathlib import Path

_PID_FILE_PATH: Path | None = None
_STARTUP_REPORT_PATH: Path | None = None
_STARTUP_REPORT_WRITTEN = False
_STARTUP_REPORT_MAX_CHARS = 2000


def install_startup_report(path: str | os.PathLike[str] | None) -> Path | None:
    """Remember where a startup failure should be reported.

    The plugin passes ``--startup-report <absolute path>`` beside the pid
    file and removes any stale report before it spawns us, so a report that
    exists after a launch was written by that launch. Nothing is written
    here; :func:`report_startup_failure` writes only when startup fails
    before the capability record is published, which is exactly the window
    the plugin otherwise sees as "exited before publishing capabilities".
    """
    global _STARTUP_REPORT_PATH, _STARTUP_REPORT_WRITTEN
    _STARTUP_REPORT_PATH = Path(path).expanduser() if path else None
    _STARTUP_REPORT_WRITTEN = False
    return _STARTUP_REPORT_PATH


def startup_report_path() -> Path | None:
    return _STARTUP_REPORT_PATH


def disarm_startup_report() -> None:
    """Stop reporting: the capability record is published, startup is over."""
    global _STARTUP_REPORT_PATH
    _STARTUP_REPORT_PATH = None


def report_startup_failure(exc: BaseException, *, hint: str = "") -> Path | None:
    """Write ``exc`` to the startup report so the editor dock can show it.

    The first report wins: a site that knows the cause (the port preflight,
    the capability directory) reports a specific message before the generic
    exception reaches ``main``'s catch-all. Best effort: a report that
    cannot be written must never mask the failure it describes, so every
    error here is swallowed.
    """
    global _STARTUP_REPORT_WRITTEN
    path = _STARTUP_REPORT_PATH
    if path is None or _STARTUP_REPORT_WRITTEN:
        return None
    if isinstance(exc, SystemExit) and not isinstance(exc.code, str):
        message = f"exited with code {exc.code}"
    else:
        message = str(exc).strip() or exc.__class__.__name__
    payload = {
        "pid": os.getpid(),
        "error": exc.__class__.__name__,
        "message": message[:_STARTUP_REPORT_MAX_CHARS],
        "hint": hint[:_STARTUP_REPORT_MAX_CHARS],
    }
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(payload, ensure_ascii=True) + "\n", encoding="utf-8")
    except OSError:
        return None
    _STARTUP_REPORT_WRITTEN = True
    return path


## The port preflight has entered its bind loop: from here the port passes to
## this process within one retry of freeing. The plugin's replacement kills
## the occupant only after reading this phase, so the port is never free long
## enough for an attach bridge to spawn a backend of its own into the gap.
STARTUP_PHASE_WAITING_FOR_PORT = "waiting_for_port"


def report_startup_phase(phase: str, **fields: object) -> Path | None:
    """Record a startup phase in the report without claiming a failure.

    A failure reported afterwards overwrites the phase, so the report the
    plugin reads on a failed launch is still the failure. Best effort, like
    :func:`report_startup_failure`: never raises.
    """
    path = _STARTUP_REPORT_PATH
    if path is None or _STARTUP_REPORT_WRITTEN:
        return None
    payload: dict[str, object] = {"pid": os.getpid(), "phase": phase}
    payload.update(fields)
    ## Whole or absent: the plugin polls this file while we write it.
    staging = path.with_name(path.name + ".phase")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        staging.write_text(json.dumps(payload, ensure_ascii=True) + "\n", encoding="utf-8")
        os.replace(staging, path)
    except OSError:
        return None
    return path


def install_pid_file(path: str | os.PathLike[str] | None) -> Path | None:
    """Write `os.getpid()` to `path` and register an atexit unlink.

    Returns the resolved Path on success, None when `path` is falsy
    (caller did not pass `--pid-file`). Any write error falls through
    to the caller — we'd rather surface a broken install than silently
    continue with the plugin unable to find our PID.
    """
    global _PID_FILE_PATH
    if not path:
        ## A subsequent install_pid_file(None) — e.g. a programmatic
        ## caller dropping plugin-managed mode — must reset the flag,
        ## otherwise `is_plugin_managed()` would stay True against the
        ## docstring's "caller did not pass --pid-file" semantics.
        _PID_FILE_PATH = None
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
