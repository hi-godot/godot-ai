"""Stage and publish inherited scenes without replacing an existing path."""

from __future__ import annotations

import errno
import hashlib
import logging
import os
import re
import stat
import tempfile
from pathlib import Path

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.godot_client.session_diagnostics import (
    NO_ACTIVE_SESSION_MESSAGE,
    no_active_session_data,
    session_not_found_data,
    session_not_found_message,
)
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session

logger = logging.getLogger(__name__)

_STAGE_PREFIX = ".godot-ai-inherit-"
_SHORT_NAME = re.compile(r"^[^.~]{0,6}~[0-9]+(?:\.[^.]{0,3})?$")
_WINDOWS_DEVICE = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", re.I)
_UNSUPPORTED_ERRNOS = {errno.EXDEV, errno.ENOSYS, errno.ENOTSUP, errno.EOPNOTSUPP}


def _scene_relative_path(value: str, parameter: str, *, for_write: bool = False) -> Path:
    relative = value.removeprefix("res://").replace("\\", "/")
    parts = [part for part in relative.split("/") if part not in {"", "."}]
    if (
        not value.startswith("res://")
        or ".." in relative
        or not parts
        or not parts[-1].endswith(".tscn")
        or any(
            ord(char) < 32 or 0xD800 <= ord(char) <= 0xDFFF or char in '<>:"|?*\ufffd'
            for char in relative
        )
    ):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE,
            f"{parameter} must be a project-relative res:// path ending in .tscn: {value!r}",
        )
    if for_write and any(part.casefold() == ".godot" for part in parts):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE, f"{parameter} must be outside editor metadata: {value!r}"
        )
    if os.name == "nt" and any(
        part.endswith((".", " ")) or _SHORT_NAME.fullmatch(part) or _WINDOWS_DEVICE.match(part)
        for part in parts
    ):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE, f"{parameter} is not a supported scene path: {value!r}"
        )
    return Path(*parts)


def _is_link(metadata: os.stat_result) -> bool:
    return stat.S_ISLNK(metadata.st_mode) or bool(
        getattr(metadata, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
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
    """Verify a real directory or regular file under the project root."""
    current = root
    try:
        metadata = current.lstat()
        if _is_link(metadata) or not stat.S_ISDIR(metadata.st_mode):
            raise NotADirectoryError(current)
        for index, part in enumerate(relative.parts):
            current = current / part
            metadata = current.lstat()
            if _is_link(metadata):
                raise GodotCommandError(
                    ErrorCode.VALUE_OUT_OF_RANGE,
                    f"Scene inheritance requires a path without links: res://{relative.as_posix()}",
                    {"reason": "linked_project_path"},
                )
            if index != len(relative.parts) - 1 and not stat.S_ISDIR(metadata.st_mode):
                raise NotADirectoryError(current)
        expected = stat.S_ISDIR if directory else stat.S_ISREG
        if expected(metadata.st_mode):
            return metadata
    except (OSError, ValueError):
        pass
    kind = "Destination directory" if directory else "Saved base scene"
    raise GodotCommandError(
        ErrorCode.RESOURCE_NOT_FOUND, f"{kind} not accessible: res://{relative.as_posix()}"
    )


def _destination_conflict(path: str) -> GodotCommandError:
    return GodotCommandError(
        ErrorCode.INVALID_PARAMS,
        f"Destination already exists: {path}",
        {"reason": "destination_exists", "path": path, "disk_committed": False},
    )


def _publish_scene(stage: Path, destination: Path) -> None:
    """Publish one complete file with a single no-replace filesystem operation."""
    if os.name == "nt":
        # Windows rename fails if a destination already exists.
        os.rename(stage, destination)
    else:
        # POSIX rename replaces the destination. Linking has no-replace semantics.
        os.link(stage, destination, follow_symlinks=False)


def _publish_error(
    error: OSError | NotImplementedError, destination: Path, path: str
) -> GodotCommandError:
    if isinstance(error, FileExistsError) or os.path.lexists(destination):
        return _destination_conflict(path)
    unsupported = (
        isinstance(error, NotImplementedError)
        or getattr(error, "errno", None) in _UNSUPPORTED_ERRNOS
        or (os.name != "nt" and getattr(error, "errno", None) == errno.EPERM)
        or getattr(error, "winerror", None) in {1, 17, 50}
    )
    return GodotCommandError(
        ErrorCode.INTERNAL_ERROR,
        (
            f"The destination filesystem does not support atomic scene publication: {path}"
            if unsupported
            else f"Could not publish the inherited scene atomically: {path}"
        ),
        {
            "reason": "atomic_publish_unsupported" if unsupported else "atomic_publish_failed",
            "path": path,
            "disk_committed": False,
        },
    )


def _same_entry(first: os.stat_result, second: os.stat_result) -> bool:
    return os.path.samestat(first, second) and not _is_link(second)


def _stage_digest(stage: Path, metadata: os.stat_result) -> str | None:
    """Read the staged file and check it stayed the same file during verification."""
    try:
        with stage.open("rb") as stream:
            opened = os.fstat(stream.fileno())
            if not _same_entry(metadata, opened):
                return None
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
            current = stage.lstat()
            if _same_entry(opened, current) and (opened.st_size, opened.st_mtime_ns) == (
                current.st_size,
                current.st_mtime_ns,
            ):
                return digest
    except OSError:
        pass
    return None


def _cleanup_stage(stage_dir: Path, ownership: os.stat_result) -> None:
    try:
        if _same_entry(ownership, stage_dir.lstat()):
            (stage_dir / "scene.tscn").unlink(missing_ok=True)
            stage_dir.rmdir()
    except FileNotFoundError:
        pass
    except OSError:
        logger.warning("Could not clean the scene inheritance staging directory %s", stage_dir)


def _pinned_session(runtime: DirectRuntime) -> Session:
    session = runtime.get_active_session()
    if session is not None:
        return session
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


def _require_same_editor(runtime: DirectRuntime, session: Session) -> None:
    current = runtime.get_session(session.session_id)
    if current is None or (current.connected_at, current.project_path) != (
        session.connected_at,
        session.project_path,
    ):
        raise GodotCommandError(
            ErrorCode.PLUGIN_DISCONNECTED,
            "The selected editor disconnected during scene inheritance.",
            {"reason": "session_changed", "session_id": session.session_id},
        )


async def stage_and_open_scene(runtime: DirectRuntime, base_path: str, path: str) -> dict:
    session = _pinned_session(runtime)
    base = _scene_relative_path(base_path, "base_path")
    target = _scene_relative_path(path, "path", for_write=True)
    root = _project_root(session)
    _project_entry(root, base, directory=False)
    original_parent = _project_entry(root, target.parent, directory=True)
    destination = root / target
    params = {"base_path": f"res://{base.as_posix()}", "path": f"res://{target.as_posix()}"}
    path = params["path"]
    if os.path.lexists(destination):
        raise _destination_conflict(path)

    try:
        stage_dir = Path(tempfile.mkdtemp(prefix=_STAGE_PREFIX, dir=destination.parent))
        ownership = stage_dir.lstat()
    except OSError as exc:
        raise GodotCommandError(
            ErrorCode.INTERNAL_ERROR,
            f"Could not create a private staging directory for {path}",
            {"reason": "stage_create_failed", "path": path, "disk_committed": False},
        ) from exc
    stage = stage_dir / "scene.tscn"
    prepare = {**params, "stage_path": f"res://{stage.relative_to(root).as_posix()}"}
    try:
        prepared = await runtime.send_command(
            "inherit_scene_prepare", prepare, session_id=session.session_id, hint_policy="retain"
        )
        _require_same_editor(runtime, session)
        parent = _project_entry(root, target.parent, directory=True)
        try:
            owner_unchanged = _same_entry(ownership, stage_dir.lstat())
            staged = (
                stage.lstat() if owner_unchanged and _same_entry(original_parent, parent) else None
            )
        except OSError:
            staged = None
        digest = None
        if (
            staged is not None
            and not _is_link(staged)
            and stat.S_ISREG(staged.st_mode)
            and staged.st_nlink == 1
            and staged.st_size > 0
        ):
            digest = _stage_digest(stage, staged)
        if (
            _project_root(session) != root
            or any(prepared.get(key) != value for key, value in prepare.items())
            or digest is None
            or prepared.get("stage_sha256") != digest
        ):
            raise GodotCommandError(
                ErrorCode.INTERNAL_ERROR,
                f"The editor did not produce a verified staged scene for {path}",
                {"reason": "stage_verification_failed", "path": path, "disk_committed": False},
            )
        try:
            _publish_scene(stage, destination)
        except (OSError, NotImplementedError) as exc:
            raise _publish_error(exc, destination, path) from exc
    finally:
        _cleanup_stage(stage_dir, ownership)

    try:
        _require_same_editor(runtime, session)
    except GodotCommandError as exc:
        raise GodotCommandError(
            exc.code,
            exc.message,
            {**exc.data, **params, "disk_committed": True, "tab_opened": False},
        ) from exc
    try:
        return await runtime.send_command(
            "inherit_scene_open", params, session_id=session.session_id
        )
    except GodotCommandError as exc:
        raise GodotCommandError(
            exc.code, exc.message, {**exc.data, **params, "disk_committed": True}
        ) from exc
    except (ConnectionError, TimeoutError) as exc:
        raise GodotCommandError(
            ErrorCode.TRANSPORT_OUTCOME_UNKNOWN,
            f"Saved {path}, but lost the editor response while opening it.",
            {**params, "disk_committed": True},
        ) from exc
    except Exception as exc:
        logger.exception("Scene publication succeeded but activation failed for %s", path)
        raise GodotCommandError(
            ErrorCode.INTERNAL_ERROR,
            f"Saved {path}, but could not confirm that the editor opened it.",
            {**params, "disk_committed": True},
        ) from exc
