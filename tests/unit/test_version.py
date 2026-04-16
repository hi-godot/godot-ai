"""Tests for the `__version__` attribute's package-metadata fallback."""

from __future__ import annotations

import importlib
import importlib.metadata


def test_version_reads_from_package_metadata():
    """When installed, __version__ matches importlib.metadata's answer."""
    import godot_ai

    expected = importlib.metadata.version("godot-ai")
    assert godot_ai.__version__ == expected


def test_version_falls_back_when_package_not_installed(monkeypatch):
    """Bare source checkouts (no install) fall back to a PEP 440 local-version
    placeholder instead of raising at import time."""
    import godot_ai

    def raise_not_found(name: str) -> str:
        raise importlib.metadata.PackageNotFoundError(name)

    # Patch at the source so the reload re-binds to the faulty version.
    monkeypatch.setattr(importlib.metadata, "version", raise_not_found)
    reloaded = importlib.reload(godot_ai)
    try:
        assert reloaded.__version__ == "0+unknown"
    finally:
        # Restore real version for subsequent tests that might read it.
        monkeypatch.undo()
        importlib.reload(godot_ai)
