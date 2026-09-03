"""Contracts for protected signing and digest-bound v4 publication."""

from pathlib import Path

import yaml

WORKFLOWS = Path(__file__).resolve().parents[2] / ".github" / "workflows"


def test_ci_checkouts_do_not_persist_credentials() -> None:
    workflow = yaml.safe_load((WORKFLOWS / "ci.yml").read_text(encoding="utf-8"))
    checkouts = [
        step
        for job in workflow["jobs"].values()
        for step in job["steps"]
        if step.get("uses", "").startswith("actions/checkout@")
    ]
    assert checkouts
    assert all(step["with"]["persist-credentials"] is False for step in checkouts)


def test_signing_secret_check_uses_the_protected_environment() -> None:
    workflow = (WORKFLOWS / "verify-signing.yml").read_text(encoding="utf-8")
    assert "RELEASE_SIGNING_KEY_PEM" in workflow
    assert "environment: release-signing" in workflow
    assert yaml.safe_load(workflow)["permissions"] == {"contents": "read"}
    for retired in ("copy_key_to_environment", "RELEASE_KEY_MIGRATION_TOKEN", "gh secret"):
        assert retired not in workflow


def test_v4_publication_is_manual_and_promotes_only_qualified_bytes() -> None:
    path = WORKFLOWS / "release.yml"
    raw = path.read_text(encoding="utf-8")
    workflow = yaml.safe_load(raw)

    triggers = workflow.get(True, workflow.get("on"))
    assert set(triggers) == {"workflow_dispatch"}
    assert workflow["permissions"] == {"contents": "read", "actions": "read"}
    assert set(workflow["jobs"]) == {"verify-approval", "publish-pypi", "publish-github"}
    assert triggers["workflow_dispatch"]["inputs"]["bump"]["options"] == [
        "patch",
        "minor",
        "major",
    ]
    assert set(triggers["workflow_dispatch"]["inputs"]) == {
        "bump",
        "previous_version",
        "qualification_run_id",
    }
    # The human approval is the release-publish reviewer, not a record in
    # another repository: promotion takes no approval commit/path inputs.
    for retired in ("approval_commit", "approval_path", "attestation", "make-approval"):
        assert retired not in raw
    assert "script.release_promotion verify" in raw
    assert "script.release_promotion pypi-preflight" in raw
    assert "script.release_promotion verify-pypi" in raw
    assert "script.release_promotion github" in raw
    assert workflow["concurrency"]["cancel-in-progress"] is False
    assert "python -m build" not in raw
    for job in workflow["jobs"].values():
        steps = job["steps"]
        check = next(i for i, step in enumerate(steps) if " run-provenance " in step.get("run", ""))
        downloads = [
            i
            for i, step in enumerate(steps)
            if step.get("uses", "").startswith("actions/download-artifact@")
        ]
        assert downloads and check < min(downloads)
        # Check out only the reviewed workflow implementation, never an input
        # candidate source in a publication-credential job.
        for step in job["steps"]:
            if step.get("uses", "").startswith("actions/checkout@"):
                assert "ref" not in step.get("with", {})
                assert step["with"]["persist-credentials"] is False
    for name in ("publish-pypi", "publish-github"):
        assert workflow["jobs"][name]["environment"] == "release-publish"
        assert workflow["jobs"][name]["permissions"]["actions"] == "read"


def test_qualification_builds_and_signs_a_b_once_then_verifies_on_all_platforms() -> None:
    raw = (WORKFLOWS / "release-qualification.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(raw)
    assert workflow["permissions"] == {"contents": "read"}
    assert set(workflow["jobs"]) == {
        "validate-inputs",
        "build",
        "sign",
        "python",
        "runtime",
        "complete-qualification",
    }
    assert "environment" not in workflow["jobs"]["build"]
    assert "secrets." not in str(workflow["jobs"]["build"])
    assert workflow["jobs"]["sign"]["environment"] == "release-signing"
    assert "pip install" not in str(workflow["jobs"]["sign"])
    # Trimmed release gate: package rows at the floor/ceiling interpreters on
    # every desktop OS; one real-editor A -> B row per OS at Godot 4.7.0, plus
    # a single Linux row at the newest supported engine.
    assert workflow["jobs"]["python"]["strategy"]["matrix"]["python"] == ["3.11", "3.14"]
    assert workflow["jobs"]["runtime"]["strategy"]["matrix"]["python"] == ["3.11"]
    assert workflow["jobs"]["runtime"]["strategy"]["matrix"]["godot"] == ["4.7.0"]
    assert workflow["jobs"]["runtime"]["strategy"]["matrix"]["include"] == [
        {"os": "ubuntu-latest", "godot": "4.7.2", "python": "3.11"}
    ]
    assert workflow["jobs"]["runtime"]["needs"] == ["sign", "python"]
    assert "--preflight" not in raw
    assert "release_qualification --complete" in raw
    assert "script.runtime_qualification" in raw
    assert "environment: release-signing" in raw
    assert "RELEASE_SIGNING_KEY_PEM" in raw
    assert "script.release_support package" in raw
    assert "script.release_support sign" in raw
    assert "v4-candidate-${{ matrix.name }}" in raw
    assert "ubuntu-latest, macos-latest, windows-latest" in raw
    assert "gh release create" not in raw
    assert "gh-action-pypi-publish" not in raw


def test_release_workflow_shells_never_interpolate_dispatch_inputs():
    for name in ("release.yml", "release-qualification.yml"):
        workflow = yaml.safe_load((WORKFLOWS / name).read_text(encoding="utf-8"))
        for job in workflow["jobs"].values():
            for step in job["steps"]:
                assert "${{" not in step.get("run", "")
                if step.get("uses", "").startswith("actions/download-artifact@"):
                    assert step["uses"] == (
                        "actions/download-artifact@37930b1c2abaa49bbe596cd826c3c89aef350131"
                    )


def test_nightly_diagnostics_are_credential_free_and_not_a_release_gate() -> None:
    raw = (WORKFLOWS / "nightly-diagnostics.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(raw)
    triggers = workflow.get(True, workflow.get("on"))
    assert set(triggers) == {"schedule", "workflow_dispatch"}
    assert workflow["permissions"] == {"contents": "read"}
    assert workflow["env"]["GODOT_AI_DISABLE_TELEMETRY"] == "true"
    assert set(workflow["jobs"]) == {"failpoint-recovery", "storm-baseline"}
    # Diagnostics only: no signing/publishing environment, secret, or
    # release tooling, and nothing that release promotion reads.
    for forbidden in ("secrets.", "environment:", "release_promotion", "release_support sign"):
        assert forbidden not in raw
    assert "chickensoft-games/setup-godot@f166999204a4f2722c6fe042fbaa3b3ea0d9c789" in raw
    assert "--measure-baseline" in raw
    assert "script.qualification_resources" in raw
    for job in workflow["jobs"].values():
        assert job["runs-on"] == "ubuntu-latest"
        for step in job["steps"]:
            if step.get("uses", "").startswith("actions/checkout@"):
                assert step["with"]["persist-credentials"] is False
            if step.get("uses", "").startswith("actions/upload-artifact@"):
                assert step["with"]["retention-days"] == 14
        assert any(
            step.get("uses", "").startswith("actions/upload-artifact@") for step in job["steps"]
        )


def test_legacy_auto_bump_tag_push_workflow_is_retired() -> None:
    assert not (WORKFLOWS / "bump-and-release.yml").exists()
