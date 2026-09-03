"""Reviewed executable identities for the release-qualification engine matrix.

Pins are derived from official archives after checking their published SHA-256.
The setup action is a delivery mechanism, not the source of expected digests.
"""

from __future__ import annotations

import hashlib
import platform
import stat
from pathlib import Path
from typing import Any

from script import release_support as support

MANIFEST = support.ROOT / "docs/verification/godot-builds-v1.json"


def host_row() -> str:
    row = {"Linux": "ubuntu-latest", "Darwin": "macos-latest", "Windows": "windows-latest"}.get(
        platform.system()
    )
    support.require(row is not None, "unsupported qualification host")
    return row


def build_pin(version: str, os_label: str) -> dict[str, Any]:
    manifest = support.read_json(MANIFEST, canonical_required=False)
    support.require(manifest.get("schema") == 1, "unsupported Godot pin schema")
    pin = manifest.get("builds", {}).get(version, {}).get(os_label)
    support.require(isinstance(pin, dict), "Godot build has no reviewed executable pin")
    return pin


def verify_executable(executable: Path, version: str) -> dict[str, Any]:
    """Check bytes before executing even --version; aliases must resolve to real bytes."""
    pin = build_pin(version, host_row())
    executable = executable.resolve(strict=True)
    info = executable.stat()
    support.require(
        stat.S_ISREG(info.st_mode) and info.st_size == pin["size"],
        "Godot executable size/type differs from reviewed pin",
    )
    with executable.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    support.require(digest == pin["sha256"], "Godot executable SHA-256 differs from reviewed pin")
    return {
        "path": str(executable.resolve()),
        "sha256": digest,
        "size": info.st_size,
        "archive_sha256": pin["archive_sha256"],
    }


def validate_identity(identity: Any, version: str, os_label: str) -> None:
    """An evidence row cannot select its own expected executable digest."""
    pin = build_pin(version, os_label)
    support.require(isinstance(identity, dict), "missing pinned Godot identity")
    support.require(
        identity.get("sha256") == pin["sha256"]
        and type(identity.get("size")) is int
        and identity["size"] == pin["size"]
        and identity.get("archive_sha256") == pin["archive_sha256"],
        "Godot evidence differs from reviewed executable pin",
    )
    display = version.removesuffix(".0")
    actual = identity.get("version")
    support.require(
        isinstance(actual, str) and actual.startswith(f"{display}.stable.official."),
        "Godot evidence reports a different official build",
    )
