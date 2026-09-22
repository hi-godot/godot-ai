import hashlib
import io
import json
import zipfile

import pytest

from script import release_predecessor as predecessor
from script import release_support as support


class Response(io.BytesIO):
    url = "https://files.pythonhosted.org/package.whl"


def test_editor_environment_does_not_inherit_github_tokens_or_user_settings(monkeypatch, tmp_path):
    monkeypatch.setenv("GH_TOKEN", "read-only-fixture-token")
    monkeypatch.setenv("GITHUB_TOKEN", "another-fixture-token")
    monkeypatch.setenv("APPDATA", "host-settings")
    environment = predecessor.isolated_environment(
        tmp_path / "environment", "http://127.0.0.1/index"
    )
    assert "GH_TOKEN" not in environment and "GITHUB_TOKEN" not in environment
    assert environment["APPDATA"] == str(tmp_path / "environment/app-data")
    assert environment["UV_INDEX"] == "http://127.0.0.1/index"


@pytest.mark.parametrize(
    "body,size,digest,expected",
    [
        (b"good", 4, hashlib.sha256(b"good").hexdigest(), None),
        (b"bad", 4, hashlib.sha256(b"good").hexdigest(), "digest or size"),
        (b"evil", 4, hashlib.sha256(b"good").hexdigest(), "digest or size"),
        (b"excess", 4, None, "exceeds declared size"),
    ],
)
def test_download_checks_actual_bytes(monkeypatch, tmp_path, body, size, digest, expected):
    monkeypatch.setattr(predecessor.public, "open_public_artifact", lambda *_: Response(body))
    target = tmp_path / "artifact.whl"
    if expected:
        with pytest.raises(support.ReleaseError, match=expected):
            predecessor.download(Response.url, target, size, digest, {"files.pythonhosted.org"})
    else:
        receipt = predecessor.download(
            Response.url, target, size, digest, {"files.pythonhosted.org"}
        )
        assert target.read_bytes() == body
        assert receipt == {"url": Response.url, "size": size, "sha256": digest}


def test_public_tag_is_peeled_and_bounded(monkeypatch):
    calls = []

    def api(path):
        calls.append(path)
        return {"object": {"type": "tag" if len(calls) == 1 else "commit", "sha": "a" * 40}}

    monkeypatch.setattr(predecessor.public, "gh", api)
    assert predecessor.public_source("4.0.4") == "a" * 40
    assert calls == [
        "repos/hi-godot/godot-ai/git/ref/tags/v4.0.4",
        "repos/hi-godot/godot-ai/git/tags/" + "a" * 40,
    ]
    monkeypatch.setattr(
        predecessor.public, "gh", lambda _: {"object": {"type": "tag", "sha": "a" * 40}}
    )
    with pytest.raises(support.ReleaseError, match="nesting exceeds"):
        predecessor.public_source("4.0.4")


def test_public_predecessor_cannot_be_draft_or_missing_assets(monkeypatch, tmp_path):
    monkeypatch.setattr(predecessor, "public_source", lambda _: "a" * 40)
    monkeypatch.setattr(predecessor.public, "gh", lambda _: {"tag_name": "v4.0.4", "draft": True})
    with pytest.raises(support.ReleaseError, match="public stable"):
        predecessor.fetch_predecessor("4.0.4", tmp_path)
    monkeypatch.setattr(predecessor.public, "gh", lambda _: {"tag_name": "v4.0.4", "assets": []})
    with pytest.raises(support.ReleaseError, match="asset inventory"):
        predecessor.fetch_predecessor("4.0.4", tmp_path)


def _public_fixture(monkeypatch, tmp_path):
    version, source = "4.0.4", "a" * 40
    monkeypatch.setattr(predecessor, "public_source", lambda _: source)
    assets = [
        {"name": name, "size": 4, "browser_download_url": "https://github.com/" + name}
        for name in sorted(support.RELEASE_NAMES)
    ]
    monkeypatch.setattr(
        predecessor.public,
        "gh",
        lambda _: {
            "tag_name": "v" + version,
            "draft": False,
            "prerelease": False,
            "assets": assets,
        },
    )
    distributions = [
        {
            "filename": name,
            "url": "https://files.pythonhosted.org/" + name,
            "size": 4,
            "digests": {"sha256": "b" * 64},
            "yanked": False,
        }
        for name in sorted(support.distribution_names(version))
    ]
    monkeypatch.setattr(predecessor.public, "public_json", lambda _: {"urls": distributions})
    downloaded = []

    def download(url, path, size, digest, hosts):
        downloaded.append((url, path, digest))
        return {"url": url, "size": size, "sha256": digest or "c" * 64}

    monkeypatch.setattr(predecessor, "download", download)
    verified = []
    monkeypatch.setattr(
        support, "verify_signed_assets", lambda path, record: verified.append((path, record))
    )
    monkeypatch.setattr(
        support,
        "check_distribution_metadata",
        lambda path, version: verified.append((path, version)),
    )
    return distributions, downloaded, verified


def test_public_receipt_requires_signatures_and_both_distribution_identities(monkeypatch, tmp_path):
    _, downloads, verified = _public_fixture(monkeypatch, tmp_path)
    result = predecessor.fetch_predecessor("4.0.4", tmp_path)
    assert len(downloads) == 8
    assert verified[0] == (
        tmp_path / "release",
        {"version": "4.0.4", "tag": "v4.0.4", "source": "a" * 40},
    )
    assert {path.name for path, version in verified[1:]} == support.distribution_names("4.0.4")
    assert {version for path, version in verified[1:]} == {"4.0.4"}
    assert len(result["files"]) == 8
    assert result["source"] == "a" * 40


def test_public_predecessor_refuses_moved_tag_and_yanked_distribution(monkeypatch, tmp_path):
    distributions, _, _ = _public_fixture(monkeypatch, tmp_path)
    distributions[0]["yanked"] = True
    with pytest.raises(support.ReleaseError, match="yanked"):
        predecessor.fetch_predecessor("4.0.4", tmp_path)
    distributions[0]["yanked"] = False
    sources = iter(["a" * 40, "d" * 40])
    monkeypatch.setattr(predecessor, "public_source", lambda _: next(sources))
    with pytest.raises(support.ReleaseError, match="tag moved"):
        predecessor.fetch_predecessor("4.0.4", tmp_path)


def _input_fixture(monkeypatch, tmp_path):
    candidate, row_root = tmp_path / "candidate", tmp_path / "python"
    candidate.mkdir()
    (row_root / "packages").mkdir(parents=True)
    (candidate / "evidence.json").write_text("sealed", encoding="utf-8")
    wheel = row_root / "packages/godot_ai-4.1.0-py3-none-any.whl"
    wheel.write_bytes(b"candidate-wheel")
    record = {
        "version": "4.1.0",
        "source": "a" * 40,
        "workflow_sha": "a" * 40,
        "run_id": "123",
        "run_attempt": 1,
        "files": {"dist/" + wheel.name: support.fingerprint(wheel)},
    }
    dependencies = [
        {
            "filename": wheel.name,
            "name": "godot-ai",
            "version": "4.1.0",
            **support.fingerprint(wheel),
        }
    ]
    row = {
        "kind": "python",
        "status": "passed",
        "os": "windows-latest",
        "python": "3.11",
        "candidates": {"a": support.fingerprint(candidate / "evidence.json")},
        "dependencies": dependencies,
    }
    (row_root / "row.json").write_bytes(support.canonical(row))
    monkeypatch.setattr(predecessor.runtime.engine, "host_row", lambda: "windows-latest")
    monkeypatch.setattr(predecessor.runtime, "current_python_version", lambda: "3.11")
    monkeypatch.setattr(
        support,
        "verify_candidate",
        lambda root, role: record if role == "a" else pytest.fail("relabelled A"),
    )
    monkeypatch.setattr(predecessor.qualification, "dependency_inventory", lambda _: dependencies)
    return candidate, row_root, row, record, dependencies


@pytest.mark.parametrize(
    "field,value",
    [
        ("status", "failed"),
        ("os", "macos-latest"),
        ("python", "3.14"),
        ("candidates", {"a": {}}),
        ("dependencies", []),
    ],
)
def test_predecessor_rejects_wrong_retained_row(monkeypatch, tmp_path, field, value):
    candidate, row_root, row, _, _ = _input_fixture(monkeypatch, tmp_path)
    row[field] = value
    (row_root / "row.json").write_bytes(support.canonical(row))
    with pytest.raises(support.ReleaseError):
        predecessor.validate_inputs(candidate, row_root, "4.0.4", "windows-latest")


def test_predecessor_rejects_changed_retained_candidate_wheel(monkeypatch, tmp_path):
    candidate, row_root, _, _, _ = _input_fixture(monkeypatch, tmp_path)
    (row_root / "packages/godot_ai-4.1.0-py3-none-any.whl").write_bytes(b"substitution")
    with pytest.raises(support.ReleaseError, match="wheel differs"):
        predecessor.validate_inputs(candidate, row_root, "4.0.4", "windows-latest")


@pytest.mark.parametrize("previous", ["3.2.5", "4.1.0", "4.1.1", "5.0.0"])
def test_predecessor_requires_an_earlier_published_v4(monkeypatch, tmp_path, previous):
    candidate, row_root, _, _, _ = _input_fixture(monkeypatch, tmp_path)
    with pytest.raises(support.ReleaseError, match="earlier v4"):
        predecessor.validate_inputs(candidate, row_root, previous, "windows-latest")


def test_predecessor_row_retains_real_candidate_identity(monkeypatch, tmp_path):
    candidate, row_root, _, record, dependencies = _input_fixture(monkeypatch, tmp_path)
    monkeypatch.setattr(
        predecessor,
        "fetch_predecessor",
        lambda version, destination: {"version": version, "source": "b" * 40},
    )
    calls = []

    def update(*args):
        calls.append(args)
        return {"id": predecessor.CASE_ID, "status": "passed"}

    monkeypatch.setattr(predecessor, "run_update", update)
    output = tmp_path / "output"
    predecessor.predecessor_row(
        candidate, row_root, "4.0.4", "godot", "4.7.0", output, "windows-latest"
    )
    report = support.read_json(output / "row.json")
    assert report["candidate"] == support.fingerprint(candidate / "evidence.json")
    assert report["status"] == "passed" and report["source"] == record["source"]
    assert report["predecessor"]["source"] == "b" * 40
    assert calls[0][:3] == (candidate, row_root, dependencies)
    assert report["cases"] == [{"id": predecessor.CASE_ID, "status": "passed"}]


def test_failed_runtime_cannot_produce_a_passed_predecessor_receipt(monkeypatch, tmp_path):
    candidate, row_root, _, _, _ = _input_fixture(monkeypatch, tmp_path)
    monkeypatch.setattr(predecessor, "fetch_predecessor", lambda *_: {"version": "4.0.4"})
    monkeypatch.setattr(
        predecessor, "run_update", lambda *_: {"id": "exact-a-to-b-hot-update", "status": "passed"}
    )
    output = tmp_path / "output"
    with pytest.raises(support.ReleaseError, match="required passed case"):
        predecessor.predecessor_row(
            candidate, row_root, "4.0.4", "godot", "4.7.0", output, "windows-latest"
        )
    result = support.read_json(output / "row.json")
    assert result["status"] == "failed"
    assert result["cases"] == []


def _updated_project(tmp_path):
    roots = [tmp_path / name for name in ("predecessor", "candidate")]
    project = tmp_path / "project"
    manifests = []
    for root, content in zip(roots, (b"old", b"new"), strict=True):
        release = root / "release"
        release.mkdir(parents=True)
        manifest = {
            "inventory": [
                {
                    "path": "addons/godot_ai/plugin.cfg",
                    "size": len(content),
                    "sha256": hashlib.sha256(content).hexdigest(),
                }
            ]
        }
        (release / predecessor.MANIFEST).write_bytes(support.canonical(manifest))
        manifests.append(manifest)
    for relative, content in (
        ("addons/godot_ai/plugin.cfg", b"new"),
        ("addons/.godot_ai_update/backup/4.0.4/plugin.cfg", b"old"),
    ):
        path = project / relative
        path.parent.mkdir(parents=True)
        path.write_bytes(content)
    marker = {
        "status": "success",
        "clients_migrated": True,
        "from_version": "4.0.4",
        "to_version": "4.1.0",
        "manifest_sha256": support.fingerprint(roots[1] / "release" / predecessor.MANIFEST)[
            "sha256"
        ],
        "expected_tree_sha256": predecessor.runtime.release_verify.inventory_tree_hash(
            manifests[1]
        ),
        "backup_root": "res://addons/.godot_ai_update/backup/4.0.4",
    }
    (project / predecessor.runtime.UPDATE_STATE / "pending.json").write_text(
        json.dumps(marker), encoding="utf-8"
    )
    return project, roots, marker


def test_update_evidence_binds_exact_live_and_backup_bytes(tmp_path):
    project, roots, _ = _updated_project(tmp_path)
    result = predecessor.verify_update(project, *roots, {"version": "4.0.4"}, {"version": "4.1.0"})
    assert result["live_tree"] == {
        "plugin.cfg": support.fingerprint(project / "addons/godot_ai/plugin.cfg")
    }
    assert result["backup_tree"] == {
        "plugin.cfg": support.fingerprint(
            project / "addons/.godot_ai_update/backup/4.0.4/plugin.cfg"
        )
    }


@pytest.mark.parametrize("corruption", ["live", "backup", "marker", "lock", "migration-flag"])
def test_update_evidence_rejects_wrong_tree_or_incomplete_cleanup(tmp_path, corruption):
    project, roots, marker = _updated_project(tmp_path)
    if corruption == "live":
        (project / "addons/godot_ai/plugin.cfg").write_bytes(b"wrong")
    elif corruption == "backup":
        (project / "addons/.godot_ai_update/backup/4.0.4/plugin.cfg").write_bytes(b"wrong")
    elif corruption in {"marker", "migration-flag"}:
        if corruption == "marker":
            marker["from_version"] = "4.0.3"
        else:
            marker["clients_migrated"] = 1
        (project / predecessor.runtime.UPDATE_STATE / "pending.json").write_text(
            json.dumps(marker), encoding="utf-8"
        )
    else:
        (project / predecessor.runtime.UPDATE_STATE / "lock.json").write_text(
            "{}", encoding="utf-8"
        )
    with pytest.raises(support.ReleaseError):
        predecessor.verify_update(project, *roots, {"version": "4.0.4"}, {"version": "4.1.0"})


def _wheel(root, name, version, requirement=None):
    root.mkdir(parents=True, exist_ok=True)
    filename = f"{name}-{version}-py3-none-any.whl"
    metadata = f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n"
    if requirement:
        metadata += f"Requires-Dist: {requirement}\n"
    with zipfile.ZipFile(root / filename, "w") as archive:
        prefix = f"{name}-{version}.dist-info/"
        archive.writestr(prefix + "METADATA", metadata)
        archive.writestr(
            prefix + "WHEEL",
            "Wheel-Version: 1.0\nGenerator: fixture\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
        )
        archive.writestr(prefix + "RECORD", "")
    return root / filename


def test_merge_rejects_conflicting_filename_and_changed_source(tmp_path):
    source, target = tmp_path / "source", tmp_path / "target"
    target.mkdir()
    wheel = _wheel(source, "dependency", "1.0")
    rows = predecessor.qualification.dependency_inventory(source)
    predecessor.merge_dependency_files(source, rows, target)
    predecessor.merge_dependency_files(source, rows, target)
    assert (target / wheel.name).read_bytes() == wheel.read_bytes()
    (target / wheel.name).write_bytes(b"different bytes")
    with pytest.raises(support.ReleaseError, match="conflicting retained"):
        predecessor.merge_dependency_files(source, rows, target)
    assert (target / wheel.name).read_bytes() == b"different bytes"
    wheel.write_bytes(b"changed source")
    with pytest.raises(support.ReleaseError, match="changed before merge"):
        predecessor.merge_dependency_files(source, rows, target)


def test_offline_preflight_requires_both_distinct_dependency_versions(tmp_path):
    candidate, old, combined = (tmp_path / name for name in ("candidate", "old", "combined"))
    combined.mkdir()
    _wheel(candidate, "release_probe_dep", "2.0")
    _wheel(candidate, "godot_ai", "4.2.0", "release_probe_dep==2.0")
    old_wheel = _wheel(old, "godot_ai", "4.1.0", "release_probe_dep==1.0")
    predecessor.merge_dependency_files(
        candidate, predecessor.qualification.dependency_inventory(candidate), combined
    )
    predecessor.merge_dependency_files(
        old, predecessor.qualification.dependency_inventory(old), combined
    )
    before = support.inventory(combined)
    failed = tmp_path / "failed"
    failed.mkdir()
    with pytest.raises(support.ReleaseError, match="qualification command failed"):
        predecessor.offline_preflight(
            combined, "4.1.0", failed, failed, predecessor.qualification.dependency_inventory(old)
        )
    _wheel(old, "release_probe_dep", "1.0")
    predecessor.merge_dependency_files(
        old, predecessor.qualification.dependency_inventory(old), combined
    )
    assert all(support.fingerprint(combined / name) == digest for name, digest in before.items())
    assert support.fingerprint(combined / old_wheel.name) == support.fingerprint(old_wheel)
    for version, dependency in (("4.1.0", "1.0"), ("4.2.0", "2.0")):
        result = predecessor.offline_preflight(
            combined,
            version,
            tmp_path,
            tmp_path,
            predecessor.qualification.dependency_inventory(
                old if version == "4.1.0" else candidate
            ),
        )
        assert result["status"] == "passed"
        report = json.loads(
            (tmp_path / ("offline-" + version + ".json")).read_text(encoding="utf-8")
        )
        installed = {
            item["metadata"]["name"].replace("_", "-"): item["metadata"]["version"]
            for item in report["install"]
        }
        assert installed == {"godot-ai": version, "release-probe-dep": dependency}


@pytest.mark.parametrize("corruption", [None, "wheel", "dependency", "yanked"])
def test_resolve_predecessor_checks_public_bytes(monkeypatch, tmp_path, corruption):
    original = tmp_path / "public"
    wheel = _wheel(original / "dist", "godot_ai", "4.1.0", "release_probe_dep==1.0")
    expected = support.fingerprint(wheel)
    output = tmp_path / "output"
    output.mkdir()
    commands = []

    def execute(command, log, **kwargs):
        commands.append(command)
        packages = output / "predecessor-packages"
        (packages / wheel.name).write_bytes(wheel.read_bytes())
        dependency = _wheel(packages, "release_probe_dep", "1.0")
        metadata = {
            "urls": [
                {
                    "filename": dependency.name,
                    "url": "https://files.pythonhosted.org/" + dependency.name,
                    "size": dependency.stat().st_size,
                    "digests": {"sha256": support.fingerprint(dependency)["sha256"]},
                    "yanked": corruption == "yanked",
                }
            ]
        }
        if corruption == "dependency":
            metadata["urls"][0]["digests"]["sha256"] = "0" * 64
        monkeypatch.setattr(predecessor.public, "public_json", lambda _: metadata)

    monkeypatch.setattr(predecessor.qualification, "execute", execute)
    previous = {"version": "4.1.0", "files": {"dist/" + wheel.name: expected}}
    if corruption == "wheel":
        previous["files"]["dist/" + wheel.name] = {"size": 1, "sha256": "0" * 64}
    if corruption:
        with pytest.raises(support.ReleaseError):
            predecessor.retain_predecessor_dependencies(original, previous, output)
    else:
        rows = predecessor.retain_predecessor_dependencies(original, previous, output)
        assert {(row["name"], row["version"]) for row in rows} == {
            ("godot-ai", "4.1.0"),
            ("release-probe-dep", "1.0"),
        }
        assert commands[0][-1] == str(wheel)
        assert "--only-binary=:all:" in commands[0]


@pytest.mark.parametrize(
    "fault", ["missing_release", "unqualified_dependency", "wrong_hash", "wrong_version"]
)
def test_offline_resolution_cannot_install_outside_its_own_closure(fault):
    rows = [
        {
            "filename": "godot_ai-4.2.0-py3-none-any.whl",
            "name": "godot-ai",
            "version": "4.2.0",
            "sha256": "a" * 64,
        },
        {
            "filename": "dependency-1.0-py3-none-any.whl",
            "name": "dependency",
            "version": "1.0",
            "sha256": "b" * 64,
        },
    ]
    report = {
        "install": [
            {
                "metadata": {"name": row["name"], "version": row["version"]},
                "download_info": {
                    "url": "file:///packages/" + row["filename"],
                    "archive_info": {"hashes": {"sha256": row["sha256"]}},
                },
            }
            for row in rows
        ]
    }
    predecessor.verify_offline_resolution(report, rows, "4.2.0")
    if fault == "missing_release":
        report["install"].pop(0)
    elif fault == "unqualified_dependency":
        report["install"][1]["download_info"]["url"] = (
            "file:///packages/dependency-2.0-py3-none-any.whl"
        )
    elif fault == "wrong_hash":
        report["install"][1]["download_info"]["archive_info"]["hashes"]["sha256"] = "c" * 64
    else:
        report["install"][0]["metadata"]["version"] = "4.1.0"
    with pytest.raises(support.ReleaseError):
        predecessor.verify_offline_resolution(report, rows, "4.2.0")
