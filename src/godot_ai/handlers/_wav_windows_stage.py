"""Own an exclusive Windows staging file through publication or cleanup."""

from __future__ import annotations

import ctypes
import errno
import logging
import os
from ctypes import wintypes
from functools import cache
from pathlib import Path

logger = logging.getLogger(__name__)

_GENERIC_WRITE = 0x40000000
_DELETE_ACCESS = 0x00010000
_CREATE_NEW = 1
_FILE_ATTRIBUTE_NORMAL = 0x00000080
_FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
_FILE_RENAME_INFO = 3
_FILE_DISPOSITION_INFO = 4


class _RenameInfo(ctypes.Structure):
    _fields_ = [
        ("flags", wintypes.DWORD),
        ("root_directory", wintypes.HANDLE),
        ("filename_length", wintypes.DWORD),
        ("filename", wintypes.WCHAR * 1),
    ]


@cache
def _file_info_setter():
    setter = ctypes.WinDLL("kernel32", use_last_error=True).SetFileInformationByHandle
    setter.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD]
    setter.restype = wintypes.BOOL
    return setter


def _set_file_info(handle: int, kind: int, data: ctypes.Array | ctypes.c_ubyte) -> None:
    if not _file_info_setter()(handle, kind, ctypes.byref(data), ctypes.sizeof(data)):
        raise ctypes.WinError(ctypes.get_last_error())


def _rename_buffer(destination: Path) -> ctypes.Array:
    filename = str(destination).encode("utf-16-le")
    offset = _RenameInfo.filename.offset
    size = offset + len(filename) + ctypes.sizeof(wintypes.WCHAR)
    buffer = ctypes.create_string_buffer(max(size, ctypes.sizeof(_RenameInfo)))
    # Zero initialization leaves ReplaceIfExists false and RootDirectory NULL.
    info = _RenameInfo.from_buffer(buffer)
    info.filename_length = len(filename)
    ctypes.memmove(ctypes.addressof(buffer) + offset, filename, len(filename))
    return buffer


class WindowsStage:
    """Keep the original file handle open so publication never reopens its name."""

    def __init__(self, fd: int) -> None:
        self.fd = fd
        self._published = False

    @classmethod
    def open(cls, directory_path: Path, name: str) -> WindowsStage:
        import _winapi
        import msvcrt

        path = directory_path / name
        handle = _winapi.CreateFile(
            str(path),
            _GENERIC_WRITE | _DELETE_ACCESS,
            0,  # Deny other handles read, write and delete access while staged.
            0,
            _CREATE_NEW,
            _FILE_ATTRIBUTE_NORMAL | _FILE_FLAG_OPEN_REPARSE_POINT,
            0,
        )
        try:
            fd = msvcrt.open_osfhandle(handle, os.O_WRONLY | os.O_BINARY | os.O_NOINHERIT)
        except BaseException:
            try:
                _set_file_info(handle, _FILE_DISPOSITION_INFO, ctypes.c_ubyte(1))
            except OSError:
                logger.warning("Could not delete owned WAV staging file %s", path)
            finally:
                _winapi.CloseHandle(handle)
            raise
        return cls(fd)

    def publish(self, destination_path: Path) -> None:
        import msvcrt

        if self._published or not destination_path.is_absolute():
            raise OSError(errno.EINVAL, "Expected an unpublished WAV and an absolute destination")
        _set_file_info(
            msvcrt.get_osfhandle(self.fd), _FILE_RENAME_INFO, _rename_buffer(destination_path)
        )
        self._published = True

    def close(self) -> None:
        import msvcrt

        if self.fd < 0:
            return
        fd, self.fd = self.fd, -1
        try:
            if not self._published:
                _set_file_info(msvcrt.get_osfhandle(fd), _FILE_DISPOSITION_INFO, ctypes.c_ubyte(1))
        finally:
            os.close(fd)
