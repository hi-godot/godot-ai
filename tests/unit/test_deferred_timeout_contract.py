"""Source-level contracts for deferred-response timeout diagnostics."""

from __future__ import annotations

from pathlib import Path

from godot_ai.protocol.errors import ErrorCode

PLUGIN_ROOT = Path(__file__).resolve().parents[2] / "plugin" / "addons" / "godot_ai"


def test_deferred_timeout_error_code_registered_on_both_sides() -> None:
    assert ErrorCode.DEFERRED_TIMEOUT == "DEFERRED_TIMEOUT"
    gd_error_codes = (PLUGIN_ROOT / "utils" / "error_codes.gd").read_text(encoding="utf-8")
    assert 'const DEFERRED_TIMEOUT := "DEFERRED_TIMEOUT"' in gd_error_codes


def test_dispatcher_tracks_deferred_ids_and_emits_timeout_error() -> None:
    source = (PLUGIN_ROOT / "dispatcher.gd").read_text(encoding="utf-8")
    assert "_pending_deferred" in source
    assert 'const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")' in source
    assert "ErrorCodes.DEFERRED_TIMEOUT" in source
    assert "complete_deferred_response" in source
