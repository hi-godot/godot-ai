"""Crash-recoverable, fail-closed activation of a staged Godot plug-in tree.

This module deliberately owns only filesystem transaction mechanics.  Package
verification and staging happen before it is called; Godot reload coordination
happens around it.  The durable records make interrupted work inspectable and
repairable without guessing from a partly overlaid live tree.

Durability here means ordered, atomic namespace changes on one filesystem.  It
does not claim survival from storage devices that acknowledge but lose writes.
"""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import stat
import sys
import time
import unicodedata
from collections.abc import Callable, Mapping
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator, NoReturn

from . import __version__
from .release_verify import (
    ASSET_NAME,
    MANIFEST_NAME,
    MAX_ARCHIVE_SIZE,
    MAX_MANIFEST_SIZE,
    PLUGIN_PREFIX,
    REPOSITORY,
    SIGNATURE_NAME,
    ReleaseError,
    stage_verified_release,
)

SCHEMA_VERSION = 1
PROTOCOL_VERSION = 1
PACKAGE_VERSION = __version__
MAX_RECORD_BYTES = 1_048_576
MAX_FILES = 20_000
MAX_TREE_BYTES = 512 * 1024 * 1024
POLL_SECONDS = 0.02
WINDOWS_SHARING_RETRY_SECONDS = 0.5
HARD_LINK_SETTLE_SECONDS = 1.0
DOWNLOAD_LIMITS = {
    ASSET_NAME: MAX_ARCHIVE_SIZE,
    MANIFEST_NAME: MAX_MANIFEST_SIZE,
    SIGNATURE_NAME: 512,
}

HEX64 = re.compile(r"[0-9a-f]{64}")
IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{15,127}")
VERSION = re.compile(r"[0-9A-Za-z][0-9A-Za-z.+-]{0,63}")
FINGERPRINT = re.compile(r"[ -~]{1,128}")
EFFECT = re.compile(r"[a-z][a-z0-9_]{0,63}")
QUALIFICATION_TIMEOUT = re.compile(r"(?:0|[1-9][0-9]*)(?:\.[0-9]+)?")
MAX_QUALIFICATION_TIMEOUT = 300.0
MANUAL_MIGRATION_MARKER_RELATIVE = Path(".godot") / "godot-ai-v4-migration.json"
MANUAL_MIGRATION_STATE_RELATIVE = Path(".godot") / "godot-ai-v4-migration-state"
MANUAL_MIGRATION_KIND = "pre_v4_migration"

QUALIFICATION_FAILPOINT_TOKEN_ENV = "GODOT_AI_QUALIFICATION_FAILPOINT_TOKEN"
QUALIFICATION_FAILPOINT_EFFECT_ENV = "GODOT_AI_QUALIFICATION_FAILPOINT_EFFECT"
QUALIFICATION_FAILPOINT_WHEN_ENV = "GODOT_AI_QUALIFICATION_FAILPOINT_WHEN"
QUALIFICATION_FAILPOINT_TIMEOUT_ENV = "GODOT_AI_QUALIFICATION_FAILPOINT_TIMEOUT"
QUALIFICATION_FAILPOINT_OCCURRENCE_ENV = "GODOT_AI_QUALIFICATION_FAILPOINT_OCCURRENCE"
QUALIFICATION_FAILPOINT_ENV = (
    QUALIFICATION_FAILPOINT_TOKEN_ENV,
    QUALIFICATION_FAILPOINT_EFFECT_ENV,
    QUALIFICATION_FAILPOINT_WHEN_ENV,
    QUALIFICATION_FAILPOINT_TIMEOUT_ENV,
    QUALIFICATION_FAILPOINT_OCCURRENCE_ENV,
)
ACTIVATE_FAILPOINT_EFFECTS = frozenset(
    {
        "activation_lock",
        "backup_to_live",
        "intent_commit",
        "journal_commit",
        "live_to_backup",
        "quarantine_live",
        "result_commit",
        "stage_to_live",
    }
)
COORDINATOR_FAILPOINT_EFFECTS = frozenset(
    {
        "coordinator_disable_request",
        "coordinator_disable_verified",
        "coordinator_enable",
        "coordinator_filesystem_scan",
    }
)

TRANSITIONS = {
    "prepared": {"stage_live", "rolling_back"},
    "stage_live": {"success", "rolling_back", "repair_required"},
    "rolling_back": {"rolled_back", "repair_required"},
    "success": set(),
    "rolled_back": set(),
    "repair_required": set(),
}
TERMINAL_PHASES = {"success", "rolled_back", "repair_required"}
FIXED_SEQUENCE = {"prepared": 0, "stage_live": 1, "success": 2}


class TransactionError(RuntimeError):
    """A transaction or durable record failed validation."""


class LockBusy(TransactionError):
    """Another activation (or an interrupted one) owns this install."""


class RepairRefused(TransactionError):
    """Repair could not prove exclusive, safe takeover."""


class InjectedFailure(TransactionError):
    """A qualification-only failpoint requested deterministic failure."""


def _fail(message: str) -> NoReturn:
    raise TransactionError(message)


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _reject_constant(value: str) -> NoReturn:
    _fail(f"non-finite JSON number: {value}")


def canonical_json(value: Mapping[str, Any]) -> bytes:
    try:
        return (
            json.dumps(
                value,
                allow_nan=False,
                ensure_ascii=False,
                separators=(",", ":"),
                sort_keys=True,
            )
            + "\n"
        ).encode()
    except (TypeError, ValueError) as exc:
        raise TransactionError(f"record is not canonical JSON: {exc}") from exc


def actor_response(value: Mapping[str, Any]) -> dict[str, Any]:
    if "protocol_version" in value or "package_version" in value:
        _fail("actor payload may not replace protocol identity")
    return {
        "package_version": PACKAGE_VERSION,
        "protocol_version": PROTOCOL_VERSION,
        **value,
    }


def _exact(row: Any, *, name: str, keys: set[str]) -> dict[str, Any]:
    if not isinstance(row, dict):
        _fail(f"{name} must be an object")
    actual = set(row)
    if actual != keys:
        _fail(
            f"{name} fields differ: missing={sorted(keys - actual)!r}, "
            f"unknown={sorted(actual - keys)!r}"
        )
    return row


RECORD_FIELDS = {
    "prepare_claim": "editor install_root old_tree project_root recovery_root stage_root "
    "transaction",
    "prepared_release": "editor install_root manifest_sha256 new_tree old_tree project_root "
    "recovery_root stage_root to_version transaction",
    "abort_intent": "authority_sha256 requester transaction",
    "preactivation_repair_claim": "abort_sha256 authority_sha256 prior_owner repairer transaction",
    "preactivation_cleanup": "authority_sha256 claim_sha256 transaction writer",
    "intent": "editor from_version install_root manifest_sha256 new_tree old_tree "
    "project_root recovery_root runner stage_root to_version transaction",
    "journal": "intent_sha256 phase sequence transaction",
    "activation_lock": "intent_sha256 runner transaction",
    "readiness": "editor_nonce intent_sha256 live_tree transaction",
    "terminal": "intent_sha256 outcome transaction writer",
    "migration_complete": "claim_sha256 editor intent_sha256 live_tree transaction",
    "migration_election": "editor install_root project_root transaction",
    "manual_migration_election": "editor install_root marker_sha256 project_root",
    "qualification_capability": "effect intent_sha256 occurrence token_sha256 transaction when",
    "failpoint_barrier": "effect install_root intent_sha256 project_root recovery_root "
    "sequence transaction when",
    "failpoint_decision": "action effect install_root intent_sha256 mac project_root "
    "recovery_root sequence transaction when",
    "coordinator_failpoint_barrier": "effect install_root project_root recovery_root sequence "
    "token_sha256 transaction when",
    "coordinator_failpoint_decision": "action effect install_root mac project_root recovery_root "
    "sequence token_sha256 transaction when",
    "repair_claim": "intent_sha256 prior_runner repairer transaction",
    "editor_lease": "editor install_root project_root",
}


def _typed(value: Any, kind: str) -> dict[str, Any]:
    fields = set(RECORD_FIELDS[kind].split()) | {"record", "schema_version"}
    row = _exact(value, name=kind.replace("_", " "), keys=fields)
    if _integer(row["schema_version"], name=f"{kind}.schema_version", minimum=1) != 1:
        _fail(f"unsupported {kind.replace('_', '-')} schema")
    if row["record"] != kind:
        _fail(f"invalid {kind.replace('_', '-')} record type")
    return row


def _string(value: Any, *, name: str, pattern: re.Pattern[str] | None = None) -> str:
    if not isinstance(value, str):
        _fail(f"{name} must be a string")
    if pattern is not None and pattern.fullmatch(value) is None:
        _fail(f"{name} has an invalid value")
    return value


def _integer(value: Any, *, name: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        _fail(f"{name} must be an integer >= {minimum}")
    return value


def _is_reparse(info: os.stat_result) -> bool:
    flag = getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0x400)
    return bool(getattr(info, "st_file_attributes", 0) & flag)


def _windows() -> bool:
    return os.name == "nt"


def _lstat(path: Path) -> os.stat_result:
    info = path.lstat()
    if stat.S_ISLNK(info.st_mode) or _is_reparse(info):
        _fail(f"{path}: links and reparse points are forbidden")
    return info


def _device(path: Path) -> int:
    return _lstat(path).st_dev


def _existing_ancestor(path: Path) -> Path:
    while not _lexists(path):
        path = path.parent
    return path


def _lexists(path: Path) -> bool:
    return os.path.lexists(path)


def _canonical_path(path: os.PathLike[str] | str, *, must_exist: bool) -> Path:
    raw = Path(path).expanduser()
    absolute = Path(os.path.abspath(raw))
    current = Path(absolute.anchor)
    for index, part in enumerate(absolute.parts[1:]):
        candidate = current / part
        if _lexists(candidate):
            info = _lstat(candidate)
            # resolve() preserves caller spelling on case-insensitive APFS.
            # Recover the directory-entry spelling so aliases share one ID.
            if sys.platform == "darwin" or _windows():
                matches: list[str] = []
                with os.scandir(current) as entries:
                    for entry in entries:
                        if _windows():
                            # Windows directory st_ino values are not reliably
                            # unique (some filesystems report zero for every
                            # entry).  Names are unique case-insensitively on
                            # the supported Windows filesystems, and lstat
                            # above already proved this spelling resolves.
                            if entry.name.casefold() == part.casefold():
                                matches.append(entry.name)
                            continue
                        try:
                            entry_info = entry.stat(follow_symlinks=False)
                        except OSError:
                            continue
                        if (entry_info.st_dev, entry_info.st_ino) == (
                            info.st_dev,
                            info.st_ino,
                        ):
                            matches.append(entry.name)
                if len(matches) != 1:
                    _fail(f"{candidate}: cannot determine canonical filesystem spelling")
                candidate = current / matches[0]
                _lstat(candidate)
            current = candidate
        elif must_exist:
            _fail(f"{absolute}: path does not exist")
        else:
            current = candidate.joinpath(*absolute.parts[index + 2 :])
            break
    resolved = current.resolve(strict=must_exist)
    if must_exist:
        _lstat(resolved)
    return resolved


def _descendant(path: Path, parent: Path, *, name: str) -> None:
    if path == parent or parent not in path.parents:
        _fail(f"{name} must be a strict descendant of {parent}")


def _posix_private(info: os.stat_result, *, path: Path, directory: bool) -> None:
    if os.name == "nt":
        return
    if info.st_uid != os.getuid():
        _fail(f"{path}: must be owned by the current user")
    expected = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected(info.st_mode):
        _fail(f"{path}: unexpected file type")
    if info.st_mode & 0o077:
        _fail(f"{path}: must not grant group or other permissions")


def _safe_posix_ancestor(uid: int, mode: int) -> bool:
    permissions = stat.S_IMODE(mode)
    root_sticky = uid == 0 and stat.S_ISDIR(mode) and bool(permissions & stat.S_ISVTX)
    return uid in {0, os.getuid()} and not (permissions & 0o022 and not root_sticky)


def _private_ancestors(path: Path) -> None:
    """Reject a POSIX namespace another local account can replace."""

    if os.name == "nt":
        return
    current = Path(path.anchor)
    for part in path.parts[1:]:
        current /= part
        if not _lexists(current):
            break
        info = _lstat(current)
        if not _safe_posix_ancestor(info.st_uid, info.st_mode):
            _fail(f"{current}: recovery path has an unsafe ancestor")


def _private_dir(path: Path, *, create: bool = False) -> Path:
    path = _canonical_path(path, must_exist=False)
    _private_ancestors(path)
    if create and not _lexists(path):
        ## Another same-user actor may create the shared recovery directory
        ## after our lstat but before mkdir. Treat that as an ordinary race;
        ## the lstat/owner/mode checks below still reject links or unsafe dirs.
        path.mkdir(mode=0o700, exist_ok=True)
        _private_ancestors(path)
    info = _lstat(path)
    _posix_private(info, path=path, directory=True)
    return path


def _secure_file(path: Path) -> os.stat_result:
    info = _lstat(path)
    _posix_private(info, path=path, directory=False)
    if os.name != "nt" and info.st_nlink == 2:
        # Immutable publication links the complete temp inode into place, then
        # immediately drops the temp name. A heavily contended writer can be
        # descheduled between those two syscalls, so wait by elapsed time rather
        # than a 10 ms attempt count. Persistent or additional links still fail
        # closed, and link counts above two never enter this settle path.
        deadline = time.monotonic() + HARD_LINK_SETTLE_SECONDS
        while info.st_nlink == 2 and time.monotonic() < deadline:
            time.sleep(0.005)
            info = _lstat(path)
    if os.name != "nt" and info.st_nlink != 1:
        _fail(f"{path}: record has an unexpected hard link")
    if info.st_size > MAX_RECORD_BYTES:
        _fail(f"{path}: record exceeds {MAX_RECORD_BYTES} bytes")
    return info


def _retry_windows_sharing_denial(operation: Callable[[], Any]) -> Any:
    deadline = time.monotonic() + WINDOWS_SHARING_RETRY_SECONDS
    while True:
        try:
            return operation()
        except PermissionError:
            # Windows can briefly deny both opening the old destination and
            # replacing it while another process closes a read handle. Retry
            # only that platform/error pair, for a fixed bound; durable ACL
            # denial still fails closed.
            if not _windows() or time.monotonic() >= deadline:
                raise
            time.sleep(POLL_SECONDS)


def _load_json_object(path: Path, *, require_canonical: bool) -> dict[str, Any]:
    before = _secure_file(path)
    fd = _retry_windows_sharing_denial(
        lambda: os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    )
    with os.fdopen(fd, "rb") as stream:
        opened = os.fstat(stream.fileno())
        if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            _fail(f"{path}: record changed before reading")
        raw = stream.read(MAX_RECORD_BYTES + 1)
    if len(raw) > MAX_RECORD_BYTES:
        _fail(f"{path}: record exceeds {MAX_RECORD_BYTES} bytes")
    try:
        row = json.loads(
            raw,
            object_pairs_hook=_strict_object,
            parse_constant=_reject_constant,
        )
    except (UnicodeDecodeError, ValueError) as exc:
        raise TransactionError(f"{path}: invalid JSON: {exc}") from exc
    if not isinstance(row, dict):
        _fail(f"{path}: record must be an object")
    if require_canonical and canonical_json(row) != raw:
        _fail(f"{path}: record is not canonical")
    return row


def load_record(path: Path) -> dict[str, Any]:
    return _load_json_object(path, require_canonical=True)


def _sync_dir(path: Path) -> None:
    if os.name == "nt":
        return
    fd = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_temp(parent: Path, data: bytes) -> Path:
    _private_dir(parent)
    path = parent / f".record-{secrets.token_hex(12)}.tmp"
    fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            if hasattr(os, "fchmod"):
                os.fchmod(stream.fileno(), 0o600)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        try:
            path.unlink()
        except OSError:
            pass
        raise
    return path


def _store_record(path: Path, row: Mapping[str, Any], *, replace: bool) -> None:
    if _lexists(path) and not replace:
        _fail(f"{path}: immutable record already exists")
    if _lexists(path):
        _secure_file(path)
    temporary = _write_temp(path.parent, canonical_json(row))
    try:
        if replace:
            _retry_windows_sharing_denial(lambda: os.replace(temporary, path))
        else:
            os.link(temporary, path)
            temporary.unlink()
        _sync_dir(path.parent)
    except FileExistsError as exc:
        raise TransactionError(f"{path}: immutable record already exists") from exc
    except OSError as exc:
        raise TransactionError(f"{path}: cannot store record: {exc}") from exc
    finally:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def publish_record(path: Path, row: Mapping[str, Any]) -> None:
    """Publish an immutable record without overwriting an existing name."""

    _store_record(path, row, replace=False)


def replace_record(path: Path, row: Mapping[str, Any]) -> None:
    """Atomically replace the reducer's single mutable journal record."""

    _store_record(path, row, replace=True)


@dataclass(frozen=True)
class TreeIdentity:
    sha256: str
    file_count: int
    total_size: int

    def __post_init__(self) -> None:
        _string(self.sha256, name="tree.sha256", pattern=HEX64)
        _integer(self.file_count, name="tree.file_count")
        _integer(self.total_size, name="tree.total_size")

    def record(self) -> dict[str, Any]:
        return {
            "file_count": self.file_count,
            "sha256": self.sha256,
            "total_size": self.total_size,
        }

    @classmethod
    def parse(cls, value: Any, *, name: str) -> TreeIdentity:
        row = _exact(
            value,
            name=name,
            keys={"file_count", "sha256", "total_size"},
        )
        return cls(
            sha256=_string(row["sha256"], name=f"{name}.sha256", pattern=HEX64),
            file_count=_integer(row["file_count"], name=f"{name}.file_count"),
            total_size=_integer(row["total_size"], name=f"{name}.total_size"),
        )


def hash_tree(root: os.PathLike[str] | str) -> TreeIdentity:
    """Hash every regular file and its relative path; reject ambiguous trees."""

    root_path = _canonical_path(root, must_exist=True)
    root_info = _lstat(root_path)
    if not stat.S_ISDIR(root_info.st_mode):
        _fail(f"{root_path}: tree root is not a directory")

    entries: list[tuple[str, int, str]] = []
    directories: list[tuple[Path, tuple[int, int, int]]] = []
    collision_keys: dict[str, str] = {}
    total = 0

    def walk_error(error: OSError) -> NoReturn:
        raise error

    for current, dirs, files in os.walk(
        root_path, topdown=True, onerror=walk_error, followlinks=False
    ):
        dirs.sort()
        files.sort()
        current_path = Path(current)
        current_info = _lstat(current_path)
        directories.append(
            (current_path, (current_info.st_dev, current_info.st_ino, current_info.st_mtime_ns))
        )
        if current_path != root_path and not dirs and not files:
            _fail(f"{current_path}: empty directories are forbidden in an exact tree")
        for name in dirs:
            info = _lstat(current_path / name)
            if not stat.S_ISDIR(info.st_mode):
                _fail(f"{current_path / name}: tree contains a non-directory entry")
        for name in files:
            path = current_path / name
            info = _lstat(path)
            if not stat.S_ISREG(info.st_mode):
                _fail(f"{path}: tree contains a non-regular file")
            if os.name != "nt" and info.st_nlink != 1:
                _fail(f"{path}: tree contains a hard-linked file")
            relative = path.relative_to(root_path).as_posix()
            normalized = unicodedata.normalize("NFC", relative)
            key = normalized.casefold()
            previous = collision_keys.get(key)
            if previous is not None:
                _fail(f"case/Unicode-colliding tree paths: {previous!r} and {relative!r}")
            collision_keys[key] = relative
            if len(entries) >= MAX_FILES:
                _fail(f"{root_path}: tree exceeds {MAX_FILES} files")
            total += info.st_size
            if total > MAX_TREE_BYTES:
                _fail(f"{root_path}: tree exceeds {MAX_TREE_BYTES} bytes")
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(fd, "rb") as stream:
                opened = os.fstat(stream.fileno())
                if (opened.st_dev, opened.st_ino) != (info.st_dev, info.st_ino):
                    _fail(f"{path}: file changed before hashing")
                file_sha = hashlib.file_digest(stream, "sha256").hexdigest()
            after = _lstat(path)
            if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != (
                after.st_dev,
                after.st_ino,
                after.st_size,
                after.st_mtime_ns,
            ):
                _fail(f"{path}: file changed while hashing")
            entries.append((relative, info.st_size, file_sha))

    for path, before in directories:
        after = _lstat(path)
        if (after.st_dev, after.st_ino, after.st_mtime_ns) != before:
            _fail(f"{path}: directory changed while hashing")

    digest = hashlib.sha256()
    for relative, size, file_sha in sorted(entries):
        digest.update(canonical_json({"path": relative, "sha256": file_sha, "size": size}))
    return TreeIdentity(digest.hexdigest(), len(entries), total)


@dataclass(frozen=True)
class ProcessIdentity:
    pid: int
    start_fingerprint: str
    nonce: str

    def __post_init__(self) -> None:
        _integer(self.pid, name="process.pid", minimum=1)
        _string(self.start_fingerprint, name="process.start_fingerprint", pattern=FINGERPRINT)
        _string(self.nonce, name="process.nonce", pattern=IDENTIFIER)

    def record(self) -> dict[str, Any]:
        return {
            "nonce": self.nonce,
            "pid": self.pid,
            "start_fingerprint": self.start_fingerprint,
        }

    @classmethod
    def parse(cls, value: Any, *, name: str) -> ProcessIdentity:
        row = _exact(value, name=name, keys={"nonce", "pid", "start_fingerprint"})
        return cls(
            pid=_integer(row["pid"], name=f"{name}.pid", minimum=1),
            start_fingerprint=_string(
                row["start_fingerprint"],
                name=f"{name}.start_fingerprint",
                pattern=FINGERPRINT,
            ),
            nonce=_string(row["nonce"], name=f"{name}.nonce", pattern=IDENTIFIER),
        )

    @classmethod
    def current(cls, nonce: str | None = None) -> ProcessIdentity:
        pid = os.getpid()
        fingerprint = process_start_fingerprint(pid)
        if fingerprint is None:
            _fail("cannot determine current process start fingerprint")
        return cls(pid, fingerprint, nonce or secrets.token_hex(16))


def process_start_fingerprint(pid: int) -> str | None:
    """Return a stable boot-relative/process-start identifier, or None."""

    if pid < 1:
        return None
    if sys.platform.startswith("linux"):
        try:
            content = Path(f"/proc/{pid}/stat").read_text()
            tail = content[content.rfind(")") + 2 :].split()
            return f"linux:{tail[19]}"
        except (OSError, IndexError, ValueError):
            return None
    if sys.platform == "darwin":
        try:
            import ctypes
            import struct

            # Darwin's stable proc_bsdinfo layout is 120 bytes of fixed fields
            # followed by start_tvsec/start_tvusec as two uint64 values.
            info = ctypes.create_string_buffer(136)
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            libproc.proc_pidinfo.argtypes = [
                ctypes.c_int,
                ctypes.c_int,
                ctypes.c_uint64,
                ctypes.c_void_p,
                ctypes.c_int,
            ]
            libproc.proc_pidinfo.restype = ctypes.c_int
            size = libproc.proc_pidinfo(pid, 3, 0, info, len(info))
            seconds, micros = struct.unpack_from("@QQ", info.raw, 120)
            if size == len(info) and seconds:
                return f"darwin:{seconds}:{micros}"
            return None
        except (AttributeError, OSError):
            return None
    if os.name == "nt":
        state, fingerprint = _windows_process_status(pid)
        return fingerprint if state == "alive" else None
    return None


def _windows_process_status(pid: int) -> tuple[str, str | None]:
    """Side-effect-free Windows liveness and start identity query."""

    try:
        import ctypes
        from ctypes import wintypes

        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel32.OpenProcess.restype = wintypes.HANDLE
        kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
        kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, wintypes.LPDWORD]
        kernel32.GetExitCodeProcess.restype = wintypes.BOOL
        filetime_pointer = ctypes.POINTER(wintypes.FILETIME)
        kernel32.GetProcessTimes.argtypes = [wintypes.HANDLE] + [filetime_pointer] * 4
        kernel32.GetProcessTimes.restype = wintypes.BOOL
        handle = kernel32.OpenProcess(0x1000, False, pid)
        if not handle:
            return ("dead", None) if ctypes.get_last_error() == 87 else ("unknown", None)
        try:
            exit_code = wintypes.DWORD()
            if not kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code)):
                return "unknown", None
            if exit_code.value != 259:  # STILL_ACTIVE
                return "dead", None
            created = wintypes.FILETIME()
            exited = wintypes.FILETIME()
            kernel = wintypes.FILETIME()
            user = wintypes.FILETIME()
            if not kernel32.GetProcessTimes(
                handle,
                ctypes.byref(created),
                ctypes.byref(exited),
                ctypes.byref(kernel),
                ctypes.byref(user),
            ):
                return "unknown", None
            ticks = (created.dwHighDateTime << 32) | created.dwLowDateTime
            return "alive", f"windows:{ticks}"
        finally:
            kernel32.CloseHandle(handle)
    except (AttributeError, OSError):
        return "unknown", None


def probe_process(identity: ProcessIdentity) -> str:
    """Return identity state; dead or a fingerprint mismatch permits repair."""

    if os.name == "nt":
        state, current = _windows_process_status(identity.pid)
        if state != "alive" or current is None:
            return state
        return "alive" if current == identity.start_fingerprint else "reused"
    try:
        os.kill(identity.pid, 0)
    except ProcessLookupError:
        return "dead"
    except PermissionError:
        return "unknown"
    except OSError:
        return "unknown"
    current = process_start_fingerprint(identity.pid)
    if current is None:
        return "unknown"
    return "alive" if current == identity.start_fingerprint else "reused"


def install_id(project_root: Path, install_root: Path) -> str:
    project_text = os.path.normcase(str(project_root))
    install_text = os.path.normcase(str(install_root))
    material = f"{project_text}\0{install_text}".encode()
    return hashlib.sha256(material).hexdigest()[:24]


def _canonical_install(
    project: os.PathLike[str] | str,
    install: os.PathLike[str] | str,
    *,
    allow_missing_install: bool = False,
) -> tuple[Path, Path]:
    project_root = _canonical_path(project, must_exist=True)
    install_root = _canonical_path(install, must_exist=not allow_missing_install)
    if not stat.S_ISDIR(_lstat(project_root).st_mode):
        _fail(f"{project_root}: project root is not a directory")
    if _lexists(install_root) and not stat.S_ISDIR(_lstat(install_root).st_mode):
        _fail(f"{install_root}: install root is not a directory")
    _descendant(install_root, project_root, name="install root")
    return project_root, install_root


def recovery_root(
    project: os.PathLike[str] | str,
    install: os.PathLike[str] | str,
    *,
    override: os.PathLike[str] | str | None = None,
    create: bool = False,
    _allow_missing_install: bool = False,
) -> Path:
    """Return the canonical, out-of-project recovery root for an install."""

    project_root, install_root = _canonical_install(
        project, install, allow_missing_install=_allow_missing_install
    )
    if override is not None and _windows():
        _fail("Windows recovery-root overrides are forbidden")
    base = _canonical_path(override or project_root.parent / ".godot-ai-recovery", must_exist=False)
    if base == project_root or project_root in base.parents:
        _fail("recovery root must be outside the project")
    install_device = _device(_existing_ancestor(install_root))
    if _device(_existing_ancestor(base)) != install_device:
        _fail("recovery root must be on the same filesystem as the install root")
    root = base / install_id(project_root, install_root)
    if create:
        _private_dir(base, create=True)
        _private_dir(root, create=True)
    elif _lexists(root):
        _private_dir(root)
    if _lexists(root) and _device(root) != install_device:
        _fail("recovery root must be on the same filesystem as the install root")
    return root


def _bound_recovery_root(
    project: os.PathLike[str] | str,
    install: os.PathLike[str] | str,
    exact_root: os.PathLike[str] | str,
    *,
    allow_missing_install: bool = False,
) -> Path:
    project_root, install_root = _canonical_install(
        project, install, allow_missing_install=allow_missing_install
    )
    root = _private_dir(Path(exact_root))
    if root.name != install_id(project_root, install_root):
        _fail("recovery root is bound to another install")
    if root == project_root or project_root in root.parents:
        _fail("recovery root must be outside the project")
    if _windows() and root != recovery_root(
        project_root,
        install_root,
        _allow_missing_install=allow_missing_install,
    ):
        _fail("Windows requires the fixed recovery root")
    return root


@dataclass(frozen=True)
class Intent:
    transaction: str
    project_root: Path
    install_root: Path
    recovery_root: Path
    stage_root: Path
    from_version: str
    to_version: str
    manifest_sha256: str
    old_tree: TreeIdentity
    new_tree: TreeIdentity
    editor: ProcessIdentity
    runner: ProcessIdentity

    def __post_init__(self) -> None:
        _string(self.transaction, name="transaction", pattern=IDENTIFIER)
        _string(self.from_version, name="from_version", pattern=VERSION)
        _string(self.to_version, name="to_version", pattern=VERSION)
        _string(self.manifest_sha256, name="manifest_sha256", pattern=HEX64)
        canonical = {
            name: _canonical_path(getattr(self, name), must_exist=False)
            for name in (
                "project_root",
                "install_root",
                "recovery_root",
                "stage_root",
            )
        }
        for name, value in canonical.items():
            if value != getattr(self, name):
                _fail(f"{name} is not canonical")
        _descendant(self.install_root, self.project_root, name="install root")
        expected_id = install_id(self.project_root, self.install_root)
        if self.recovery_root.name != expected_id:
            _fail("recovery root is not bound to the project/install identity")
        recovery_inside_project = (
            self.recovery_root == self.project_root
            or self.project_root in self.recovery_root.parents
        )
        if recovery_inside_project:
            _fail("recovery root must be outside the project")
        _descendant(self.stage_root, self.recovery_root / "stages", name="stage root")
        if self.editor.nonce == self.runner.nonce:
            _fail("editor and runner nonces must differ")

    @property
    def backup_root(self) -> Path:
        return self.recovery_root / "retained-backup"

    @property
    def quarantine_root(self) -> Path:
        return self.recovery_root / "quarantine" / self.transaction

    @classmethod
    def create(
        cls,
        *,
        transaction: str,
        project_root: os.PathLike[str] | str,
        install_root: os.PathLike[str] | str,
        recovery: os.PathLike[str] | str,
        stage_root: os.PathLike[str] | str,
        from_version: str,
        to_version: str,
        manifest_sha256: str,
        editor: ProcessIdentity,
        runner: ProcessIdentity,
    ) -> Intent:
        project_path = _canonical_path(project_root, must_exist=True)
        install_path = _canonical_path(install_root, must_exist=True)
        recovery_path = _canonical_path(recovery, must_exist=True)
        stage_path = _canonical_path(stage_root, must_exist=True)
        return cls(
            transaction=transaction,
            project_root=project_path,
            install_root=install_path,
            recovery_root=recovery_path,
            stage_root=stage_path,
            from_version=from_version,
            to_version=to_version,
            manifest_sha256=manifest_sha256,
            old_tree=hash_tree(install_path),
            new_tree=hash_tree(stage_path),
            editor=editor,
            runner=runner,
        )

    def record(self) -> dict[str, Any]:
        return {
            "editor": self.editor.record(),
            "from_version": self.from_version,
            "install_root": str(self.install_root),
            "manifest_sha256": self.manifest_sha256,
            "new_tree": self.new_tree.record(),
            "old_tree": self.old_tree.record(),
            "project_root": str(self.project_root),
            "record": "intent",
            "recovery_root": str(self.recovery_root),
            "runner": self.runner.record(),
            "schema_version": SCHEMA_VERSION,
            "stage_root": str(self.stage_root),
            "to_version": self.to_version,
            "transaction": self.transaction,
        }

    @classmethod
    def parse(cls, value: Any) -> Intent:
        row = _typed(value, "intent")
        return cls(
            transaction=_string(row["transaction"], name="transaction", pattern=IDENTIFIER),
            project_root=Path(_string(row["project_root"], name="project_root")),
            install_root=Path(_string(row["install_root"], name="install_root")),
            recovery_root=Path(_string(row["recovery_root"], name="recovery_root")),
            stage_root=Path(_string(row["stage_root"], name="stage_root")),
            from_version=_string(row["from_version"], name="from_version", pattern=VERSION),
            to_version=_string(row["to_version"], name="to_version", pattern=VERSION),
            manifest_sha256=_string(row["manifest_sha256"], name="manifest_sha256", pattern=HEX64),
            old_tree=TreeIdentity.parse(row["old_tree"], name="old_tree"),
            new_tree=TreeIdentity.parse(row["new_tree"], name="new_tree"),
            editor=ProcessIdentity.parse(row["editor"], name="editor"),
            runner=ProcessIdentity.parse(row["runner"], name="runner"),
        )


@dataclass(frozen=True)
class TransactionPaths:
    root: Path
    directory: Path
    prepared: Path
    intent: Path
    journal: Path
    readiness: Path
    result: Path
    claim: Path
    migration_complete: Path

    @classmethod
    def for_transaction(
        cls, root: Path, transaction: str, *, create: bool = False
    ) -> TransactionPaths:
        _string(transaction, name="transaction", pattern=IDENTIFIER)
        root = _private_dir(root)
        transactions = root / "transactions"
        directory = transactions / transaction
        if create:
            _private_dir(transactions, create=True)
            _private_dir(directory, create=True)
        else:
            _private_dir(directory)
        return cls(
            root=root,
            directory=directory,
            prepared=directory / "prepared.json",
            intent=directory / "intent.json",
            journal=directory / "journal.json",
            readiness=directory / "readiness.json",
            result=directory / "result.json",
            claim=directory / "claim.json",
            migration_complete=directory / "migration-complete.json",
        )


def _signed_tree(manifest: Mapping[str, Any]) -> TreeIdentity:
    """Derive the transaction identity from signed inventory, never from stage."""
    digest = hashlib.sha256()
    total = 0
    rows = manifest["inventory"]
    for row in rows:
        relative = row["path"][len(PLUGIN_PREFIX) :]
        digest.update(
            canonical_json({"path": relative, "sha256": row["sha256"], "size": row["size"]})
        )
        total += row["size"]
    return TreeIdentity(digest.hexdigest(), len(rows), total)


def _prepared_record(
    *,
    transaction: str,
    project: Path,
    install: Path,
    recovery: Path,
    stage: Path,
    version: str,
    manifest_sha256: str,
    new_tree: TreeIdentity,
    old_tree: TreeIdentity,
    editor: ProcessIdentity,
) -> dict[str, Any]:
    return {
        "editor": editor.record(),
        "install_root": str(install),
        "manifest_sha256": manifest_sha256,
        "new_tree": new_tree.record(),
        "old_tree": old_tree.record(),
        "project_root": str(project),
        "record": "prepared_release",
        "recovery_root": str(recovery),
        "schema_version": SCHEMA_VERSION,
        "stage_root": str(stage),
        "to_version": version,
        "transaction": transaction,
    }


def _prepare_claim_record(
    *,
    transaction: str,
    project: Path,
    install: Path,
    recovery: Path,
    stage: Path,
    old_tree: TreeIdentity,
    editor: ProcessIdentity,
) -> dict[str, Any]:
    return {
        "editor": editor.record(),
        "install_root": str(install),
        "old_tree": old_tree.record(),
        "project_root": str(project),
        "record": "prepare_claim",
        "recovery_root": str(recovery),
        "schema_version": SCHEMA_VERSION,
        "stage_root": str(stage),
        "transaction": transaction,
    }


def load_prepare_claim(paths: TransactionPaths) -> dict[str, Any]:
    row = _typed(load_record(paths.directory / "prepare-claim.json"), "prepare_claim")
    project, install = _canonical_install(row["project_root"], row["install_root"])
    recovery = _canonical_path(row["recovery_root"], must_exist=True)
    stage = _canonical_path(row["stage_root"], must_exist=False)
    transaction = _string(row["transaction"], name="prepare claim.transaction", pattern=IDENTIFIER)
    if (
        recovery != paths.root
        or transaction != paths.directory.name
        or recovery.name != install_id(project, install)
        or stage != recovery / "stages" / transaction / "addons" / "godot_ai"
    ):
        _fail("prepare claim path identity does not match its contents")
    TreeIdentity.parse(row["old_tree"], name="prepare claim.old_tree")
    ProcessIdentity.parse(row["editor"], name="prepare claim.editor")
    return row


def _prepared_from_intent(intent: Intent) -> dict[str, Any]:
    return _prepared_record(
        transaction=intent.transaction,
        project=intent.project_root,
        install=intent.install_root,
        recovery=intent.recovery_root,
        stage=intent.stage_root,
        version=intent.to_version,
        manifest_sha256=intent.manifest_sha256,
        new_tree=intent.new_tree,
        old_tree=intent.old_tree,
        editor=intent.editor,
    )


def load_prepared(paths: TransactionPaths, *, require_stage: bool = True) -> dict[str, Any]:
    row = _typed(load_record(paths.prepared), "prepared_release")
    project, install = _canonical_install(row["project_root"], row["install_root"])
    recovery = _canonical_path(row["recovery_root"], must_exist=True)
    stage = _canonical_path(row["stage_root"], must_exist=require_stage)
    transaction = _string(row["transaction"], name="prepared.transaction", pattern=IDENTIFIER)
    if (
        recovery != paths.root
        or transaction != paths.directory.name
        or recovery.name != install_id(project, install)
    ):
        _fail("prepared release path identity does not match its contents")
    _descendant(stage, recovery / "stages", name="prepared stage root")
    _string(row["to_version"], name="prepared.to_version", pattern=VERSION)
    _string(row["manifest_sha256"], name="prepared.manifest_sha256", pattern=HEX64)
    TreeIdentity.parse(row["new_tree"], name="prepared.new_tree")
    TreeIdentity.parse(row["old_tree"], name="prepared.old_tree")
    ProcessIdentity.parse(row["editor"], name="prepared.editor")
    return row


def _preparation_authority(paths: TransactionPaths, *, require_stage: bool) -> dict[str, Any]:
    claim = load_prepare_claim(paths)
    if not _lexists(paths.prepared):
        return claim
    prepared = load_prepared(paths, require_stage=require_stage)
    for key in (
        "editor",
        "install_root",
        "old_tree",
        "project_root",
        "recovery_root",
        "stage_root",
        "transaction",
    ):
        if prepared[key] != claim[key]:
            _fail(f"prepared release differs from prepare claim: {key}")
    return prepared


def _abort_record(authority: Mapping[str, Any], requester: ProcessIdentity) -> dict[str, Any]:
    return {
        "authority_sha256": hashlib.sha256(canonical_json(authority)).hexdigest(),
        "record": "abort_intent",
        "requester": requester.record(),
        "schema_version": SCHEMA_VERSION,
        "transaction": authority["transaction"],
    }


def _load_abort_intent(
    path: Path, authority: Mapping[str, Any], transaction: str
) -> dict[str, Any]:
    row = _typed(load_record(path), "abort_intent")
    if (
        row["authority_sha256"] != hashlib.sha256(canonical_json(authority)).hexdigest()
        or row["transaction"] != transaction
    ):
        _fail("prepared-abort claim differs from its authority")
    ProcessIdentity.parse(row["requester"], name="abort requester")
    return row


def _preactivation_repair_record(
    authority: Mapping[str, Any],
    abort: Mapping[str, Any],
    prior_owner: ProcessIdentity,
    repairer: ProcessIdentity,
) -> dict[str, Any]:
    return {
        "abort_sha256": hashlib.sha256(canonical_json(abort)).hexdigest(),
        "authority_sha256": hashlib.sha256(canonical_json(authority)).hexdigest(),
        "prior_owner": prior_owner.record(),
        "record": "preactivation_repair_claim",
        "repairer": repairer.record(),
        "schema_version": SCHEMA_VERSION,
        "transaction": authority["transaction"],
    }


def _load_preactivation_repair_claim(
    path: Path,
    authority: Mapping[str, Any],
    abort: Mapping[str, Any],
    prior_owner: ProcessIdentity,
) -> dict[str, Any]:
    row = _typed(load_record(path), "preactivation_repair_claim")
    repairer = ProcessIdentity.parse(row["repairer"], name="preactivation repairer")
    expected = _preactivation_repair_record(authority, abort, prior_owner, repairer)
    if row != expected:
        _fail("preactivation repair claim differs from its abort authority")
    return row


def _cleanup_record(
    authority: Mapping[str, Any], claim: Mapping[str, Any], *, writer: str
) -> dict[str, Any]:
    if writer not in {"editor", "repair"}:
        _fail("invalid preactivation cleanup writer")
    return {
        "authority_sha256": hashlib.sha256(canonical_json(authority)).hexdigest(),
        "claim_sha256": hashlib.sha256(canonical_json(claim)).hexdigest(),
        "record": "preactivation_cleanup",
        "schema_version": SCHEMA_VERSION,
        "transaction": authority["transaction"],
        "writer": writer,
    }


def _validate_cleanup(
    paths: TransactionPaths,
    authority: Mapping[str, Any],
    claim: Mapping[str, Any],
    *,
    writer: str,
) -> dict[str, Any]:
    row = _typed(load_record(paths.directory / "cleanup.json"), "preactivation_cleanup")
    if row != _cleanup_record(authority, claim, writer=writer):
        _fail("preactivation cleanup identity differs from its claim")
    container = paths.root / "stages" / paths.directory.name
    if _lexists(container):
        _fail("completed preactivation cleanup still has a staged tree")
    return row


def _has_resolved_pre_activation_cleanup(paths: TransactionPaths) -> bool:
    cleanup_path = paths.directory / "cleanup.json"
    if not _lexists(cleanup_path):
        return False
    authority = _preparation_authority(paths, require_stage=False)
    raw_claim = load_record(paths.intent)
    if raw_claim.get("record") == "abort_intent":
        abort = _load_abort_intent(paths.intent, authority, paths.directory.name)
        prepared_editor = ProcessIdentity.parse(authority["editor"], name="prepared.editor")
        repair_path = paths.directory / "repair-claim.json"
        if _lexists(repair_path):
            claim = _load_preactivation_repair_claim(repair_path, authority, abort, prepared_editor)
            writer = "repair"
        else:
            if ProcessIdentity.parse(abort["requester"], name="abort requester") != prepared_editor:
                _fail("prepared-abort repair is missing its durable repair claim")
            claim = abort
            writer = "editor"
    elif raw_claim.get("record") == "intent":
        intent = load_intent(paths)
        if not _lexists(paths.directory / "repair-claim.json"):
            _fail("intent cleanup is missing its repair claim")
        claim = _typed(load_record(paths.directory / "repair-claim.json"), "repair_claim")
        if (
            claim["intent_sha256"] != _intent_sha(intent)
            or claim["transaction"] != intent.transaction
            or ProcessIdentity.parse(claim["prior_runner"], name="prior runner") != intent.runner
        ):
            _fail("intent cleanup repair claim differs from durable intent")
        ProcessIdentity.parse(claim["repairer"], name="repairer")
        writer = "repair"
    else:
        _fail("cleanup intent has an unexpected record type")
    _validate_cleanup(paths, authority, claim, writer=writer)
    if any(_lexists(path) for path in (paths.journal, paths.readiness, paths.result, paths.claim)):
        _fail("preactivation cleanup coexists with activation records")
    return True


def load_intent(paths: TransactionPaths) -> Intent:
    intent = Intent.parse(load_record(paths.intent))
    if intent.recovery_root != paths.root or intent.transaction != paths.directory.name:
        _fail("intent path identity does not match its contents")
    return intent


def _intent_sha(intent: Intent) -> str:
    return hashlib.sha256(canonical_json(intent.record())).hexdigest()


def _journal_record(intent: Intent, phase: str, sequence: int) -> dict[str, Any]:
    return {
        "intent_sha256": _intent_sha(intent),
        "phase": phase,
        "record": "journal",
        "schema_version": SCHEMA_VERSION,
        "sequence": sequence,
        "transaction": intent.transaction,
    }


def load_journal(paths: TransactionPaths, intent: Intent) -> dict[str, Any]:
    row = _typed(load_record(paths.journal), "journal")
    phase = _string(row["phase"], name="journal.phase")
    if phase not in TRANSITIONS:
        _fail("journal has an impossible phase")
    if row["transaction"] != intent.transaction or row["intent_sha256"] != _intent_sha(intent):
        _fail("journal identity does not match intent")
    sequence = _integer(row["sequence"], name="journal.sequence")
    if phase in FIXED_SEQUENCE and sequence != FIXED_SEQUENCE[phase]:
        _fail("journal phase/sequence pair is impossible")
    if phase in {"rolling_back", "rolled_back", "repair_required"}:
        minimum = 1 + (phase in {"rolled_back", "repair_required"})
        if sequence < minimum:
            _fail("journal phase/sequence pair is impossible")
    return row


def _advance(
    paths: TransactionPaths,
    intent: Intent,
    next_phase: str,
    failpoints: Failpoints | None = None,
    *,
    repair: bool = False,
) -> dict[str, Any]:
    current = load_journal(paths, intent)
    phase = current["phase"]
    repair_reopen = (
        repair and phase in {"success", "repair_required"} and next_phase == "rolling_back"
    )
    if next_phase not in TRANSITIONS[phase] and not repair_reopen:
        _fail(f"impossible journal transition: {phase} -> {next_phase}")
    row = _journal_record(intent, next_phase, current["sequence"] + 1)
    with _mutation(failpoints, "journal_commit"):
        replace_record(paths.journal, row)
    return row


class ActivationLock:
    """An atomically published lock record that is never auto-stolen."""

    def __init__(self, root: Path):
        self.root = _private_dir(root)
        self.path = self.root / "activation.lock"

    @staticmethod
    def _owner_record(intent: Intent) -> dict[str, Any]:
        return {
            "intent_sha256": _intent_sha(intent),
            "record": "activation_lock",
            "runner": intent.runner.record(),
            "schema_version": SCHEMA_VERSION,
            "transaction": intent.transaction,
        }

    def acquire(self, intent: Intent) -> None:
        if _lexists(intent.backup_root):
            raise LockBusy(
                "retained successful backup blocks activation; archive it explicitly first"
            )
        try:
            publish_record(self.path, self._owner_record(intent))
        except TransactionError as exc:
            if _lexists(self.path):
                raise LockBusy(f"activation lock already exists: {self.path}") from exc
            raise

    def owner(self) -> dict[str, Any]:
        row = _typed(load_record(self.path), "activation_lock")
        ProcessIdentity.parse(row["runner"], name="lock.runner")
        _string(row["intent_sha256"], name="lock.intent_sha256", pattern=HEX64)
        _string(row["transaction"], name="lock.transaction", pattern=IDENTIFIER)
        return row

    def validate(self, intent: Intent) -> dict[str, Any]:
        row = self.owner()
        if row != self._owner_record(intent):
            _fail("activation-lock identity does not match intent")
        return row

    def release(self, intent: Intent) -> None:
        self.validate(intent)
        self.path.unlink()
        _sync_dir(self.root)


class EditorLeases:
    """Small per-install census; activation admits exactly one live editor process."""

    def __init__(self, root: Path, project: Path, install: Path):
        self.root = _private_dir(root)
        self.project, self.install = _canonical_install(project, install)
        self.directory = self.root / "editor-leases"

    def _record(self, editor: ProcessIdentity) -> dict[str, Any]:
        return {
            "editor": editor.record(),
            "install_root": str(self.install),
            "project_root": str(self.project),
            "record": "editor_lease",
            "schema_version": SCHEMA_VERSION,
        }

    def _load(self, path: Path) -> ProcessIdentity:
        row = _typed(load_record(path), "editor_lease")
        if row["project_root"] != str(self.project) or row["install_root"] != str(self.install):
            _fail("editor lease root identity differs from its recovery root")
        return ProcessIdentity.parse(row["editor"], name="lease.editor")

    def acquire(self, editor: ProcessIdentity) -> None:
        _private_dir(self.directory, create=True)
        path = self.directory / f"{editor.nonce}.json"
        if _lexists(path):
            if load_record(path) != self._record(editor):
                _fail("editor lease nonce is already bound to another process")
            return
        publish_record(path, self._record(editor))

    def validate(self, editor: ProcessIdentity) -> None:
        """Require an exact lease held by this live editor identity."""

        path = self.directory / f"{editor.nonce}.json"
        if not _lexists(path) or self._load(path) != editor:
            _fail("post-update migration completion requires the current editor lease")

    def transfer_restart(
        self,
        previous: ProcessIdentity,
        current: ProcessIdentity,
        *,
        timeout: float,
        process_probe: Callable[[ProcessIdentity], str] = probe_process,
    ) -> None:
        """Transfer one nonce-bound lease after Godot's graceful restart."""

        if current.nonce != previous.nonce or current == previous:
            _fail("restart lease transfer requires the inherited editor nonce")
        path = self.directory / f"{previous.nonce}.json"
        deadline = time.monotonic() + timeout
        while True:
            leased = self._load(path)
            if leased == current:
                return
            if leased != previous:
                _fail("restart lease changed before transfer")
            state = process_probe(previous)
            # A reused PID proves the recorded process identity is gone just as
            # strongly as a missing PID does.
            if state in {"dead", "reused"}:
                replace_record(path, self._record(current))
                self.validate(current)
                return
            if time.monotonic() >= deadline:
                if state == "unknown":
                    raise LockBusy(
                        f"restarted editor cannot prove its predecessor closed: pid={previous.pid}"
                    )
                raise LockBusy(
                    f"restarted editor timed out waiting for its predecessor: pid={previous.pid}"
                )
            # During graceful exit, liveness can remain observable while the
            # start fingerprint has already disappeared (e.g. an unreaped
            # Darwin process). Unknown is not permission to transfer, but one
            # transient observation must not defeat this bounded wait. Only
            # positively dead/reused observations above may change the lease.
            time.sleep(POLL_SECONDS)

    def release(self, editor: ProcessIdentity) -> None:
        path = self.directory / f"{editor.nonce}.json"
        if not _lexists(path):
            return
        if self._load(path) != editor:
            _fail("refusing to release another editor's lease")
        path.unlink()
        _sync_dir(self.directory)

    def assert_exclusive(
        self,
        editor: ProcessIdentity,
        *,
        process_probe: Callable[[ProcessIdentity], str] = probe_process,
    ) -> None:
        _private_dir(self.directory, create=True)
        for path in sorted(self.directory.glob("*.json")):
            leased = self._load(path)
            if leased.pid == editor.pid and leased.start_fingerprint == editor.start_fingerprint:
                continue
            state = process_probe(leased)
            if state == "alive":
                raise LockBusy(f"another live editor uses this install: pid={leased.pid}")
            if state == "unknown":
                raise LockBusy(f"another editor lease cannot be proven stale: pid={leased.pid}")
            path.unlink()
            _sync_dir(self.directory)

    def assert_closed(
        self,
        *,
        process_probe: Callable[[ProcessIdentity], str] = probe_process,
    ) -> None:
        """Prove every recorded editor dead before explicit backup archival."""
        if not _lexists(self.directory):
            return
        _private_dir(self.directory)
        removed = False
        for path in sorted(self.directory.glob("*.json")):
            leased = self._load(path)
            state = process_probe(leased)
            if state in {"alive", "unknown"}:
                raise LockBusy(f"editor lease is not proven closed: pid={leased.pid}")
            path.unlink()
            removed = True
        if removed:
            _sync_dir(self.directory)


class MigrationElection:
    """Atomic, crash-recoverable single winner for post-update M6 work."""

    def __init__(self, root: Path, project: Path, install: Path):
        self.root = _private_dir(root)
        self.project, self.install = _canonical_install(project, install)
        self.path = self.root / "migration-election.json"

    def _record(self, intent: Intent, editor: ProcessIdentity) -> dict[str, Any]:
        return {
            "editor": editor.record(),
            "install_root": str(self.install),
            "project_root": str(self.project),
            "record": "migration_election",
            "schema_version": SCHEMA_VERSION,
            "transaction": intent.transaction,
        }

    def owner(self) -> tuple[dict[str, Any], ProcessIdentity]:
        row = _typed(load_record(self.path), "migration_election")
        if row["project_root"] != str(self.project) or row["install_root"] != str(
            self.install
        ):
            _fail("migration election root identity differs from its recovery root")
        _string(row["transaction"], name="migration election.transaction", pattern=IDENTIFIER)
        return row, ProcessIdentity.parse(row["editor"], name="migration election.editor")

    def _archive_stale(self, row: Mapping[str, Any]) -> None:
        digest = hashlib.sha256(canonical_json(row)).hexdigest()[:16]
        archive = self.root / f"migration-election-stale-{digest}.json"
        try:
            os.link(self.path, archive)
        except FileExistsError:
            if load_record(archive) != row:
                _fail("stale migration-election archive has conflicting identity")
        except FileNotFoundError:
            return
        if not _lexists(self.path):
            return
        current = _lstat(self.path)
        archived = _lstat(archive)
        if (current.st_dev, current.st_ino) != (archived.st_dev, archived.st_ino):
            return
        self.path.unlink()
        _sync_dir(self.root)

    def acquire(
        self,
        intent: Intent,
        editor: ProcessIdentity,
        *,
        process_probe: Callable[[ProcessIdentity], str] = probe_process,
    ) -> None:
        expected = self._record(intent, editor)
        for _attempt in range(3):
            try:
                publish_record(self.path, expected)
                return
            except TransactionError:
                if not _lexists(self.path):
                    continue
            row, owner = self.owner()
            if row == expected:
                return
            same_process = (
                owner.pid == editor.pid
                and owner.start_fingerprint == editor.start_fingerprint
            )
            state = "reused" if same_process else process_probe(owner)
            if state == "alive":
                raise LockBusy(f"another editor owns post-update migration: pid={owner.pid}")
            if state == "unknown":
                raise LockBusy(
                    f"post-update migration owner cannot be proven stale: pid={owner.pid}"
                )
            self._archive_stale(row)
        raise LockBusy("post-update migration election changed concurrently")

    def validate(self, intent: Intent, editor: ProcessIdentity) -> None:
        if not _lexists(self.path) or self.owner()[0] != self._record(intent, editor):
            _fail("post-update migration completion requires the elected editor")

    def release(self, intent: Intent, editor: ProcessIdentity) -> None:
        self.validate(intent, editor)
        self.path.unlink()
        _sync_dir(self.root)

    def clear_completed(
        self,
        editor: ProcessIdentity,
        *,
        process_probe: Callable[[ProcessIdentity], str] = probe_process,
    ) -> None:
        """Clear only an election whose exact transaction already completed M6."""

        if not _lexists(self.path):
            return
        row, owner = self.owner()
        paths = TransactionPaths.for_transaction(self.root, row["transaction"])
        intent = load_intent(paths)
        if not _lexists(paths.migration_complete):
            return
        validate_migration_complete(paths, intent)
        if owner == editor:
            self.release(intent, editor)
            return
        same_process = (
            owner.pid == editor.pid
            and owner.start_fingerprint == editor.start_fingerprint
        )
        state = "reused" if same_process else process_probe(owner)
        if state == "alive":
            raise LockBusy(f"another editor is releasing completed migration: pid={owner.pid}")
        if state == "unknown":
            raise LockBusy(f"completed migration owner cannot be proven stale: pid={owner.pid}")
        self._archive_stale(row)


def _manual_migration_marker(
    project: Path,
    install: Path,
) -> tuple[Path, dict[str, Any]] | None:
    canonical_project, _canonical_install_root = _canonical_install(project, install)
    path = canonical_project / MANUAL_MIGRATION_MARKER_RELATIVE
    if not _lexists(path):
        return None
    row = _exact(
        _load_json_object(path, require_canonical=True),
        name="manual migration marker",
        keys={"from_version", "kind", "schema_version", "source_commit", "to_version"},
    )
    if _integer(row["schema_version"], name="manual marker.schema_version", minimum=1) != 1:
        _fail("unsupported manual migration marker schema")
    if row["kind"] != MANUAL_MIGRATION_KIND:
        _fail("invalid manual migration marker kind")
    from_version = _string(row["from_version"], name="manual marker.from_version")
    if (
        not from_version
        or len(from_version) > 64
        or any(ord(value) < 0x20 for value in from_version)
    ):
        _fail("manual migration source version is invalid")
    _string(
        row["source_commit"],
        name="manual marker.source_commit",
        pattern=re.compile(r"[0-9a-f]{40}"),
    )
    to_version = _string(row["to_version"], name="manual marker.to_version", pattern=VERSION)
    if to_version != PACKAGE_VERSION:
        _fail("manual migration marker targets another package version")
    return path, row


class ManualMigrationElection:
    """One durable editor owner for clean-major client repin and marker removal."""

    def __init__(self, project: Path, install: Path):
        self.project, self.install = _canonical_install(project, install)
        self.directory = self.project / MANUAL_MIGRATION_STATE_RELATIVE
        self.path = self.directory / "owner.json"

    def _record(
        self, marker: Mapping[str, Any], editor: ProcessIdentity
    ) -> dict[str, Any]:
        return {
            "editor": editor.record(),
            "install_root": str(self.install),
            "marker_sha256": hashlib.sha256(canonical_json(marker)).hexdigest(),
            "project_root": str(self.project),
            "record": "manual_migration_election",
            "schema_version": SCHEMA_VERSION,
        }

    def owner(self) -> tuple[dict[str, Any], ProcessIdentity]:
        _private_dir(self.directory)
        row = _typed(load_record(self.path), "manual_migration_election")
        if row["project_root"] != str(self.project) or row["install_root"] != str(self.install):
            _fail("manual migration election targets another project or install")
        _string(row["marker_sha256"], name="manual election.marker_sha256", pattern=HEX64)
        return row, ProcessIdentity.parse(row["editor"], name="manual election.editor")

    def _archive_stale(self, row: Mapping[str, Any]) -> None:
        digest = hashlib.sha256(canonical_json(row)).hexdigest()[:16]
        archive = self.directory / f"stale-{digest}.json"
        try:
            os.link(self.path, archive)
        except FileExistsError:
            if load_record(archive) != row:
                _fail("manual migration stale-owner archive conflicts")
        except FileNotFoundError:
            return
        if not _lexists(self.path):
            return
        current = _lstat(self.path)
        archived = _lstat(archive)
        if (current.st_dev, current.st_ino) == (archived.st_dev, archived.st_ino):
            self.path.unlink()
            _sync_dir(self.directory)

    def acquire(
        self,
        marker: Mapping[str, Any],
        editor: ProcessIdentity,
        *,
        process_probe: Callable[[ProcessIdentity], str] = probe_process,
    ) -> None:
        _private_dir(self.directory, create=True)
        expected = self._record(marker, editor)
        for _attempt in range(3):
            try:
                publish_record(self.path, expected)
                return
            except TransactionError:
                if not _lexists(self.path):
                    continue
            row, owner = self.owner()
            if row == expected:
                return
            same_process = (
                owner.pid == editor.pid
                and owner.start_fingerprint == editor.start_fingerprint
            )
            state = "reused" if same_process else process_probe(owner)
            if state == "alive":
                raise LockBusy(f"another editor owns manual migration: pid={owner.pid}")
            if state == "unknown":
                raise LockBusy(f"manual migration owner cannot be proven stale: pid={owner.pid}")
            self._archive_stale(row)
        raise LockBusy("manual migration election changed concurrently")

    def validate(self, marker: Mapping[str, Any], editor: ProcessIdentity) -> None:
        if not _lexists(self.path) or self.owner()[0] != self._record(marker, editor):
            _fail("manual migration completion requires the elected editor")

    def release(self, marker: Mapping[str, Any], editor: ProcessIdentity) -> None:
        self.validate(marker, editor)
        self.path.unlink()
        _sync_dir(self.directory)

    def clear_finished(
        self,
        editor: ProcessIdentity,
        *,
        process_probe: Callable[[ProcessIdentity], str] = probe_process,
    ) -> None:
        if not _lexists(self.path):
            return
        if _lexists(self.project / MANUAL_MIGRATION_MARKER_RELATIVE):
            return
        row, owner = self.owner()
        if owner == editor:
            self.path.unlink()
            _sync_dir(self.directory)
            return
        same_process = (
            owner.pid == editor.pid
            and owner.start_fingerprint == editor.start_fingerprint
        )
        state = "reused" if same_process else process_probe(owner)
        if state == "alive":
            raise LockBusy(f"another editor is finishing manual migration: pid={owner.pid}")
        if state == "unknown":
            raise LockBusy(f"manual migration owner cannot be proven stale: pid={owner.pid}")
        self._archive_stale(row)


def complete_manual_migration(
    project: Path,
    install: Path,
    editor: ProcessIdentity,
) -> dict[str, Any]:
    marker_value = _manual_migration_marker(project, install)
    if marker_value is None:
        _fail("manual migration marker is absent")
    marker_path, marker = marker_value
    election = ManualMigrationElection(project, install)
    election.validate(marker, editor)
    if _load_json_object(marker_path, require_canonical=True) != marker:
        _fail("manual migration marker changed before completion")
    marker_path.unlink()
    _sync_dir(marker_path.parent)
    election.release(marker, editor)
    return {
        "status": "migration_complete",
        "transaction": "manual-" + hashlib.sha256(canonical_json(marker)).hexdigest()[:24],
    }


def editor_identity(pid: int, nonce: str) -> ProcessIdentity:
    fingerprint = process_start_fingerprint(pid)
    if fingerprint is None:
        _fail("cannot prove editor process identity")
    return ProcessIdentity(pid, fingerprint, nonce)


def preflight_update(
    project: Path,
    install: Path,
    editor: ProcessIdentity,
    *,
    override: Path | None = None,
    create: bool = True,
    process_probe: Callable[[ProcessIdentity], str] = probe_process,
) -> Path:
    """Refuse before download/staging when backup, lock, or another editor exists."""

    root = recovery_root(project, install, override=override, create=create)
    if _lexists(root / "retained-backup"):
        raise LockBusy("retained successful backup blocks the next update")
    lock = ActivationLock(root)
    if _lexists(lock.path):
        raise LockBusy(f"activation lock already exists: {lock.path}")
    transactions = root / "transactions"
    if _lexists(transactions):
        transactions = _private_dir(transactions)
        for directory in sorted(transactions.iterdir()):
            directory = _private_dir(directory)
            paths = TransactionPaths.for_transaction(root, directory.name)
            if _has_resolved_pre_activation_cleanup(paths):
                continue
            if not _lexists(paths.claim):
                raise LockBusy(f"unresolved update transaction blocks preflight: {directory.name}")
            intent = load_intent(paths)
            terminal = validate_terminal(paths.claim, intent)
            if (
                terminal["outcome"] == "repair_required"
                or load_journal(paths, intent)["phase"] != terminal["outcome"]
            ):
                raise LockBusy(f"unresolved update transaction blocks preflight: {directory.name}")
            if _lexists(paths.migration_complete):
                validate_migration_complete(paths, intent)
            elif terminal["outcome"] == "success":
                raise LockBusy(
                    f"post-update client migration blocks the next update: {directory.name}"
                )
    stages = root / "stages"
    if _lexists(stages):
        stages = _private_dir(stages)
        for container in sorted(stages.iterdir()):
            container = _private_dir(container)
            _string(container.name, name="staged transaction", pattern=IDENTIFIER)
            if not _lexists(root / "transactions" / container.name):
                raise LockBusy(f"unresolved staged tree blocks preflight: {container.name}")
    leases = EditorLeases(root, project, install)
    leases.acquire(editor)
    leases.assert_exclusive(editor, process_probe=process_probe)
    return root


def allocate_download_root(root: Path, download_id: str) -> Path:
    """Publish one empty private directory for untrusted release downloads."""

    _string(download_id, name="download_id", pattern=IDENTIFIER)
    downloads = _private_dir(root / "downloads", create=True)
    destination = downloads / download_id
    try:
        destination.mkdir(mode=0o700)
    except FileExistsError as exc:
        raise TransactionError("download directory already exists") from exc
    try:
        destination = _private_dir(destination)
        _sync_dir(downloads)
    except BaseException:
        try:
            destination.rmdir()
        except OSError:
            pass
        raise
    return destination


def clean_stale_downloads(root: Path) -> None:
    """Remove only bounded release files from prior private download roots."""

    downloads_path = root / "downloads"
    if not _lexists(downloads_path):
        return
    downloads = _private_dir(downloads_path)
    validated: list[tuple[Path, list[tuple[Path, tuple[int, int, int]]]]] = []
    for child in sorted(downloads.iterdir()):
        directory = _private_dir(child)
        files: list[tuple[Path, tuple[int, int, int]]] = []
        for path in sorted(directory.iterdir()):
            limit = DOWNLOAD_LIMITS.get(path.name)
            info = _lstat(path)
            if (
                limit is None
                or not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_size > limit
                or (os.name != "nt" and info.st_uid != os.getuid())
            ):
                _fail(f"{path}: unexpected stale download entry")
            files.append((path, (info.st_dev, info.st_ino, info.st_size)))
        validated.append((directory, files))
    for directory, files in validated:
        for path, identity in files:
            current = _lstat(path)
            if (current.st_dev, current.st_ino, current.st_size) != identity:
                _fail(f"{path}: stale download changed during cleanup")
            path.unlink()
        _sync_dir(directory)
        directory.rmdir()
        _sync_dir(downloads)


def archive_retained_backup(
    project: Path,
    install: Path,
    *,
    editors_closed: bool,
    recovery: Path | None = None,
    process_probe: Callable[[ProcessIdentity], str] = probe_process,
) -> dict[str, Any]:
    """Explicitly free the one active backup slot without deleting history."""
    if not editors_closed:
        _fail("backup archival requires --editors-closed")
    root = (
        _bound_recovery_root(project, install, recovery)
        if recovery is not None
        else recovery_root(project, install)
    )
    if not _lexists(root):
        _fail("recovery root does not exist")
    root = _private_dir(root)
    if _lexists(root / "activation.lock"):
        raise LockBusy("cannot archive a backup during activation or repair")
    EditorLeases(root, project, install).assert_closed(process_probe=process_probe)
    backup = _private_dir(root / "retained-backup")
    identity = hash_tree(backup)
    archives = _private_dir(root / "archived-backups", create=True)
    target = archives / identity.sha256
    if _lexists(target):
        target = archives / f"{identity.sha256}-{secrets.token_hex(8)}"
    _rename_tree(backup, target)
    return {"archive": str(target), "tree": identity.record()}


def _readiness_record(intent: Intent, live_tree: TreeIdentity) -> dict[str, Any]:
    return {
        "editor_nonce": intent.editor.nonce,
        "intent_sha256": _intent_sha(intent),
        "live_tree": live_tree.record(),
        "record": "readiness",
        "schema_version": SCHEMA_VERSION,
        "transaction": intent.transaction,
    }


def validate_readiness(paths: TransactionPaths, intent: Intent) -> dict[str, Any]:
    row = _typed(load_record(paths.readiness), "readiness")
    expected = _readiness_record(intent, intent.new_tree)
    if row != expected:
        _fail("readiness identity or live-tree hash does not match intent")
    if hash_tree(intent.install_root) != intent.new_tree:
        _fail("live tree changed after readiness was written")
    return row


def write_readiness(intent: Intent, *, failpoints: Failpoints | None = None) -> None:
    """Commit readiness from the initiating editor lineage after reload."""

    paths = TransactionPaths.for_transaction(intent.recovery_root, intent.transaction)
    if load_intent(paths) != intent:
        _fail("readiness caller's intent does not match the durable intent")
    ActivationLock(intent.recovery_root).validate(intent)
    journal = load_journal(paths, intent)
    if journal["phase"] != "stage_live":
        _fail("readiness is only valid while the staged tree is live")
    live_tree = hash_tree(intent.install_root)
    if live_tree != intent.new_tree:
        _fail("readiness live-tree hash does not match staged identity")
    with _mutation(failpoints, "readiness_commit"):
        publish_record(paths.readiness, _readiness_record(intent, live_tree))


def _terminal_record(intent: Intent, *, outcome: str, writer: str) -> dict[str, Any]:
    if outcome not in TERMINAL_PHASES or writer not in {"normal", "repair"}:
        _fail("invalid terminal outcome or writer")
    return {
        "intent_sha256": _intent_sha(intent),
        "outcome": outcome,
        "record": "terminal",
        "schema_version": SCHEMA_VERSION,
        "transaction": intent.transaction,
        "writer": writer,
    }


def validate_terminal(path: Path, intent: Intent) -> dict[str, Any]:
    row = _typed(load_record(path), "terminal")
    outcome = _string(row["outcome"], name="terminal.outcome")
    writer = _string(row["writer"], name="terminal.writer")
    if outcome not in TERMINAL_PHASES or writer not in {"normal", "repair"}:
        _fail("terminal outcome or writer is impossible")
    expected = _terminal_record(intent, outcome=outcome, writer=writer)
    if row != expected:
        _fail("terminal identity does not match intent")
    return row


def _rename_tree(source: Path, target: Path) -> None:
    source = _canonical_path(source, must_exist=True)
    target = _canonical_path(target, must_exist=False)
    source_info = _lstat(source)
    if not stat.S_ISDIR(source_info.st_mode):
        _fail(f"{source}: rename source is not a directory")
    if _lexists(target):
        _fail(f"{target}: rename target already exists")
    target_parent = _canonical_path(target.parent, must_exist=True)
    parent_info = _lstat(target_parent)
    if not stat.S_ISDIR(parent_info.st_mode):
        _fail(f"{target_parent}: rename target parent is not a directory")
    if source_info.st_dev != parent_info.st_dev:
        _fail("tree swaps require source and target on the same filesystem")
    os.rename(source, target)
    _sync_dir(source.parent)
    if target.parent != source.parent:
        _sync_dir(target.parent)


def _wait_for(path: Path, timeout: float, description: str) -> None:
    deadline = time.monotonic() + timeout
    while not _lexists(path):
        if time.monotonic() >= deadline:
            _fail(f"timed out waiting for {description}")
        time.sleep(POLL_SECONDS)


def claim_result(intent: Intent, *, failpoints: Failpoints | None = None) -> dict[str, Any]:
    """Atomically consume the result for the initiating editor lineage."""

    paths = TransactionPaths.for_transaction(intent.recovery_root, intent.transaction)
    durable = load_intent(paths)
    if durable != intent:
        _fail("claim caller's intent does not match the durable intent")
    if _lexists(paths.claim):
        claimed = validate_terminal(paths.claim, intent)
        if claimed["outcome"] != load_journal(paths, intent)["phase"]:
            _fail("claim outcome does not match journal phase")
        lock = ActivationLock(intent.recovery_root)
        if claimed["outcome"] == "repair_required" and not _lexists(lock.path):
            _fail("repair-required claim must retain its activation lock")
        if claimed["outcome"] != "repair_required" and _lexists(lock.path):
            lock.release(intent)
        return claimed
    ActivationLock(intent.recovery_root).validate(intent)
    terminal = validate_terminal(paths.result, intent)
    if terminal["outcome"] != load_journal(paths, intent)["phase"]:
        _fail("result outcome does not match journal phase")

    def rename_result() -> None:
        os.rename(paths.result, paths.claim)
        _sync_dir(paths.directory)

    with _mutation(failpoints, "result_to_claim"):
        rename_result()
    if terminal["outcome"] != "repair_required":
        with _mutation(failpoints, "activation_lock_release"):
            ActivationLock(intent.recovery_root).release(intent)
    return terminal


def _migration_complete_record(
    intent: Intent,
    claim: Mapping[str, Any],
    editor: ProcessIdentity,
) -> dict[str, Any]:
    return {
        "claim_sha256": hashlib.sha256(canonical_json(claim)).hexdigest(),
        "editor": editor.record(),
        "intent_sha256": _intent_sha(intent),
        "live_tree": intent.new_tree.record(),
        "record": "migration_complete",
        "schema_version": SCHEMA_VERSION,
        "transaction": intent.transaction,
    }


def validate_migration_complete(paths: TransactionPaths, intent: Intent) -> dict[str, Any]:
    """Validate the immutable M6 acknowledgement without assuming it is current."""

    claim = validate_terminal(paths.claim, intent)
    if claim["outcome"] != "success":
        _fail("only a successful activation may complete client migration")
    row = _typed(load_record(paths.migration_complete), "migration_complete")
    editor = ProcessIdentity.parse(row["editor"], name="migration complete.editor")
    TreeIdentity.parse(row["live_tree"], name="migration complete.live_tree")
    expected = _migration_complete_record(intent, claim, editor)
    if row != expected:
        _fail("migration completion identity differs from its successful claim")
    return row


def complete_migration(
    project: Path,
    install: Path,
    recovery: Path,
    transaction: str,
    editor: ProcessIdentity,
    *,
    failpoints: Failpoints | None = None,
) -> dict[str, Any]:
    """Durably acknowledge M6 only from the leased editor on the exact new tree."""

    root = _bound_recovery_root(project, install, recovery)
    paths = TransactionPaths.for_transaction(root, transaction)
    intent = load_intent(paths)
    canonical_project, canonical_install = _canonical_install(project, install)
    if intent.project_root != canonical_project or intent.install_root != canonical_install:
        _fail("migration completion targets another project or install")
    if _lexists(ActivationLock(root).path):
        raise LockBusy("activation must finish before client migration completion")
    claim = validate_terminal(paths.claim, intent)
    if claim["outcome"] != "success" or load_journal(paths, intent)["phase"] != "success":
        _fail("client migration completion requires a successful terminal claim")
    if hash_tree(intent.install_root) != intent.new_tree:
        _fail("client migration completion live tree differs from the signed update")
    EditorLeases(root, canonical_project, canonical_install).validate(editor)
    election = MigrationElection(root, canonical_project, canonical_install)
    election.acquire(intent, editor)
    if _lexists(paths.migration_complete):
        validate_migration_complete(paths, intent)
        election.release(intent, editor)
        return {"status": "migration_complete", "transaction": transaction}
    with _mutation(failpoints, "migration_complete"):
        publish_record(
            paths.migration_complete,
            _migration_complete_record(intent, claim, editor),
        )
    validate_migration_complete(paths, intent)
    election.release(intent, editor)
    return {"status": "migration_complete", "transaction": transaction}


def _result_once(
    paths: TransactionPaths,
    intent: Intent,
    *,
    outcome: str,
    writer: str,
    failpoints: Failpoints | None,
) -> dict[str, Any]:
    if _lexists(paths.result):
        existing = validate_terminal(paths.result, intent)
        if existing["outcome"] != outcome:
            _fail("existing terminal outcome conflicts with reducer state")
        return existing
    row = _terminal_record(intent, outcome=outcome, writer=writer)
    with _mutation(failpoints, "result_commit"):
        publish_record(paths.result, row)
    return row


def _rollback(
    paths: TransactionPaths,
    intent: Intent,
    *,
    writer: str,
    failpoints: Failpoints | None,
) -> dict[str, Any]:
    """Reduce any preterminal physical state back to the exact old tree."""

    journal = load_journal(paths, intent)
    phase = journal["phase"]
    if phase == "repair_required" and writer == "repair":
        journal = _advance(paths, intent, "rolling_back", failpoints, repair=True)
        phase = journal["phase"]
    elif phase in TERMINAL_PHASES:
        return _result_once(
            paths,
            intent,
            outcome=phase,
            writer=writer,
            failpoints=failpoints,
        )
    if phase != "rolling_back":
        _advance(paths, intent, "rolling_back", failpoints)

    try:
        live_exists = _lexists(intent.install_root)
        backup_exists = _lexists(intent.backup_root)
        if live_exists:
            live_tree = hash_tree(intent.install_root)
            if live_tree != intent.old_tree or backup_exists:
                _private_dir(intent.quarantine_root.parent, create=True)
                if _lexists(intent.quarantine_root):
                    _fail("transaction quarantine already exists")
                with _mutation(failpoints, "quarantine_live"):
                    _rename_tree(intent.install_root, intent.quarantine_root)
                live_exists = False
        if _lexists(intent.backup_root):
            if hash_tree(intent.backup_root) != intent.old_tree:
                _fail("retained backup does not match the old-tree identity")
            if live_exists or _lexists(intent.install_root):
                _fail("cannot restore backup over an existing live tree")
            with _mutation(failpoints, "backup_to_live"):
                _rename_tree(intent.backup_root, intent.install_root)
        if not _lexists(intent.install_root) or hash_tree(intent.install_root) != intent.old_tree:
            _fail("rollback could not restore the exact old live tree")
        if load_journal(paths, intent)["phase"] != "rolling_back":
            _fail("rollback journal reached an impossible state")
        _advance(paths, intent, "rolled_back", failpoints)
        return _result_once(
            paths,
            intent,
            outcome="rolled_back",
            writer=writer,
            failpoints=failpoints,
        )
    except Exception as exc:
        try:
            phase = load_journal(paths, intent)["phase"]
            if "repair_required" in TRANSITIONS[phase]:
                _advance(paths, intent, "repair_required")
            return _result_once(
                paths,
                intent,
                outcome="repair_required",
                writer=writer,
                failpoints=None,
            )
        except TransactionError:
            raise TransactionError(
                f"rollback failed without a safe terminal record: {exc}"
            ) from exc


def run_activation(
    intent: Intent,
    *,
    readiness_timeout: float = 30.0,
    claim_timeout: float = 30.0,
    failpoints: Failpoints | None = None,
) -> dict[str, Any]:
    """Run the sole normal mutation path and wait for its result claim."""

    if readiness_timeout <= 0 or claim_timeout <= 0:
        _fail("timeouts must be positive")
    root = _private_dir(intent.recovery_root)
    paths = TransactionPaths.for_transaction(root, intent.transaction)
    if load_prepared(paths) != _prepared_from_intent(intent):
        _fail("activation intent differs from the signed prepared release")
    if _lexists(paths.intent):
        _fail("transaction intent already exists; use inspect or explicit repair")
    with _mutation(failpoints, "intent_commit"):
        publish_record(paths.intent, intent.record())
    lock = ActivationLock(root)
    lock_acquired = False
    journal_started = False
    try:
        with _mutation(failpoints, "activation_lock"):
            lock.acquire(intent)
            lock_acquired = True
        EditorLeases(root, intent.project_root, intent.install_root).assert_exclusive(intent.editor)
        with _mutation(failpoints, "journal_commit"):
            replace_record(paths.journal, _journal_record(intent, "prepared", 0))
            journal_started = True
        lock.validate(intent)
        if hash_tree(intent.install_root) != intent.old_tree:
            _fail("live tree changed after intent creation")
        if hash_tree(intent.stage_root) != intent.new_tree:
            _fail("staged tree changed after intent creation")
        if _lexists(intent.backup_root) or _lexists(intent.quarantine_root):
            _fail("backup or transaction quarantine already exists")

        with _mutation(failpoints, "live_to_backup"):
            _rename_tree(intent.install_root, intent.backup_root)
        with _mutation(failpoints, "stage_to_live"):
            _rename_tree(intent.stage_root, intent.install_root)
        _advance(paths, intent, "stage_live", failpoints)
        _wait_for(paths.readiness, readiness_timeout, "initiating-editor readiness")
        validate_readiness(paths, intent)
        _advance(paths, intent, "success", failpoints)
        _result_once(
            paths,
            intent,
            outcome="success",
            writer="normal",
            failpoints=failpoints,
        )
    except Exception:
        if not lock_acquired:
            raise
        # replace_record publishes before its directory fsync returns.  If that
        # final sync reports an error, the durable journal—not the local flag—
        # decides whether repair authority must remain locked.
        if not journal_started and _lexists(paths.journal):
            load_journal(paths, intent)
            journal_started = True
        if not journal_started:
            lock.release(intent)
            raise
        phase = load_journal(paths, intent)["phase"]
        if phase == "stage_live":
            # Publishing stage_live authorizes Godot's asynchronous scan.  The
            # editor may now be loading/executing this tree, so the actor must
            # never rename it away on a timeout or readiness failure.  Keep
            # live+backup+lock intact for repair after the editor is proven dead.
            _advance(paths, intent, "repair_required")
            _result_once(
                paths,
                intent,
                outcome="repair_required",
                writer="normal",
                failpoints=None,
            )
        elif phase not in TERMINAL_PHASES:
            _rollback(
                paths,
                intent,
                writer="normal",
                failpoints=failpoints,
            )
        elif phase != "success" and not _lexists(paths.result):
            _result_once(
                paths,
                intent,
                outcome=phase,
                writer="normal",
                failpoints=None,
            )

    _wait_for(paths.claim, claim_timeout, "initiating-editor result claim")
    claimed = validate_terminal(paths.claim, intent)
    if claimed["outcome"] != "repair_required":
        deadline = time.monotonic() + claim_timeout
        while _lexists(lock.path):
            if time.monotonic() >= deadline:
                _fail("claimed transaction still holds the activation lock")
            time.sleep(POLL_SECONDS)
    if claimed["outcome"] == "repair_required" and not _lexists(lock.path):
        _fail("repair-required transaction lost its activation lock")
    return claimed


class Failpoints:
    """Production-inert controller for one explicitly armed qualification barrier."""

    def __init__(
        self,
        capability: Path,
        token: bytes,
        intent: Intent,
        *,
        timeout: float = 30.0,
    ):
        if not 0 < timeout <= MAX_QUALIFICATION_TIMEOUT:
            _fail(f"failpoint timeout must be between 0 and {MAX_QUALIFICATION_TIMEOUT:g}s")
        self.token = token
        self.intent = intent
        self.timeout = timeout
        self.sequence = 0
        self.spent = False
        if len(token) < 32:
            _fail("failpoint token must contain at least 32 bytes")
        expected_path = intent.recovery_root / "qualification-capability.json"
        if _canonical_path(capability, must_exist=True) != expected_path:
            _fail("failpoint capability must use the fixed recovery-root path")
        row = self._capability(load_record(expected_path))
        expected = {
            "effect": row["effect"],
            "occurrence": row["occurrence"],
            "intent_sha256": _intent_sha(intent),
            "record": "qualification_capability",
            "schema_version": SCHEMA_VERSION,
            "token_sha256": hashlib.sha256(token).hexdigest(),
            "transaction": intent.transaction,
            "when": row["when"],
        }
        if row != expected:
            _fail("failpoint capability is not bound to this transaction and token")
        self.armed_effect = row["effect"]
        self.armed_when = row["when"]
        self.armed_occurrence = row["occurrence"]
        self.capability_path = expected_path

    @staticmethod
    def _capability(value: Any) -> dict[str, Any]:
        row = _typed(value, "qualification_capability")
        effect = _string(row["effect"], name="capability.effect", pattern=EFFECT)
        if effect not in ACTIVATE_FAILPOINT_EFFECTS:
            _fail("qualification capability effect is not reachable from activate")
        _integer(row["occurrence"], name="capability.occurrence", minimum=1)
        _string(row["intent_sha256"], name="capability.intent_sha256", pattern=HEX64)
        _string(row["token_sha256"], name="capability.token_sha256", pattern=HEX64)
        _string(row["transaction"], name="capability.transaction", pattern=IDENTIFIER)
        if row["when"] not in {"before", "after"}:
            _fail("capability.when must be before or after")
        return row

    @staticmethod
    def _barrier(value: Any) -> dict[str, Any]:
        row = _typed(value, "failpoint_barrier")
        _string(row["effect"], name="barrier.effect", pattern=EFFECT)
        _integer(row["sequence"], name="barrier.sequence", minimum=1)
        _string(row["transaction"], name="barrier.transaction", pattern=IDENTIFIER)
        if row["when"] not in {"before", "after"}:
            _fail("barrier.when must be before or after")
        for key in ("install_root", "project_root", "recovery_root"):
            _string(row[key], name=f"barrier.{key}")
        return row

    def barrier(self, effect: str, when: str) -> None:
        if self.spent or effect != self.armed_effect or when != self.armed_when:
            return
        self.sequence += 1
        if self.sequence != self.armed_occurrence:
            return
        self.spent = True
        barrier_path = self.intent.recovery_root / "failpoint-barrier.json"
        decision_path = self.intent.recovery_root / "failpoint-decision.json"
        barrier_published = False
        decision_owned = False
        row = {
            "effect": effect,
            "install_root": str(self.intent.install_root),
            "intent_sha256": _intent_sha(self.intent),
            "project_root": str(self.intent.project_root),
            "record": "failpoint_barrier",
            "recovery_root": str(self.intent.recovery_root),
            "schema_version": SCHEMA_VERSION,
            "sequence": self.sequence,
            "transaction": self.intent.transaction,
            "when": when,
        }
        try:
            if _lexists(decision_path):
                _fail("stale failpoint decision already exists")
            publish_record(barrier_path, row)
            barrier_published = True
            _wait_for(decision_path, self.timeout, "external failpoint decision")
            decision_owned = True
            decision = _typed(load_record(decision_path), "failpoint_decision")
            action = _string(decision["action"], name="decision.action")
            mac = _string(decision["mac"], name="decision.mac", pattern=HEX64)
            signed = {key: value for key, value in decision.items() if key != "mac"}
            expected = hmac.new(self.token, canonical_json(signed), hashlib.sha256).hexdigest()
            expected_signed = {**row, "action": action, "record": "failpoint_decision"}
            if not hmac.compare_digest(mac, expected) or signed != expected_signed:
                _fail("failpoint decision authentication or identity failed")
            if action not in {"continue", "fail"}:
                _fail("failpoint decision must be continue or fail")
        finally:
            owned_paths = []
            if decision_owned:
                owned_paths.append(decision_path)
            if barrier_published:
                owned_paths.append(barrier_path)
            for path in owned_paths:
                try:
                    path.unlink()
                except FileNotFoundError:
                    pass
            self.close()

        if action == "fail":
            raise InjectedFailure(f"qualification failpoint: {effect}:{when}")

    def close(self) -> None:
        """Remove a handled capability; an abrupt process death preserves it."""

        try:
            self.capability_path.unlink()
        except FileNotFoundError:
            pass
        finally:
            _sync_dir(self.intent.recovery_root)


def write_failpoint_capability(
    intent: Intent,
    *,
    effect: str,
    when: str,
    token: bytes,
    occurrence: int = 1,
) -> Path:
    """Arm one local barrier without storing or returning its secret token."""

    _string(effect, name="effect", pattern=EFFECT)
    if effect not in ACTIVATE_FAILPOINT_EFFECTS:
        _fail("qualification capability effect is not reachable from activate")
    if when not in {"before", "after"} or len(token) < 32:
        _fail("failpoint capability requires before/after and a 32-byte token")
    _integer(occurrence, name="occurrence", minimum=1)
    path = intent.recovery_root / "qualification-capability.json"
    publish_record(
        path,
        {
            "effect": effect,
            "occurrence": occurrence,
            "intent_sha256": _intent_sha(intent),
            "record": "qualification_capability",
            "schema_version": SCHEMA_VERSION,
            "token_sha256": hashlib.sha256(token).hexdigest(),
            "transaction": intent.transaction,
            "when": when,
        },
    )
    return path


def activate_failpoints_from_environment(intent: Intent) -> Failpoints | None:
    """Consume one complete process-local qualification tuple, or stay inert."""

    values = {name: os.environ.pop(name, None) for name in QUALIFICATION_FAILPOINT_ENV}
    if all(value is None for value in values.values()):
        return None
    if any(
        value is None
        for name, value in values.items()
        if name != QUALIFICATION_FAILPOINT_OCCURRENCE_ENV
    ):
        _fail("qualification failpoint environment is incomplete")
    token_hex = values[QUALIFICATION_FAILPOINT_TOKEN_ENV]
    effect = values[QUALIFICATION_FAILPOINT_EFFECT_ENV]
    when = values[QUALIFICATION_FAILPOINT_WHEN_ENV]
    timeout_text = values[QUALIFICATION_FAILPOINT_TIMEOUT_ENV]
    occurrence_text = values[QUALIFICATION_FAILPOINT_OCCURRENCE_ENV]
    if occurrence_text is None:
        occurrence_text = "1"
    if re.fullmatch(r"[1-9][0-9]{0,3}", occurrence_text) is None:
        _fail("qualification failpoint occurrence must be an integer from 1 to 9999")
    assert token_hex is not None and effect is not None and when is not None
    assert timeout_text is not None
    if HEX64.fullmatch(token_hex) is None:
        _fail("qualification failpoint token must be 64 lowercase hexadecimal digits")
    _string(effect, name="qualification effect", pattern=EFFECT)
    if effect not in ACTIVATE_FAILPOINT_EFFECTS | COORDINATOR_FAILPOINT_EFFECTS:
        _fail("qualification effect is unknown")
    if when not in {"before", "after"}:
        _fail("qualification failpoint timing must be before or after")
    if QUALIFICATION_TIMEOUT.fullmatch(timeout_text) is None:
        _fail("qualification failpoint timeout must be a positive decimal number")
    timeout = float(timeout_text)
    if not 0 < timeout <= MAX_QUALIFICATION_TIMEOUT:
        _fail(
            f"qualification failpoint timeout must be between 0 and {MAX_QUALIFICATION_TIMEOUT:g}s"
        )
    if effect in COORDINATOR_FAILPOINT_EFFECTS:
        return None
    token = bytes.fromhex(token_hex)
    capability = write_failpoint_capability(
        intent, effect=effect, when=when, token=token, occurrence=int(occurrence_text)
    )
    try:
        return Failpoints(capability, token, intent, timeout=timeout)
    except BaseException:
        capability.unlink(missing_ok=True)
        _sync_dir(intent.recovery_root)
        raise


def write_failpoint_decision(recovery: Path, *, token: bytes, action: str) -> None:
    """Authenticate the controller's response to the currently visible barrier."""

    root = _private_dir(recovery)
    capability = Failpoints._capability(load_record(root / "qualification-capability.json"))
    if not hmac.compare_digest(capability["token_sha256"], hashlib.sha256(token).hexdigest()):
        _fail("failpoint controller token does not match capability")
    barrier = Failpoints._barrier(load_record(root / "failpoint-barrier.json"))
    if (
        barrier["effect"] != capability["effect"]
        or barrier["when"] != capability["when"]
        or barrier["transaction"] != capability["transaction"]
        or barrier["recovery_root"] != str(root)
    ):
        _fail("barrier does not match qualification capability")
    if action not in {"continue", "fail"}:
        _fail("failpoint decision must be continue or fail")
    signed = {**barrier, "action": action, "record": "failpoint_decision"}
    publish_record(
        root / "failpoint-decision.json",
        {**signed, "mac": hmac.new(token, canonical_json(signed), hashlib.sha256).hexdigest()},
    )


def write_coordinator_failpoint_decision(recovery: Path, *, token: bytes, action: str) -> None:
    """Authenticate a controller response to the current coordinator barrier."""

    root = _private_dir(recovery)
    if len(token) != 32:
        _fail("coordinator failpoint token must contain exactly 32 bytes")
    if action not in {"continue", "fail"}:
        _fail("coordinator failpoint decision must be continue or fail")
    barrier = _typed(
        _load_json_object(root / "coordinator-failpoint-barrier.json", require_canonical=False),
        "coordinator_failpoint_barrier",
    )
    transaction = _string(
        barrier["transaction"], name="coordinator barrier.transaction", pattern=IDENTIFIER
    )
    effect = _string(barrier["effect"], name="coordinator barrier.effect", pattern=EFFECT)
    if effect not in COORDINATOR_FAILPOINT_EFFECTS:
        _fail("coordinator failpoint effect is unknown")
    when = _string(barrier["when"], name="coordinator barrier.when")
    if when not in {"before", "after"}:
        _fail("coordinator failpoint timing must be before or after")
    sequence = _integer(barrier["sequence"], name="coordinator barrier.sequence", minimum=1)
    token_sha256 = _string(
        barrier["token_sha256"],
        name="coordinator barrier.token_sha256",
        pattern=HEX64,
    )
    if not hmac.compare_digest(token_sha256, hashlib.sha256(token).hexdigest()):
        _fail("coordinator failpoint controller token does not match barrier")
    project_text = _string(barrier["project_root"], name="coordinator barrier.project_root")
    install_text = _string(barrier["install_root"], name="coordinator barrier.install_root")
    recovery_text = _string(barrier["recovery_root"], name="coordinator barrier.recovery_root")
    project, install = _canonical_install(project_text, install_text, allow_missing_install=True)
    bound = _bound_recovery_root(project, install, root, allow_missing_install=True)
    if project_text != str(project) or install_text != str(install) or recovery_text != str(bound):
        _fail("coordinator failpoint barrier roots are not canonical and bound")
    message = (
        "godot-ai-coordinator-failpoint-v1\n"
        f"{transaction}\n{project}\n{install}\n{bound}\n"
        f"{effect}\n{when}\n{sequence}\n{action}\n"
    ).encode("utf-8")
    decision = {
        **barrier,
        "action": action,
        "record": "coordinator_failpoint_decision",
    }
    publish_record(
        root / "coordinator-failpoint-decision.json",
        {**decision, "mac": hmac.new(token, message, hashlib.sha256).hexdigest()},
    )


@contextmanager
def _mutation(failpoints: Failpoints | None, name: str) -> Iterator[None]:
    if failpoints is not None:
        failpoints.barrier(name, "before")
    yield
    if failpoints is not None:
        failpoints.barrier(name, "after")


def _archive_pre_repair_terminal(paths: TransactionPaths, intent: Intent) -> None:
    candidates = [path for path in (paths.result, paths.claim) if _lexists(path)]
    if len(candidates) > 1:
        _fail("result and claim cannot both exist")
    if not candidates:
        return
    source = candidates[0]
    terminal = validate_terminal(source, intent)
    digest = hashlib.sha256(canonical_json(terminal)).hexdigest()[:16]
    target = paths.directory / f"pre-repair-terminal-{digest}.json"
    if _lexists(target):
        if load_record(target) != terminal:
            _fail("archived repair terminal digest collision")
        source.unlink()
    else:
        os.rename(source, target)
    _sync_dir(paths.directory)


def _claim_repair(
    paths: TransactionPaths,
    intent: Intent,
    runner: ProcessIdentity,
    repairer: ProcessIdentity,
    process_probe: Callable[[ProcessIdentity], str],
    failpoints: Failpoints | None,
) -> None:
    path = paths.directory / "repair-claim.json"
    if _lexists(path):
        prior = _typed(load_record(path), "repair_claim")
        if (
            prior["intent_sha256"] != _intent_sha(intent)
            or prior["transaction"] != intent.transaction
            or ProcessIdentity.parse(prior["prior_runner"], name="prior runner") != runner
        ):
            _fail("existing repair claim does not match this transaction")
        prior_repairer = ProcessIdentity.parse(prior["repairer"], name="prior repairer")
        state = process_probe(prior_repairer)
        if state not in {"dead", "reused"}:
            raise RepairRefused(f"prior repair runner identity is not gone: {state}")
        suffix = hashlib.sha256(canonical_json(prior_repairer.record())).hexdigest()[:16]
        archive = paths.directory / f"repair-claim-{suffix}.json"
        if _lexists(archive):
            _fail("prior repair claim was already archived")
        os.rename(path, archive)
        _sync_dir(paths.directory)
    row = {
        "intent_sha256": _intent_sha(intent),
        "prior_runner": runner.record(),
        "record": "repair_claim",
        "repairer": repairer.record(),
        "schema_version": SCHEMA_VERSION,
        "transaction": intent.transaction,
    }
    with _mutation(failpoints, "repair_claim"):
        publish_record(path, row)


def _claim_preactivation_repair(
    paths: TransactionPaths,
    authority: Mapping[str, Any],
    abort: Mapping[str, Any],
    prior_owner: ProcessIdentity,
    repairer: ProcessIdentity,
    process_probe: Callable[[ProcessIdentity], str],
    failpoints: Failpoints | None,
) -> dict[str, Any]:
    """Serialize cleanup takeover without granting activation authority."""

    path = paths.directory / "repair-claim.json"
    if _lexists(path):
        prior = _load_preactivation_repair_claim(path, authority, abort, prior_owner)
        prior_repairer = ProcessIdentity.parse(
            prior["repairer"], name="prior preactivation repairer"
        )
        if prior_repairer == repairer:
            return prior
        state = process_probe(prior_repairer)
        if state not in {"dead", "reused"}:
            raise RepairRefused(f"prior preactivation repairer identity is not gone: {state}")
        suffix = hashlib.sha256(canonical_json(prior_repairer.record())).hexdigest()[:16]
        archive = paths.directory / f"repair-claim-{suffix}.json"
        if _lexists(archive):
            _fail("prior preactivation repair claim was already archived")
        os.rename(path, archive)
        _sync_dir(paths.directory)
    row = _preactivation_repair_record(authority, abort, prior_owner, repairer)
    with _mutation(failpoints, "preactivation_repair_claim"):
        publish_record(path, row)
    return row


def repair_transaction(
    recovery: Path,
    transaction: str,
    *,
    repairer: ProcessIdentity | None = None,
    process_probe: Callable[[ProcessIdentity], str] = probe_process,
    failpoints: Failpoints | None = None,
) -> dict[str, Any]:
    """Explicitly finish or roll back work only after proving both owners dead."""

    paths = TransactionPaths.for_transaction(recovery, transaction)
    intent = load_intent(paths)
    lock = ActivationLock(intent.recovery_root)
    owner = lock.validate(intent)
    runner = ProcessIdentity.parse(owner["runner"], name="lock.runner")
    runner_state = process_probe(runner)
    editor_state = process_probe(intent.editor)
    if runner_state not in {"dead", "reused"} or editor_state not in {
        "dead",
        "reused",
    }:
        raise RepairRefused(
            "repair requires runner and initiating editor identities gone; "
            f"runner={runner_state}, editor={editor_state}"
        )

    repairer = repairer or ProcessIdentity.current()
    _claim_repair(paths, intent, runner, repairer, process_probe, failpoints)

    if not _lexists(paths.journal):
        with _mutation(failpoints, "journal_commit"):
            replace_record(paths.journal, _journal_record(intent, "prepared", 0))
    journal = load_journal(paths, intent)
    phase = journal["phase"]
    existing_claim = validate_terminal(paths.claim, intent) if _lexists(paths.claim) else None
    completed_claim = (
        existing_claim is not None
        and existing_claim["outcome"] == phase
        and phase != "repair_required"
    )
    if completed_claim:
        terminal = existing_claim
    elif phase == "success":
        try:
            validate_readiness(paths, intent)
        except TransactionError:
            _archive_pre_repair_terminal(paths, intent)
            _advance(paths, intent, "rolling_back", failpoints, repair=True)
            terminal = _rollback(
                paths,
                intent,
                writer="repair",
                failpoints=failpoints,
            )
        else:
            terminal = _result_once(
                paths,
                intent,
                outcome="success",
                writer="repair",
                failpoints=failpoints,
            )
    elif (
        phase == "rolled_back"
        and _lexists(intent.install_root)
        and hash_tree(intent.install_root) == intent.old_tree
    ):
        terminal = _result_once(
            paths,
            intent,
            outcome="rolled_back",
            writer="repair",
            failpoints=failpoints,
        )
    else:
        _archive_pre_repair_terminal(paths, intent)
        terminal = _rollback(
            paths,
            intent,
            writer="repair",
            failpoints=failpoints,
        )

    if terminal["outcome"] == "repair_required":
        raise RepairRefused("repair could not restore a safe terminal tree")
    if not _lexists(paths.claim):
        if not _lexists(paths.result):
            _fail("repair produced no claimable terminal result")
        os.rename(paths.result, paths.claim)
        _sync_dir(paths.directory)
    validate_terminal(paths.claim, intent)
    with _mutation(failpoints, "activation_lock_release"):
        lock.release(intent)
    return validate_terminal(paths.claim, intent)


@contextmanager
def _clean_failed_preparation(
    project: Path,
    install: Path,
    root: Path,
    transaction: str,
    editor: ProcessIdentity,
) -> Iterator[None]:
    """Clean handled preparation errors; crash/failpoint evidence remains durable."""

    try:
        yield
    except (OSError, ReleaseError, TransactionError) as error:
        if isinstance(error, InjectedFailure):
            raise
        try:
            abort_prepared(project, install, root, transaction, editor)
        except (OSError, TransactionError) as cleanup_error:
            raise TransactionError(
                f"release preparation failed ({error}); cleanup refused ({cleanup_error})"
            ) from error
        raise


def prepare_release(
    *,
    archive: Path,
    manifest: Path,
    signature: Path,
    project: Path,
    install: Path,
    transaction: str,
    channel: str,
    tag: str,
    version: str,
    source: str,
    editor: ProcessIdentity,
    override: Path | None = None,
    failpoints: Failpoints | None = None,
) -> dict[str, Any]:
    """Authenticate and stage exact release bytes before quiescence."""

    _string(transaction, name="transaction", pattern=IDENTIFIER)
    root = preflight_update(project, install, editor, override=override)
    project_root, install_root = _canonical_install(project, install)
    stage_root = root / "stages" / transaction / "addons" / "godot_ai"
    with _clean_failed_preparation(project_root, install_root, root, transaction, editor):
        with _mutation(failpoints, "prepare_transaction"):
            paths = TransactionPaths.for_transaction(root, transaction, create=True)
        prepare_claim = _prepare_claim_record(
            transaction=transaction,
            project=project_root,
            install=install_root,
            recovery=root,
            stage=stage_root,
            old_tree=hash_tree(install_root),
            editor=editor,
        )
        with _mutation(failpoints, "prepare_claim"):
            publish_record(paths.directory / "prepare-claim.json", prepare_claim)
        stages = _private_dir(root / "stages", create=True)
        container = stages / transaction
        with _mutation(failpoints, "prepare_stage"):
            stage, manifest_sha, signed_manifest = stage_verified_release(
                archive,
                manifest,
                signature,
                (REPOSITORY, channel, tag, version, source),
                container,
            )
        stage_root = _canonical_path(stage, must_exist=True)
        new_tree = _signed_tree(signed_manifest)
        if hash_tree(stage_root) != new_tree:
            _fail("verified stage differs from the signed manifest inventory")
        if _lexists(paths.prepared):
            _fail("transaction preparation already exists")
        with _mutation(failpoints, "prepared_commit"):
            publish_record(
                paths.prepared,
                _prepared_record(
                    transaction=transaction,
                    project=project_root,
                    install=install_root,
                    recovery=root,
                    stage=stage_root,
                    version=version,
                    manifest_sha256=manifest_sha,
                    new_tree=new_tree,
                    old_tree=TreeIdentity.parse(prepare_claim["old_tree"], name="old tree"),
                    editor=editor,
                ),
            )
        result = {
            "manifest_sha256": manifest_sha,
            "recovery_root": str(root),
            "stage_root": str(stage_root),
            "transaction": transaction,
        }
    return result


def abort_prepared(
    project: Path,
    install: Path,
    recovery: Path,
    transaction: str,
    requester: ProcessIdentity,
    *,
    intent_only: bool = False,
    dead_owner_takeover: bool = False,
    process_probe: Callable[[ProcessIdentity], str] = probe_process,
    failpoints: Failpoints | None = None,
) -> dict[str, Any]:
    """Resumably discard pre-activation state without touching the live tree."""

    if intent_only and dead_owner_takeover:
        _fail("preactivation cleanup takeover modes are mutually exclusive")

    project_root, install_root = _canonical_install(project, install)
    root = _bound_recovery_root(project_root, install_root, recovery)
    _string(transaction, name="transaction", pattern=IDENTIFIER)
    directory = root / "transactions" / transaction
    container = root / "stages" / transaction
    if not _lexists(directory):
        if _lexists(container) or _lexists(root / "activation.lock"):
            _fail("missing preparation record has unexpected activation state")
        if _lexists(directory.parent):
            _sync_dir(directory.parent)
        return {"status": "aborted_empty", "transaction": transaction}
    paths = TransactionPaths.for_transaction(root, transaction)

    prepare_claim_path = paths.directory / "prepare-claim.json"
    if not _lexists(prepare_claim_path):
        if any(paths.directory.iterdir()):
            _fail("preparation has records but no durable prepare claim")
        if _lexists(container) or _lexists(root / "activation.lock"):
            _fail("claimless preparation has unexpected activation state")
        with _mutation(failpoints, "abort_empty_delete"):
            paths.directory.rmdir()
        with _mutation(failpoints, "abort_empty_sync"):
            _sync_dir(paths.directory.parent)
        return {"status": "aborted_empty", "transaction": transaction}

    authority = _preparation_authority(paths, require_stage=False)
    prepared_editor = ProcessIdentity.parse(authority["editor"], name="prepared.editor")
    if authority["project_root"] != str(project_root) or authority["install_root"] != str(
        install_root
    ):
        _fail("prepared release is bound to another editor or install")
    if any(
        _lexists(path) for path in (paths.journal, paths.readiness, paths.result, paths.claim)
    ) or _lexists(root / "activation.lock"):
        _fail("activation already began; prepared release cannot be aborted")

    cleanup_path = paths.directory / "cleanup.json"
    if _lexists(cleanup_path):
        _has_resolved_pre_activation_cleanup(paths)
        status = "aborted_intent" if load_record(paths.intent)["record"] == "intent" else "aborted"
        return {"status": status, "transaction": transaction}

    old_tree = TreeIdentity.parse(authority["old_tree"], name="old tree")
    if hash_tree(install_root) != old_tree:
        _fail("prepared cleanup found a changed live tree")

    durable_intent: Intent | None = None
    abort: dict[str, Any] | None = None
    preactivation_repair: dict[str, Any] | None = None
    if _lexists(paths.intent):
        raw_intent = load_record(paths.intent)
        if raw_intent.get("record") == "abort_intent":
            if intent_only:
                _fail("abort intent cannot use activation-intent cleanup")
            abort = _load_abort_intent(paths.intent, authority, transaction)
            abort_requester = ProcessIdentity.parse(abort["requester"], name="abort requester")
            if abort_requester == prepared_editor and requester == prepared_editor:
                if dead_owner_takeover:
                    _fail("dead-owner takeover requires a different requester")
                claim = abort
                writer = "editor"
            else:
                if not dead_owner_takeover:
                    _fail("prepared cleanup claim belongs to another requester")
                if requester == prepared_editor:
                    _fail("dead-owner takeover requires a different requester")
                editor_state = process_probe(prepared_editor)
                abort_state = (
                    "current" if abort_requester == requester else process_probe(abort_requester)
                )
                if editor_state not in {"dead", "reused"} or abort_state not in {
                    "current",
                    "dead",
                    "reused",
                }:
                    raise RepairRefused(
                        "prepared cleanup takeover requires prior identities gone; "
                        f"editor={editor_state}, abort_requester={abort_state}"
                    )
                preactivation_repair = _claim_preactivation_repair(
                    paths,
                    authority,
                    abort,
                    prepared_editor,
                    requester,
                    process_probe,
                    failpoints,
                )
                claim = preactivation_repair
                writer = "repair"
        else:
            if not intent_only or dead_owner_takeover:
                _fail("activation intent exists; explicit intent-only cleanup is required")
            durable_intent = load_intent(paths)
            if (
                not _lexists(paths.prepared)
                or _prepared_from_intent(durable_intent) != authority
                or durable_intent.editor != prepared_editor
            ):
                _fail("intent-only cleanup differs from the signed prepared release")
            runner_state = process_probe(durable_intent.runner)
            editor_state = process_probe(durable_intent.editor)
            if runner_state not in {"dead", "reused"} or editor_state not in {
                "dead",
                "reused",
            }:
                raise RepairRefused(
                    "intent-only cleanup requires prior runner and editor identities gone; "
                    f"runner={runner_state}, editor={editor_state}"
                )
            _claim_repair(
                paths,
                durable_intent,
                durable_intent.runner,
                requester,
                process_probe,
                failpoints,
            )
            claim = _typed(load_record(paths.directory / "repair-claim.json"), "repair_claim")
            writer = "repair"
    else:
        if intent_only:
            _fail("intent-only cleanup requires a durable activation intent")
        if prepared_editor != requester:
            if not dead_owner_takeover:
                _fail("prepared release is bound to another editor or install")
            editor_state = process_probe(prepared_editor)
            if editor_state not in {"dead", "reused"}:
                raise RepairRefused(
                    "prepared cleanup takeover requires prepared editor identity gone; "
                    f"editor={editor_state}"
                )
        elif dead_owner_takeover:
            _fail("dead-owner takeover requires a different requester")
        with _mutation(failpoints, "abort_claim"):
            publish_record(paths.intent, _abort_record(authority, requester))
        abort = _load_abort_intent(paths.intent, authority, transaction)
        if dead_owner_takeover:
            preactivation_repair = _claim_preactivation_repair(
                paths,
                authority,
                abort,
                prepared_editor,
                requester,
                process_probe,
                failpoints,
            )
            claim = preactivation_repair
            writer = "repair"
        else:
            claim = abort
            writer = "editor"

    if hash_tree(install_root) != old_tree:
        _fail("prepared cleanup found a changed live tree")

    stage = Path(authority["stage_root"])
    addons = container / "addons"
    if stage != addons / "godot_ai":
        _fail("prepared stage does not have the fixed release layout")
    if _lexists(paths.journal) or _lexists(root / "activation.lock"):
        _fail("activation state appeared while claiming prepared cleanup")

    if _lexists(container):
        _private_dir(container)
        if _lexists(paths.prepared):
            for directory, expected in ((container, {"addons"}), (addons, {"godot_ai"})):
                directory = _private_dir(directory)
                if {child.name for child in directory.iterdir()} != expected:
                    _fail("prepared stage container has unexpected entries")
            if hash_tree(stage) != TreeIdentity.parse(
                authority["new_tree"], name="prepared.new_tree"
            ):
                _fail("prepared stage no longer matches its signed identity")

    names = {path.name for path in paths.directory.iterdir()}
    expected = {"intent.json", "prepare-claim.json"}
    if _lexists(paths.prepared):
        expected.add("prepared.json")
    if preactivation_repair is not None:
        if abort is None:
            _fail("prepared cleanup takeover is missing its abort authority")
        expected.add("repair-claim.json")
        archives = names - expected
        if any(re.fullmatch(r"repair-claim-[0-9a-f]{16}\.json", name) is None for name in archives):
            _fail("prepared cleanup takeover found unexpected transaction records")
        for name in names - {"intent.json", "prepared.json", "prepare-claim.json"}:
            _load_preactivation_repair_claim(
                paths.directory / name, authority, abort, prepared_editor
            )
        active = _load_preactivation_repair_claim(
            paths.directory / "repair-claim.json", authority, abort, prepared_editor
        )
        if ProcessIdentity.parse(active["repairer"], name="repairer") != requester:
            _fail("prepared cleanup takeover belongs to another repairer")
        if not expected.issubset(names):
            _fail("prepared cleanup takeover is missing its durable repair claim")
    elif durable_intent is None:
        if names != expected:
            _fail("prepared transaction has unexpected records")
    else:
        expected.add("repair-claim.json")
        archives = names - expected
        if any(re.fullmatch(r"repair-claim-[0-9a-f]{16}\.json", name) is None for name in archives):
            _fail("intent-only cleanup found unexpected transaction records")
        for name in names - {"intent.json", "prepared.json", "prepare-claim.json"}:
            row = _typed(load_record(paths.directory / name), "repair_claim")
            if (
                row["intent_sha256"] != _intent_sha(durable_intent)
                or row["transaction"] != durable_intent.transaction
                or ProcessIdentity.parse(row["prior_runner"], name="prior runner")
                != durable_intent.runner
            ):
                _fail("intent-only cleanup repair claim differs from the transaction")
        active = _typed(load_record(paths.directory / "repair-claim.json"), "repair_claim")
        if ProcessIdentity.parse(active["repairer"], name="repairer") != requester:
            _fail("intent-only cleanup claim belongs to another repairer")
        if not expected.issubset(names):
            _fail("intent-only cleanup is missing its durable repair claim")

    if _lexists(container):
        with _mutation(failpoints, "abort_stage_delete"):
            shutil.rmtree(container)
        with _mutation(failpoints, "abort_stage_sync"):
            _sync_dir(container.parent)
    with _mutation(failpoints, "abort_cleanup_commit"):
        publish_record(cleanup_path, _cleanup_record(authority, claim, writer=writer))
    _validate_cleanup(paths, authority, claim, writer=writer)
    return {
        "status": "aborted_intent" if durable_intent is not None else "aborted",
        "transaction": transaction,
    }


def _post_outcome(
    intent: Intent,
    terminal: Mapping[str, Any],
    *,
    status: str = "claimed",
) -> dict[str, Any]:
    return {
        "backup_root": str(intent.backup_root),
        "from_version": intent.from_version,
        # A major-version bridge must replace every owned client entry, not
        # only an entry already pinned to the exact old package. This is still
        # a normal transaction completion, not the separate manual-marker lane.
        "replace_owned_mismatches": not intent.from_version.startswith("4."),
        "new_tree": intent.new_tree.record(),
        "outcome": terminal["outcome"],
        "recovery_root": str(intent.recovery_root),
        "status": status,
        "to_version": intent.to_version,
        "transaction": intent.transaction,
    }


def _pending_migration(
    root: Path,
    project: Path,
    install: Path,
) -> tuple[Intent, dict[str, Any]] | None:
    """Find the one successful claim whose post-update M6 is not acknowledged."""

    transactions_path = root / "transactions"
    if not _lexists(transactions_path):
        return None
    transactions = _private_dir(transactions_path)
    pending: list[tuple[Intent, dict[str, Any]]] = []
    for directory_path in sorted(transactions.iterdir()):
        directory = _private_dir(directory_path)
        paths = TransactionPaths.for_transaction(root, directory.name)
        if not _lexists(paths.claim):
            continue
        intent = load_intent(paths)
        if intent.project_root != project or intent.install_root != install:
            _fail("transaction history is bound to another project or install")
        claim = validate_terminal(paths.claim, intent)
        if load_journal(paths, intent)["phase"] != claim["outcome"]:
            _fail("claimed transaction outcome differs from its journal")
        if _lexists(paths.migration_complete):
            validate_migration_complete(paths, intent)
        elif claim["outcome"] == "success":
            pending.append((intent, claim))
    if len(pending) > 1:
        _fail("multiple post-update client migrations are pending")
    if not pending:
        return None
    intent, claim = pending[0]
    if hash_tree(install) != intent.new_tree:
        _fail("pending client migration does not match the current live tree")
    return intent, claim


def startup_barrier(
    project: Path,
    install: Path,
    *,
    editor_pid: int,
    editor_nonce: str,
    transaction: str | None = None,
    override: Path | None = None,
    timeout: float = 30.0,
) -> dict[str, Any]:
    """Admit ordinary startup or complete the exact initiating handoff."""

    if timeout <= 0:
        _fail("startup timeout must be positive")
    root = recovery_root(project, install, override=override)
    if not _lexists(root):
        if transaction is not None:
            _fail("explicit startup transaction has no recovery root")
        root = recovery_root(project, install, override=override, create=True)
    lock = ActivationLock(root)
    if transaction is None:
        current_editor = editor_identity(editor_pid, editor_nonce)
        leases = EditorLeases(root, project, install)
        election = MigrationElection(root, project, install)
        manual_election = ManualMigrationElection(project, install)
        pending: tuple[Intent, dict[str, Any]] | None = None
        manual: tuple[Path, dict[str, Any]] | None = None
        try:
            if _lexists(lock.path):
                raise LockBusy(
                    "activation in progress; only the initiating coordinator handoff may start"
                )
            election.clear_completed(current_editor)
            canonical_project, canonical_install = _canonical_install(project, install)
            pending = _pending_migration(root, canonical_project, canonical_install)
            if pending is not None:
                # Client configuration is user-global for several supported
                # clients.  Elect one live editor for the durable M6 replay so
                # two post-crash startups cannot mutate those files together.
                # Ordinary, fully-completed startup remains multi-editor.
                election.acquire(pending[0], current_editor)
            else:
                manual_election.clear_finished(current_editor)
                manual = _manual_migration_marker(project, install)
                if manual is not None:
                    manual_election.acquire(manual[1], current_editor)
            leases.acquire(current_editor)
            if pending is not None:
                leases.assert_exclusive(current_editor)
        except BaseException:
            leases.release(current_editor)
            if pending is not None and _lexists(election.path):
                try:
                    election.release(pending[0], current_editor)
                except TransactionError:
                    pass
            if manual is not None and _lexists(manual_election.path):
                try:
                    manual_election.release(manual[1], current_editor)
                except TransactionError:
                    pass
            raise
        if pending is not None:
            intent, terminal = pending
            return _post_outcome(intent, terminal, status="migration_pending")
        if manual is not None:
            marker = manual[1]
            return {
                "from_version": marker["from_version"],
                "manual_migration": True,
                "outcome": "success",
                "status": "migration_pending",
                "to_version": marker["to_version"],
                "transaction": "manual-"
                + hashlib.sha256(canonical_json(marker)).hexdigest()[:24],
            }
        return {"status": "none"}
    paths = TransactionPaths.for_transaction(root, transaction)
    intent = load_intent(paths)
    current_editor = editor_identity(editor_pid, editor_nonce)
    if current_editor != intent.editor:
        if intent.from_version.startswith("4."):
            _fail("startup transaction is bound to another initiating editor")
        if not _lexists(lock.path):
            _fail("restart handoff lost its activation lock")
        lock.validate(intent)
        if load_journal(paths, intent)["phase"] != "stage_live":
            _fail("restart handoff is not at the live-tree boundary")
        if hash_tree(intent.install_root) != intent.new_tree:
            _fail("restart handoff live tree differs from the signed update")
        EditorLeases(root, project, install).transfer_restart(
            intent.editor,
            current_editor,
            timeout=timeout,
        )
    if _lexists(paths.claim):
        terminal = claim_result(intent)
        if terminal["outcome"] == "success" and not _lexists(paths.migration_complete):
            MigrationElection(root, project, install).acquire(intent, current_editor)
        EditorLeases(root, project, install).acquire(current_editor)
        return _post_outcome(intent, terminal)
    if not _lexists(lock.path):
        _fail("transaction has neither a terminal claim nor its activation lock")
    lock.validate(intent)
    journal = load_journal(paths, intent)
    if journal["phase"] == "stage_live" and not _lexists(paths.readiness):
        write_readiness(intent)
    deadline = time.monotonic() + timeout
    while not (_lexists(paths.result) or _lexists(paths.claim)):
        if time.monotonic() >= deadline:
            _fail("timed out waiting for activation result")
        time.sleep(POLL_SECONDS)
    terminal = claim_result(intent)
    if terminal["outcome"] == "success" and not _lexists(paths.migration_complete):
        MigrationElection(root, project, install).acquire(intent, current_editor)
    EditorLeases(root, project, install).acquire(current_editor)
    return _post_outcome(intent, terminal)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="python -m godot_ai.update_transaction",
        description="Inspect, explicitly repair, or archive v4 activation state.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser(
        "identity",
        help="print this actor's protocol/package identity without filesystem effects",
    )
    for command in ("root", "startup"):
        subparser = subparsers.add_parser(command)
        subparser.add_argument("--project", type=Path, required=True)
        subparser.add_argument("--install", type=Path, required=True)
        subparser.add_argument(
            "--recovery-base",
            type=Path,
            help="optional parent under which the install-specific root is derived",
        )
        if command == "startup":
            subparser.add_argument("--transaction")
            subparser.add_argument("--editor-pid", type=int, required=True)
            subparser.add_argument("--editor-nonce", required=True)
            subparser.add_argument("--timeout", type=float, default=30.0)
    subparsers.choices["root"].add_argument("--create", action="store_true")
    repair = subparsers.add_parser("repair")
    for name in ("project", "install", "recovery-root"):
        repair.add_argument(f"--{name}", type=Path, required=True)
    repair.add_argument("--transaction", required=True)
    prepare = subparsers.add_parser("prepare")
    for name in ("archive", "manifest", "signature", "project", "install"):
        prepare.add_argument(f"--{name}", type=Path, required=True)
    prepare.add_argument("--recovery-base", type=Path)
    prepare.add_argument("--transaction", required=True)
    prepare.add_argument("--channel", choices=("stable",), required=True)
    prepare.add_argument("--editor-pid", type=int, required=True)
    prepare.add_argument("--editor-nonce", required=True)
    for name in ("tag", "version", "source"):
        prepare.add_argument(f"--{name}", required=True)
    activate = subparsers.add_parser("activate")
    for name in ("project", "install", "recovery-root", "stage"):
        activate.add_argument(f"--{name}", type=Path, required=True)
    for name in (
        "transaction",
        "from-version",
        "to-version",
        "manifest-sha256",
        "editor-nonce",
    ):
        activate.add_argument(f"--{name}", required=True)
    activate.add_argument("--editor-pid", type=int, required=True)
    activate.add_argument("--readiness-timeout", type=float, default=30.0)
    activate.add_argument("--claim-timeout", type=float, default=30.0)
    lease = subparsers.add_parser("lease")
    lease.add_argument("action", choices=("acquire", "release", "preflight"))
    for name in ("project", "install"):
        lease.add_argument(f"--{name}", type=Path, required=True)
    lease.add_argument("--recovery-base", type=Path)
    lease.add_argument("--editor-pid", type=int, required=True)
    lease.add_argument("--editor-nonce", required=True)
    lease.add_argument(
        "--download-id",
        help="with preflight, exclusively allocate this private download directory",
    )
    archive = subparsers.add_parser(
        "archive-backup",
        help="archive the retained backup after proving every editor closed",
    )
    for name in ("project", "install"):
        archive.add_argument(f"--{name}", type=Path, required=True)
    archive.add_argument("--recovery-root", type=Path, required=True)
    archive.add_argument("--editors-closed", action="store_true", required=True)
    complete = subparsers.add_parser(
        "complete-migration",
        help="durably acknowledge post-update client repin/restart before server startup",
    )
    for name in ("project", "install", "recovery-root"):
        complete.add_argument(f"--{name}", type=Path, required=True)
    complete.add_argument("--transaction", required=True)
    complete.add_argument("--editor-pid", type=int, required=True)
    complete.add_argument("--editor-nonce", required=True)
    complete_manual = subparsers.add_parser(
        "complete-manual-migration",
        help="atomically consume the clean-major marker held by the elected editor",
    )
    for name in ("project", "install"):
        complete_manual.add_argument(f"--{name}", type=Path, required=True)
    complete_manual.add_argument("--editor-pid", type=int, required=True)
    complete_manual.add_argument("--editor-nonce", required=True)
    abort = subparsers.add_parser(
        "abort-prepared",
        help="discard an authenticated stage only if activation never began",
    )
    for name in ("project", "install"):
        abort.add_argument(f"--{name}", type=Path, required=True)
    abort.add_argument("--recovery-root", type=Path, required=True)
    abort.add_argument("--transaction", required=True)
    abort.add_argument("--editor-pid", type=int)
    abort.add_argument("--editor-nonce")
    takeover = abort.add_mutually_exclusive_group()
    takeover.add_argument(
        "--intent-only-owners-dead",
        action="store_true",
        help="clean an intent-only crash after proving its actor and editor identities dead",
    )
    takeover.add_argument(
        "--dead-owner-takeover",
        action="store_true",
        help="clean prepared/abort state after proving its prior owner identities dead",
    )
    return parser


def _write_actor_response(value: Mapping[str, Any]) -> None:
    sys.stdout.buffer.write(canonical_json(actor_response(value)))


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        if args.command == "identity":
            _write_actor_response({"status": "identity"})
            return 0
        if args.command == "lease":
            editor = editor_identity(args.editor_pid, args.editor_nonce)
            if args.download_id is not None and args.action != "preflight":
                _fail("--download-id is valid only for lease preflight")
            if args.action == "preflight":
                root = preflight_update(
                    args.project,
                    args.install,
                    editor,
                    override=args.recovery_base,
                )
            else:
                root = recovery_root(
                    args.project,
                    args.install,
                    override=args.recovery_base,
                    create=args.action == "acquire",
                )
                if args.action == "acquire":
                    if _lexists(ActivationLock(root).path):
                        raise LockBusy("activation is already in progress")
                    EditorLeases(root, args.project, args.install).acquire(editor)
                elif _lexists(root):
                    EditorLeases(root, args.project, args.install).release(editor)
            response = {
                "recovery_root": str(root),
                "status": f"lease_{args.action}",
            }
            if args.download_id is not None:
                clean_stale_downloads(root)
                response["download_root"] = str(allocate_download_root(root, args.download_id))
            _write_actor_response(response)
            return 0
        if args.command == "prepare":
            result = prepare_release(
                archive=args.archive,
                manifest=args.manifest,
                signature=args.signature,
                project=args.project,
                install=args.install,
                transaction=args.transaction,
                channel=args.channel,
                tag=args.tag,
                version=args.version,
                source=args.source,
                editor=editor_identity(args.editor_pid, args.editor_nonce),
                override=args.recovery_base,
            )
            _write_actor_response(result)
            return 0
        if args.command == "activate":
            failpoints: Failpoints | None = None
            try:
                fingerprint = process_start_fingerprint(args.editor_pid)
                if fingerprint is None:
                    _fail("cannot prove initiating editor process identity")
                intent = Intent.create(
                    transaction=args.transaction,
                    project_root=args.project,
                    install_root=args.install,
                    recovery=args.recovery_root,
                    stage_root=args.stage,
                    from_version=args.from_version,
                    to_version=args.to_version,
                    manifest_sha256=args.manifest_sha256,
                    editor=ProcessIdentity(args.editor_pid, fingerprint, args.editor_nonce),
                    runner=ProcessIdentity.current(),
                )
                failpoints = activate_failpoints_from_environment(intent)
                result = run_activation(
                    intent,
                    readiness_timeout=args.readiness_timeout,
                    claim_timeout=args.claim_timeout,
                    failpoints=failpoints,
                )
            finally:
                for name in QUALIFICATION_FAILPOINT_ENV:
                    os.environ.pop(name, None)
                if failpoints is not None:
                    failpoints.close()
            _write_actor_response(result)
            return 0
        if args.command == "archive-backup":
            result = archive_retained_backup(
                args.project,
                args.install,
                editors_closed=args.editors_closed,
                recovery=args.recovery_root,
            )
            _write_actor_response(result)
            return 0
        if args.command == "complete-migration":
            result = complete_migration(
                args.project,
                args.install,
                args.recovery_root,
                args.transaction,
                editor_identity(args.editor_pid, args.editor_nonce),
            )
            _write_actor_response(result)
            return 0
        if args.command == "complete-manual-migration":
            result = complete_manual_migration(
                args.project,
                args.install,
                editor_identity(args.editor_pid, args.editor_nonce),
            )
            _write_actor_response(result)
            return 0
        if args.command == "abort-prepared":
            if args.intent_only_owners_dead or args.dead_owner_takeover:
                requester = ProcessIdentity.current()
            else:
                if args.editor_pid is None or args.editor_nonce is None:
                    _fail("prepared abort requires --editor-pid and --editor-nonce")
                requester = editor_identity(args.editor_pid, args.editor_nonce)
            result = abort_prepared(
                args.project,
                args.install,
                args.recovery_root,
                args.transaction,
                requester,
                intent_only=args.intent_only_owners_dead,
                dead_owner_takeover=args.dead_owner_takeover,
            )
            _write_actor_response(result)
            return 0
        root = (
            _bound_recovery_root(
                args.project,
                args.install,
                args.recovery_root,
                allow_missing_install=True,
            )
            if args.command == "repair"
            else recovery_root(
                args.project,
                args.install,
                override=args.recovery_base,
                create=args.command == "root" and args.create,
            )
        )
        if args.command == "root":
            _write_actor_response({"recovery_root": str(root), "status": "root"})
        elif args.command == "startup":
            result = startup_barrier(
                args.project,
                args.install,
                editor_pid=args.editor_pid,
                editor_nonce=args.editor_nonce,
                transaction=args.transaction,
                override=args.recovery_base,
                timeout=args.timeout,
            )
            _write_actor_response(result)
        else:
            result = repair_transaction(root, args.transaction)
            _write_actor_response(result)
        return 0
    except (OSError, ReleaseError, TransactionError) as exc:
        print(f"update transaction refused: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
