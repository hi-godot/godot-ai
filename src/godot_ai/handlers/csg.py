"""Shared handlers for CSG authoring tools."""

from __future__ import annotations

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
from godot_ai.handlers._readiness import require_writable_async
from godot_ai.protocol.errors import ErrorCode
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session

CSG_BAKE_PLUGIN_TIMEOUT_MS = 30000
CSG_BAKE_TIMEOUT_SEC = CSG_BAKE_PLUGIN_TIMEOUT_MS / 1000.0 + 2.0
_STAGE_PREFIX = ".godot-ai-csg-"
_SHORT_NAME = re.compile(r"^[^.~]{0,6}~[0-9]+(?:\.[^.]{0,3})?$")
_WINDOWS_DEVICE = re.compile(r"(?:CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", re.I)
logger = logging.getLogger(__name__)


def _resource_relative_path(value: str) -> Path:
    if not value:
        raise GodotCommandError(
            ErrorCode.MISSING_REQUIRED_PARAM, "Missing required param: resource_path"
        )
    relative = value.removeprefix("res://").replace("\\", "/")
    parts = [part for part in relative.split("/") if part not in {"", "."}]
    folded = [part.casefold() for part in parts]
    if (
        not value.startswith("res://")
        or ".." in relative
        or not parts
        or not parts[-1].lower().endswith((".res", ".tres"))
        or ".godot" in folded
        or folded[:2] == ["addons", "godot_ai"]
        or any(c in "\x00:\ufffd" or 0xD800 <= ord(c) <= 0xDFFF for c in relative)
        or any(part.endswith((".", " ")) or _SHORT_NAME.fullmatch(part) for part in parts)
        or (
            os.name == "nt"
            and (
                any(ord(c) < 32 or c in '<>"|?*' for c in relative)
                or any(_WINDOWS_DEVICE.match(part) for part in parts)
            )
        )
    ):
        raise GodotCommandError(
            ErrorCode.VALUE_OUT_OF_RANGE,
            f"resource_path must be a writable res:// path ending in .res or .tres: {value!r}",
        )
    return Path(*parts)


def _is_link(entry: os.stat_result) -> bool:
    return stat.S_ISLNK(entry.st_mode) or bool(
        getattr(entry, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )


def _project_root(session: Session) -> Path:
    try:
        project = Path(session.project_path)
        if project.is_absolute():
            root = project.resolve(strict=True)
            manifest = (root / "project.godot").lstat()
            if stat.S_ISREG(manifest.st_mode) and not _is_link(manifest):
                return root
    except (OSError, RuntimeError, ValueError):
        pass
    raise GodotCommandError(
        ErrorCode.RESOURCE_NOT_FOUND,
        "The selected editor's project root is not accessible to this backend.",
        {"session_id": session.session_id, "disk_committed": False},
    )


def _directory(root: Path, relative: Path, *, create: bool = False) -> Path:
    """Find the deepest existing directory, or create the missing suffix."""
    current = root
    for part in relative.parts:
        child = current / part
        try:
            entry = child.lstat()
        except FileNotFoundError:
            if not create:
                break
            child.mkdir(exist_ok=True)
            entry = child.lstat()
        if not stat.S_ISDIR(entry.st_mode) or _is_link(entry):
            raise NotADirectoryError(child)
        current = child
    return current


def _destination_conflict(resource_path: str) -> GodotCommandError:
    return GodotCommandError(
        ErrorCode.INVALID_PARAMS,
        f"Choose a new resource_path; {resource_path} already exists",
        {"disk_committed": False, "resource_path": resource_path},
    )


def _publish_no_replace(stage: Path, destination: Path) -> None:
    # Windows rename refuses existing names. POSIX rename replaces them, so
    # create the destination with link(2)'s atomic no-replace semantics.
    if os.name == "nt":
        os.rename(stage, destination)
    else:
        os.link(stage, destination, follow_symlinks=False)


def _stage_digest(stage: Path, stage_dir: Path, owner: os.stat_result) -> str:
    current = stage_dir.lstat()
    entry = stage.lstat()
    if _is_link(current) or not os.path.samestat(owner, current) or _is_link(entry):
        return ""
    if not stat.S_ISREG(entry.st_mode) or entry.st_size <= 0 or entry.st_nlink != 1:
        return ""
    with stage.open("rb") as stream:
        before = os.fstat(stream.fileno())
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
        after = stage.lstat()
    if (
        not _is_link(after)
        and os.path.samestat(entry, before)
        and os.path.samestat(before, after)
        and (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns)
    ):
        return digest
    return ""


def _remove_stage(stage: Path, stage_dir: Path, owner: os.stat_result) -> None:
    try:
        current = stage_dir.lstat()
        if not _is_link(current) and os.path.samestat(owner, current):
            stage.unlink(missing_ok=True)
            stage_dir.rmdir()
    except FileNotFoundError:
        pass
    except OSError:
        logger.warning("Could not clean the CSG staging directory %s", stage_dir)


def _require_same_editor(runtime: DirectRuntime, session: Session) -> None:
    current = runtime.get_session(session.session_id)
    if current is None or (current.connected_at, current.project_path) != (
        session.connected_at,
        session.project_path,
    ):
        raise GodotCommandError(
            ErrorCode.PLUGIN_DISCONNECTED, "The selected editor disconnected during the CSG bake."
        )


async def csg_bake_mesh(
    runtime: DirectRuntime,
    path: str,
    resource_path: str,
    scene_file: str = "",
    apply_material_override: bool = False,
) -> dict:
    """Bake the edited CSG root into a fresh project mesh asset."""
    await require_writable_async(runtime)
    session = runtime.get_active_session()
    if session is None:
        session_id = runtime.active_session_id
        raise GodotCommandError(
            ErrorCode.PLUGIN_DISCONNECTED,
            NO_ACTIVE_SESSION_MESSAGE
            if session_id is None
            else session_not_found_message(session_id),
            no_active_session_data() if session_id is None else session_not_found_data(session_id),
        )
    relative = _resource_relative_path(resource_path)
    root = _project_root(session)
    destination = root / relative
    resource_path = f"res://{relative.as_posix()}"
    try:
        ancestor = _directory(root, relative.parent)
        if ancestor == destination.parent and os.path.lexists(destination):
            raise _destination_conflict(resource_path)
        ancestor_entry = ancestor.lstat()
        stage_dir = Path(tempfile.mkdtemp(prefix=_STAGE_PREFIX, dir=ancestor))
        owner = stage_dir.lstat()
    except OSError as exc:
        raise GodotCommandError(
            ErrorCode.INTERNAL_ERROR,
            f"Could not create a private staging directory for {resource_path}",
            {"disk_committed": False, "resource_path": resource_path},
        ) from exc

    stage = stage_dir / ("mesh." + relative.name.rsplit(".", 1)[1])
    stage_path = f"res://{stage.relative_to(root).as_posix()}"
    params = {"path": path, "resource_path": resource_path, "stage_path": stage_path}
    if scene_file:
        params["scene_file"] = scene_file
    if apply_material_override:
        params["apply_material_override"] = True
    try:
        prepared = await runtime.send_command(
            "csg_bake_mesh", params, session_id=session.session_id, timeout=CSG_BAKE_TIMEOUT_SEC
        )
        _require_same_editor(runtime, session)
        if (
            _project_root(session) != root
            or _directory(root, ancestor.relative_to(root)) != ancestor
            or not os.path.samestat(ancestor_entry, ancestor.lstat())
        ):
            raise OSError("The staging parent changed")
        digest = _stage_digest(stage, stage_dir, owner)
        surface_count = prepared.get("surface_count")
        if (
            not digest
            or prepared.get("stage_sha256") != digest
            or prepared.get("stage_path") != stage_path
            or prepared.get("resource_path") != resource_path
            or not isinstance(prepared.get("path"), str)
            or type(surface_count) is not int
            or surface_count <= 0
            or type(prepared.get("material_override_applied")) is not bool
        ):
            raise OSError("The staged mesh could not be verified")
        _directory(root, relative.parent, create=True)
        _publish_no_replace(stage, destination)
    except (OSError, NotImplementedError) as exc:
        if isinstance(exc, FileExistsError) or os.path.lexists(destination):
            raise _destination_conflict(resource_path) from exc
        raise GodotCommandError(
            ErrorCode.INTERNAL_ERROR,
            f"Could not publish the CSG mesh atomically at {resource_path}",
            {"disk_committed": False, "resource_path": resource_path},
        ) from exc
    finally:
        _remove_stage(stage, stage_dir, owner)

    committed = {
        "disk_committed": True,
        "resource_path": resource_path,
        "cleanup": {"rm": [resource_path]},
    }
    try:
        _require_same_editor(runtime, session)
        return await runtime.send_command(
            "csg_bake_mesh_finalize",
            {
                "path": prepared["path"],
                "resource_path": resource_path,
                "stage_sha256": digest,
                "surface_count": surface_count,
                "material_override_applied": prepared["material_override_applied"],
            },
            session_id=session.session_id,
            timeout=CSG_BAKE_TIMEOUT_SEC,
        )
    except GodotCommandError as exc:
        raise GodotCommandError(exc.code, exc.message, {**exc.data, **committed}) from exc
    except (ConnectionError, TimeoutError) as exc:
        raise GodotCommandError(
            ErrorCode.TRANSPORT_OUTCOME_UNKNOWN,
            f"Saved {resource_path}, but lost the editor response while verifying the mesh.",
            committed,
        ) from exc
    except Exception as exc:
        logger.exception(
            "Could not confirm editor verification of the published CSG mesh %s", resource_path
        )
        raise GodotCommandError(
            ErrorCode.INTERNAL_ERROR,
            f"Saved {resource_path}, but could not confirm the editor verified the mesh.",
            committed,
        ) from exc


async def csg_create(
    runtime: DirectRuntime,
    parent_path: str,
    name: str = "",
    shape: str = "box",
    operation: str = "union",
) -> dict:
    """Create a CSG shape (box, sphere, cylinder, torus, prism) under a
    Node3D parent, with a boolean operation (union / intersection /
    subtraction).
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "csg_create",
        {
            "parent_path": parent_path,
            "name": name,
            "shape": shape,
            "operation": operation,
        },
    )


async def csg_set_operation(
    runtime: DirectRuntime,
    path: str,
    operation: str,
) -> dict:
    """Set the boolean operation of a CSG shape (union / intersection /
    subtraction).
    """
    await require_writable_async(runtime)
    return await runtime.send_command(
        "csg_set_operation",
        {
            "path": path,
            "operation": operation,
        },
    )
