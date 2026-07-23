"""Contract test: the plugin-event allowlist twins must stay identical.

`plugin/addons/godot_ai/telemetry.gd::_ALLOWED_EVENTS` (plugin side) and
`godot_ai.transport.websocket._PLUGIN_EVENT_NAMES` (server side) both carry
"update both together" comments, but until this test nothing enforced it.
Both sides drop unknown names silently (telemetry.gd drops before sending,
websocket.py drops at ingest with a debug log), so one-sided drift loses the
new event's telemetry without failing anything: the exact event a change
shipped to measure never arrives, and CI stays green.

Modeled on test_error_code_parity.py. Unlike the error-code contract this
one is two-way set equality: an event name on either side without its twin
is dead weight at best and silent data loss at worst.
"""

from __future__ import annotations

import re
from pathlib import Path

from godot_ai.transport.websocket import _PLUGIN_EVENT_NAMES

TELEMETRY_GD = (
    Path(__file__).resolve().parents[2]
    / "plugin"
    / "addons"
    / "godot_ai"
    / "telemetry.gd"
)

_ALLOWLIST_BLOCK_RE = re.compile(
    r"const\s+_ALLOWED_EVENTS\s*:=\s*\[(?P<body>.*?)\]", re.DOTALL
)
_NAME_RE = re.compile(r'"([a-z0-9_]+)"')


def _parse_gdscript_allowlist() -> frozenset[str]:
    text = TELEMETRY_GD.read_text(encoding="utf-8")
    match = _ALLOWLIST_BLOCK_RE.search(text)
    assert match is not None, (
        "Could not find `const _ALLOWED_EVENTS := [...]` in telemetry.gd — "
        "if the declaration moved or was renamed, update this test's regex "
        "so the allowlist contract stays enforced."
    )
    names = frozenset(_NAME_RE.findall(match.group("body")))
    # Vacuity guard: an empty parse would make the equality below
    # trivially comparable against a bug, not against the real list.
    assert names, "Parsed an empty _ALLOWED_EVENTS block — regex drift?"
    return names


def test_plugin_event_allowlists_match() -> None:
    gd_names = _parse_gdscript_allowlist()
    assert gd_names == _PLUGIN_EVENT_NAMES, (
        "telemetry.gd _ALLOWED_EVENTS and websocket.py _PLUGIN_EVENT_NAMES "
        "have drifted. Only GDScript: %s. Only Python: %s. Update both "
        "together (see the comments on each declaration)."
        % (
            sorted(gd_names - _PLUGIN_EVENT_NAMES),
            sorted(_PLUGIN_EVENT_NAMES - gd_names),
        )
    )


def test_dev_transport_env_twin_matches_asgi() -> None:
    """Reload and reaper paths consume the shared protocol env-var name."""
    from godot_ai import asgi, orphan_reaper

    assert orphan_reaper.DEV_TRANSPORT_ENV == asgi.DEV_TRANSPORT_ENV
