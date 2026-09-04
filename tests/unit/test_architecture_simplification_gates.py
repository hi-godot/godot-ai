from __future__ import annotations

import importlib.util
import json
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script" / "architecture_simplification_gates.py"
BASELINE = ROOT / "docs" / "verification" / "architecture-simplification-gates-a468a7e.json"
LANDING_COMMIT = "a468a7eedd7dcbbeb0221a297f7e7c50f5ab2b4e"
LANDING_TREE = "508149f3ca1f79fa1b60c23cc922e7ff7caa0c9b"

spec = importlib.util.spec_from_file_location("architecture_simplification_gates", SCRIPT)
assert spec is not None and spec.loader is not None
gates = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gates)


def _fixture(root: Path) -> None:
    sources = {
        "plugin/addons/godot_ai/utils/server_lifecycle.gd": (
            "var _host\nvar _episode := {}\nfunc run():\n\t_host.beta()\n\t_host.alpha = 1\n"
        ),
        "plugin/addons/godot_ai/utils/update_manager.gd": (
            "var _plugin\nvar _dock\nvar _unrelated\n"
        ),
        "plugin/addons/godot_ai/utils/client_job_owner.gd": "",
        "plugin/addons/godot_ai/mcp_dock.gd": (
            "var _client_status_refresh_thread\n"
            "static var _orphaned_client_action_threads := []\nvar _unrelated\n"
            "func start():\n    var worker := Thread.new()\n"
        ),
        "plugin/addons/godot_ai/handlers/client_handler.gd": (
            "var _status_workers := []\nfunc start():\n    var worker := Thread.new()\n"
        ),
        "plugin/addons/godot_ai/connection.gd": (
            'var result := {"recovery_action": "retry_tokenless"}\n'
        ),
        "src/godot_ai/sessions/registry.py": (
            "class Session:\n    current_scene: str\n    error_watermark: dict[str, int]\n\n"
            "class PendingCommandLimitError:\n    def __init__(self):\n"
            "        self.current_scene = 'not a Session'\n\n"
            "class SessionRegistry:\n    def __init__(self):\n"
            "        self._entries: dict[str, Session] = {}\n\n"
            "    def update(self, session):\n        session.current_scene = 'x'\n"
            "        session.error_watermark.update({'errors': 1})\n"
        ),
        "src/godot_ai/transport/websocket.py": (
            "class GodotWebSocketServer:\n    def __init__(self):\n"
            "        self._connections: dict[str, object] = {}\n"
            "    def accept(self, handshake):\n"
            "        if self._auth_token is not None and handshake.auth_token:\n"
            "            return True\n"
        ),
        "src/godot_ai/protocol/envelope.py": "class HandshakeMessage:\n    pass\n",
        "src/godot_ai/release_verify.py": (
            'ASSET_NAME = "godot-ai-v4-plugin.zip"\n'
            'PLUGIN_PREFIX = "addons/godot_ai/"\n'
        ),
        "script/v4-release": "ASSET_NAME = verifier.ASSET_NAME\n",
        ".github/workflows/release.yml": "name: release\n",
    }
    for relative, source in sources.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(source, encoding="utf-8")


def test_collectors_recognize_entries_and_ignore_non_session_self_fields(tmp_path: Path):
    _fixture(tmp_path)
    report = gates.collect_report(
        tmp_path, source_commit="a" * 40, source_tree="b" * 40, production_dirty=False
    )
    measured = report["gates"]
    assert {name: gate["value"] for name, gate in measured.items()} == {
        "active_lifecycle_episode_variants": 1,
        "dock_client_worker_static_stores": 2,
        "external_mutable_session_assignments": 2,
        "legacy_tokenless_transport_branches": 3,
        "lifecycle_generic_host_dependencies": 2,
        "non_owner_client_thread_spawns": 2,
        "owner_dependency_cycles": 3,
        "production_python_gdscript_loc": 42,
        "python_session_peer_membership_maps": 2,
        "update_manager_plugin_dock_references": 2,
        "v4_release_plugin_zip_shapes": 1,
    }
    membership = measured["python_session_peer_membership_maps"]["maps"]
    assert [item["field"] for item in membership] == ["_entries", "_connections"]
    assert [
        (item["field"], item["line"])
        for item in measured["external_mutable_session_assignments"]["mutations"]
    ] == [("current_scene", 14), ("error_watermark", 15)]


def test_explicit_source_binding_refuses_a_different_production_tree(monkeypatch, tmp_path):
    responses = {
        ("rev-parse", "landing^{commit}"): LANDING_COMMIT,
        ("rev-parse", f"{LANDING_COMMIT}^{{tree}}"): LANDING_TREE,
    }
    monkeypatch.setattr(gates, "_git", lambda _root, *args: responses[args])
    monkeypatch.setattr(gates, "_production_differs_from", lambda *_args: True)
    with pytest.raises(ValueError, match="differ from requested source commit"):
        gates._working_tree_report(tmp_path, source_ref="landing")


def test_checked_in_baseline_is_canonical_and_bound_to_landing():
    raw = BASELINE.read_text(encoding="utf-8")
    baseline = json.loads(raw)
    assert raw == json.dumps(baseline, indent=2, sort_keys=True) + "\n"
    assert baseline["source"]["commit"] == LANDING_COMMIT
    assert baseline["source"]["tree"] == LANDING_TREE
    assert baseline["source"]["production_dirty"] is False
    assert {name: gate["value"] for name, gate in baseline["gates"].items()} == {
        "active_lifecycle_episode_variants": 4,
        "detached_runner_owner_node_references": 1,
        "dock_client_worker_static_stores": 20,
        "external_mutable_session_assignments": 11,
        "legacy_tokenless_transport_branches": 3,
        "lifecycle_generic_host_dependencies": 40,
        "non_owner_client_thread_spawns": 4,
        "owner_dependency_cycles": 4,
        "production_python_gdscript_loc": 59859,
        "python_session_peer_membership_maps": 2,
        "update_manager_plugin_dock_references": 2,
        "v4_release_plugin_zip_shapes": 2,
    }


def test_target_failures_report_only_hard_gate_regressions():
    report = {
        "gates": {
            "passing": {"value": 1, "target": 1},
            "failing": {"value": 2, "target": 1},
            "informational": {"value": 999},
        }
    }
    assert gates.target_failures(report) == ["failing: 2 > target 1"]


def test_current_tree_satisfies_every_hard_architecture_target():
    report = gates._working_tree_report(ROOT)
    assert gates.target_failures(report) == []
