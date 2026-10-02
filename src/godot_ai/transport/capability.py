"""Private bootstrap record for one backend's HTTP and editor capabilities."""

from __future__ import annotations

import errno
import hmac
import json
import os
import re
import secrets
import stat
import sys
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HTTP_CAPABILITY_ENV = "GODOT_AI_HTTP_CAPABILITY"
# Keep the shipped environment name while replacing its optional-token semantics.
WS_CAPABILITY_ENV = "GODOT_AI_WS_TOKEN"
CAPABILITY_DIR_ENV = "GODOT_AI_CAPABILITY_DIR"

RECORD_VERSION = 1
MAX_RECORD_BYTES = 1024
_TOKEN = re.compile(r"[A-Za-z0-9._~+/=-]{32,128}\Z")
_WS_TOKEN = re.compile(r"[0-9a-f]{64}\Z")
_NONCE = re.compile(r"[A-Fa-f0-9]{32}\Z")
_KEYS = frozenset({"version", "http", "websocket", "instance_nonce"})
_REPARSE_POINT = 0x400
# Bound on link components followed while resolving one capability path.
_MAX_LINK_HOPS = 8
_FLATPAK_INFO = Path("/.flatpak-info")
# Every read-write spelling of the two grants that expose the home directory.
# Flatpak 1.16 writes plain read-write as the bare name; ``:create`` is
# read-write too. ``:ro`` is absent on purpose.
_FLATPAK_HOME_GRANTS = frozenset(
    {"host", "host:rw", "host:create", "home", "home:rw", "home:create"}
)
# Every read-write spelling of the grant that exposes the host's whole config
# directory without the home around it.
_FLATPAK_CONFIG_GRANTS = frozenset({"xdg-config", "xdg-config:rw", "xdg-config:create"})
_USER_NAMESPACE_MAP = Path("/proc/self/uid_map")
_OVERFLOW_UID = Path("/proc/sys/kernel/overflowuid")


@dataclass(frozen=True)
class LaunchCapabilities:
    http: str
    websocket: str


@dataclass(frozen=True)
class CapabilityRecord:
    http: str
    websocket: str
    instance_nonce: str


class PortClaimUnavailable(OSError):
    """Another godot-ai process owns this HTTP port's launch claim."""


class PortClaim:
    """Process-lifetime advisory lock for one HTTP port."""

    def __init__(self, handle: Any) -> None:
        self._handle = handle

    def release(self) -> None:
        if self._handle is None:
            return
        handle, self._handle = self._handle, None
        try:
            if os.name == "nt":
                import msvcrt

                handle.seek(0)
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
        finally:
            handle.close()

    def __del__(self) -> None:
        try:
            self.release()
        except OSError:
            pass


def generate_capabilities() -> LaunchCapabilities:
    return LaunchCapabilities(secrets.token_urlsafe(32), secrets.token_hex(32))


def validate_capability(value: str) -> str:
    if not isinstance(value, str) or _TOKEN.fullmatch(value) is None:
        raise ValueError("transport capability must be 32-128 ASCII bearer-token characters")
    return value


def validate_ws_capability(value: str) -> str:
    if not isinstance(value, str) or _WS_TOKEN.fullmatch(value) is None:
        raise ValueError("WebSocket capability must be 64 lowercase hexadecimal digits")
    return value


def validate_launch_capabilities(http: str, websocket: str) -> LaunchCapabilities:
    result = LaunchCapabilities(validate_capability(http), validate_ws_capability(websocket))
    if hmac.compare_digest(result.http, result.websocket):
        raise ValueError("HTTP and WebSocket capabilities must be independent")
    return result


def validate_record(http: str, websocket: str, instance_nonce: str) -> CapabilityRecord:
    launch = validate_launch_capabilities(http, websocket)
    return CapabilityRecord(launch.http, launch.websocket, validate_instance_nonce(instance_nonce))


def validate_instance_nonce(value: str) -> str:
    if not isinstance(value, str) or _NONCE.fullmatch(value) is None:
        raise ValueError("instance nonce must be 32 hexadecimal digits")
    return value.lower()


def launch_capabilities_from_env(*, generate_if_missing: bool = True) -> LaunchCapabilities:
    """Resolve one complete launch pair; partial environment state is invalid."""
    http = os.environ.get(HTTP_CAPABILITY_ENV) or None
    websocket = os.environ.get(WS_CAPABILITY_ENV) or None
    if (http is None) != (websocket is None):
        raise ValueError("HTTP and WebSocket capabilities must be supplied together")
    if http is None:
        if not generate_if_missing:
            raise ValueError("HTTP and WebSocket capabilities are required")
        generated = generate_capabilities()
        http, websocket = generated.http, generated.websocket
    return validate_launch_capabilities(http, websocket)


def capability_directory() -> Path:
    override = os.environ.get(CAPABILITY_DIR_ENV, "").strip()
    if os.name == "nt":
        if override:
            raise ValueError(f"{CAPABILITY_DIR_ENV} is not supported on Windows")
        local = os.environ.get("LOCALAPPDATA", "").strip()
        base = Path(local) if local else Path.home() / "AppData" / "Local"
        directory = base / "godot-ai" / "capabilities"
    elif override:
        base = Path(override).expanduser()
        if not base.is_absolute():
            raise ValueError(f"{CAPABILITY_DIR_ENV} must be an absolute path")
        directory = base
    elif sys.platform == "darwin":
        directory = Path.home() / "Library" / "Application Support" / "godot-ai" / "capabilities"
    else:
        # Flatpak points XDG_CONFIG_HOME at the app's own ~/.var/app/<id>/config,
        # which a client outside that sandbox never reads. When the sandbox
        # shares the host's config directory, use the one the host itself names.
        name = "HOST_XDG_CONFIG_HOME" if _flatpak_shares_config_home() else "XDG_CONFIG_HOME"
        config = os.environ.get(name, "").strip()
        if config:
            base = Path(config).expanduser()
            if not base.is_absolute():
                raise ValueError(f"{name} must be an absolute path")
        else:
            base = Path.home() / ".config"
        directory = base / "godot-ai" / "capabilities"
    if os.name != "nt":
        if not directory.is_absolute():
            raise ValueError("capability directory must be an absolute path")
        directory = _reject_unsafe_posix_ancestors(directory)
    return directory


def _flatpak_shares_home() -> bool:
    """Whether this is a Flatpak sandbox that can write the host's home directory.

    Flatpak lists the sandbox's filesystem grants in ``/.flatpak-info``. A
    read-write ``host`` or ``home`` grant exposes the real home at its own
    path; a ``:ro`` grant, a narrower one, or none leaves the app's private
    directories as the only ones a process outside the sandbox can also see.
    """

    return not _FLATPAK_HOME_GRANTS.isdisjoint(_flatpak_filesystem_grants())


def _flatpak_shares_config_home() -> bool:
    """Whether this is a Flatpak sandbox that can write the host's config directory.

    True when it shares the home, and for a read-write grant of the whole of
    ``xdg-config``: Flatpak mounts that one at the host's path only and leaves
    ``XDG_CONFIG_HOME`` on the per-app directory. An ``xdg-config/<dir>`` grant
    does not count, because Flatpak mounts it inside the per-app directory as
    well, so ``XDG_CONFIG_HOME`` already reaches it.
    """

    return _flatpak_shares_home() or not _FLATPAK_CONFIG_GRANTS.isdisjoint(
        _flatpak_filesystem_grants()
    )


def _flatpak_filesystem_grants() -> list[str]:
    """The ``[Context] filesystems=`` entries of ``/.flatpak-info``; empty outside Flatpak."""

    try:
        lines = _FLATPAK_INFO.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    group = ""
    for line in lines:
        if line.startswith("["):
            group = line.strip()
        elif group == "[Context]" and line.startswith("filesystems="):
            return line.partition("=")[2].split(";")
    return []


def record_path(http_port: int, directory: Path | None = None) -> Path:
    port = int(http_port)
    if not 1 <= port <= 65535:
        raise ValueError("HTTP port must be between 1 and 65535")
    selected = Path(directory).expanduser() if directory is not None else capability_directory()
    if os.name != "nt":
        if not selected.is_absolute():
            raise ValueError("capability directory must be an absolute path")
        selected = _reject_unsafe_posix_ancestors(selected)
    return selected / f"http-{port}.json"


def _is_link_or_reparse(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & _REPARSE_POINT
    )


def _reject_link_components(path: Path) -> None:
    current = Path(path.anchor) if path.is_absolute() else Path()
    for part in path.parts[1:] if path.is_absolute() else path.parts:
        current /= part
        try:
            info = current.lstat()
        except FileNotFoundError:
            continue
        if _is_link_or_reparse(info):
            raise OSError(errno.ELOOP, "capability path traverses a link or reparse point", current)


def _is_root_or_self(_path: Path, uid: int) -> bool:
    return uid in {0, os.getuid()}


def _is_safe_posix_ancestor(
    path: Path,
    info: os.stat_result,
    owner_trusted: Callable[[Path, int], bool] = _is_root_or_self,
) -> bool:
    """Accept private ancestors and only canonical root-owned sticky temp roots."""

    mode = stat.S_IMODE(info.st_mode)
    root_sticky_directory = (
        path in {Path("/tmp"), Path("/private/tmp"), Path("/var/tmp")}
        and info.st_uid == 0
        and stat.S_ISDIR(info.st_mode)
        and bool(mode & stat.S_ISVTX)
    )
    return root_sticky_directory or (owner_trusted(path, info.st_uid) and mode & 0o022 == 0)


def _is_trusted_private_directory(
    path: Path, owner_trusted: Callable[[Path, int], bool] = _is_root_or_self
) -> bool:
    """Trusted ownership, no group/other writes or sticky exception."""

    try:
        info = path.lstat()
    except OSError:
        return False
    return (
        stat.S_ISDIR(info.st_mode)
        and owner_trusted(path, info.st_uid)
        and stat.S_IMODE(info.st_mode) & 0o022 == 0
    )


def _unnameable_owner_uid() -> int | None:
    """The UID this user namespace reports for an owner it cannot name.

    Flatpak and Steam's pressure-vessel run in a user namespace that maps only
    the invoking user, so a directory owned by the host's root reads back as
    the kernel's overflow UID (65534). ``None`` whenever a mapped range contains
    that UID, because it is then a real account here: every owner in the
    initial namespace, and ``nobody`` in a rootless container that maps a
    subordinate ID range. A map that cannot be read or parsed is ``None`` too.
    """

    try:
        fields = [int(field) for field in _USER_NAMESPACE_MAP.read_text(encoding="ascii").split()]
        overflow_uid = int(_OVERFLOW_UID.read_text(encoding="ascii"))
    except (OSError, ValueError):
        return None
    if not fields or len(fields) % 3:
        return None
    for start, length in zip(fields[0::3], fields[2::3], strict=True):
        if start <= overflow_uid < start + length:
            return None
    return overflow_uid


def _ancestors_of_home(unnameable_uid: int) -> frozenset[Path]:
    """Every component walked to reach the home directory, excluding it."""

    try:
        home = Path.home()
    except RuntimeError:
        return frozenset()
    if not home.is_absolute():
        return frozenset()
    visited: list[Path] = []
    try:
        resolved = _walk_ancestors(
            home, lambda _path, uid: uid in {0, os.getuid(), unnameable_uid}, visited
        )
    except OSError:
        return frozenset()
    return frozenset(visited) - {resolved}


def _reject_unsafe_posix_ancestors(path: Path) -> Path:
    """Reject any POSIX capability namespace mutable by another account.

    Returns ``path`` with every accepted link component replaced by its
    target, so callers operate on a link-free path. A link is followed only
    when it and its parent have a trusted owner, the parent is closed to
    group/other writes, and every ancestor before it already passed.
    Another account cannot place such a link. Steam's pressure-vessel owns
    its ``/home -> /var/home`` link and namespace root as the invoking user.
    This applies the same account boundary as ordinary directory ancestors.
    Every other link fails closed, as does a chain longer than ``_MAX_LINK_HOPS``.
    The target's own components are walked under the same rules, so lexical
    ``..`` resolution against the already-resolved parent matches the kernel.

    A trusted owner is root or this user. Inside a user namespace that maps
    neither the host's root nor the overflow UID (Flatpak, pressure-vessel), the
    host's ``/home`` reads back as the overflow UID, so there the owner of
    a directory above the home directory is not tested: that is where sshd's
    StrictModes stops too, because the administrator chose where homes live.
    Such a directory must still be closed to group/other writes, and the home
    directory and everything below it must still be root's or this user's.
    Outside a user namespace nothing is relaxed.
    """

    if os.name == "nt":  # pragma: no cover - overrides are already disabled
        return path
    unnameable_uid = _unnameable_owner_uid()
    above_home = _ancestors_of_home(unnameable_uid) if unnameable_uid is not None else frozenset()

    def owner_trusted(component: Path, uid: int) -> bool:
        return uid in {0, os.getuid()} or (uid == unnameable_uid and component in above_home)

    return _walk_ancestors(path, owner_trusted)


def _walk_ancestors(
    path: Path,
    owner_trusted: Callable[[Path, int], bool],
    visited: list[Path] | None = None,
) -> Path:
    remaining = list(path.parts[1:])
    current = Path(path.anchor)
    if visited is not None:
        visited.append(current)
    if not _is_trusted_private_directory(current, owner_trusted):
        raise OSError(errno.EACCES, "capability path has an unsafe ancestor", current)
    hops = 0
    while remaining:
        current = current / remaining.pop(0)
        try:
            info = current.lstat()
        except FileNotFoundError:
            # Nothing below a missing component exists yet; it is created 0700.
            return current.joinpath(*remaining)
        if visited is not None:
            visited.append(current)
        if _is_link_or_reparse(info):
            if (
                not owner_trusted(current, info.st_uid)
                or hops >= _MAX_LINK_HOPS
                or not _is_trusted_private_directory(current.parent, owner_trusted)
            ):
                raise OSError(
                    errno.ELOOP,
                    "capability path traverses a link or reparse point",
                    current,
                )
            hops += 1
            target = Path(os.readlink(current))
            if not target.is_absolute():
                target = current.parent / target
            target = Path(os.path.normpath(target))
            remaining = list(target.parts[1:]) + remaining
            current = Path(target.anchor)
            continue
        if not _is_safe_posix_ancestor(current, info, owner_trusted):
            if not owner_trusted(current, info.st_uid):
                raise PermissionError(
                    errno.EACCES,
                    f"capability path has an unsafe ancestor: owner UID {info.st_uid} "
                    f"is neither root nor current UID {os.getuid()}. "
                    "A sandbox may hide ownership. Set GODOT_AI_CAPABILITY_DIR to a "
                    "verified private shared directory in both Godot's launch environment "
                    "and the outside AI client's environment. Do not change system-directory "
                    "ownership or permissions.",
                    current,
                )
            raise OSError(errno.EACCES, "capability path has an unsafe ancestor", current)
    return current


def private_mkdir(path: Path, *, windows: bool | None = None) -> None:
    """Create one directory that only this user can read.

    POSIX gets mode ``0o700``. Windows deliberately gets no mode: CPython
    (3.12.4+, 3.13) turns ``mode=0o700`` into a non-inherited DACL holding
    only SYSTEM, Administrators and OWNER RIGHTS. When the creating process
    was elevated the owner is the Administrators group, so the user's own
    unelevated editor, server and bridge can no longer read or write the
    directory (#988). Inheriting ``%LOCALAPPDATA%``'s per-user DACL is what
    makes the directory private on Windows.
    """
    on_windows = os.name == "nt" if windows is None else windows
    if on_windows:
        path.mkdir(exist_ok=True)
    else:
        path.mkdir(mode=0o700, exist_ok=True)


def windows_repair_hint(directory: Path) -> str:
    """Directory-specific permission guidance without destructive repair commands."""
    return (
        f"Godot AI cannot use the directory {directory}: this Windows account "
        "cannot access it. This can happen when an elevated (Run as administrator) "
        "process created it. Check this directory's permissions and grant your "
        "Windows account access, then reopen Godot and your AI clients without "
        "Run as administrator."
    )


def _windows_access_probe(directory: Path) -> OSError | None:
    """Return the error a write into ``directory`` raises for this account."""

    probe = directory / f".access-probe.{os.getpid()}.{secrets.token_hex(4)}"
    try:
        fd = os.open(probe, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except OSError as exc:
        return exc
    os.close(fd)
    try:
        probe.unlink()
    except OSError:
        pass
    return None


def directory_access_error(directory: Path | None = None) -> str | None:
    """A repair message when this account cannot use the capability directory.

    Windows only; ``None`` on POSIX, when the directory does not exist yet,
    or when a write probe succeeds. Used by the bridge to explain an
    unanswered status probe and by the server before it publishes.
    """
    if os.name != "nt":
        return None
    selected = Path(directory).expanduser() if directory is not None else capability_directory()
    try:
        if not selected.exists():
            return None
    except OSError:
        return windows_repair_hint(selected)
    if _windows_access_probe(selected) is None:
        return None
    return windows_repair_hint(selected)


def _prepare_directory(directory: Path) -> None:
    if os.name != "nt":
        if not directory.is_absolute():
            raise ValueError("capability directory must be an absolute path")
        _reject_unsafe_posix_ancestors(directory)
    _reject_link_components(directory)
    missing: list[Path] = []
    current = directory
    try:
        while not current.exists():
            missing.append(current)
            current = current.parent
        for path in reversed(missing):
            private_mkdir(path)
    except PermissionError as exc:
        if os.name == "nt":
            raise OSError(errno.EACCES, windows_repair_hint(directory), directory) from exc
        raise
    if os.name != "nt":
        _reject_unsafe_posix_ancestors(directory)
    _reject_link_components(directory)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode):
        raise OSError(errno.ENOTDIR, "capability path is not a directory", directory)
    if os.name != "nt":
        if info.st_uid != os.getuid():
            raise OSError(errno.EACCES, "capability directory has another owner", directory)
        directory.chmod(0o700)
        if stat.S_IMODE(directory.lstat().st_mode) != 0o700:
            raise OSError(errno.EACCES, "capability directory mode is not 0700", directory)
    elif _windows_access_probe(directory) is not None:
        raise OSError(errno.EACCES, windows_repair_hint(directory), directory)


def acquire_port_claim(http_port: int, directory: Path | None = None) -> PortClaim:
    path = record_path(http_port, directory).with_suffix(".lock")
    _prepare_directory(path.parent)
    _reject_link_components(path)
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    handle = os.fdopen(os.open(path, flags, 0o600), "r+b", buffering=0)
    try:
        info = os.fstat(handle.fileno())
        if not stat.S_ISREG(info.st_mode) or _is_link_or_reparse(info):
            raise OSError(errno.EINVAL, "capability claim is not a regular file", path)
        if os.name != "nt" and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077):
            raise OSError(errno.EACCES, "capability claim is not private", path)
        if handle.seek(0, os.SEEK_END) == 0:
            handle.write(b"\0")
        handle.seek(0)
        try:
            if os.name == "nt":
                import msvcrt

                msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl

                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            if exc.errno in {errno.EACCES, errno.EAGAIN, getattr(errno, "EDEADLK", -1)}:
                raise PortClaimUnavailable(
                    errno.EADDRINUSE,
                    f"another godot-ai server claims HTTP port {int(http_port)}",
                    str(path),
                ) from exc
            raise
        return PortClaim(handle)
    except BaseException:
        handle.close()
        raise


def write_capabilities(
    http_port: int,
    http: str,
    websocket: str,
    *,
    instance_nonce: str,
    directory: Path | None = None,
) -> Path:
    record = validate_record(http, websocket, instance_nonce)
    path = record_path(http_port, directory)
    _prepare_directory(path.parent)
    _reject_link_components(path)
    payload = (
        json.dumps(
            {
                "version": RECORD_VERSION,
                "http": record.http,
                "websocket": record.websocket,
                "instance_nonce": record.instance_nonce,
            },
            ensure_ascii=True,
            separators=(",", ":"),
        ).encode("ascii")
        + b"\n"
    )
    temporary = path.with_name(f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(temporary, flags, 0o600)
    published = False
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        published = True
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or _is_link_or_reparse(info):
            raise OSError(errno.EINVAL, "capability record is not a regular file", path)
        if os.name != "nt" and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600):
            raise OSError(errno.EACCES, "capability record mode is not 0600", path)
    except BaseException:
        if published:
            path.unlink(missing_ok=True)
        raise
    finally:
        temporary.unlink(missing_ok=True)
    return path


def read_capabilities(http_port: int, directory: Path | None = None) -> CapabilityRecord | None:
    path = record_path(http_port, directory)
    try:
        _reject_link_components(path)
        directory_info = path.parent.lstat()
        if not stat.S_ISDIR(directory_info.st_mode):
            return None
        if os.name != "nt" and (
            directory_info.st_uid != os.getuid() or stat.S_IMODE(directory_info.st_mode) & 0o077
        ):
            return None
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        with os.fdopen(os.open(path, flags), "rb") as handle:
            info = os.fstat(handle.fileno())
            if not stat.S_ISREG(info.st_mode) or _is_link_or_reparse(info):
                return None
            if os.name != "nt" and (
                info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) & 0o077
            ):
                return None
            if info.st_size > MAX_RECORD_BYTES + 1:
                return None
            raw = handle.read(MAX_RECORD_BYTES + 2)
    except (OSError, ValueError):
        return None
    if len(raw) > MAX_RECORD_BYTES + 1:
        return None
    if raw.endswith(b"\n"):
        raw = raw[:-1]
    try:
        pairs = json.loads(raw.decode("ascii"), object_pairs_hook=list)
        if not isinstance(pairs, list) or any(not isinstance(item, tuple) for item in pairs):
            return None
        keys = [item[0] for item in pairs]
        if len(keys) != len(set(keys)) or frozenset(keys) != _KEYS:
            return None
        payload = dict(pairs)
        if type(payload["version"]) is not int or payload["version"] != RECORD_VERSION:
            return None
        return validate_record(payload["http"], payload["websocket"], payload["instance_nonce"])
    except (UnicodeDecodeError, json.JSONDecodeError, KeyError, TypeError, ValueError):
        return None


def remove_capabilities(
    http_port: int,
    instance_nonce: str,
    directory: Path | None = None,
) -> bool:
    """Remove the record only while it still names this process instance.

    The caller must retain the matching :class:`PortClaim` through this check
    and unlink, which excludes a legitimate successor publisher from racing
    the comparison.
    """

    expected = validate_instance_nonce(instance_nonce)
    current = read_capabilities(http_port, directory)
    if current is None or not hmac.compare_digest(current.instance_nonce, expected):
        return False
    try:
        record_path(http_port, directory).unlink()
    except FileNotFoundError:
        return False
    return True
