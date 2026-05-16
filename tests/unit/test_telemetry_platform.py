"""Unit tests for platform-specific telemetry code paths.

These tests intentionally avoid the isolated_data_dir fixture so they
can exercise the real _resolve_data_directory and _cleanup_local_files
implementations without mocking.
"""

from __future__ import annotations

from pathlib import Path
from unittest.mock import patch

import pytest

from godot_ai import telemetry as tel


@pytest.fixture
def clean_env(monkeypatch) -> None:
    for name in (
        "GODOT_AI_DISABLE_TELEMETRY",
        "DISABLE_TELEMETRY",
        "GODOT_AI_TELEMETRY_ENDPOINT",
        "GODOT_AI_TELEMETRY_TIMEOUT",
        "GODOT_AI_TELEMETRY_ALLOW_LOOPBACK",
        "APPDATA",
        "XDG_DATA_HOME",
    ):
        monkeypatch.delenv(name, raising=False)


class TestResolveDataDirectory:
    """Tests for the platform-specific data directory resolution."""

    def test_windows_uses_appdata(self, monkeypatch, clean_env) -> None:
        """Windows uses APPDATA environment variable."""
        monkeypatch.setenv("APPDATA", "C:\\Users\\Test\\AppData\\Roaming")

        class MockPath:
            def __init__(self, path_str):
                self._path = path_str

            def __truediv__(self, other):
                return MockPath(f"{self._path}/{other}")

            def __str__(self):
                return self._path

            @property
            def name(self):
                return self._path.split("/")[-1]

            @staticmethod
            def home():
                return MockPath("/home/test")

        with patch("godot_ai.telemetry.os.name", "nt"):
            with patch("godot_ai.telemetry.Path", MockPath):
                result = tel.TelemetryConfig._resolve_data_directory()
        assert result.name == "godot-ai"
        assert "Roaming" in str(result)

    def test_windows_fallback_to_home(self, monkeypatch, clean_env) -> None:
        """Windows falls back to user's home if APPDATA is unset."""
        monkeypatch.setenv("APPDATA", "")
        with patch("godot_ai.telemetry.Path.home", return_value=Path("C:\\Users\\Test")):
            result = tel.TelemetryConfig._resolve_data_directory()
        assert "godot-ai" in str(result)
        assert "Test" in str(result)

    def test_macos_uses_library_application_support(self, monkeypatch, clean_env) -> None:
        """macOS uses ~/Library/Application Support."""
        with patch("godot_ai.telemetry.sys.platform", "darwin"):
            result = tel.TelemetryConfig._resolve_data_directory()
        assert "Library" in str(result)
        assert "Application Support" in str(result)
        assert result.name == "godot-ai"

    def test_linux_uses_xdg_data_home(self, monkeypatch, clean_env) -> None:
        """Linux uses XDG_DATA_HOME when set."""
        with patch("godot_ai.telemetry.sys.platform", "linux"):
            monkeypatch.setenv("XDG_DATA_HOME", "/custom/data")
            result = tel.TelemetryConfig._resolve_data_directory()
        assert str(result) == "/custom/data/godot-ai"

    def test_linux_fallback_to_home(self, monkeypatch, clean_env) -> None:
        """Linux falls back to ~/.local/share when XDG_DATA_HOME unset."""
        with patch("godot_ai.telemetry.sys.platform", "linux"):
            with patch("godot_ai.telemetry.Path.home", return_value=Path("/home/user")):
                result = tel.TelemetryConfig._resolve_data_directory()
        assert ".local" in str(result)
        assert "share" in str(result)
        assert "godot-ai" in str(result)


class TestCleanupLocalFilesEdgeCases:
    """Tests for _cleanup_local_files exception handling."""

    def test_returns_early_when_resolve_raises(self, monkeypatch, clean_env) -> None:
        """Returns early when _resolve_data_directory raises an exception."""
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")

        def _raise(*args):
            raise OSError("simulated failure")

        monkeypatch.setattr(tel.TelemetryConfig, "_resolve_data_directory", _raise)
        config = tel.TelemetryConfig()
        assert config.enabled is False

    def test_returns_early_when_data_dir_not_exists(self, monkeypatch, tmp_path: Path) -> None:
        """Returns early when resolved data directory does not exist on disk."""
        nonexistent = tmp_path / "nonexistent_telemetry_dir"

        def mock_resolve(self):
            return nonexistent

        class MockConfig(tel.TelemetryConfig):
            _resolve_data_directory = mock_resolve

        monkeypatch.setattr(tel, "TelemetryConfig", MockConfig)
        monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")
        monkeypatch.setenv("GODOT_AI_TELEMETRY_ENDPOINT", "ftp://test-leak-guard.invalid/")
        config = tel.TelemetryConfig()
        assert config.enabled is False
