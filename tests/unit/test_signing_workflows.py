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
    assert workflow["permissions"] == {"contents": "read"}
    assert set(workflow["jobs"]) == {"verify-approval", "publish-pypi", "publish-github"}
    assert triggers["workflow_dispatch"]["inputs"]["bump"]["options"] == [
        "patch",
        "minor",
        "major",
    ]
    assert "qualification_run_id" in raw
    assert "approval_repository" in raw
    assert "approval_commit" in raw
    assert "approval does not name this exact A/B digest set" in raw
    assert "gh release create" in raw
    assert "python -m build" not in raw
    assert "actions/checkout@" not in raw


def test_qualification_builds_and_signs_a_b_once_then_verifies_on_all_platforms() -> None:
    raw = (WORKFLOWS / "release-qualification.yml").read_text(encoding="utf-8")
    workflow = yaml.safe_load(raw)
    assert workflow["permissions"] == {"contents": "read"}
    assert set(workflow["jobs"]) == {"validate-inputs", "build", "qualify"}
    assert "environment: release-signing" in raw
    assert "RELEASE_SIGNING_KEY_PEM" in raw
    assert "python script/v4-release build" in raw
    assert "v4-candidate-${{ matrix.name }}" in raw
    assert "ubuntu-latest, macos-latest, windows-latest" in raw
    assert "gh release create" not in raw
    assert "gh-action-pypi-publish" not in raw


def test_legacy_auto_bump_tag_push_workflow_is_retired() -> None:
    assert not (WORKFLOWS / "bump-and-release.yml").exists()
