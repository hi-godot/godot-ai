"""CLI dispatch and stdio startup-diagnostic contracts."""

from __future__ import annotations

import pytest

import godot_ai
from godot_ai.attach import main as attach_main_module
from godot_ai.attach.ensure import AttachStartupError


def test_root_main_dispatches_attach_before_legacy_parser(monkeypatch) -> None:
    received: list[list[str]] = []
    monkeypatch.setattr(attach_main_module, "main", lambda argv: received.append(list(argv)))

    godot_ai.main(["attach", "--port", "8123"])

    assert received == [["--port", "8123"]]


def test_preinitialize_failure_uses_stderr_only(monkeypatch, capsys) -> None:
    async def fail(*_args):
        raise AttachStartupError(
            "NEW_CLIENT_SESSION_REQUIRED",
            "version mismatch",
            hint="reconfigure and start a new session",
        )

    monkeypatch.setattr(attach_main_module, "run_attach", fail)

    with pytest.raises(SystemExit) as exc_info:
        attach_main_module.main([])

    captured = capsys.readouterr()
    assert exc_info.value.code == 1
    assert captured.out == ""
    assert "NEW_CLIENT_SESSION_REQUIRED" in captured.err
    assert "reconfigure and start a new session" in captured.err
