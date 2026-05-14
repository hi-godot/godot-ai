"""Shared fixtures for unit tests.

The telemetry-touching tests in ``test_telemetry*.py`` historically
each defined their own ``isolated_data_dir`` fixture with identical
bodies (env clean + tmp data dir + collector reset). Consolidating
here removes 30+ lines of copy-paste and gives one place to update
the isolation contract if it ever evolves.

Tests that need a live collector + captured records (decorator
tests, integration tests) compose this fixture from their own files;
this conftest exposes the data-dir isolation building block.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from godot_ai import telemetry as tel


@pytest.fixture
def isolated_data_dir(monkeypatch, tmp_path: Path) -> Path:
    """Force ``TelemetryConfig._get_data_directory`` into a tmp_path,
    drop any inherited opt-out env vars (CI workflows / conftest.py
    set them globally), and reset the module-level collector
    singleton before and after the test."""
    monkeypatch.delenv("GODOT_AI_DISABLE_TELEMETRY", raising=False)
    monkeypatch.delenv("DISABLE_TELEMETRY", raising=False)
    monkeypatch.setattr(tel.TelemetryConfig, "_get_data_directory", lambda self: tmp_path)
    tel.reset_telemetry()
    yield tmp_path
    tel.reset_telemetry()
