"""Fail-closed contract for runtime packages that define v4 security behavior."""

from __future__ import annotations

from collections.abc import Callable
from importlib.metadata import PackageNotFoundError, version

RUNTIME_DEPENDENCIES = {
    "anyio": "4.15.1",
    "fastmcp": "4.0.5",
    "fastmcp-slim": "4.0.5",
    "h11": "0.16.0",
    "httpx": "0.28.1",
    "httpx2": "2.13.0",
    "httpcore2": "2.13.0",
    "mcp": "2.2.0",
    "mcp-types": "2.2.0",
    "pydantic": "2.13.5",
    "sniffio": "1.3.1",
    "starlette": "1.6.0",
    "uvicorn": "0.53.0",
    "websockets": "17.1",
}


def verify_runtime_dependencies(
    version_of: Callable[[str], str] = version,
) -> None:
    """Refuse a resolver result not reviewed with this exact server release."""

    mismatches: list[str] = []
    for distribution, expected in RUNTIME_DEPENDENCIES.items():
        try:
            actual = version_of(distribution)
        except PackageNotFoundError:
            actual = "missing"
        if actual != expected:
            mismatches.append(f"{distribution}=={actual} (expected {expected})")
    if mismatches:
        raise RuntimeError("unsupported godot-ai runtime dependency set: " + ", ".join(mismatches))
