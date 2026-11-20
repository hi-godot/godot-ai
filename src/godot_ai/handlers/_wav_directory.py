"""Directory anchors for WAV staging across native platforms."""

from __future__ import annotations

import errno
import os
import stat
from contextlib import ExitStack
from dataclasses import dataclass
from pathlib import Path

_FILE_LIST_DIRECTORY = 0x00000001
_FILE_READ_ATTRIBUTES = 0x00000080
_FILE_SHARE_READ = 0x00000001
_FILE_SHARE_WRITE = 0x00000002
_FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
_FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000


def is_link(info: os.stat_result) -> bool:
    return stat.S_ISLNK(info.st_mode) or bool(
        getattr(info, "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT
    )


def _real_directory(info: os.stat_result) -> os.stat_result:
    if is_link(info):
        raise OSError(errno.ELOOP, "Linked directory")
    if not stat.S_ISDIR(info.st_mode):
        raise NotADirectoryError(errno.ENOTDIR, "Not a directory")
    return info


def _check_opened_directory(expected: os.stat_result, fd: int) -> os.stat_result:
    opened = _real_directory(os.fstat(fd))
    if not os.path.samestat(expected, opened):
        raise OSError(errno.ESTALE, "The directory changed while opening it")
    return opened


def _open_windows_directory(path: Path) -> int:
    import _winapi
    import msvcrt

    # Listing rights participate in sharing checks. Attribute-only access
    # would still allow a rename despite omitting FILE_SHARE_DELETE.
    handle = _winapi.CreateFile(
        str(path),
        _FILE_LIST_DIRECTORY | _FILE_READ_ATTRIBUTES,
        _FILE_SHARE_READ | _FILE_SHARE_WRITE,
        0,
        _winapi.OPEN_EXISTING,
        _FILE_FLAG_BACKUP_SEMANTICS | _FILE_FLAG_OPEN_REPARSE_POINT,
        0,
    )
    try:
        return msvcrt.open_osfhandle(handle, os.O_RDONLY | os.O_NOINHERIT)
    except BaseException:
        _winapi.CloseHandle(handle)
        raise


def _pin_windows_path(path: Path, handles: ExitStack) -> os.stat_result:
    # A path-based operation stays anchored while every ancestor is pinned.
    current = Path(path.anchor)
    for component in ("", *path.parts[1:]):
        current /= component
        expected = _real_directory(current.lstat())
        fd = _open_windows_directory(current)
        handles.callback(os.close, fd)
        info = _check_opened_directory(expected, fd)
    return info


def _walk_posix_path(path: Path) -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    fd = os.open(path.anchor, flags)
    try:
        for component in path.parts[1:]:
            expected = _real_directory(os.stat(component, dir_fd=fd, follow_symlinks=False))
            child = os.open(component, flags, dir_fd=fd)
            previous, fd = fd, child
            os.close(previous)
            _check_opened_directory(expected, fd)
        return fd
    except BaseException:
        os.close(fd)
        raise


@dataclass(frozen=True)
class DirectoryAnchor:
    path: Path
    fd: int | None
    info: os.stat_result
    _handles: ExitStack

    @classmethod
    def open(cls, path: Path) -> DirectoryAnchor:
        with ExitStack() as handles:
            if os.name == "nt":
                fd = None
                info = _pin_windows_path(path, handles)
            else:
                fd = _walk_posix_path(path)
                handles.callback(os.close, fd)
                info = os.fstat(fd)
            return cls(path, fd, info, handles.pop_all())

    def close(self) -> None:
        self._handles.close()

    def _entry(self, name: str) -> str | Path:
        return name if self.fd is not None else self.path / name

    def stat(self, name: str) -> os.stat_result:
        return os.stat(self._entry(name), dir_fd=self.fd, follow_symlinks=False)

    def open_file(self, name: str, flags: int, mode: int = 0o600) -> int:
        return os.open(self._entry(name), flags, mode, dir_fd=self.fd)

    def unlink(self, name: str) -> None:
        os.unlink(self._entry(name), dir_fd=self.fd)

    def publish(self, stage: str, destination: str) -> None:
        if self.fd is None:
            # Windows rename refuses an occupied destination.
            os.rename(self.path / stage, self.path / destination)
        else:
            os.link(
                stage, destination, src_dir_fd=self.fd, dst_dir_fd=self.fd, follow_symlinks=False
            )
