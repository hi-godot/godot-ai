"""Read a WAV from the selected local project for loop analysis."""

from __future__ import annotations

import os
import re
import stat
from pathlib import Path

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers._wav_loop import WavLoopError, find_pcm_wav_loops
from godot_ai.protocol.errors import ErrorCode
from godot_ai.sessions.registry import Session

_WINDOWS_DEVICE = re.compile(
    r"(?:CON|CONIN\$|CONOUT\$|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", re.I
)


def _relative_wav_path(source_path: str) -> Path:
    relative = source_path.removeprefix("res://")
    segments = relative.split("/")
    if (
        not source_path.startswith("res://")
        or not relative.lower().endswith(".wav")
        or any(part in {"", ".", ".."} for part in segments)
        or any(
            ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF or char in '\\:<>"|?*\ufffd'
            for char in relative
        )
        or (
            os.name == "nt"
            and any(part.endswith((".", " ")) or _WINDOWS_DEVICE.match(part) for part in segments)
        )
    ):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE,
            f"source_path must be a project-relative res:// .wav path: {source_path!r}",
        )
    return Path(*segments)


def _project_root(session: Session) -> Path:
    try:
        project = Path(session.project_path)
        if project.is_absolute():
            root = project.resolve(strict=True)
            if stat.S_ISREG((root / "project.godot").lstat().st_mode):
                return root
    except (OSError, RuntimeError, ValueError):
        pass
    raise GodotCommandError(
        ErrorCode.RESOURCE_NOT_FOUND,
        "The selected editor's local project is not accessible to this backend.",
        {"reason": "project_root_unavailable", "session_id": session.session_id},
    )


def _project_wav(root: Path, requested: Path, source_path: str) -> Path:
    try:
        source = requested.resolve(strict=True)
    except RuntimeError as exc:
        raise OSError("Could not resolve the source WAV") from exc
    if not source.is_relative_to(root):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE,
            f"Source WAV resolves outside the selected project: {source_path}",
            {"reason": "outside_project"},
        )
    return source


def _source_changed(source_path: str) -> GodotCommandError:
    return GodotCommandError(
        ErrorCode.INVALID_PARAMS,
        f"Source WAV changed during analysis: {source_path}",
        {"reason": "source_changed"},
    )


def _same_file(expected: os.stat_result, current: os.stat_result) -> bool:
    return (
        stat.S_ISREG(current.st_mode)
        and os.path.samestat(expected, current)
        and (expected.st_size, expected.st_mtime_ns) == (current.st_size, current.st_mtime_ns)
    )


def analyze_project_wav(session: Session, source_path: str, **options: float | int | None) -> dict:
    relative = _relative_wav_path(source_path)
    root = _project_root(session)
    try:
        requested = root / relative
        source = _project_wav(root, requested, source_path)
        expected = source.lstat()
        if not stat.S_ISREG(expected.st_mode):
            raise GodotCommandError(
                ErrorCode.WRONG_TYPE, f"Source WAV is not a file: {source_path}"
            )
        flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
        flags |= getattr(os, "O_NONBLOCK", 0)
        with os.fdopen(os.open(source, flags), "rb") as reader:
            opened = os.fstat(reader.fileno())
            current = _project_wav(root, requested, source_path).lstat()
            if not _same_file(expected, opened) or not _same_file(opened, current):
                raise _source_changed(source_path)
            result = find_pcm_wav_loops(reader, **options)
            after = os.fstat(reader.fileno())
            try:
                current = _project_wav(root, requested, source_path).lstat()
            except (GodotCommandError, OSError) as exc:
                raise _source_changed(source_path) from exc
            if not _same_file(opened, after) or not _same_file(opened, current):
                raise _source_changed(source_path)
        return {"source_path": source_path, **result}
    except WavLoopError as exc:
        code = (
            ErrorCode.INVALID_PARAMS
            if exc.reason in {"malformed_wav", "unsupported_wav"}
            else ErrorCode.VALUE_OUT_OF_RANGE
        )
        raise GodotCommandError(code, str(exc), {"reason": exc.reason}) from exc
    except OSError as exc:
        raise GodotCommandError(
            ErrorCode.RESOURCE_NOT_FOUND,
            f"Source WAV is not accessible: {source_path}",
            {"reason": "source_unavailable"},
        ) from exc
