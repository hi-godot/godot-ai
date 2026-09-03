from pathlib import Path

import pytest

from script import release_qualification as qualification
from script import release_support as support
from script import runtime_qualification as runtime


def test_isolated_environment_removes_package_source_poison(monkeypatch, tmp_path):
    monkeypatch.setenv("UV_EXTRA_INDEX_URL", "https://untrusted.invalid/simple")
    monkeypatch.setenv("PIP_INDEX_URL", "https://untrusted.invalid/simple")
    monkeypatch.setenv("GODOT_AI_MODE", "dev")

    environment = runtime._isolated_environment(tmp_path, "http://127.0.0.1/private/simple/")

    assert "UV_EXTRA_INDEX_URL" not in environment
    assert "PIP_INDEX_URL" not in environment
    assert environment["GODOT_AI_MODE"] == "user"
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
    with pytest.raises(support.ReleaseError, match="persisted in nested/leak.bin"):
        runtime._require_values_absent(tmp_path, ("private-token",))


def test_private_index_path_capability_can_be_scanned_independently():
    index = "http://127.0.0.1:12345/unrepeatable-capability/simple/"

    assert runtime._private_index_capability(index) == "unrepeatable-capability"


def _stub_candidate_validation(monkeypatch, candidates):
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
    monkeypatch.setattr(
        runtime,
        "exact_a_to_b",
        lambda *args: {"status": "passed", "transaction": "test-transaction-0001"},
    )
    output = tmp_path / "output"

    runtime.runtime_row(candidates, python_row, "godot", output, "ubuntu-latest")

    report = support.read_json(output / "row.json")
    assert report["status"] == "passed"
    assert report["required_skips"] == 0
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
        runtime.runtime_row(candidates, python_row, "godot", tmp_path / "output", "ubuntu-latest")


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
