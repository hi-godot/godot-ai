"""Contracts for scaffold-aware diagnostic hint policy."""

from __future__ import annotations

import pytest

from godot_ai.godot_client.client import GodotClient
from godot_ai.protocol.envelope import CommandResponse
from godot_ai.sessions.registry import Session, SessionRegistry


class _StaticWsServer:
    async def send_command(self, **_kwargs) -> CommandResponse:
        return CommandResponse(request_id="hint-contract", status="ok", data={"ok": True})


def _client_with_pending_diagnostics(*, errors: int = 0, warnings: int = 0) -> GodotClient:
    session = Session(
        session_id="hint-contract",
        godot_version="4.7",
        project_path="/tmp/hint-contract",
        plugin_version="test",
        pending_new_errors=errors,
        pending_new_warnings=warnings,
    )
    registry = SessionRegistry()
    registry.register(session)
    return GodotClient(_StaticWsServer(), registry)  # type: ignore[arg-type]


@pytest.mark.parametrize(
    ("errors", "warnings", "hint_key", "expected_lead"),
    [
        (2, 0, "new_errors_hint", "2 new GDScript errors since your last call."),
        (0, 1, "new_warnings_hint", "1 new GDScript warning since your last call."),
    ],
)
async def test_injected_diagnostic_hints_keep_scaffold_condition_and_logs_fallback(
    errors, warnings, hint_key, expected_lead
) -> None:
    client = _client_with_pending_diagnostics(errors=errors, warnings=warnings)

    result = await client.send("get_editor_state")
    hint = result[hint_key]

    assert hint.startswith(expected_lead)
    assert 'filesystem_manage(op="scan") before debugging' in hint
    assert "logs_read(source='editor'|'game', include_details=true)" in hint


@pytest.mark.parametrize(
    ("env_value", "expected_policy"),
    [
        (None, "surface"),
        ("true", "discard"),
        ("TRUE", "discard"),
        ("1", "discard"),
        ("garbage", "surface"),
    ],
)
def test_suppress_diagnostic_hints_env_sets_client_default(
    monkeypatch, env_value, expected_policy
) -> None:
    if env_value is None:
        monkeypatch.delenv("GODOT_AI_SUPPRESS_DIAGNOSTIC_HINTS", raising=False)
    else:
        monkeypatch.setenv("GODOT_AI_SUPPRESS_DIAGNOSTIC_HINTS", env_value)

    client = GodotClient(None, None)  # type: ignore[arg-type]

    assert client.default_hint_policy == expected_policy


def test_constructor_hint_policy_override_beats_environment(monkeypatch) -> None:
    monkeypatch.setenv("GODOT_AI_SUPPRESS_DIAGNOSTIC_HINTS", "true")

    client = GodotClient(  # type: ignore[arg-type]
        None,
        None,
        default_hint_policy="surface",
    )

    assert client.default_hint_policy == "surface"


def test_constructor_rejects_unknown_hint_policy() -> None:
    with pytest.raises(ValueError, match="Unknown diagnostic hint policy"):
        GodotClient(  # type: ignore[arg-type]
            None,
            None,
            default_hint_policy="banana",  # type: ignore[arg-type]
        )


async def test_send_rejects_unknown_hint_policy() -> None:
    client = GodotClient(None, None)  # type: ignore[arg-type]

    with pytest.raises(ValueError, match="Unknown diagnostic hint policy"):
        await client.send("get_editor_state", hint_policy="banana")  # type: ignore[arg-type]
