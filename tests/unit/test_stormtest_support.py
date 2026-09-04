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
from httpx import HTTPStatusError, ReadError, RemoteProtocolError, Request, Response

ROOT = Path(__file__).resolve().parents[2]
CONFIG = ROOT / "docs" / "verification" / "storm-profiles-v1.json"
SPEC = importlib.util.spec_from_file_location(
    "stormtest_support", ROOT / "script" / "stormtest_support.py"
)
support = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(support)

OPS = ["editor_state"] * 3 + ["node_create"] * 2 + ["scene_save"]


@pytest.mark.parametrize("failure", [
    None, "reload_missing", "reload_unswitched", "reload_not_disk", "tree_missing", "tree_empty",
    "tree_not_dict", "tree_wrong_root", "tree_children", "tree_extra", "tree_more", "tool_error",
])
async def test_scratch_setup_reloads_retained_tab_and_proves_empty_root(failure):
    from unittest.mock import AsyncMock

    tree = ast.parse((ROOT / "script/stormtest.py").read_text(encoding="utf-8"))
    function = next(node for node in tree.body if isinstance(node, ast.AsyncFunctionDef)
                    and node.name == "_fresh_scratch_root")
    target = {"id": "editor-a", "session_id": "exact-session"}
    namespace = {"_target_params": lambda t, p: {**p, "session_id": t["session_id"]},
                 "SCRATCH_SCENE": "res://_stormtest/storm.tscn",
                 "StormConfigError": support.StormConfigError}
    exec(compile(ast.Module(body=[function], type_ignores=[]), "stormtest.py", "exec"), namespace)
    reload_data = {"switched": True, "reloaded_from_disk": True}
    hierarchy = {"nodes": [{"path": "/Root", "children_count": 0}], "has_more": False}
    if failure == "reload_missing":
        reload_data = None
    elif failure == "reload_unswitched":
        reload_data["switched"] = False
    elif failure == "reload_not_disk":
        reload_data["reloaded_from_disk"] = False
    elif failure == "tree_missing":
        hierarchy = None
    elif failure == "tree_empty":
        hierarchy["nodes"] = []
    elif failure == "tree_not_dict":
        hierarchy["nodes"] = [None]
    elif failure == "tree_wrong_root":
        hierarchy["nodes"][0]["path"] = "/OldRoot"
    elif failure == "tree_children":
        hierarchy["nodes"][0]["children_count"] = 8
    elif failure == "tree_extra":
        hierarchy["nodes"].append({"path": "/Root/w0", "children_count": 1})
    elif failure == "tree_more":
        hierarchy["has_more"] = True
    responses = [SimpleNamespace(data={}), SimpleNamespace(data=reload_data),
                 SimpleNamespace(data=hierarchy)]
    if failure == "tool_error":
        responses[1] = RuntimeError("reload refused")
    call = AsyncMock(side_effect=responses)
    if failure:
        with pytest.raises(RuntimeError if failure == "tool_error" else support.StormConfigError):
            await namespace["_fresh_scratch_root"](SimpleNamespace(call_tool=call), target)
    else:
        root = await namespace["_fresh_scratch_root"](SimpleNamespace(call_tool=call), target)
        assert root == "/Root"
    calls = call.call_args_list
    assert calls[0].args == ("scene_open", {"path": "res://_stormtest/storm.tscn",
                                          "session_id": "exact-session"})
    assert calls[1].args == ("scene_open", {"path": "res://_stormtest/storm.tscn",
                                          "force_reload": True, "session_id": "exact-session"})
    assert all(entry.args[0] != "scene_save" for entry in calls)
    if failure is None or failure.startswith("tree_"):
        assert calls[2].args == ("scene_get_hierarchy", {"depth": 1, "session_id": "exact-session"})


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


@pytest.mark.parametrize("thresholds", [{}, {"unexpected_errors": 0}])
def test_baseline_measurement_can_never_pass_qualification(thresholds):
    report = {"baseline_measurement": True, "unexpected_errors": 0}
    failures = support.evaluate_contract(report, thresholds)
    assert failures == ["baseline measurement is not qualification"]
    assert support.threshold_exit_code(failures) != 0
    assert support.evaluate_contract({**report, "baseline_measurement": False}, thresholds) == []


def test_baseline_measurement_preserves_all_other_acceptance_failures():
    report = {"baseline_measurement": True, "unexpected_errors": 1,
              "aborted": True, "stopped": True, "cleanup_complete": False}
    thresholds = {"unexpected_errors": 0, "require_not_aborted": True,
                  "require_live_at_end": True, "require_cleanup_complete": True}
    failures = support.evaluate_contract(report, thresholds)
    assert failures == ["baseline measurement is not qualification", "unexpected_errors 1 > 0",
                        "run aborted", "target not live at end", "qualification cleanup incomplete"]


@pytest.mark.parametrize("mode,expected", [
    ("qualification", "unresolved"),
    ("baseline-marker", "regular marker"),
    ("baseline-no-profile", "requires a canonical locked profile"),
    ("baseline-override", "do not allow threshold overrides"),
    ("baseline-config", "locked profiles require"),
])
def test_baseline_cli_has_explicit_mode_without_weakening_qualification(tmp_path, mode, expected):
    import subprocess
    import sys

    project = tmp_path / "project"
    project.mkdir()
    (project / "project.godot").write_text('[application]\nconfig/name="Not authorized"\n')
    arguments = [sys.executable, str(ROOT / "script/stormtest.py"), "--seed", "41001",
                 "--target", "editor-a=http://127.0.0.1:1/mcp",
                 "--qualification-project", f"editor-a={project}"]
    if mode != "baseline-no-profile":
        arguments += ["--profile", "steady"]
    if mode != "qualification":
        arguments.append("--measure-baseline")
    if mode == "baseline-override":
        arguments += ["--thresholds", str(tmp_path / "unread.json")]
    if mode == "baseline-config":
        arguments += ["--config", str(tmp_path / "unread.json")]
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith("SS_")}
    environment["GODOT_AI_DISABLE_TELEMETRY"] = "true"
    result = subprocess.run(arguments, capture_output=True, text=True, env=environment, timeout=20)
    assert result.returncode == 2
    assert "stormtest configuration error:" in result.stderr
    assert expected in result.stderr
    assert "stormtest REPORT" not in result.stdout


def test_storm_entrypoint_uses_the_real_hierarchy_contract_and_fails_aborts():
    source = (ROOT / "script" / "stormtest.py").read_text(encoding="utf-8")
    assert 'nodes = tree.get("nodes") if isinstance(tree, dict) else None' in source
    assert 'ROOT_PATHS[target_id] = await _fresh_scratch_root(c, target)' in source
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


@pytest.mark.parametrize(
    "error_type", [BrokenResourceError, ClosedResourceError, EndOfStream, ReadError]
)
def test_closed_sdk_stream_is_tolerated_only_during_measured_reload(error_type):
    error = error_type("") if error_type is ReadError else error_type()
    code = support.transport_exception_code(error)
    assert code == "CONNECTION"
    assert support.error_disposition(code, reload_window_open=True) == "tolerated_reload_transient"
    assert support.error_disposition(code, reload_window_open=False) == "unexpected"
    assert support.transport_exception_code(RuntimeError("BrokenResourceError")) is None
    assert support.transport_exception_code(RuntimeError("ReadError")) is None


@pytest.mark.parametrize("failure", ["read", "malformed", "forbidden", "session", "identity"])
def test_repin_retries_typed_read_disconnect_without_relaxing_identity(tmp_path, failure):
    import time
    from unittest.mock import AsyncMock, Mock

    tree = ast.parse((ROOT / "script/stormtest.py").read_text(encoding="utf-8"))
    functions = [node for node in tree.body
                 if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))
                 and node.name in {"_err_code", "_repin_locked_target"}]
    request = Request("GET", "http://127.0.0.1/mcp")
    errors = {
        "read": ReadError("", request=request),
        "malformed": RemoteProtocolError("invalid response"),
        "forbidden": HTTPStatusError(
            "forbidden", request=request, response=Response(403, request=request)),
        "session": RuntimeError("SESSION"),
        "identity": support.StormConfigError("ambiguous replacement"),
    }
    replacement = {"session_id": "project@new", "editor_pid": 1234,
                   "project_path": str(tmp_path)}
    candidate = SimpleNamespace(call_tool=AsyncMock(side_effect=[[replacement], {}]))
    worker = SimpleNamespace(target={"id": "editor-a", "url": str(request.url),
                                    "session_id": "project@old"}, client=object())
    evidence = {"current_session_id": "project@old", "repins": []}
    namespace = {
        "Worker": object, "asyncio": SimpleNamespace(
            timeout=asyncio.timeout, TimeoutError=asyncio.TimeoutError, sleep=AsyncMock()),
        "time": time, "RECONNECT_TIMEOUT": 1, "CALL_TIMEOUT": 1, "STOP": [False],
        "TARGET_IDENTITIES": {"editor-a": {"editor_pid": 1234, "project_path": str(tmp_path)}},
        "QUALIFICATION_EVIDENCE": {"editor-a": evidence},
        "_hard_close": AsyncMock(), "_open_client": AsyncMock(
            side_effect=[errors[failure], candidate]),
        "_sessions_from_result": lambda result: result,
        "_requires_single_editor_topology": lambda: True,
        "select_replacement_session": support.select_replacement_session,
        "StormConfigError": support.StormConfigError,
        "TOLERATED_RELOAD_ERRORS": support.TOLERATED_RELOAD_ERRORS,
        "transport_exception_code": support.transport_exception_code,
        "_abort": Mock(), "_record_admin_error": Mock(),
    }
    exec(compile(ast.Module(body=functions, type_ignores=[]), "stormtest.py", "exec"), namespace)
    assert asyncio.run(namespace["_repin_locked_target"](worker, "project@old")) == (
        failure == "read")
    if failure == "read":
        assert namespace["_open_client"].await_count == 2
        assert worker.client is candidate
        assert worker.target["session_id"] == "project@new"
        assert evidence["repins"] == [{"old_session_id": "project@old",
            "new_session_id": "project@new", "editor_pid": 1234, "project_path": str(tmp_path)}]
        candidate.call_tool.assert_awaited_with("editor_state", {"session_id": "project@new"})
        namespace["_abort"].assert_not_called()
        namespace["_record_admin_error"].assert_not_called()
    else:
        assert namespace["_open_client"].await_count == 1
        assert worker.client is None
        assert worker.target["session_id"] == "project@old"
        assert evidence == {"current_session_id": "project@old", "repins": []}
        namespace["_abort"].assert_called_once()
        namespace["_record_admin_error"].assert_called_once()


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


@pytest.mark.parametrize(
    "mode", ["pinned", "unpinned", "locked", "connect-fails", "bad-identity",
             "repin-fails", "reload-disconnect", "stopped"]
)
def test_isolated_reload_captures_and_rotates_explicit_identity(mode):
    import time
    from unittest.mock import AsyncMock, Mock

    tree = ast.parse((ROOT / "script/stormtest.py").read_text(encoding="utf-8"))
    function = next(node for node in tree.body if isinstance(node, ast.AsyncFunctionDef)
                    and node.name == "run_isolated_reload")
    target = {"id": "editor-a", "url": "http://127.0.0.1:18349/mcp",
              "session_id": "" if mode == "unpinned" else "project@old"}
    call = AsyncMock(side_effect=ConnectionError() if mode == "reload-disconnect" else None)
    worker = SimpleNamespace(
        target=target, client=SimpleNamespace(call_tool=call),
        connect=AsyncMock(return_value=mode != "connect-fails"),
        routed=lambda params, **kwargs: {**params, "session_id": target["session_id"]},
    )
    capture = AsyncMock(side_effect=ValueError() if mode == "bad-identity" else None)
    repin = AsyncMock(return_value=mode != "repin-fails")
    namespace = {
        "Worker": Mock(return_value=worker), "TARGETS": [target],
        "IS_LOCKED": mode == "locked", "ISOLATED_ITERS": 1,
        "RECONNECT_TIMEOUT": 1, "CALL_TIMEOUT": 1, "STOP": [mode == "stopped"],
        "M": {"reloads_attempted": 0, "reloads_survived": 0,
              "reconnects": 0, "reload_recovery_s": []},
        "asyncio": SimpleNamespace(timeout=asyncio.timeout, sleep=AsyncMock()),
        "time": time, "_hard_close": AsyncMock(), "_capture_pinned_target": capture,
        "_repin_locked_target": repin, "_active_session_id": AsyncMock(
            side_effect=["project@old", "project@new"]),
        "_abort": Mock(), "_record_admin_error": Mock(), "_err_code": lambda error: "ERROR",
    }
    exec(compile(ast.Module(body=[function], type_ignores=[]), "stormtest.py", "exec"), namespace)
    asyncio.run(namespace["run_isolated_reload"]())
    capture_expected = mode not in {"unpinned", "locked", "connect-fails"}
    assert capture.await_count == int(capture_expected)
    if capture_expected:
        assert capture.await_args.args[1] is target
    repin_expected = mode in {"pinned", "locked", "repin-fails", "reload-disconnect"}
    assert repin.await_count == int(repin_expected)
    if repin_expected:
        repin.assert_awaited_once_with(worker, "project@old")
    assert worker.connect.await_count == (2 if mode == "unpinned" else 1)
    failed = mode in {"connect-fails", "bad-identity", "repin-fails"}
    assert namespace["_abort"].call_count == int(failed)
    assert namespace["M"]["reloads_survived"] == int(not failed and mode != "stopped")
    if mode != "connect-fails":
        assert worker.client is None


def test_exploratory_identity_capture_records_exact_pin_without_qualification_claim(tmp_path):
    from unittest.mock import AsyncMock

    tree = ast.parse((ROOT / "script/stormtest.py").read_text(encoding="utf-8"))
    function = next(node for node in tree.body if isinstance(node, ast.AsyncFunctionDef)
                    and node.name == "_capture_pinned_target")
    target = {"id": "editor-a", "session_id": "project@old"}
    session = {"session_id": "project@old", "project_path": str(tmp_path), "editor_pid": 1234}
    client = SimpleNamespace(call_tool=AsyncMock(return_value=[session]))
    namespace = {"asyncio": asyncio, "CALL_TIMEOUT": 1, "TARGET_IDENTITIES": {},
                 "QUALIFICATION_EVIDENCE": {},
                 "pinned_session_identity": support.pinned_session_identity,
                 "_sessions_from_result": lambda result: result}
    exec(compile(ast.Module(body=[function], type_ignores=[]), "stormtest.py", "exec"), namespace)
    asyncio.run(namespace["_capture_pinned_target"](client, target))
    expected = support.pinned_session_identity([session], "project@old")
    assert namespace["TARGET_IDENTITIES"] == {"editor-a": expected}
    assert namespace["QUALIFICATION_EVIDENCE"] == {"editor-a": {
        **expected, "initial_session_id": "project@old", "current_session_id": "project@old",
        "repins": [],
    }}
    client.call_tool.assert_awaited_once_with("session_manage", {"op": "list", "params": {}})
