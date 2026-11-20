"""Stage a project-local WAV clip and publish it without replacing a file."""

from __future__ import annotations

import asyncio
import errno
import logging
import os
import re
import secrets
import stat
from contextlib import closing
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
from godot_ai.handlers._wav_directory import DirectoryAnchor, is_link
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
    anchor: DirectoryAnchor
    name: str
    file_info: os.stat_result
    metadata: dict[str, int]

    @property
    def path(self) -> Path:
        return self.anchor.path / self.name


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


def _project_root(session: Session) -> Path:
    try:
        root = Path(session.project_path)
        if root.is_absolute():
            root = root.resolve(strict=True)
            manifest = (root / "project.godot").lstat()
            if stat.S_ISREG(manifest.st_mode) and not is_link(manifest):
                return root
    except (OSError, RuntimeError, ValueError):
        pass
    raise GodotCommandError(
        ErrorCode.RESOURCE_NOT_FOUND,
        "The selected editor's project root is not accessible to this backend.",
        {"reason": "project_root_unavailable", "session_id": session.session_id},
    )


def _entry_error(error: OSError, relative: Path, label: str) -> GodotCommandError:
    path = f"res://{relative.as_posix()}"
    if error.errno == errno.ELOOP:
        return GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE,
            f"WAV paths must stay inside the project without links: {path}",
            {"reason": "linked_project_path"},
        )
    return _path_length_error(error, path) or GodotCommandError(
        ErrorCode.RESOURCE_NOT_FOUND, f"{label} not accessible: {path}"
    )


def _open_project_directory(root: Path, relative: Path, *, label: str) -> DirectoryAnchor:
    try:
        return DirectoryAnchor.open(root / relative)
    except OSError as exc:
        raise _entry_error(exc, relative, label) from exc


def _source_info(anchor: DirectoryAnchor, relative: Path) -> os.stat_result:
    try:
        info = anchor.stat(relative.name)
        if is_link(info):
            raise OSError(errno.ELOOP, "Linked source WAV")
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EINVAL, "Source WAV must be a regular file")
        return info
    except OSError as exc:
        raise _entry_error(exc, relative, "Source WAV") from exc


def _same_file(expected: os.stat_result, current: os.stat_result) -> bool:
    return (
        os.path.samestat(expected, current)
        and not is_link(current)
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


def _require_new_destination(anchor: DirectoryAnchor, name: str, path: str) -> None:
    try:
        anchor.stat(name)
    except FileNotFoundError:
        return
    except OSError as exc:
        raise (
            _path_length_error(exc, path)
            or GodotCommandError(ErrorCode.INTERNAL_ERROR, f"Could not inspect WAV path: {path}")
        ) from exc
    raise _destination_exists(path)


def _remove_stage(anchor: DirectoryAnchor, name: str, expected: os.stat_result) -> None:
    try:
        current = anchor.stat(name)
        if os.path.samestat(expected, current) and not is_link(current):
            anchor.unlink(name)
    except FileNotFoundError:
        pass
    except OSError:
        logger.warning("Could not clean owned WAV staging file %s", anchor.path / name)


def _new_stage(anchor: DirectoryAnchor) -> tuple[int, str]:
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    for _ in range(8):
        # Hidden, non-WAV staging files stay out of Godot's importer.
        name = f"{_STAGE_PREFIX}{secrets.token_hex(12)}.tmp"
        try:
            return anchor.open_file(name, flags), name
        except FileExistsError:
            continue
    raise OSError(errno.EEXIST, "Could not reserve a private WAV staging file")


def _stage_clip(
    root: Path, source: Path, destination: Path, edit_options: dict[str, float]
) -> _StagedClip:
    anchor = _open_project_directory(root, destination.parent, label="Destination directory")
    output_path = f"res://{destination.as_posix()}"
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    name = None
    owned = None
    clip = None
    try:
        _require_new_destination(anchor, destination.name, output_path)
        with closing(
            _open_project_directory(root, source.parent, label="Source WAV directory")
        ) as inputs:
            expected_source = _source_info(inputs, source)
            with os.fdopen(inputs.open_file(source.name, flags), "rb") as source_data:
                if not _same_file(expected_source, os.fstat(source_data.fileno())):
                    raise GodotCommandError(
                        ErrorCode.INVALID_PARAMS, "The source WAV changed before reading"
                    )
                fd, name = _new_stage(anchor)
                with os.fdopen(fd, "wb") as output:
                    owned = os.fstat(output.fileno())
                    metadata = edit_pcm_wav(source_data, output, **edit_options)
                    output.flush()
                    if not _same_file(expected_source, os.fstat(source_data.fileno())):
                        raise GodotCommandError(
                            ErrorCode.INVALID_PARAMS, "The source WAV changed while reading"
                        )
                    written_size = os.fstat(output.fileno()).st_size
        complete = anchor.stat(name)
        if (
            not os.path.samestat(owned, complete)
            or is_link(complete)
            or complete.st_size != written_size
        ):
            raise _publication_path_changed(output_path)
        clip = _StagedClip(anchor, name, complete, metadata)
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
        if clip is None:
            try:
                if name is not None and owned is not None:
                    _remove_stage(anchor, name, owned)
            finally:
                anchor.close()


def _close_clip(clip: _StagedClip) -> None:
    try:
        _remove_stage(clip.anchor, clip.name, clip.file_info)
    finally:
        clip.anchor.close()


def _discard_worker_result(future: asyncio.Future[_StagedClip]) -> None:
    if not future.cancelled() and future.exception() is None:
        _close_clip(future.result())


def _publication_path_changed(path: str) -> GodotCommandError:
    return GodotCommandError(
        ErrorCode.INVALID_PARAMS,
        f"The destination directory or staged file changed before publication: {path}",
        {"reason": "publication_path_changed", "path": path},
    )


def _entry_exists(anchor: DirectoryAnchor, name: str) -> bool:
    try:
        anchor.stat(name)
        return True
    except OSError:
        return False


def _publish_clip(root: Path, destination: Path, clip: _StagedClip) -> None:
    path = f"res://{destination.as_posix()}"
    anchor = clip.anchor
    try:
        current = _open_project_directory(root, destination.parent, label="Destination directory")
    except GodotCommandError as exc:
        raise _publication_path_changed(path) from exc
    try:
        with closing(current):
            if not os.path.samestat(anchor.info, current.info) or not _same_file(
                clip.file_info, anchor.stat(clip.name)
            ):
                raise _publication_path_changed(path)
            anchor.publish(clip.name, destination.name)
    except (OSError, NotImplementedError) as exc:
        if isinstance(exc, FileExistsError) or _entry_exists(anchor, destination.name):
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
        _close_clip(clip)
    return {
        "source_path": source_path,
        "path": path,
        "undoable": False,
        "reason": "Creating an audio asset writes a file outside editor undo",
        **clip.metadata,
    }
