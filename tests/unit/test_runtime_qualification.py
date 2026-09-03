from pathlib import Path
from types import SimpleNamespace

import pytest

from script import qualification_engine as engine
from script import release_qualification as qualification
from script import release_support as support
from script import runtime_qualification as runtime


@pytest.mark.parametrize(
    ("expected", "actual"),
    [("4.7.0", "4.7.stable.official.deadbeef"), ("4.7.2", "4.7.2.stable.official.deadbeef")],
)
def test_runtime_engine_identity_accepts_only_the_pinned_official_patch(
    monkeypatch, expected, actual
):
    monkeypatch.setattr(
        runtime.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(stdout=actual + "\n"),
    )

    assert runtime._validate_godot_version("godot", expected) == actual


def test_runtime_engine_identity_rejects_a_different_patch(monkeypatch):
    monkeypatch.setattr(
        runtime.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(stdout="4.7.1.stable.official.deadbeef\n"),
    )

    with pytest.raises(support.ReleaseError, match="required official build"):
        runtime._validate_godot_version("godot", "4.7.2")


def test_runtime_rejects_unpinned_bytes_before_executing_version(monkeypatch, tmp_path):
    executable = tmp_path / "godot"
    executable.write_bytes(b"untrusted executable")
    monkeypatch.setattr(support, "verify_candidate", lambda *args: {})
    monkeypatch.setattr(
        runtime, "_validate_godot_version", lambda *args: pytest.fail("unverified binary executed")
    )
    with pytest.raises(support.ReleaseError, match="size/type differs"):
        runtime.exact_a_to_b(tmp_path, tmp_path, [], str(executable), "4.7.2", tmp_path / "row")


def test_runtime_rejects_a_row_labeled_as_another_platform(monkeypatch, tmp_path):
    monkeypatch.setattr(engine, "host_row", lambda: "macos-latest")
    with pytest.raises(support.ReleaseError, match="differs from actual host"):
        runtime.runtime_row(
            tmp_path, tmp_path, "godot", "4.7.2", tmp_path / "row", "windows-latest"
        )


def test_required_runtime_rows_distinguish_both_supported_godot_builds():
    runtime_keys = {key for key in qualification.required_row_keys() if key[0] == "runtime"}

    assert len(runtime_keys) == 12
    for os_label in support.PLATFORMS:
        for python in ("3.11", "3.14"):
            assert ("runtime", os_label, python, "4.7.0") in runtime_keys
            assert ("runtime", os_label, python, "4.7.2") in runtime_keys


def test_aggregate_rejects_a_missing_engine_row(monkeypatch, tmp_path):
    from script import stormtest_support

    monkeypatch.setattr(qualification, "preflight", lambda: None)
    monkeypatch.setattr(qualification, "dependency_inventory", lambda _root: [])
    monkeypatch.setattr(
        stormtest_support, "validate_locked_qualification_thresholds", lambda *_: None
    )
    bindings = {"a": "candidate-a", "b": "candidate-b"}
    omitted = None
    for number, (kind, os_label, python, godot) in enumerate(
        sorted(qualification.required_row_keys())
    ):
        directory = tmp_path / str(number)
        directory.mkdir()
        row = {
            "kind": kind,
            "os": os_label,
            "python": python,
            "status": "passed",
            "candidates": bindings,
            "files": {},
        }
        if kind == "python":
            row.update(
                dependencies=[],
                installs={
                    name: {"status": "passed", "managed_tree": {"plugin.cfg": {}}}
                    for name in bindings
                },
                tests={name: {"tests": 1, "failures": 0, "errors": 0} for name in bindings},
            )
        else:
            row.update(
                required_skips=0,
                cases=[
                    {"id": case, "status": "passed"} for case in qualification.MANDATORY_CASES[kind]
                ],
            )
        if godot is not None:
            row["godot_version"] = godot
            for case in row["cases"]:
                if case["id"] == "exact-a-to-b-hot-update":
                    case["godot"] = {
                        **engine.build_pin(godot, os_label),
                        "version": f"{godot.removesuffix('.0')}.stable.official.fixture",
                    }
            if godot == "4.7.2":
                omitted = directory / "row.json"
        (directory / "row.json").write_bytes(support.canonical(row))

    assert len(qualification.validate_rows(tmp_path, bindings)) == len(
        qualification.required_row_keys()
    )
    assert omitted is not None
    tampered = support.read_json(omitted)
    for case in tampered["cases"]:
        if case["id"] == "exact-a-to-b-hot-update":
            case["godot"]["sha256"] = "f" * 64
    omitted.write_bytes(support.canonical(tampered))
    with pytest.raises(support.ReleaseError, match="Godot evidence differs"):
        qualification.validate_rows(tmp_path, bindings)
    omitted.unlink()
    with pytest.raises(
        support.ReleaseError, match="missing mandatory qualification rows: runtime/.*/4.7.2"
    ):
        qualification.validate_rows(tmp_path, bindings)


def test_manifest_tree_is_relative_to_the_managed_addon(tmp_path):
    release = tmp_path / "release"
    release.mkdir()
    manifest = release / "godot-ai-v4-plugin.manifest.json"
    manifest.write_bytes(
        support.canonical(
            {"inventory": [{"path": "addons/godot_ai/plugin.cfg", "size": 5, "sha256": "a" * 64}]}
        )
    )

    assert runtime._manifest_tree(tmp_path) == {"plugin.cfg": {"size": 5, "sha256": "a" * 64}}

    manifest.write_bytes(
        support.canonical(
            {"inventory": [{"path": "elsewhere/plugin.cfg", "size": 5, "sha256": "a" * 64}]}
        )
    )
    with pytest.raises(support.ReleaseError, match="outside the managed add-on"):
        runtime._manifest_tree(tmp_path)


def test_isolated_environment_removes_package_source_poison(monkeypatch, tmp_path):
    monkeypatch.setenv("UV_EXTRA_INDEX_URL", "https://untrusted.invalid/simple")
    monkeypatch.setenv("PIP_INDEX_URL", "https://untrusted.invalid/simple")
    monkeypatch.setenv("GODOT_AI_MODE", "dev")

    environment = runtime._isolated_environment(tmp_path, "http://127.0.0.1/private/simple/")

    assert "UV_EXTRA_INDEX_URL" not in environment
    assert "PIP_INDEX_URL" not in environment
    assert environment["GODOT_AI_MODE"] == "user"
    assert environment["GODOT_AI_ALLOW_HEADLESS"] == "1"
    assert environment["GODOT_AI_QUALIFICATION_PYTHON_INDEX"] == "1"
    assert environment["UV_INDEX"] == environment["UV_DEFAULT_INDEX"]
    assert Path(environment["CODEX_HOME"]).is_dir()


def test_runtime_project_driver_is_external_to_candidate_tree(tmp_path):
    project = tmp_path / "project"
    addon = project / "addons/godot_ai"
    addon.mkdir(parents=True)
    sentinel = addon / "candidate.gd"
    sentinel.write_bytes(b"candidate bytes\n")

    runtime._write_project(project, tmp_path / "certificate.pem", "4.0.0", "4.0.1")

    assert sentinel.read_bytes() == b"candidate bytes\n"
    project_text = (project / "project.godot").read_text(encoding="utf-8")
    assert "_qualification_transport.gd" in project_text
    transport = (project / "_qualification_transport.gd").read_text(encoding="utf-8")
    assert 'resource_path != "res://addons/godot_ai/utils/update_manager.gd"' in transport
    driver = (project / "_qualification_driver.gd").read_text(encoding="utf-8")
    assert 'const VERSION_A := "4.0.0"' in driver
    assert 'const VERSION_B := "4.0.1"' in driver
    assert 'plugin.call("_on_dock_update_requested")' in driver


def test_private_capability_is_never_written_to_retained_log(tmp_path):
    log = tmp_path / "process.log"
    with pytest.raises(support.ReleaseError, match="printed a private capability"):
        runtime._write_secret_free_log(log, b"prefix secret-token suffix", ("secret-token",))
    assert log.read_text(encoding="utf-8") == (
        "qualification output withheld: private capability leaked\n"
    )


def test_private_capability_scan_covers_nested_retained_files(tmp_path):
    nested = tmp_path / "nested"
    nested.mkdir()
    (nested / "clean.bin").write_bytes(b"ordinary retained evidence")
    runtime._require_values_absent(tmp_path, ("private-token",))
    (nested / "leak.bin").write_bytes(b"prefix private-token suffix")
    with pytest.raises(support.ReleaseError) as caught:
        runtime._require_values_absent(tmp_path, ("private-token",))
    assert f"persisted in {Path('nested') / 'leak.bin'}" in str(caught.value)


def test_private_index_path_capability_can_be_scanned_independently():
    index = "http://127.0.0.1:12345/unrepeatable-capability/simple/"

    assert runtime._private_index_capability(index) == "unrepeatable-capability"


def _stub_candidate_validation(monkeypatch, candidates):
    monkeypatch.setattr(runtime.engine, "host_row", lambda: "ubuntu-latest")
    records = {
        "a": {"version": "4.0.0", "tag": "v4.0.0", "source": "a" * 40},
        "b": {"version": "4.0.1", "tag": "v4.0.1", "source": "b" * 40},
    }
    monkeypatch.setattr(
        runtime.support,
        "verify_candidate",
        lambda path, name: records[name] if path == candidates / name else pytest.fail(str(path)),
    )
    monkeypatch.setattr(
        runtime.support,
        "fingerprint",
        lambda path: {"size": 1, "sha256": ("a" if path.parent.name == "a" else "b") * 64},
    )
    return {
        name: runtime.support.fingerprint(candidates / name / "evidence.json") for name in records
    }


def test_runtime_row_is_bound_to_matching_python_evidence(monkeypatch, tmp_path):
    candidates = tmp_path / "candidates"
    python_row = tmp_path / "python-row"
    packages = python_row / "packages"
    packages.mkdir(parents=True)
    bindings = _stub_candidate_validation(monkeypatch, candidates)
    monkeypatch.setattr(runtime, "current_python_version", lambda: "3.11")
    monkeypatch.setattr(runtime.qualification, "dependency_inventory", lambda root: [])
    (python_row / "row.json").write_bytes(
        support.canonical(
            {
                "kind": "python",
                "status": "passed",
                "os": "ubuntu-latest",
                "python": "3.11",
                "candidates": bindings,
                "dependencies": [],
            }
        )
    )
    output = tmp_path / "output"

    def run_case(*args):
        case_output = args[-1]
        assert case_output == output / "exact-a-to-b"
        assert not case_output.exists()
        case_output.mkdir()
        return {"status": "passed", "transaction": "test-transaction-0001"}

    monkeypatch.setattr(runtime, "exact_a_to_b", run_case)

    runtime.runtime_row(candidates, python_row, "godot", "4.7.0", output, "ubuntu-latest")

    report = support.read_json(output / "row.json")
    assert report["status"] == "passed"
    assert report["required_skips"] == 0
    assert report["godot_version"] == "4.7.0"
    assert report["candidates"] == bindings
    assert report["cases"] == [{"status": "passed", "transaction": "test-transaction-0001"}]


def test_runtime_row_rejects_different_candidate_binding(monkeypatch, tmp_path):
    candidates = tmp_path / "candidates"
    python_row = tmp_path / "python-row"
    (python_row / "packages").mkdir(parents=True)
    bindings = _stub_candidate_validation(monkeypatch, candidates)
    monkeypatch.setattr(runtime, "current_python_version", lambda: "3.11")
    bindings["b"] = {"size": 1, "sha256": "c" * 64}
    (python_row / "row.json").write_bytes(
        support.canonical(
            {
                "kind": "python",
                "status": "passed",
                "os": "ubuntu-latest",
                "python": "3.11",
                "candidates": bindings,
                "dependencies": [],
            }
        )
    )

    with pytest.raises(support.ReleaseError, match="matching exact Python evidence"):
        runtime.runtime_row(
            candidates,
            python_row,
            "godot",
            "4.7.0",
            tmp_path / "output",
            "ubuntu-latest",
        )


def test_sparse_or_duplicate_non_python_rows_cannot_qualify():
    complete = [
        {"id": case_id, "status": "passed"}
        for case_id in sorted(qualification.MANDATORY_CASES["runtime"])
    ]
    qualification.validate_mandatory_cases("runtime", complete)

    with pytest.raises(support.ReleaseError, match="cases are missing"):
        qualification.validate_mandatory_cases("runtime", complete[:-1])
    with pytest.raises(support.ReleaseError, match="unexpected or duplicate"):
        qualification.validate_mandatory_cases("runtime", [*complete, complete[0]])
    with pytest.raises(support.ReleaseError, match="case failed"):
        qualification.validate_mandatory_cases(
            "runtime", [{**case, "status": "failed"} for case in complete]
        )
