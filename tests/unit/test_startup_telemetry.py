"""STARTUP record contracts, incl. the diagnostic-hint escape-hatch flag (#761)."""

from __future__ import annotations

import pytest

from godot_ai import __version__ as _SERVER_VERSION
from godot_ai.godot_client.client import GodotClient
from godot_ai.server import _startup_record_data


def _client(monkeypatch, *, env_value: str | None = None, **kwargs) -> GodotClient:
    if env_value is None:
        monkeypatch.delenv("GODOT_AI_SUPPRESS_DIAGNOSTIC_HINTS", raising=False)
    else:
        monkeypatch.setenv("GODOT_AI_SUPPRESS_DIAGNOSTIC_HINTS", env_value)
    return GodotClient(None, None, **kwargs)  # type: ignore[arg-type]


def test_startup_record_defaults_to_hints_not_suppressed(monkeypatch) -> None:
    client = _client(monkeypatch)

    data = _startup_record_data(client, ws_port=9500, lifespan_start_ms=12.5)

    assert data["diagnostic_hints_suppressed"] is False


def test_startup_record_flags_suppression_from_env_constructed_client(monkeypatch) -> None:
    client = _client(monkeypatch, env_value="true")

    data = _startup_record_data(client, ws_port=9500, lifespan_start_ms=12.5)

    assert data["diagnostic_hints_suppressed"] is True


def test_startup_record_reads_client_policy_not_env(monkeypatch) -> None:
    ## Drift-proofing contract: env says suppress, but the client was
    ## constructed with an explicit override — the record must report
    ## the client's live policy, not a fresh env read.
    client = _client(monkeypatch, env_value="true", default_hint_policy="surface")

    data = _startup_record_data(client, ws_port=9500, lifespan_start_ms=12.5)

    assert data["diagnostic_hints_suppressed"] is False


@pytest.mark.parametrize(
    ("policy", "expected"),
    [
        ("surface", False),
        ("retain", False),
        ("discard", True),
    ],
)
def test_startup_record_suppressed_only_for_discard_policy(monkeypatch, policy, expected) -> None:
    client = _client(monkeypatch, default_hint_policy=policy)

    data = _startup_record_data(client, ws_port=9500, lifespan_start_ms=12.5)

    assert data["diagnostic_hints_suppressed"] is expected


def test_startup_record_keeps_existing_fields(monkeypatch) -> None:
    client = _client(monkeypatch)

    data = _startup_record_data(client, ws_port=9501, lifespan_start_ms=7.25)

    assert data == {
        "server_version": _SERVER_VERSION,
        "ws_port": 9501,
        "lifespan_start_ms": 7.25,
        "diagnostic_hints_suppressed": False,
    }
