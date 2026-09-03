"""Offline proofs for the deterministic storm profiles."""

from __future__ import annotations

import ast
import asyncio
import copy
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace

import pytest
from anyio import BrokenResourceError, ClosedResourceError, EndOfStream

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "docs" / "verification" / "storm-profiles-v1.json"
SPEC = importlib.util.spec_from_file_location(
    "stormtest_support", ROOT / "script" / "stormtest_support.py"
)
support = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support)

OPS = ["editor_state"] * 3 + ["node_create"] * 2 + ["scene_save"]


def _profile(workers: int = 2) -> dict:
    return {
        "id": "test",
        "editors": 1,
        "workers_per_editor": workers,
        "waves": 3,
        "calls_per_worker_wave": 5,
        "reload_enabled": False,
        "reload_every": 0,
        "reload_replaces_wave": False,
        "session_pin_fraction": 0,
    }


def _trace(profile: dict, seed: int = 41001, targets: list[str] | None = None) -> dict:
    return support.generate_trace(
        profile=profile,
        seed=seed,
        weighted_operations=OPS,
        target_ids=targets or ["editor-a"],
    )


def _disposable_project(tmp_path: Path, name: str = "qualification") -> Path:
    root = tmp_path / name
    root.mkdir()
    (root / "project.godot").write_text('[application]\nconfig/name="Storm"\n')
    (root / "main.tscn").write_text("[gd_scene format=3]\n")
    (root / support.DISPOSABLE_MARKER).write_text(support.DISPOSABLE_MARKER_TOKEN + "\n")
    return root


def test_trace_is_deterministic_and_worker_streams_are_independent():
    first = _trace(_profile(), 41002)
    assert first == _trace(_profile(), 41002)
    assert first != _trace(_profile(), 41003)
    worker_zero = [entry[1:] for entry in first["entries"] if entry[0] == 0]
    expanded = _trace(_profile(workers=3), 41002)
    assert worker_zero == [entry[1:] for entry in expanded["entries"] if entry[0] == 0]
    assert (
        support.worker_rng(41002, "editor-a", 0, "operation").random()
        != support.worker_rng(41002, "editor-a", 0, "payload").random()
    )


def test_saved_trace_replays_identically_and_rejects_tampering(tmp_path):
    trace = _trace(_profile(), 41003)
    path = tmp_path / "trace.json"
    support.save_trace(path, trace)
    recorded = path.read_bytes()
    support.save_trace(path, trace)
    assert path.read_bytes() == recorded
    assert support.load_trace(path) == trace

    tampered = json.loads(path.read_text(encoding="utf-8"))
    tampered["entries"][0][3] = (tampered["entries"][0][3] + 1) % len(tampered["operations"])
    path.write_text(json.dumps(tampered), encoding="utf-8")
    with pytest.raises(support.StormConfigError, match="digest mismatch"):
        support.load_trace(path)

    tampered["trace_sha256"] = support.canonical_sha256(
        {key: value for key, value in tampered.items() if key != "trace_sha256"}
    )
    with pytest.raises(support.StormConfigError, match="canonical generated schedule"):
        support.validate_canonical_trace(
            tampered,
            profile=_profile(),
            seed=41003,
            weighted_operations=OPS,
            target_ids=["editor-a"],
        )


def test_p99_and_threshold_failures_produce_nonzero_exit():
    assert support.latency_stats(list(range(1, 101)))["p99"] == 99
    report = {
        "err": 2,
        "overall_latency_ms": {"p99": 40},
        "per_op": {"node_create": {"latency_ms": {"p99": 20}}},
        "per_domain": {"calls": {"node": 8}},
        "reloads_attempted": 2,
        "reloads_survived": 1,
        "reload_recovery_s": [4, 18],
        "routing": {"session_pinned_fraction": 0.25},
    }
    thresholds = {
        "unexpected_errors": 0,
        "required_domains": ["node", "scene"],
        "minimum_calls_per_supported_domain": 10,
        "overall_latency_ms": {"p99": 30},
        "per_operation_latency_ms": {"node_create": {"p99": 15}},
        "required_reload_survival_percent": 100,
        "recovery_max_seconds": 15,
        "minimum_session_pinned_fraction": 0.5,
    }
    failures = support.evaluate_contract(report, thresholds)
    assert {failure.split()[0] for failure in failures} >= {
        "unexpected_errors",
        "domain",
        "overall",
        "operation",
        "reload",
        "session-pinned",
    }
    assert support.threshold_exit_code(failures) == 1
    assert support.threshold_exit_code([]) == 0


def test_threshold_contract_rejects_missing_and_unexpected_operation_labels():
    report = {
        "unexpected_errors": 0,
        "per_op": {
            "expected": {"latency_ms": {"p95": 1, "p99": 2}},
            "unexpected": {"latency_ms": {"p95": 1, "p99": 2}},
        },
    }
    thresholds = {
        "required_operation_labels": ["expected", "missing"],
        "per_operation_latency_ms": {
            "expected": {"p95": 10, "p99": 20},
            "missing": {"p95": 10, "p99": 20},
        },
    }
    failures = support.evaluate_contract(report, thresholds)
    assert failures[0] == (
        "measured operation labels differ from the required labels: "
        "missing=['missing'], extra=['unexpected']"
    )
    assert "operation missing has no measurements" in failures


def test_three_locked_profiles_have_exact_call_counts_and_real_multi_routes():
    config = support.load_profile_config(CONFIG)
    assert tuple(config["seeds"]) == support.APPROVED_SEEDS
    assert support.LOCKED_TARGET_IDS == {
        "steady": ("editor-a",),
        "reload-churn": ("editor-a",),
        "multi-editor": ("editor-a", "editor-b"),
    }
    for profile_id, expected in {"steady": 4000, "reload-churn": 9000}.items():
        profile = support.normalize_profile(profile_id, config["profiles"][profile_id])
        assert len(_trace(profile)["entries"]) == expected

    multi = support.normalize_profile("multi-editor", config["profiles"]["multi-editor"])
    trace = _trace(multi, targets=["editor-a", "editor-b"])
    assert len(trace["entries"]) == 4000
    assert {worker["target_id"] for worker in trace["workers"]} == {
        "editor-a",
        "editor-b",
    }
    assert sum(entry[4] for entry in trace["entries"]) == 4000


def test_unresolved_baselines_block_locked_qualification_but_not_profile_loading():
    config = support.load_profile_config(CONFIG)
    assert config["unresolved_baseline_fields"]
    with pytest.raises(support.StormConfigError, match="baseline gates remain unresolved"):
        support.validate_locked_qualification_thresholds(config, "steady")


def test_locked_qualification_requires_complete_latency_ceilings():
    config = copy.deepcopy(support.load_profile_config(CONFIG))
    config["unresolved_baseline_fields"] = []
    with pytest.raises(support.StormConfigError, match="overall latency p95"):
        support.validate_locked_qualification_thresholds(config, "steady")

    config["profile_thresholds"]["steady"].update(
        overall_latency_ms={"p95": 500, "p99": 1000},
    )
    with pytest.raises(support.StormConfigError, match="non-empty per-operation"):
        support.validate_locked_qualification_thresholds(config, "steady")

    config["profile_thresholds"]["steady"]["per_operation_latency_ms"] = {
        "node_create": {"p95": 300}
    }
    with pytest.raises(support.StormConfigError, match="operation 'node_create'.*p99"):
        support.validate_locked_qualification_thresholds(config, "steady")

    config["profile_thresholds"]["steady"]["per_operation_latency_ms"] = {
        "node_create": {"p95": 300, "p99": 600}
    }
    with pytest.raises(support.StormConfigError, match="missing=.*editor_state"):
        support.validate_locked_qualification_thresholds(config, "steady")

    config["profile_thresholds"]["steady"]["per_operation_latency_ms"] = {
        operation: {"p95": 300, "p99": 600}
        for operation in config["thresholds"]["required_operation_labels"]
    }
    support.validate_locked_qualification_thresholds(config, "steady")


def test_storm_entrypoint_applies_locked_qualification_threshold_preflight():
    source = (ROOT / "script" / "stormtest.py").read_text(encoding="utf-8")
    load_index = source.index("PROFILE_CONFIG = load_profile_config(ARGS.config)")
    assert source.find("validate_locked_qualification_thresholds(", load_index) > load_index


def test_storm_entrypoint_uses_the_real_hierarchy_contract_and_fails_aborts():
    source = (ROOT / "script" / "stormtest.py").read_text(encoding="utf-8")
    assert 'nodes = hierarchy.data.get("nodes", [])' in source
    assert 'hierarchy.data.get("root")' not in source
    assert "if ABORTED[0]:\n            return 1" in source


def test_storm_entrypoint_attributes_in_flight_failures_to_reload_epoch():
    source = (ROOT / "script" / "stormtest.py").read_text(encoding="utf-8")
    assert "reload_epoch = TARGET_RELOAD_EPOCHS[target_id]" in source
    assert "TARGET_RELOAD_EPOCHS[target_id] != reload_epoch" in source
    assert 'TARGET_RELOAD_EPOCHS = Counter({target["id"]: 0 for target in TARGETS})' in source


def test_storm_entrypoint_rejects_noncanonical_locked_replay_and_bad_deadlines():
    source = (ROOT / "script" / "stormtest.py").read_text(encoding="utf-8")
    assert "validate_canonical_trace(" in source
    assert "math.isfinite(value)" in source
    assert "task.cancel()" in source


def test_target_routes_and_domain_coverage_are_preserved():
    targets = support.parse_target_specs(
        [
            "editor-a=http://127.0.0.1:8000/mcp,project-a@1234",
            "editor-b=http://127.0.0.1:8010/mcp,project-b@5678",
        ]
    )
    assert targets[1]["url"].endswith(":8010/mcp")
    assert targets[1]["session_id"] == "project-b@5678"
    assert support.tool_domain("node_set_property") == "node"
    assert support.tool_domain("material_manage") == "material"
    coverage = support.coverage_report({"node": 7}, ["node", "scene"])
    assert coverage["calls"] == {"node": 7, "scene": 0}


def test_locked_target_names_are_part_of_the_canonical_schedule():
    support.validate_locked_target_ids("steady", ["editor-a"])
    support.validate_locked_target_ids("multi-editor", ["editor-a", "editor-b"])
    with pytest.raises(support.StormConfigError, match="canonical target ids"):
        support.validate_locked_target_ids("steady", ["arbitrary"])
    with pytest.raises(support.StormConfigError, match="canonical target ids"):
        support.validate_locked_target_ids("multi-editor", ["editor-b", "editor-a"])


def test_only_connection_readiness_errors_inside_reload_window_are_tolerated():
    assert (
        support.error_disposition("CONNECTION", reload_window_open=True)
        == "tolerated_reload_transient"
    )
    assert (
        support.error_disposition("EDITOR_NOT_READY", reload_window_open=True)
        == "tolerated_reload_transient"
    )
    assert support.error_disposition("NODE_NOT_FOUND", reload_window_open=True) == "unexpected"
    assert support.error_disposition("SESSION", reload_window_open=True) == "unexpected"
    assert support.error_disposition("CONNECTION", reload_window_open=False) == "unexpected"


def test_domain_specific_minimum_overrides_default():
    report = {
        "unexpected_errors": 0,
        "per_domain": {"calls": {"node": 80, "project": 25}},
    }
    thresholds = {
        "unexpected_errors": 0,
        "required_domains": ["node", "project"],
        "minimum_calls_per_supported_domain": 80,
        "minimum_calls_by_domain": {"project": 25},
    }
    assert support.evaluate_contract(report, thresholds) == []
    report["per_domain"]["calls"]["project"] = 24
    assert support.evaluate_contract(report, thresholds) == ["domain project calls 24 < 25"]


def test_locked_completion_contract_rejects_truncation_and_missing_reloads():
    thresholds = {
        "unexpected_errors": 0,
        "require_not_aborted": True,
        "require_live_at_end": True,
        "require_cleanup_complete": True,
        "expected_scheduled_operations": 4000,
        "expected_reload_attempts": 9,
        "required_reload_survival_percent": 100,
    }
    report = {
        "unexpected_errors": 0,
        "aborted": True,
        "stopped": True,
        "cleanup_complete": False,
        "scheduled_operations": 3999,
        "reloads_attempted": 0,
        "reloads_survived": 0,
        "per_domain": {"calls": {}},
    }
    assert support.evaluate_contract(report, thresholds) == [
        "run aborted",
        "target not live at end",
        "qualification cleanup incomplete",
        "scheduled_operations 3999 != 4000",
        "reloads_attempted 0 != 9",
    ]


def test_disposable_project_requires_exact_marker_and_absent_scratch(tmp_path):
    root = _disposable_project(tmp_path)
    assert support.validate_disposable_project(root) == root.resolve()
    assert support.parse_qualification_project_specs([f"editor-a={root}"]) == {
        "editor-a": root.resolve()
    }

    (root / support.DISPOSABLE_MARKER).write_text("yes, delete this\n")
    with pytest.raises(support.StormConfigError, match="must contain exactly"):
        support.validate_disposable_project(root)
    (root / support.DISPOSABLE_MARKER).write_text(support.DISPOSABLE_MARKER_TOKEN)
    (root / support.SCRATCH_DIRECTORY).mkdir()
    with pytest.raises(support.StormConfigError, match="must be absent"):
        support.validate_disposable_project(root)
    (root / support.SCRATCH_DIRECTORY).rmdir()
    (root / ".godot").write_text("not a cache directory")
    with pytest.raises(support.StormConfigError, match="plain directory"):
        support.validate_disposable_project(root)


def test_qualification_project_specs_reject_duplicate_roots_and_relative_paths(tmp_path):
    root = _disposable_project(tmp_path)
    with pytest.raises(support.StormConfigError, match="distinct canonical roots"):
        support.parse_qualification_project_specs([f"editor-a={root}", f"editor-b={root / '.'}"])
    with pytest.raises(support.StormConfigError, match="must be absolute"):
        support.parse_qualification_project_specs(["editor-a=relative/project"])


def test_project_inventory_ignores_cache_and_reports_durable_drift(tmp_path):
    root = _disposable_project(tmp_path)
    (root / ".godot").mkdir()
    (root / ".godot" / "generated").write_text("one")
    before = support.project_tree_inventory(root)
    (root / ".godot" / "generated").write_text("two")
    assert support.project_tree_inventory(root) == before

    (root / "project.godot").write_text("changed")
    (root / "unexpected.txt").write_text("added")
    drift = support.project_tree_drift(before, support.project_tree_inventory(root))
    assert drift == ["changed project.godot", "added unexpected.txt"]


def test_locked_session_selection_proves_topology_and_project_identity(tmp_path):
    root = _disposable_project(tmp_path)
    session = {
        "session_id": "project@old",
        "editor_pid": 4242,
        "project_path": str(root),
    }
    assert (
        support.select_initial_session(
            [session],
            expected_project_path=root,
            require_only_session=True,
        )
        == session
    )
    with pytest.raises(support.StormConfigError, match="exactly one session"):
        support.select_initial_session(
            [session, {**session, "session_id": "other"}],
            expected_project_path=root,
            require_only_session=True,
        )
    with pytest.raises(support.StormConfigError, match="does not match"):
        support.select_initial_session(
            [session],
            expected_project_path=_disposable_project(tmp_path, "other"),
            require_only_session=True,
        )
    with pytest.raises(support.StormConfigError, match="must be absolute"):
        support.select_initial_session(
            [{**session, "project_path": "relative/project"}],
            expected_project_path=root,
            require_only_session=True,
        )


def test_repin_requires_one_new_session_with_same_pid_and_project(tmp_path):
    root = _disposable_project(tmp_path)
    old = {"session_id": "project@old", "editor_pid": 4242, "project_path": str(root)}
    replacement = {**old, "session_id": "project@new"}
    noise = {"session_id": "noise", "editor_pid": 7, "project_path": str(root)}
    assert (
        support.select_replacement_session(
            [old, noise],
            expected_project_path=root,
            editor_pid=4242,
            previous_session_id=old["session_id"],
        )
        is None
    )
    assert (
        support.select_replacement_session(
            [old, replacement, noise],
            expected_project_path=root,
            editor_pid=4242,
            previous_session_id=old["session_id"],
        )
        == replacement
    )
    with pytest.raises(support.StormConfigError, match="2 replacement sessions"):
        support.select_replacement_session(
            [replacement, {**replacement, "session_id": "project@newer"}],
            expected_project_path=root,
            editor_pid=4242,
            previous_session_id=old["session_id"],
        )


@pytest.mark.parametrize("invalid", [None, [], [None], [{"session_id": "missing"}]])
def test_exploratory_pin_requires_exactly_one_real_session(invalid):
    with pytest.raises(support.StormConfigError):
        support.pinned_session_identity(invalid, "project@old")


def test_exploratory_pin_records_identity_without_following_other_editor(tmp_path):
    project = tmp_path / "MiXeD-Project"
    project.mkdir()
    reported_path = str(project)
    replacement_path = reported_path
    if os.name == "nt":
        reported_path = reported_path.upper()
        replacement_path = str(project).lower()
        assert reported_path != os.path.normcase(reported_path)
        assert Path(reported_path).samefile(project)
        assert Path(replacement_path).samefile(project)
    old = {"session_id": "old", "editor_pid": 42, "project_path": reported_path}
    noise = {"session_id": "other", "editor_pid": 99, "project_path": str(tmp_path / "other")}
    identity = support.pinned_session_identity([noise, old], "old")
    # Deliberately vary Windows input casing; neither the initial identity nor
    # the replacement session may depend on the spelling an editor reports.
    assert identity == {
        "editor_pid": 42,
        "project_path": os.path.normcase(str(project.resolve())),
    }
    assert (
        support.select_replacement_session(
            [noise, {**old, "session_id": "new", "project_path": replacement_path}],
            expected_project_path=identity["project_path"],
            editor_pid=identity["editor_pid"],
            previous_session_id="old",
        )["session_id"]
        == "new"
    )
    for rows in ([old, old], [{**old, "editor_pid": True}], [{**old, "project_path": "relative"}]):
        with pytest.raises(support.StormConfigError):
            support.pinned_session_identity(rows, "old")


@pytest.mark.parametrize("error_type", [BrokenResourceError, ClosedResourceError, EndOfStream])
def test_closed_sdk_stream_is_tolerated_only_during_measured_reload(error_type):
    code = support.transport_exception_code(error_type())
    assert code == "CONNECTION"
    assert support.error_disposition(code, reload_window_open=True) == "tolerated_reload_transient"
    assert support.error_disposition(code, reload_window_open=False) == "unexpected"
    assert support.transport_exception_code(RuntimeError("BrokenResourceError")) is None


@pytest.mark.parametrize("envelope,code", [("error", 408), ("response", 401)])
def test_transport_envelope_is_tolerated_only_during_measured_reload(envelope, code):
    error = RuntimeError("SDK transport failure")
    setattr(
        error, envelope, SimpleNamespace(**{"code" if envelope == "error" else "status_code": code})
    )
    extracted = support.transport_exception_code(error)
    assert extracted == "CONNECTION"
    assert (
        support.error_disposition(extracted, reload_window_open=True)
        == "tolerated_reload_transient"
    )
    assert support.error_disposition(extracted, reload_window_open=False) == "unexpected"
    error.error = SimpleNamespace(code=-32603)
    error.response = SimpleNamespace(status_code=500)
    assert support.transport_exception_code(error) is None


def test_profile_validation_rejects_noncanonical_reload_mode():
    profile = _profile()
    profile["reload_mode"] = "anything"
    with pytest.raises(support.StormConfigError, match="invalid reload_mode"):
        support.normalize_profile("test", profile)


@pytest.mark.parametrize(
    "operation,expected",
    [
        ("add_action", ["ensure_action"]),
        ("bind_event", ["ensure_action", "bind_event"]),
        ("remove_action", ["ensure_action", "remove_action"]),
        ("list", ["list"]),
    ],
)
def test_exploratory_input_stress_uses_valid_idempotent_preconditions(operation, expected):
    tree = ast.parse((ROOT / "script/stormtest.py").read_text(encoding="utf-8"))
    function = next(
        node
        for node in tree.body
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "op_input_map"
    )
    namespace = {"Worker": object, "IS_LOCKED": False}
    exec(compile(ast.Module(body=[function], type_ignores=[]), "stormtest.py", "exec"), namespace)
    calls = []

    async def call(_tool, arguments, **_kwargs):
        calls.append(arguments["op"])

    worker = SimpleNamespace(
        wi=0, rng=SimpleNamespace(randint=lambda *_: 0, choice=lambda _: operation), call=call
    )
    asyncio.run(namespace["op_input_map"](worker))
    assert calls == expected


def test_canonical_sha_is_order_independent():
    assert support.canonical_sha256({"a": 1, "b": 2}) == support.canonical_sha256({"b": 2, "a": 1})


@pytest.mark.parametrize(
    "locked,explicit,trace_pin,expected",
    [
        (False, "project@one", 0, True),
        (False, "project@one", 1, True),
        (False, "", 0, False),
        (True, "project@one", 0, False),
        (True, "project@one", 1, True),
    ],
)
def test_exploratory_explicit_route_cannot_be_unpinned_by_trace(
    locked, explicit, trace_pin, expected
):
    from collections import defaultdict
    from unittest.mock import AsyncMock

    tree = ast.parse((ROOT / "script/stormtest.py").read_text(encoding="utf-8"))
    function = next(
        node
        for node in tree.body
        if isinstance(node, ast.AsyncFunctionDef) and node.name == "worker_loop"
    )
    observed = []

    async def operation(worker):
        observed.append(worker.session_pinned)

    namespace = {
        "Worker": object,
        "asyncio": asyncio,
        "defaultdict": defaultdict,
        "IS_LOCKED": locked,
        "WAVES": 1,
        "STOP": [False],
        "TRACE_BY_WORKER": {0: [[0, 0, 0, 0, trace_pin]]},
        "TRACE": [{"operations": ["test"]}],
        "OPERATION_BY_NAME": {"test": operation},
        "M": {"scheduled_operations": 0},
        "_hard_close": AsyncMock(),
    }
    exec(compile(ast.Module(body=[function], type_ignores=[]), "stormtest.py", "exec"), namespace)
    worker = SimpleNamespace(
        wi=0,
        connect=AsyncMock(return_value=True),
        ensure_container=AsyncMock(),
        is_chaos=False,
        client=object(),
        target={"session_id": explicit},
        session_pinned=False,
    )
    asyncio.run(namespace["worker_loop"](worker))
    assert observed == [expected]
    assert namespace["M"]["scheduled_operations"] == 1
    assert worker.client is None
