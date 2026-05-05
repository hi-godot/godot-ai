"""Unit tests for the FAILED_MIXED self-update diagnostic in `editor_state`.

The plugin's `update_mixed_state.gd` scanner attaches a structured
`mixed_state` Dictionary to the GDScript `get_editor_state` response when
`addons/godot_ai/` contains `*.update_backup` files left behind by a
self-update whose rollback couldn't restore the previous addon contents
(`UpdateReloadRunner.InstallStatus.FAILED_MIXED`). These tests pin the
Python-side passthrough so an MCP agent observing the field can rely on
its presence and shape without having to probe the plugin directly.

See issue #354 / audit-v2 #10. The GDScript scanner itself is exercised
by `test_project/tests/test_update_mixed_state.gd`.
"""

from __future__ import annotations

from godot_ai.handlers import editor as editor_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session, SessionRegistry


class _EditorStateClient:
    """Stub plugin that returns whatever payload the test injects."""

    def __init__(self, payload: dict):
        self._payload = payload

    async def send(
        self,
        command: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float = 5.0,
    ) -> dict:
        if command != "get_editor_state":
            raise AssertionError(f"unexpected command: {command}")
        return dict(self._payload)


def _runtime_with_payload(payload: dict) -> DirectRuntime:
    session = Session(
        session_id="test-001",
        godot_version="4.4.1",
        project_path="/tmp/test",
        plugin_version="0.0.1",
        readiness="ready",
    )
    registry = SessionRegistry()
    registry.register(session)
    return DirectRuntime(registry=registry, client=_EditorStateClient(payload))


_BASE_PAYLOAD: dict = {
    "godot_version": "4.4.1",
    "project_name": "p",
    "current_scene": "res://main.tscn",
    "is_playing": False,
    "readiness": "ready",
    "game_capture_ready": False,
}


async def test_editor_state_omits_mixed_state_when_clean():
    """When the addons tree has no `.update_backup` files, the plugin
    omits the `mixed_state` key entirely. The Python handler must not
    invent it — agents distinguish "clean" vs "MIXED" on key presence."""
    runtime = _runtime_with_payload(_BASE_PAYLOAD)

    result = await editor_handlers.editor_state(runtime)

    assert "mixed_state" not in result, (
        "mixed_state must be absent when the plugin reports a clean tree"
    )


async def test_editor_state_passes_through_mixed_state_diagnostic():
    """When the plugin reports a half-installed addon tree, the Python
    handler must surface every field of the structured diagnostic so an
    MCP agent (or the dock crash banner consumer) can render it."""
    mixed = {
        "addon_dir": "res://addons/godot_ai/",
        "backup_files": [
            "res://addons/godot_ai/handlers/scene_handler.gd.update_backup",
            "res://addons/godot_ai/plugin.gd.update_backup",
        ],
        "backup_count": 2,
        "truncated": False,
        "message": (
            "Self-update rollback failed; addons/godot_ai/ contains a mix"
            " of old and new files. Restore the addon from your VCS or a"
            " fresh release ZIP, then delete the listed *.update_backup"
            " files."
        ),
    }
    payload = dict(_BASE_PAYLOAD)
    payload["mixed_state"] = mixed
    runtime = _runtime_with_payload(payload)

    result = await editor_handlers.editor_state(runtime)

    assert result.get("mixed_state") == mixed, (
        "Python handler must pass through the GDScript scanner's mixed_state Dictionary unchanged"
    )
    ## Spot-check structural keys so a future field rename in the
    ## scanner can't silently drop one downstream.
    surfaced = result["mixed_state"]
    assert surfaced["addon_dir"] == "res://addons/godot_ai/"
    assert len(surfaced["backup_files"]) == 2
    assert surfaced["backup_count"] == 2
    assert surfaced["truncated"] is False
    assert "addons/godot_ai/" in surfaced["message"]


async def test_editor_state_passes_through_truncated_mixed_state():
    """A pathological install that left thousands of backups gets capped
    by the scanner. Pin that the truncated flag still passes through so
    the agent knows the list isn't exhaustive."""
    mixed = {
        "addon_dir": "res://addons/godot_ai/",
        "backup_files": [f"res://addons/godot_ai/file_{i}.gd.update_backup" for i in range(200)],
        "backup_count": 200,
        "truncated": True,
        "message": "Self-update rollback failed; addons/godot_ai/ ...",
    }
    payload = dict(_BASE_PAYLOAD)
    payload["mixed_state"] = mixed
    runtime = _runtime_with_payload(payload)

    result = await editor_handlers.editor_state(runtime)

    assert result["mixed_state"]["truncated"] is True
    assert len(result["mixed_state"]["backup_files"]) == 200
