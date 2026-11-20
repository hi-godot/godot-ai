"""Stage a project-local WAV clip and publish it without replacing a file."""

from __future__ import annotations

import asyncio
import errno
import logging
import os
import re
import stat
import tempfile
from dataclasses import dataclass
from pathlib import Path

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.godot_client.session_diagnostics import (
    NO_ACTIVE_SESSION_MESSAGE,
    no_active_session_data,
    session_not_found_data,
    session_not_found_message,
)
from godot_ai.handlers._readiness import require_writable_async
from godot_ai.handlers._wav_pcm import WavEditError, edit_pcm_wav
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session

logger = logging.getLogger(__name__)

_STAGE_PREFIX = ".godot-ai-wav-"
_WINDOWS_SHORT_NAME = re.compile(r"^[^.~]{0,6}~[0-9]+(?:\.[^.]{0,3})?$")
_WINDOWS_DEVICE = re.compile(
    r"(?:CON|CONIN\$|CONOUT\$|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", re.I
)
_UNSUPPORTED_ERRNOS = {errno.EXDEV, errno.ENOSYS, errno.ENOTSUP, errno.EOPNOTSUPP}


@dataclass(frozen=True)
class _StagedClip:
    path: Path
    file_info: os.stat_result
    parent_info: os.stat_result
    metadata: dict[str, int]


def _relative_wav_path(value: str, parameter: str, *, for_write: bool = False) -> Path:
    relative = value.removeprefix("res://")
    segments = relative.split("/")
    if (
        not value.startswith("res://")
        or not relative.lower().endswith(".wav")
        or any(segment in {"", ".", ".."} for segment in segments)
        or any(
            ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF or char in '\\<>:"|?*\ufffd'
            for char in relative
        )
    ):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE,
            f"{parameter} must be a project-relative res:// .wav path: {value!r}",
        )
    folded = [segment.casefold() for segment in segments]
    if for_write and (".godot" in folded or folded[:2] == ["addons", "godot_ai"]):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE,
            f"{parameter} is under a protected project directory: {value!r}",
        )
    if os.name == "nt" and any(
        segment.endswith((".", " "))
        or _WINDOWS_SHORT_NAME.fullmatch(segment)
        or _WINDOWS_DEVICE.match(segment)
        for segment in segments
    ):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE, f"{parameter} is not a supported path: {value!r}"
        )
    return Path(*segments)


def _is_link(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )


def _project_root(session: Session) -> Path:
    try:
        root = Path(session.project_path)
        if root.is_absolute():
            root = root.resolve(strict=True)
            manifest = (root / "project.godot").lstat()
            if stat.S_ISREG(manifest.st_mode) and not _is_link(manifest):
                return root
    except (OSError, RuntimeError, ValueError):
        pass
    raise GodotCommandError(
        ErrorCode.RESOURCE_NOT_FOUND,
        "The selected editor's project root is not accessible to this backend.",
        {"reason": "project_root_unavailable", "session_id": session.session_id},
    )


def _project_entry(root: Path, relative: Path, *, directory: bool) -> os.stat_result:
    current = root
    try:
        info = current.lstat()
        for part in relative.parts:
            if _is_link(info) or not stat.S_ISDIR(info.st_mode):
                break
            current /= part
            info = current.lstat()
        if _is_link(info):
            raise GodotCommandError(
                ErrorCode.VALUE_OUT_OF_RANGE,
                f"WAV paths must stay inside the project without links: res://{relative.as_posix()}",
                {"reason": "linked_project_path"},
            )
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if current == root / relative and expected(info.st_mode):
            return info
    except OSError as exc:
        path_error = _path_length_error(exc, f"res://{relative.as_posix()}")
        if path_error is not None:
            raise path_error from exc
    label = "Destination directory" if directory else "Source WAV"
    raise GodotCommandError(
        ErrorCode.RESOURCE_NOT_FOUND, f"{label} not accessible: res://{relative.as_posix()}"
    )


def _same_file(expected: os.stat_result, current: os.stat_result) -> bool:
    return (
        os.path.samestat(expected, current)
        and not _is_link(current)
        and stat.S_ISREG(current.st_mode)
        and (expected.st_size, expected.st_mtime_ns) == (current.st_size, current.st_mtime_ns)
    )


def _destination_exists(path: str) -> GodotCommandError:
    return GodotCommandError(
        ErrorCode.INVALID_PARAMS,
        f"Destination already exists: {path}",
        {"reason": "destination_exists", "path": path},
    )


def _path_length_error(error: OSError, path: str) -> GodotCommandError | None:
    if error.errno == errno.ENAMETOOLONG or getattr(error, "winerror", None) == 206:
        return GodotCommandError(ErrorCode.VALUE_OUT_OF_RANGE, f"WAV path is too long: {path}")
    return None


def _require_new_destination(target: Path, path: str) -> None:
    try:
        target.lstat()
    except FileNotFoundError:
        return
    except OSError as exc:
        raise (
            _path_length_error(exc, path)
            or GodotCommandError(ErrorCode.INTERNAL_ERROR, f"Could not inspect WAV path: {path}")
        ) from exc
    raise _destination_exists(path)


def _remove_stage(path: Path, expected: os.stat_result) -> None:
    try:
        current = path.lstat()
        if os.path.samestat(expected, current) and not _is_link(current):
            path.unlink()
    except FileNotFoundError:
        pass
    except OSError:
        logger.warning("Could not clean owned WAV staging file %s", path)


def _stage_clip(
    root: Path, source: Path, destination: Path, edit_options: dict[str, float]
) -> _StagedClip:
    source_info = _project_entry(root, source, directory=False)
    parent_info = _project_entry(root, destination.parent, directory=True)
    output_path = f"res://{destination.as_posix()}"
    _require_new_destination(root / destination, output_path)

    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    stage = None
    owned = None
    clip = None
    try:
        with os.fdopen(os.open(root / source, flags), "rb") as source_data:
            if not _same_file(source_info, os.fstat(source_data.fileno())):
                raise GodotCommandError(
                    ErrorCode.INVALID_PARAMS, "The source WAV changed before reading"
                )
            # The tempfile is on the destination volume and hidden from Godot's scanner.
            fd, name = tempfile.mkstemp(
                prefix=_STAGE_PREFIX, suffix=".tmp", dir=root / destination.parent
            )
            stage = Path(name)
            with os.fdopen(fd, "wb") as output:
                owned = os.fstat(output.fileno())
                metadata = edit_pcm_wav(source_data, output, **edit_options)
                output.flush()
                if not _same_file(source_info, os.fstat(source_data.fileno())):
                    raise GodotCommandError(
                        ErrorCode.INVALID_PARAMS, "The source WAV changed while reading"
                    )
                written_size = os.fstat(output.fileno()).st_size
        complete = stage.lstat()
        if (
            not os.path.samestat(owned, complete)
            or _is_link(complete)
            or complete.st_size != written_size
        ):
            raise GodotCommandError(
                ErrorCode.INVALID_PARAMS,
                f"The staged WAV changed while closing: {output_path}",
                {"reason": "publication_path_changed", "path": output_path},
            )
        clip = _StagedClip(stage, complete, parent_info, metadata)
        return clip
    except WavEditError as exc:
        code = (
            ErrorCode.INVALID_PARAMS
            if exc.reason in {"malformed_wav", "unsupported_wav"}
            else ErrorCode.VALUE_OUT_OF_RANGE
        )
        raise GodotCommandError(code, str(exc), {"reason": exc.reason}) from exc
    except OSError as exc:
        raise (
            _path_length_error(exc, output_path)
            or GodotCommandError(
                ErrorCode.INTERNAL_ERROR,
                f"Could not stage the WAV clip for {output_path}",
                {"reason": "wav_io_failed", "path": output_path},
            )
        ) from exc
    finally:
        # Windows cannot unlink the file while its writer is still open.
        if clip is None and stage is not None and owned is not None:
            _remove_stage(stage, owned)


def _discard_worker_result(future: asyncio.Future[_StagedClip]) -> None:
    if not future.cancelled() and future.exception() is None:
        clip = future.result()
        _remove_stage(clip.path, clip.file_info)


def _publish_clip(root: Path, destination: Path, clip: _StagedClip) -> None:
    path = f"res://{destination.as_posix()}"
    parent = _project_entry(root, destination.parent, directory=True)
    target = root / destination
    try:
        if not os.path.samestat(clip.parent_info, parent) or not _same_file(
            clip.file_info, clip.path.lstat()
        ):
            raise GodotCommandError(
                ErrorCode.INVALID_PARAMS,
                f"The destination directory or staged file changed before publication: {path}",
                {"reason": "publication_path_changed", "path": path},
            )
        if os.name == "nt":
            # Windows rename refuses an occupied destination.
            os.rename(clip.path, target)
        else:
            os.link(clip.path, target, follow_symlinks=False)
    except (OSError, NotImplementedError) as exc:
        if isinstance(exc, FileExistsError) or os.path.lexists(target):
            raise _destination_exists(path) from exc
        if isinstance(exc, OSError):
            path_error = _path_length_error(exc, path)
            if path_error is not None:
                raise path_error from exc
        unsupported = (
            isinstance(exc, NotImplementedError)
            or getattr(exc, "errno", None) in _UNSUPPORTED_ERRNOS
            or (os.name != "nt" and getattr(exc, "errno", None) == errno.EPERM)
            or getattr(exc, "winerror", None) in {1, 17, 50}
        )
        reason = "atomic_publish_unsupported" if unsupported else "atomic_publish_failed"
        raise GodotCommandError(
            ErrorCode.INTERNAL_ERROR,
            f"Could not publish the WAV clip without replacing a file: {path}",
            {"reason": reason, "path": path},
        ) from exc


def _require_same_session(runtime: DirectRuntime, session: Session) -> None:
    current = runtime.get_session(session.session_id)
    if current is None or (current.connected_at, current.project_path) != (
        session.connected_at,
        session.project_path,
    ):
        raise GodotCommandError(
            ErrorCode.PLUGIN_DISCONNECTED,
            "The selected editor disconnected during WAV editing.",
            {"reason": "session_changed", "session_id": session.session_id},
        )


async def write_wav_clip(
    runtime: DirectRuntime,
    session: Session | None,
    source_path: str,
    path: str,
    **edit_options: float,
) -> dict:
    if session is None:
        session_id = runtime.active_session_id
        if session_id is None:
            raise GodotCommandError(
                ErrorCode.PLUGIN_DISCONNECTED, NO_ACTIVE_SESSION_MESSAGE, no_active_session_data()
            )
        raise GodotCommandError(
            ErrorCode.PLUGIN_DISCONNECTED,
            session_not_found_message(session_id),
            session_not_found_data(session_id),
        )
    _require_same_session(runtime, session)
    source = _relative_wav_path(source_path, "source_path")
    destination = _relative_wav_path(path, "path", for_write=True)
    root = _project_root(session)
    work = asyncio.get_running_loop().run_in_executor(
        None, _stage_clip, root, source, destination, edit_options
    )
    try:
        clip = await asyncio.shield(work)
    except asyncio.CancelledError:
        # The executor may still be closing the file. It never publishes.
        work.add_done_callback(_discard_worker_result)
        raise
    try:
        _require_same_session(runtime, session)
        await require_writable_async(runtime)
        _require_same_session(runtime, session)
        if _project_root(session) != root:
            raise GodotCommandError(
                ErrorCode.INVALID_PARAMS,
                "The selected project root changed during WAV editing",
                {"reason": "publication_path_changed"},
            )
        _publish_clip(root, destination, clip)
    finally:
        _remove_stage(clip.path, clip.file_info)
    return {
        "source_path": source_path,
        "path": path,
        "undoable": False,
        "reason": "Creating an audio asset writes a file outside editor undo",
        **clip.metadata,
    }
