"""Supplemental release evidence requires native proof and public byte inventories."""

import copy

import pytest

from script import qualification_engine as engine
from script import release_promotion as promotion
from script import release_support as support
from script import release_validation as validation

DIGEST = {"sha256": "b" * 64, "size": 12}
MANIFEST = "godot-ai-v4-plugin.manifest.json"


def public_inventory(version):
    return {
        **{
            "release/" + name: {
                "url": "https://github.com/hi-godot/godot-ai/releases/download/v"
                + version
                + "/"
                + name,
                **DIGEST,
            }
            for name in support.RELEASE_NAMES
        },
        **{
            "dist/" + name: {"url": "https://files.pythonhosted.org/" + name, **DIGEST}
            for name in support.distribution_names(version)
        },
    }


@pytest.fixture
def rows(tmp_path, monkeypatch):
    candidate = tmp_path / "candidate"
    (candidate / "release").mkdir(parents=True)
    (candidate / "evidence.json").write_text("qualified candidate")
    manifest = {"inventory": [{"path": "addons/godot_ai/plugin.gd", **DIGEST}]}
    (candidate / "release" / MANIFEST).write_bytes(support.canonical(manifest))
    record = {
        "version": "4.1.0",
        "tag": "v4.1.0",
        "source": "a" * 40,
        "workflow_sha": "a" * 40,
        "run_id": "123",
        "run_attempt": "1",
        "spki_sha256": "c" * 64,
        "files": {name: DIGEST for name in public_inventory("4.1.0")},
    }
    monkeypatch.setattr(support, "verify_candidate", lambda *args: record)
    tree_hash = support.verifier().inventory_tree_hash(manifest)
    case = {
        "id": "exact-published-predecessor-to-a",
        "status": "passed",
        "backend_stopped": True,
        "from_version": "4.0.4",
        "to_version": "4.1.0",
        "runtime_result": {
            "status": "passed",
            "attached_bridge_served_b": True,
            "from_version": "4.0.4",
            "to_version": "4.1.0",
        },
        "attached_bridge": {"pin": "4.0.4", "ok_before_update": 1, "served_b": True, "fault": ""},
        "live_tree": {"plugin.gd": DIGEST},
        "live_tree_sha256": tree_hash,
        "backup_tree": {"plugin.gd": DIGEST},
        "backup_tree_sha256": tree_hash,
        "update_marker": DIGEST,
        "update_state": {
            "status": "success",
            "clients_migrated": True,
            "from_version": "4.0.4",
            "to_version": "4.1.0",
            "manifest_sha256": support.fingerprint(candidate / "release" / MANIFEST)["sha256"],
            "expected_tree_sha256": tree_hash,
        },
    }
    root = tmp_path / "rows"
    for os_label in support.PLATFORMS:
        for python in ("3.11", "3.14"):
            path = root / f"{os_label}-{python}"
            path.mkdir(parents=True)
            (path / "godot.log").write_text("native evidence")
            case["godot"] = {
                **engine.build_pin("4.7.0", os_label),
                "version": "4.7.stable.official.fixture",
            }
            row = {
                "godot_version": "4.7.0",
                "schema": 1,
                "kind": "predecessor",
                "status": "passed",
                "os": os_label,
                "python": python,
                "candidate": support.fingerprint(candidate / "evidence.json"),
                "version": record["version"],
                "source": record["source"],
                "run_id": "123",
                "run_attempt": "1",
                "required_skips": 0,
                "previous_version": "4.0.4",
                "predecessor": {
                    "version": "4.0.4",
                    "tag": "v4.0.4",
                    "source": "d" * 40,
                    "spki_sha256": record["spki_sha256"],
                    "files": public_inventory("4.0.4"),
                },
                "cases": [case],
                "files": support.inventory(path),
            }
            (path / "row.json").write_bytes(support.canonical(row))
    return candidate, root, tmp_path / "result.json", record


def public_rows(rows):
    candidate, root, output, record = rows
    inventory = public_inventory(record["version"])
    for path in root.glob("*/row.json"):
        row = support.read_json(path)
        row.update(
            kind="public",
            github={
                key.removeprefix("release/"): value
                for key, value in inventory.items()
                if key.startswith("release/")
            },
            pypi={
                key.removeprefix("dist/"): value
                for key, value in inventory.items()
                if key.startswith("dist/")
            },
        )
        row["resolutions"] = {
            kind: [
                {
                    "name": "godot-ai",
                    "version": record["version"],
                    **inventory["dist/godot_ai-4.1.0" + suffix],
                }
            ]
            for kind, suffix in (("wheel", "-py3-none-any.whl"), ("sdist", ".tar.gz"))
        }
        row["resolutions"]["build"] = [
            {
                "name": "setuptools",
                "version": "84.0.0",
                "url": "https://files.pythonhosted.org/setuptools.whl",
                **DIGEST,
            }
        ]
        path.write_bytes(support.canonical(row))
    receipt = root.parent / "publication.json"
    receipt.write_bytes(support.canonical(record))
    return receipt


def test_complete_binds_all_six_native_rows(rows):
    candidate, root, output, _ = rows
    validation.complete(candidate, root, output, "predecessor")
    result = support.read_json(output)
    assert result["status"] == "passed" and len(result["files"]) == 12
    assert result["candidate"] == support.fingerprint(candidate / "evidence.json")


@pytest.mark.parametrize(
    "fault",
    [
        "missing",
        "failed",
        "wrong_candidate",
        "wrong_source",
        "duplicate",
        "empty_cases",
        "wrong_case",
        "no_bridge",
        "bridge_fault",
        "wrong_tree",
        "wrong_state",
        "wrong_backup",
        "no_stop",
        "retained_file",
        "previous_source",
        "previous_version",
        "public_inventory",
        "skipped",
        "missing_engine",
        "wrong_engine",
        "wrong_engine_row",
    ],
)
def test_complete_rejects_partial_or_mixed_evidence(rows, fault):
    candidate, root, output, _ = rows
    path = next(root.glob("*/row.json"))
    row = support.read_json(path)
    if fault == "missing":
        path.unlink()
    elif fault == "duplicate":
        duplicate = root / "duplicate"
        duplicate.mkdir()
        (duplicate / "row.json").write_bytes(path.read_bytes())
    else:
        if fault in {"failed", "wrong_candidate", "wrong_source"}:
            row[
                {"failed": "status", "wrong_candidate": "candidate", "wrong_source": "source"}[
                    fault
                ]
            ] = "wrong"
        elif fault == "empty_cases":
            row["cases"] = []
        elif fault == "wrong_case":
            row["cases"][0]["id"] = "exact-a-to-b"
        elif fault == "no_bridge":
            row["cases"][0]["runtime_result"]["attached_bridge_served_b"] = False
        elif fault == "bridge_fault":
            row["cases"][0]["attached_bridge"]["fault"] = "disconnected"
        elif fault == "wrong_tree":
            row["cases"][0]["live_tree"] = {}
        elif fault == "wrong_state":
            row["cases"][0]["update_state"]["manifest_sha256"] = "e" * 64
        elif fault == "wrong_backup":
            row["cases"][0]["backup_tree_sha256"] = "e" * 64
        elif fault == "no_stop":
            row["cases"][0]["backend_stopped"] = False
        elif fault == "retained_file":
            (path.parent / "godot.log").write_text("changed")
        elif fault == "previous_source":
            row["predecessor"]["source"] = "e" * 40
        elif fault == "previous_version":
            row["previous_version"] = "4.0.3"
        elif fault == "public_inventory":
            row["predecessor"]["files"].pop(next(iter(row["predecessor"]["files"])))
        elif fault == "skipped":
            row["required_skips"] = 1
        elif fault == "missing_engine":
            row["cases"][0].pop("godot")
        elif fault == "wrong_engine":
            row["cases"][0]["godot"]["sha256"] = "e" * 64
        elif fault == "wrong_engine_row":
            row["godot_version"] = "4.7.2"
        path.write_bytes(support.canonical(row))
    with pytest.raises(support.ReleaseError):
        validation.complete(candidate, root, output, "predecessor")
    assert not output.exists()


def test_public_attestation_binds_receipt_and_resolutions(rows):
    candidate, root, output, record = rows
    receipt = public_rows(rows)
    validation.complete(candidate, root, output, "public", receipt)
    result = support.read_json(output)
    assert result["publication"] == {"receipt": record, "digest": support.fingerprint(receipt)}


@pytest.mark.parametrize(
    "fault",
    [
        "missing_pypi",
        "changed_asset",
        "private_url",
        "missing_build",
        "empty_build",
        "missing_release",
        "wrong_release",
        "duplicate_package",
        "bad_digest",
    ],
)
def test_public_attestation_rejects_incomplete_evidence(rows, fault):
    candidate, root, output, _ = rows
    receipt = public_rows(rows)
    path = next(root.glob("*/row.json"))
    row = support.read_json(path)
    if fault == "missing_pypi":
        row.pop("pypi")
    elif fault == "changed_asset":
        next(iter(row["github"].values()))["sha256"] = "e" * 64
    elif fault == "private_url":
        row["resolutions"]["build"][0]["url"] = "https://private.example/package.whl"
    elif fault == "missing_build":
        row["resolutions"].pop("build")
    elif fault == "empty_build":
        row["resolutions"]["build"] = []
    elif fault == "missing_release":
        row["resolutions"]["wheel"][0]["name"] = "unrelated"
    elif fault == "wrong_release":
        row["resolutions"]["sdist"][0]["version"] = "4.0.4"
    elif fault == "duplicate_package":
        row["resolutions"]["build"] *= 2
    elif fault == "bad_digest":
        row["resolutions"]["build"][0]["sha256"] = "bad"
    path.write_bytes(support.canonical(row))
    with pytest.raises(support.ReleaseError):
        validation.complete(candidate, root, output, "public", receipt)
    assert not output.exists()


@pytest.mark.parametrize(
    "field",
    ["version", "tag", "source", "workflow_sha", "run_id", "run_attempt", "spki_sha256", "files"],
)
def test_public_receipt_must_match_qualified_candidate(rows, field):
    candidate, root, output, record = rows
    receipt = public_rows(rows)
    changed = copy.deepcopy(record)
    changed[field] = "wrong"
    receipt.write_bytes(support.canonical(changed))
    with pytest.raises(support.ReleaseError, match="publication receipt"):
        validation.complete(candidate, root, output, "public", receipt)
    assert not output.exists()


def test_public_requires_publication_receipt(rows):
    candidate, root, output, _ = rows
    public_rows(rows)
    with pytest.raises(support.ReleaseError, match="requires publication receipt"):
        validation.complete(candidate, root, output, "public")


@pytest.mark.parametrize(
    "field", [None, "id", "repository", "path", "event", "head_branch", "head_sha", "conclusion"]
)
def test_publication_run_provenance(rows, monkeypatch, field):
    candidate, _, _, record = rows
    run = {
        "id": 123,
        "repository": {"full_name": support.REPOSITORY},
        "path": ".github/workflows/release.yml",
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": record["source"],
        "conclusion": "success",
    }
    if field is not None:
        run[field] = {} if field == "repository" else "wrong"
    monkeypatch.setattr(promotion, "gh", lambda endpoint: run)
    if field is None:
        assert validation.check_publication_run("123", candidate) == run
    else:
        with pytest.raises(support.ReleaseError, match="provenance"):
            validation.check_publication_run("123", candidate)
