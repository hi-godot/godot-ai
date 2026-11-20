"""Stage a project-local WAV clip and publish it without replacing a file."""

from __future__ import annotations

import asyncio
import errno
import logging
import os
import re
import secrets
import stat
import tempfile
from collections.abc import Iterator
from contextlib import ExitStack, closing
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

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

if TYPE_CHECKING:
    from godot_ai.handlers._wav_windows_stage import WindowsStage

logger = logging.getLogger(__name__)

_STAGE_PREFIX = ".godot-ai-wav-"
_WINDOWS_SHORT_NAME = re.compile(r"^[^.~]{0,6}~[0-9]+(?:\.[^.]{0,3})?$")
_WINDOWS_DEVICE = re.compile(
    r"(?:CON|CONIN\$|CONOUT\$|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", re.I
)
_UNSUPPORTED_ERRNOS = {errno.EXDEV, errno.ENOSYS, errno.ENOTSUP, errno.EOPNOTSUPP}


@dataclass(frozen=True)
class _StageFile:
    parent: DirectoryAnchor
    name: str
    fd: int
    windows: WindowsStage | None = None


@dataclass(frozen=True)
class _StagedClip:
    anchor: DirectoryAnchor
    stage: _StageFile
    file_info: os.stat_result
    metadata: dict[str, int]
    cleanup: ExitStack

    @property
    def path(self) -> Path:
        return self.stage.parent.path / self.stage.name


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


def _open_project_directory(
    root: Path | DirectoryAnchor, relative: Path, *, label: str
) -> DirectoryAnchor:
    try:
        if isinstance(root, DirectoryAnchor):
            return root.child(relative)
        return DirectoryAnchor.open(root / relative)
    except OSError as exc:
        raise _entry_error(exc, relative, label) from exc


def _regular_file_info(anchor: DirectoryAnchor, relative: Path, label: str) -> os.stat_result:
    try:
        info = anchor.stat(relative.name)
        if is_link(info):
            raise OSError(errno.ELOOP, "Linked file")
        if not stat.S_ISREG(info.st_mode):
            raise OSError(errno.EINVAL, "Expected a regular file")
        return info
    except OSError as exc:
        raise _entry_error(exc, relative, label) from exc


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
        # POSIX stages live in a directory that protects their names from
        # other accounts. The check also detects known replacements.
        current = anchor.stat(name)
        if os.path.samestat(expected, current) and not is_link(current):
            anchor.unlink(name)
    except FileNotFoundError:
        pass
    except OSError:
        logger.warning("Could not clean owned WAV staging file %s", anchor.path / name)


def _close_windows_stage(stage: WindowsStage) -> None:
    try:
        stage.close()
    except OSError:
        logger.warning("Could not clean owned WAV staging handle", exc_info=True)


def _reserve_stage(parent: DirectoryAnchor, cleanup: ExitStack) -> _StageFile:
    for _ in range(8):
        # Hidden, non-WAV staging files stay out of Godot's importer.
        name = f"{_STAGE_PREFIX}{secrets.token_hex(12)}.tmp"
        try:
            if os.name == "nt":
                from godot_ai.handlers._wav_windows_stage import WindowsStage

                windows = WindowsStage.open(parent.path, name)
                cleanup.callback(_close_windows_stage, windows)
                return _StageFile(parent, name, windows.fd, windows)
            flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW
            fd = parent.open_file(name, flags)
        except FileExistsError:
            continue
        cleanup.callback(os.close, fd)
        cleanup.callback(_remove_stage, parent, name, os.fstat(fd))
        return _StageFile(parent, name, fd)
    raise OSError(errno.EEXIST, "Could not reserve a private WAV staging file")


def _protected_stage(
    candidate: DirectoryAnchor, destination: DirectoryAnchor, cleanup: ExitStack
) -> _StageFile | None:
    info = candidate.info
    if info.st_dev != destination.info.st_dev or info.st_uid not in {0, os.geteuid()}:
        return None
    # A trusted owner can protect stage names even in a shared sticky directory.
    if info.st_mode & (stat.S_IWGRP | stat.S_IWOTH) and not info.st_mode & stat.S_ISVTX:
        return None
    try:
        return _reserve_stage(candidate, cleanup)
    except OSError as exc:
        if exc.errno not in {errno.EACCES, errno.EPERM, errno.EROFS}:
            raise
        return None


def _temporary_stage_paths() -> Iterator[Path]:
    # tempfile.gettempdir() may probe by creating and deleting files before
    # we have checked the directory's ownership and sharing permissions.
    configured = (tempfile.tempdir, *(os.getenv(name) for name in ("TMPDIR", "TEMP", "TMP")))
    seen: set[Path] = set()
    for value in (*configured, "/tmp", "/var/tmp", "/usr/tmp"):
        if not value:
            continue
        path = Path(os.fsdecode(value))
        if not path.is_absolute():
            continue
        try:
            path = path.resolve(strict=True)
        except (OSError, RuntimeError):
            continue
        if path not in seen:
            seen.add(path)
            yield path


def _new_stage(
    project: DirectoryAnchor, destination: DirectoryAnchor, cleanup: ExitStack
) -> _StageFile:
    if os.name == "nt":
        return _reserve_stage(destination, cleanup)

    stage = _protected_stage(destination, destination, cleanup)
    if stage is not None:
        return stage

    for ancestor in destination.path.relative_to(project.path).parents:
        with ExitStack() as attempt:
            try:
                candidate = project.child(ancestor) if ancestor.parts else project
            except OSError:
                continue
            if candidate is not project:
                attempt.callback(candidate.close)
            stage = _protected_stage(candidate, destination, attempt)
            if stage is not None:
                cleanup.callback(attempt.pop_all().close)
                return stage

    for path in _temporary_stage_paths():
        with ExitStack() as attempt:
            try:
                candidate = DirectoryAnchor.open(path)
            except OSError:
                continue
            attempt.callback(candidate.close)
            stage = _protected_stage(candidate, destination, attempt)
            if stage is not None:
                cleanup.callback(attempt.pop_all().close)
                return stage

    raise GodotCommandError(
        ErrorCode.INTERNAL_ERROR,
        "No writable protected staging directory is available on the WAV destination filesystem.",
        {"reason": "protected_staging_unavailable"},
    )


def _stage_clip(
    root: Path, source: Path, destination: Path, edit_options: dict[str, float]
) -> _StagedClip:
    output_path = f"res://{destination.as_posix()}"
    try:
        with ExitStack() as cleanup:
            project = _open_project_directory(root, Path(), label="Project directory")
            cleanup.callback(project.close)
            _regular_file_info(project, Path("project.godot"), "Project manifest")
            anchor = _open_project_directory(
                project, destination.parent, label="Destination directory"
            )
            cleanup.callback(anchor.close)
            _require_new_destination(anchor, destination.name, output_path)
            with closing(
                _open_project_directory(project, source.parent, label="Source WAV directory")
            ) as inputs:
                stage = _new_stage(project, anchor, cleanup)
                metadata = _render_clip(inputs, source, stage, edit_options)
            complete = os.fstat(stage.fd)
            if stage.windows is None and not _same_file(complete, stage.parent.stat(stage.name)):
                raise _publication_path_changed(output_path)
            return _StagedClip(anchor, stage, complete, metadata, cleanup.pop_all())
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


def _render_clip(
    inputs: DirectoryAnchor,
    source: Path,
    stage: _StageFile,
    edit_options: dict[str, float],
) -> dict[str, int]:
    expected_source = _regular_file_info(inputs, source, "Source WAV")
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0)
    flags |= getattr(os, "O_NONBLOCK", 0)
    with os.fdopen(inputs.open_file(source.name, flags), "rb") as source_data:
        if not _same_file(expected_source, os.fstat(source_data.fileno())):
            raise GodotCommandError(
                ErrorCode.INVALID_PARAMS, "The source WAV changed before reading"
            )
        with os.fdopen(stage.fd, "wb", closefd=False) as output:
            metadata = edit_pcm_wav(source_data, output, **edit_options)
            output.flush()
            if not _same_file(expected_source, os.fstat(source_data.fileno())):
                raise GodotCommandError(
                    ErrorCode.INVALID_PARAMS, "The source WAV changed while reading"
                )
    return metadata


def _close_clip(clip: _StagedClip) -> None:
    clip.cleanup.close()


def _discard_worker_result(future: asyncio.Future[_StagedClip]) -> None:
    if not future.cancelled() and future.exception() is None:
        _close_clip(future.result())


def _publication_path_changed(path: str, *, committed: bool = False) -> GodotCommandError:
    return GodotCommandError(
        ErrorCode.INVALID_PARAMS,
        (
            f"Could not verify the WAV at its requested path after publication: {path}"
            if committed
            else f"The destination directory or staged file changed before publication: {path}"
        ),
        {"reason": "publication_path_changed", "path": path, "disk_committed": committed},
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
    stage = clip.stage
    try:
        current = _open_project_directory(root, destination.parent, label="Destination directory")
    except GodotCommandError as exc:
        raise _publication_path_changed(path) from exc
    try:
        with closing(current):
            staged_info = (
                os.fstat(stage.fd) if stage.windows is not None else stage.parent.stat(stage.name)
            )
            if not os.path.samestat(anchor.info, current.info) or not _same_file(
                clip.file_info, staged_info
            ):
                raise _publication_path_changed(path)
            if stage.windows is not None:
                stage.windows.publish(anchor.path / destination.name)
            else:
                anchor.publish(stage.name, destination.name, source=stage.parent)
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
    # POSIX allows a held directory to be moved. Reopen the logical path
    # after publishing and verify both its directory and the published WAV.
    try:
        with closing(
            _open_project_directory(root, destination.parent, label="Destination directory")
        ) as published:
            verified = os.path.samestat(anchor.info, published.info) and _same_file(
                clip.file_info, published.stat(destination.name)
            )
    except (GodotCommandError, OSError) as exc:
        raise _publication_path_changed(path, committed=True) from exc
    if not verified:
        raise _publication_path_changed(path, committed=True)


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
