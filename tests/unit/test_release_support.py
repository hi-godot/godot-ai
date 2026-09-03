"""Adversarial tests for the artifact/approval boundary (no network or publishing)."""

from __future__ import annotations

import hashlib
import io
import json
import shutil
import tarfile
import zipfile
from pathlib import Path
from types import SimpleNamespace

import pytest

from script import release_promotion as promotion
from script import release_qualification as qualification
from script import release_support as support
from tests.unit.test_v4_release import _keys, _repository, _run, v4_release


@pytest.fixture(scope="module")
def signing_key(tmp_path_factory):
    return _keys(tmp_path_factory.mktemp("promotion-key"))


def distribution(root: Path, version: str) -> None:
    root.mkdir(parents=True)
    metadata = f"Metadata-Version: 2.1\nName: godot-ai\nVersion: {version}\n".encode()
    with zipfile.ZipFile(root / f"godot_ai-{version}-py3-none-any.whl", "w") as archive:
        archive.writestr(f"godot_ai-{version}.dist-info/METADATA", metadata)
    with tarfile.open(root / f"godot_ai-{version}.tar.gz", "w:gz") as archive:
        info = tarfile.TarInfo(f"godot_ai-{version}/PKG-INFO")
        info.size = len(metadata)
        archive.addfile(info, io.BytesIO(metadata))


@pytest.fixture
def pair(tmp_path, signing_key, monkeypatch):
    key, public = signing_key
    monkeypatch.setattr(v4_release, "PUBLIC_KEY_PEM", public)
    monkeypatch.setattr(v4_release._verify, "PUBLIC_KEY_PEM", public)
    monkeypatch.setattr(support, "verifier", lambda: v4_release._verify)
    repo, _ = _repository(tmp_path, public)
    readme = repo / "plugin/addons/godot_ai/README.md"
    readme.write_text("runtime-inert documentation\n")
    # Source pair checks use the production canonical version line format.
    (repo / "pyproject.toml").write_text('[project]\nname = "godot-ai"\nversion = "4.0.0"\n')
    _run("git", "add", ".", cwd=repo)
    _run("git", "commit", "-qm", "candidate A", cwd=repo)
    a = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    _run("git", "tag", "-d", "v4.0.0", cwd=repo)
    _run("git", "tag", "v4.0.0", cwd=repo)
    readme.unlink()
    for path in (repo / "pyproject.toml", repo / "plugin/addons/godot_ai/plugin.cfg"):
        path.write_text(
            path.read_text(encoding="utf-8").replace("4.0.0", "4.0.1"), encoding="utf-8"
        )
    _run("git", "add", ".", cwd=repo)
    _run("git", "commit", "-qm", "qualification B", cwd=repo)
    b = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    _run("git", "tag", "v4.0.1", cwd=repo)
    candidates = tmp_path / "candidates"
    for name, source, version in (("a", a, "4.0.0"), ("b", b, "4.0.1")):
        root = candidates / name
        _run("git", "switch", "--detach", source, cwd=repo)
        v4_release.build_release_set(
            repo, root / "release", key, "stable", "v" + version, version, source
        )
        distribution(root / "dist", version)
        for file in support.VERIFIER_PATHS:
            target = root / "verifier" / file
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(support.ROOT / file, target)
        record = support.candidate_record(root, name, source, version, a, "123", 1)
        (root / "evidence.json").write_bytes(support.canonical(record))
    return repo, candidates, a, b


def run_record(a):
    return {
        "id": 123,
        "run_attempt": 1,
        "status": "completed",
        "conclusion": "success",
        "path": support.QUALIFICATION_WORKFLOW,
        "event": "workflow_dispatch",
        "head_branch": "main",
        "head_sha": a,
        "repository": {"full_name": support.REPOSITORY},
        "head_repository": {"full_name": support.REPOSITORY},
    }


@pytest.mark.parametrize(
    ("previous", "bump", "expected"),
    [
        ("3.2.4", "major", "4.0.0"),
        ("4.0.0", "patch", "4.0.2"),
        ("4.0.2", "patch", "4.0.4"),
        ("4.1.0", "patch", "4.1.2"),
        ("5.0.0", "patch", "5.0.2"),
        ("4.0.2", "minor", "4.1.0"),
        ("4.1.3", "major", "5.0.0"),
    ],
)
def test_semantic_bumps_respect_burned_qualification_identity(previous, bump, expected):
    assert support.next_version(previous, bump) == expected


@pytest.mark.parametrize("value", ["v4.0.0", "4.0", "04.0.0", "4.0.0\n", "$(touch bad)", ""])
def test_versions_are_data_and_require_canonical_semver(value):
    with pytest.raises(support.ReleaseError):
        support.next_version(value, "patch")


@pytest.mark.parametrize("raw", [b'{"x":1,"x":2}', b'{"x":NaN}', b"not JSON"])
def test_strict_evidence_json(raw):
    with pytest.raises(support.ReleaseError):
        support.strict_json(raw)


def test_exact_signed_candidate_and_source_pair(pair):
    repo, candidates, a, b = pair
    support.validate_sources(repo, a, b, "4.0.0", "4.0.1")
    assert support.verify_candidate(candidates / "a", "a")["source"] == a
    assert support.verify_candidate(candidates / "b", "b")["source"] == b


@pytest.mark.parametrize(
    "mutation",
    [
        "extra",
        "missing",
        "tamper",
        "symlink",
        "traversal",
        "unknown-field",
        "wrong-candidate",
        "bool-schema",
    ],
)
def test_rejects_unapproved_candidate_files_and_evidence(pair, mutation, tmp_path):
    _, candidates, _, _ = pair
    root = candidates / "a"
    evidence = root / "evidence.json"
    record = support.read_json(evidence)
    if mutation == "extra":
        (root / "dist/unapproved.whl").write_bytes(b"unapproved")
    elif mutation == "missing":
        (root / "release/godot-ai-plugin.zip").unlink()
    elif mutation == "tamper":
        (root / "release/godot-ai-plugin.zip").write_bytes(b"tampered")
    elif mutation == "symlink":
        target = root / "dist/godot_ai-4.0.0-py3-none-any.whl"
        outside = tmp_path / "outside.whl"
        target.rename(outside)
        try:
            target.symlink_to(outside)
        except OSError:
            pytest.skip("host cannot create symlinks")
    else:
        if mutation == "traversal":
            record["files"]["../../outside"] = {"size": 1, "sha256": "a" * 64}
        elif mutation == "unknown-field":
            record["approved"] = True
        elif mutation == "wrong-candidate":
            record["candidate"] = "b"
        else:
            record["schema"] = True
        evidence.write_bytes(support.canonical(record))
    with pytest.raises((support.ReleaseError, v4_release.ReleaseError, zipfile.BadZipFile)):
        support.verify_candidate(root, "a")


def test_rehashed_forgery_still_fails_signature(pair):
    _, candidates, _, _ = pair
    root = candidates / "a"
    signature = root / "release/godot-ai-v4-plugin.manifest.sig"
    signature.write_bytes(b"0" * 512)
    record = support.read_json(root / "evidence.json")
    record["files"]["release/" + signature.name] = support.fingerprint(signature)
    (root / "evidence.json").write_bytes(support.canonical(record))
    with pytest.raises(v4_release.ReleaseError, match="signature"):
        support.verify_candidate(root, "a")


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("conclusion", "failure"),
        ("status", "in_progress"),
        ("path", ".github/workflows/ci.yml"),
        ("head_branch", "feature"),
        ("event", "pull_request"),
        ("run_attempt", 2),
        ("head_sha", "b" * 40),
        ("head_repository", {"full_name": "attacker/fork"}),
    ],
)
def test_rejects_failed_or_wrong_workflow_runs(field, value):
    record = run_record("a" * 40)
    support.validate_run(record, "a" * 40, "123", 1)
    record[field] = value
    with pytest.raises(support.ReleaseError):
        support.validate_run(record, "a" * 40, "123", 1)


def test_b_may_not_hide_a_runtime_change(pair):
    repo, _, a, _ = pair
    (repo / "plugin/addons/godot_ai/plugin.gd").write_text("@tool\nextends Node\n")
    _run("git", "add", ".", cwd=repo)
    _run("git", "commit", "--amend", "--no-edit", "-q", cwd=repo)
    b = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    with pytest.raises(support.ReleaseError, match="only change"):
        support.validate_sources(repo, a, b, "4.0.0", "4.0.1")


def test_b_must_be_immediate_child(pair):
    repo, _, a, _ = pair
    _run("git", "commit", "--allow-empty", "-qm", "extra commit", cwd=repo)
    b = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    with pytest.raises(support.ReleaseError, match="immediate"):
        support.validate_sources(repo, a, b, "4.0.0", "4.0.1")


@pytest.mark.parametrize("version", ["4.0.0", "4.0.2", "4.1.0", "5.0.0"])
def test_b_cannot_burn_an_arbitrary_future_release_identity(pair, version):
    repo, _, a, b = pair
    with pytest.raises(support.ReleaseError, match="following reserved patch"):
        support.validate_sources(repo, a, b, "4.0.0", version)


def test_distribution_rename_does_not_change_its_identity(tmp_path):
    distribution(tmp_path / "dist", "4.0.0")
    wheel = tmp_path / "dist/godot_ai-4.0.0-py3-none-any.whl"
    with pytest.raises(support.ReleaseError, match="identity"):
        support.check_distribution_metadata(wheel, "4.0.2")


def test_dependency_inventory_records_actual_wheel_bytes(tmp_path):
    distribution(tmp_path / "dist", "4.0.0")
    packages = tmp_path / "packages"
    packages.mkdir()
    name = "godot_ai-4.0.0-py3-none-any.whl"
    shutil.copyfile(tmp_path / "dist" / name, packages / name)
    assert qualification.dependency_inventory(packages) == [
        {
            "name": "godot-ai",
            "version": "4.0.0",
            "filename": name,
            **support.fingerprint(packages / name),
        }
    ]


def test_dependency_metadata_ignores_nested_vendor_dist_info(tmp_path):
    # setuptools ships vendored .dist-info directories as well as its own.
    packages = tmp_path / "packages"
    packages.mkdir()
    wheel = packages / "example-1.0-py3-none-any.whl"
    raw = b"Metadata-Version: 2.1\nName: Example\nVersion: 1.0\n"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr("example-1.0.dist-info/METADATA", raw)
        archive.writestr(
            "example/_vendor/other-2.0.dist-info/METADATA", b"Name: other\nVersion: 2.0\n"
        )
    assert support.wheel_metadata(wheel) == raw
    assert qualification.dependency_inventory(packages) == [
        {
            "name": "example",
            "version": "1.0",
            "filename": wheel.name,
            **support.fingerprint(wheel),
        }
    ]


@pytest.mark.parametrize("kind", ["missing", "duplicate", "oversized"])
def test_wheel_metadata_requires_one_bounded_top_level_identity(tmp_path, kind, monkeypatch):
    wheel = tmp_path / "example-1.0-py3-none-any.whl"
    with zipfile.ZipFile(wheel, "w") as archive:
        archive.writestr("example/vendor/other-2.0.dist-info/METADATA", "vendored")
        if kind != "missing":
            archive.writestr("example-1.0.dist-info/METADATA", "metadata")
        if kind == "duplicate":
            archive.writestr("other-2.0.dist-info/METADATA", "other")
    if kind == "oversized":
        monkeypatch.setattr(support, "MAX_JSON_BYTES", 4)
    with pytest.raises(support.ReleaseError, match="METADATA|bound"):
        support.wheel_metadata(wheel)


def test_pypi_resume_verifies_existing_bytes_and_uploads_only_missing(pair, monkeypatch, tmp_path):
    _, candidates, _, _ = pair
    record = support.verify_candidate(candidates / "a", "a")
    name = "godot_ai-4.0.0-py3-none-any.whl"
    expected = record["files"]["dist/" + name]
    metadata = {
        "urls": [
            {
                "filename": name,
                "size": expected["size"],
                "yanked": False,
                "digests": {"sha256": expected["sha256"]},
                "url": "https://files.pythonhosted.org/approved.whl",
            }
        ]
    }
    monkeypatch.setattr(promotion, "public_json", lambda *a, **kw: metadata)
    downloads = []
    monkeypatch.setattr(promotion, "verify_public_file", lambda *args: downloads.append(args))
    pending = tmp_path / "pending"
    promotion.pypi_preflight(candidates / "a", record, pending)
    assert set(support.inventory(pending)) == {"godot_ai-4.0.0.tar.gz"}
    assert downloads[0][1] == expected
    metadata["urls"][0]["digests"]["sha256"] = "0" * 64
    with pytest.raises(support.ReleaseError, match="does not match"):
        promotion.pypi_preflight(candidates / "a", record, tmp_path / "other")
    assert not (tmp_path / "other").exists()


def test_existing_tag_mismatch_refuses_before_writes(monkeypatch):
    calls = []

    def api(*args, **kwargs):
        calls.append(args)
        return {"object": {"type": "commit", "sha": "b" * 40}}

    monkeypatch.setattr(promotion, "gh", api)
    with pytest.raises(support.ReleaseError, match="tag"):
        promotion.github_preflight({"tag": "v4.0.0", "source": "a" * 40})
    assert len(calls) == 1 and "--method" not in calls[0]


def test_approval_repository_is_fixed_and_paths_reject_injection(monkeypatch):
    monkeypatch.setattr(promotion, "gh", lambda *args, **kw: pytest.fail("unexpected API call"))
    for path in ("../approval.json", "/approval.json", "a.json?ref=evil", "$(id).json"):
        with pytest.raises(support.ReleaseError):
            promotion.read_approval("a" * 40, path)
    assert support.ATTESTATION_REPOSITORY == "dsarno/godot-ai-release-attestations"


def test_incomplete_qualification_cannot_be_approved(pair, tmp_path):
    _, candidates, a, _ = pair
    evidence = tmp_path / "evidence"
    evidence.mkdir()
    (evidence / "qualification.json").write_bytes(support.canonical({"status": "passed"}))
    with pytest.raises(support.ReleaseError, match="complete qualification"):
        promotion.verify_approval(candidates, evidence, {}, run_record(a), "major", "3.2.4")


def test_download_verifies_bytes_not_just_registry_metadata(monkeypatch):
    class Response(io.BytesIO):
        url = "https://files.pythonhosted.org/file.whl"

    monkeypatch.setattr(promotion, "open_public_artifact", lambda *a, **kw: Response(b"forged"))
    with pytest.raises(support.ReleaseError, match="differs"):
        promotion.verify_public_file(
            Response.url,
            {"size": 6, "sha256": hashlib.sha256(b"actual").hexdigest()},
            {"files.pythonhosted.org"},
        )


@pytest.mark.parametrize(
    "url",
    [
        "http://files.pythonhosted.org/file",
        "https://files.pythonhosted.org.evil.test/file",
        "https://user@files.pythonhosted.org/file",
        "https://files.pythonhosted.org:444/file",
        "https://files.pythonhosted.org/file#fragment",
        "https://files.pythonhosted.org/file\n",
        "https://127.0.0.1/file",
    ],
)
def test_redirect_refuses_untrusted_destination_before_network(url):
    handler = promotion.PublicArtifactRedirect({"files.pythonhosted.org"})
    request = promotion.urllib.request.Request("https://files.pythonhosted.org/original")
    with pytest.raises(support.ReleaseError):
        handler.redirect_request(request, None, 302, "Found", {}, url)


def test_public_download_permits_only_verified_https_redirect(monkeypatch):
    hosts = {"files.pythonhosted.org"}
    handler = promotion.PublicArtifactRedirect(hosts)
    request = promotion.urllib.request.Request("https://files.pythonhosted.org/original")
    target = "https://files.pythonhosted.org:443/file"
    assert handler.redirect_request(request, None, 302, "Found", {}, target).full_url == target
    opened = []
    monkeypatch.setattr(
        promotion.urllib.request,
        "build_opener",
        lambda redirect: SimpleNamespace(open=lambda url, **kw: opened.append((url, kw))),
    )
    promotion.open_public_artifact(target, hosts)
    assert opened == [(target, {"timeout": 120})]


@pytest.mark.parametrize("payload,size", [(b"exact", 5), (b"oversize", 3)])
def test_public_download_checks_stream_size(monkeypatch, payload, size):
    class Response(io.BytesIO):
        url = "https://files.pythonhosted.org/file.whl"

    monkeypatch.setattr(promotion, "open_public_artifact", lambda *args: Response(payload))
    expected = {"size": size, "sha256": hashlib.sha256(payload).hexdigest()}
    if len(payload) == size:
        promotion.verify_public_file(Response.url, expected, {"files.pythonhosted.org"})
    else:
        with pytest.raises(support.ReleaseError, match="oversized"):
            promotion.verify_public_file(Response.url, expected, {"files.pythonhosted.org"})


def test_registry_json_uses_same_pre_redirect_trust_boundary(monkeypatch):
    class Response(io.BytesIO):
        url = "https://pypi.org/pypi/godot-ai/4.0.0/json"

    calls = []

    def open_response(url, hosts):
        calls.append((url, hosts))
        return Response(b'{"urls":[]}')

    monkeypatch.setattr(promotion, "open_public_artifact", open_response)
    assert promotion.public_json(Response.url) == {"urls": []}
    assert calls == [(Response.url, {"pypi.org"})]
    Response.url = "https://untrusted.example/json"
    with pytest.raises(support.ReleaseError, match="untrusted"):
        promotion.public_json("https://pypi.org/pypi/godot-ai/4.0.0/json")


@pytest.mark.parametrize("status,allow_missing", [(404, True), (404, False), (403, True)])
def test_registry_json_treats_only_explicit_404_as_absent(monkeypatch, status, allow_missing):
    error = promotion.urllib.error.HTTPError("https://pypi.org/", status, "failure", {}, None)

    def fail(*args):
        raise error

    monkeypatch.setattr(promotion, "open_public_artifact", fail)
    if status == 404 and allow_missing:
        assert promotion.public_json("https://pypi.org/", allow_missing=True) is None
    else:
        with pytest.raises(promotion.urllib.error.HTTPError):
            promotion.public_json("https://pypi.org/", allow_missing=allow_missing)


@pytest.mark.parametrize("tamper", [False, True])
def test_documented_installer_is_executed_with_exact_identity_and_tree(
    pair, tmp_path, monkeypatch, tamper
):
    _, candidates, _, _ = pair
    root = candidates / "b"
    record = support.verify_candidate(root, "b")
    work = tmp_path / "documented-install"
    environment = {"GODOT_AI_QUALIFICATION_PYTHON_INDEX": "1"}
    calls = []

    def install(command, log, *, cwd, environment):
        calls.append((command, cwd, environment))
        assert command[:3] == [
            qualification.sys.executable,
            str(support.ROOT / "script/v4-release"),
            "install",
        ]
        assert command[-1] == "--editors-closed"
        args = dict(zip(command[3:-1:2], command[4:-1:2], strict=True))
        assert args == {
            "--archive": str(root / "release/godot-ai-v4-plugin.zip"),
            "--manifest": str(root / "release/godot-ai-v4-plugin.manifest.json"),
            "--signature": str(root / "release/godot-ai-v4-plugin.manifest.sig"),
            "--expected-repository": support.REPOSITORY,
            "--expected-channel": "stable",
            "--expected-tag": record["tag"],
            "--expected-version": record["version"],
            "--expected-source": record["source"],
            "--project-root": str(work / "project"),
            "--recovery-root": str(work / "recovery"),
        }
        assert (work / "project/project.godot").read_text(encoding="utf-8") == "config_version=5\n"
        with zipfile.ZipFile(args["--archive"]) as archive:
            archive.extractall(work / "project")
        if tamper:
            (work / "project/unapproved.txt").write_text("unapproved bytes")

    monkeypatch.setattr(qualification, "execute", install)
    if tamper:
        with pytest.raises(support.ReleaseError, match="different tree"):
            qualification.closed_install(root, record, work, tmp_path / "log", environment)
    else:
        result = qualification.closed_install(root, record, work, tmp_path / "log", environment)
        assert result["status"] == "passed" and result["managed_tree"]
    assert len(calls) == 1 and calls[0][1:] == (work, environment)


def test_noncanonical_approval_is_rejected(pair, tmp_path):
    _, candidates, _, _ = pair
    path = candidates / "a/evidence.json"
    record = support.read_json(path)
    path.write_text(json.dumps(record, indent=2))
    with pytest.raises(support.ReleaseError, match="non-canonical"):
        support.verify_candidate(path.parent, "a")


def test_signer_signs_prebuilt_git_bound_bytes_without_checking_out_b(
    pair, signing_key, monkeypatch, tmp_path
):
    repo, candidates, a, b = pair
    _run("git", "switch", "--detach", a, cwd=repo)
    root = tmp_path / "unsigned-b"
    release = root / "release"
    release.mkdir(parents=True)
    for name in (v4_release.ASSET_NAME, v4_release.MANIFEST_NAME):
        shutil.copyfile(candidates / "b/release" / name, release / name)
    before = support.inventory(release)
    monkeypatch.setattr(support, "release_producer", lambda: v4_release)
    support.sign_candidate(root, repo, b, "4.0.1", signing_key[0])
    support.verify_signed_assets(release, {"tag": "v4.0.1", "source": b, "version": "4.0.1"})
    assert set(support.inventory(release)) == support.RELEASE_NAMES
    assert all(support.fingerprint(release / name) == digest for name, digest in before.items())
    assert support.git(repo, "rev-parse", "HEAD").decode().strip() == a


@pytest.mark.parametrize(
    "mutation",
    [
        "wrong-workflow",
        "failed-job",
        "skipped-job",
        "missing-gate",
        "empty",
        "invalid-attempt",
        "invalid-source",
    ],
)
def test_provenance_rejects_wrong_run_before_any_artifact_use(monkeypatch, mutation):
    run = run_record("a" * 40)
    jobs = [
        {
            "name": "Require complete release evidence",
            "status": "completed",
            "conclusion": "success",
        }
    ]
    if mutation == "wrong-workflow":
        run["path"] = ".github/workflows/ci.yml"
    elif mutation == "invalid-attempt":
        run["run_attempt"] = True
    elif mutation == "invalid-source":
        run["head_sha"] = "main"
    elif mutation == "missing-gate":
        jobs[0]["name"] = "install smoke"
    elif mutation == "empty":
        jobs.clear()
    else:
        jobs[0]["conclusion"] = "failure" if mutation == "failed-job" else "skipped"
    calls = []

    def api(path):
        calls.append(path)
        return {"jobs": jobs, "total_count": len(jobs)} if "/jobs?" in path else run

    monkeypatch.setattr(promotion, "gh", api)
    with pytest.raises(support.ReleaseError):
        promotion.check_run_provenance("123")
    assert all("artifacts" not in path for path in calls)


def test_provenance_checks_every_page_of_jobs(monkeypatch):
    run = run_record("a" * 40)
    calls = []

    def api(path):
        calls.append(path)
        if "/jobs?" not in path:
            return run
        if path.endswith("page=1"):
            return {
                "total_count": 101,
                "jobs": [
                    {
                        "name": "Require complete release evidence",
                        "status": "completed",
                        "conclusion": "success",
                    }
                ]
                * 100,
            }
        return {"total_count": 101, "jobs": [{"status": "completed", "conclusion": "failure"}]}

    monkeypatch.setattr(promotion, "gh", api)
    with pytest.raises(support.ReleaseError, match="every qualification job"):
        promotion.check_run_provenance("123")
    assert len(calls) == 3 and calls[-1].endswith("page=2")


def test_approval_read_uses_only_canonical_repository_commit_and_file(monkeypatch):
    import base64

    calls = []
    raw = support.canonical({"schema": 2})

    def api(path):
        calls.append(path)
        if "/compare/" in path:
            return {"status": "ahead"}
        return {
            "type": "file",
            "encoding": "base64",
            "size": len(raw),
            "content": base64.b64encode(raw).decode(),
        }

    monkeypatch.setattr(promotion, "gh", api)
    assert promotion.read_approval("a" * 40, "releases/v4-0-0.json") == {"schema": 2}
    assert all(path.startswith("repos/dsarno/godot-ai-release-attestations/") for path in calls)
    assert calls[-1].endswith("?ref=" + "a" * 40)


@pytest.mark.parametrize("status", ["behind", "diverged"])
def test_approval_must_belong_to_attestation_main(monkeypatch, status):
    monkeypatch.setattr(promotion, "gh", lambda *args: {"status": status})
    with pytest.raises(support.ReleaseError, match="not on canonical"):
        promotion.read_approval("a" * 40, "approval.json")


@pytest.mark.parametrize("existing_count", [0, 1, 6])
def test_github_publication_resumes_without_clobber_or_rebuilding(
    pair, monkeypatch, existing_count
):
    _, candidates, _, _ = pair
    record = support.verify_candidate(candidates / "a", "a")
    names = sorted(support.RELEASE_NAMES)
    assets = [
        {
            "name": name,
            "size": record["files"]["release/" + name]["size"],
            "digest": "sha256:" + record["files"]["release/" + name]["sha256"],
            "browser_download_url": "https://github.com/hi-godot/godot-ai/releases/download/v4.0.0/"
            + name,
        }
        for name in names
    ]
    state = {
        "tag": existing_count > 0,
        "release": None
        if existing_count == 0
        else {"id": 123, "draft": True, "prerelease": False, "assets": assets[:existing_count]},
    }
    events = []

    def api(*args, **kwargs):
        events.append(args)
        if args[:2] == ("--method", "POST"):
            if args[2].endswith("/git/refs"):
                state["tag"] = True
                return {}
            state["release"] = {"id": 123, "draft": True, "prerelease": False, "assets": []}
            return state["release"]
        if args[:2] == ("--method", "PATCH"):
            state["release"]["draft"] = False
            return state["release"]
        if "/git/ref/" in args[0]:
            return (
                {
                    "object": {
                        "type": "commit",
                        "sha": record["source"],
                        "url": f"https://api.github.com/repos/{support.REPOSITORY}/git/commits/{record['source']}",
                    }
                }
                if state["tag"]
                else None
            )
        return state["release"]

    def upload(command, **kwargs):
        events.append(tuple(command))
        assert command[:3] == ["gh", "release", "upload"]
        assert "--clobber" not in command
        assert {Path(name).name for name in command[6:]} == set(names[existing_count:])
        state["release"]["assets"] = assets
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(promotion, "gh", api)
    monkeypatch.setattr(promotion, "verify_pypi", lambda record: events.append(("pypi-verified",)))
    monkeypatch.setattr(promotion.subprocess, "run", upload)
    downloads = []
    monkeypatch.setattr(promotion, "verify_public_file", lambda *args: downloads.append(args))
    assert set(promotion.publish_github(candidates / "a", record)) == support.RELEASE_NAMES
    assert events[0] == ("pypi-verified",)
    assert not state["release"]["draft"]
    assert len(downloads) == 6


@pytest.mark.parametrize(
    "code,stderr,missing", [(0, b"", False), (1, b"HTTP 404", True), (1, b"HTTP 403", True)]
)
def test_github_api_errors_are_not_silently_missing(monkeypatch, code, stderr, missing):
    monkeypatch.setattr(
        promotion.subprocess,
        "run",
        lambda *args, **kwargs: SimpleNamespace(
            returncode=code, stderr=stderr, stdout=b'{"ok":true}'
        ),
    )
    if code and stderr != b"HTTP 404":
        with pytest.raises(support.ReleaseError):
            promotion.gh("repos/hi-godot/godot-ai", allow_missing=missing)
    else:
        assert promotion.gh("repos/hi-godot/godot-ai", allow_missing=missing) == (
            None if code else {"ok": True}
        )


def test_package_rejects_wrong_head_before_building(pair, tmp_path):
    repo, _, a, _ = pair
    with pytest.raises(support.ReleaseError, match="checkout differs"):
        support.package_candidate(tmp_path / "output", repo, a, "4.0.0")


def test_qualification_command_records_failure_and_command(tmp_path):
    log = tmp_path / "failure.log"
    with pytest.raises(support.ReleaseError, match="command failed"):
        qualification.execute(["git", "not-a-real-command"], log, cwd=tmp_path, environment={})
    assert b'"command":["git","not-a-real-command"]' in log.read_bytes()


def test_promotion_preflight_refuses_without_ever_using_a_publishing_command(monkeypatch):
    calls = []

    def failed_run(run_id):
        calls.append(run_id)
        raise support.ReleaseError("run did not qualify")

    monkeypatch.setattr(promotion, "check_run_provenance", failed_run)
    monkeypatch.setattr(promotion, "publish_github", lambda *args: pytest.fail("unexpected write"))
    assert promotion.main(["github", "--run-id", "123"]) == 1
    assert calls == ["123"]


def test_incomplete_qualification_producers_block_before_signing():
    with pytest.raises(support.ReleaseError, match="failpoints, runtime, stress"):
        qualification.preflight()
    assert qualification.main(["--preflight"]) == 1


def test_loaders_use_trusted_checkout_not_downloaded_candidate():
    assert Path(support.verifier().__file__).resolve() == support.ROOT / support.VERIFIER_PATHS[1]
    assert Path(support.release_producer().__file__).resolve() == support.ROOT / "script/v4-release"


@pytest.mark.parametrize("tag_state", ["missing", "matching", "wrong"])
def test_packager_only_creates_local_matching_tags_and_builds_without_signing(
    tmp_path, monkeypatch, tag_state
):
    repo = tmp_path / "repo"
    repo.mkdir()
    _run("git", "init", "-q", cwd=repo)
    _run("git", "config", "user.email", "fixture@example.invalid", cwd=repo)
    _run("git", "config", "user.name", "Fixture", cwd=repo)
    (repo / "pyproject.toml").write_text('[project]\nversion = "4.0.0"\n')
    for path in support.VERIFIER_PATHS:
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("trusted source verifier\n")
    _run("git", "add", ".", cwd=repo)
    _run("git", "commit", "-qm", "source", cwd=repo)
    source = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    if tag_state != "missing":
        _run("git", "tag", "v4.0.0", cwd=repo)
    if tag_state == "wrong":
        _run("git", "commit", "--allow-empty", "-qm", "different source", cwd=repo)
        source = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    commands = []
    actual_run = support.subprocess.run

    def build(command, **kwargs):
        commands.append(command)
        if command[0] == "git":
            return actual_run(command, **kwargs)
        return SimpleNamespace(returncode=0)

    monkeypatch.setattr(support.subprocess, "run", build)
    output = tmp_path / "candidate"
    if tag_state == "wrong":
        with pytest.raises(support.ReleaseError, match="local tag"):
            support.package_candidate(output, repo, source, "4.0.0")
        assert not output.exists()
        assert all(command[0] == "git" for command in commands)
        return
    support.package_candidate(output, repo, source, "4.0.0")
    assert _run("git", "rev-parse", "v4.0.0", cwd=repo).decode().strip() == source
    assert not any("push" in command or "sign" in command for command in commands)
    builders = [command for command in commands if command[0] != "git"]
    assert len(builders) == 2
    assert builders[0][1:3] == [str(support.ROOT / "script/v4-release"), "package"]
    assert builders[0][-2:] == ["--source-commit", source]
    assert builders[1] == [support.sys.executable, "-m", "build", "--outdir", str(output / "dist")]
    for path in support.VERIFIER_PATHS:
        assert (output / "verifier" / path).read_text(
            encoding="utf-8"
        ) == "trusted source verifier\n"


def test_support_cli_routes_real_source_validation_verification_and_sealing(pair, capsys):
    repo, candidates, a, b = pair
    assert support.main(["next-version", "--previous", "3.2.4", "--bump", "major"]) == 0
    assert capsys.readouterr().out == "4.0.0\n"
    assert (
        support.main(
            [
                "validate-sources",
                "--repo",
                str(repo),
                "--a",
                a,
                "--b",
                b,
                "--version-a",
                "4.0.0",
                "--version-b",
                "4.0.1",
            ]
        )
        == 0
    )
    root = candidates / "a"
    assert support.main(["verify", "--root", str(root), "--candidate", "a"]) == 0
    original = (root / "evidence.json").read_bytes()
    (root / "evidence.json").unlink()
    args = [
        "seal",
        "--root",
        str(root),
        "--candidate",
        "a",
        "--source",
        a,
        "--version",
        "4.0.0",
        "--workflow-sha",
        a,
        "--run-id",
        "123",
        "--run-attempt",
        "1",
    ]
    assert support.main(args) == 0
    assert (root / "evidence.json").read_bytes() == original
    assert support.main(args) == 1  # Never overwrite a retained candidate record.
    assert (root / "evidence.json").read_bytes() == original


@pytest.mark.parametrize("command", ["package", "sign"])
def test_support_cli_passes_validated_data_to_the_correct_operation(monkeypatch, tmp_path, command):
    calls = []
    monkeypatch.setattr(support, command + "_candidate", lambda *args: calls.append(args))
    root, repo, key = tmp_path / "output", tmp_path / "source", tmp_path / "key"
    args = [
        command,
        "--root",
        str(root),
        "--repo",
        str(repo),
        "--source",
        "a" * 40,
        "--version",
        "4.0.0",
    ]
    if command == "sign":
        args += ["--key", str(key)]
    assert support.main(args) == 0
    assert calls == [(root, repo, "a" * 40, "4.0.0", *([key] if command == "sign" else []))]


@pytest.mark.parametrize("complete", [False, True])
def test_qualification_cli_cannot_report_success_for_incomplete_rows(pair, tmp_path, complete):
    _, candidates, _, _ = pair
    output = tmp_path / "qualification"
    output.mkdir()
    args = ["--candidates", str(candidates), "--output", str(output)]
    if complete:
        args.append("--complete")
    assert qualification.main(args) == 1
    assert not (output / "qualification.json").exists()


@pytest.mark.parametrize("fail", [False, True])
def test_candidate_b_tests_use_their_own_immutable_source_and_cleanup(pair, tmp_path, fail):
    import os

    repo, _, _, b = pair
    target = tmp_path / "b-test-source"

    def exercise():
        with qualification.candidate_test_source(
            repo, b, target, tmp_path / "test-source.log", dict(os.environ)
        ) as test_source:
            assert test_source == target
            assert support.git(test_source, "rev-parse", "HEAD").decode().strip() == b
            assert 'version = "4.0.1"' in (test_source / "pyproject.toml").read_text(
                encoding="utf-8"
            )
            (test_source / "test-generated.txt").write_text(
                "disposable fixture\n", encoding="utf-8"
            )
            if fail:
                raise RuntimeError("simulated candidate test failure")

    if fail:
        with pytest.raises(RuntimeError, match="simulated"):
            exercise()
    else:
        exercise()
    assert not target.exists()
    assert str(target).encode() not in support.git(repo, "worktree", "list", "--porcelain")


def test_candidate_test_checkout_never_reuses_an_existing_directory(pair, tmp_path):
    repo, _, _, b = pair
    sentinel = tmp_path / "keep.txt"
    sentinel.write_text("keep", encoding="utf-8")
    with pytest.raises(support.ReleaseError, match="already exists"):
        with qualification.candidate_test_source(repo, b, tmp_path, tmp_path / "log", {}):
            pytest.fail("existing directory was reused")
    assert sentinel.read_text(encoding="utf-8") == "keep"


@pytest.fixture
def approval_boundary(pair, tmp_path, monkeypatch):
    """Isolate approval serialization from the separately fail-closed matrix.

    Only this test's matrix validator is stubbed. Candidate signatures,
    inventories, run binding and approval equality still use real validation.
    Nothing created here is release evidence or leaves the disposable fixture.
    """
    _, candidates, a, _ = pair
    output = tmp_path / "qualification-evidence"
    output.mkdir()
    (output / "proof.txt").write_text("test-only matrix stand-in\n", encoding="utf-8")
    bindings = {
        name: support.fingerprint(candidates / name / "evidence.json") for name in ("a", "b")
    }

    def validate(root, expected):
        assert root == output and expected == bindings
        return {}

    monkeypatch.setattr(qualification, "validate_rows", validate)
    monkeypatch.setattr(promotion, "validate_rows", validate)
    qualification.complete(candidates, output)
    run = run_record(a)
    approval = promotion.approval_payload(candidates, output, run, "major", "3.2.4")
    return candidates, output, run, approval


def test_approval_contains_exact_full_objects_and_rejects_any_mutation(approval_boundary):
    candidates, output, run, approval = approval_boundary
    for name in ("a", "b"):
        assert approval["candidates"][name] == support.read_json(
            candidates / name / "evidence.json"
        )
    expected = approval["candidates"]["a"]
    assert (
        promotion.verify_approval(candidates, output, approval, run, "major", "3.2.4") == expected
    )
    for key, value in (
        ("repository", "other/repository"),
        ("previous_version", "3.2.3"),
        ("bump", "minor"),
        ("qualification", {}),
        ("extra", True),
    ):
        with pytest.raises(support.ReleaseError, match="does not name"):
            promotion.verify_approval(
                candidates, output, {**approval, key: value}, run, "major", "3.2.4"
            )
    (output / "proof.txt").write_text("changed bytes\n", encoding="utf-8")
    with pytest.raises(support.ReleaseError, match="has changed"):
        promotion.verify_approval(candidates, output, approval, run, "major", "3.2.4")


def test_approval_draft_cli_writes_once_without_publishing(
    approval_boundary, tmp_path, monkeypatch
):
    candidates, output, run, approval = approval_boundary
    monkeypatch.setattr(promotion, "check_run_provenance", lambda run_id: run)
    monkeypatch.setattr(
        promotion, "publish_github", lambda *_: pytest.fail("unexpected publication")
    )
    destination = tmp_path / "approval.json"
    args = [
        "make-approval",
        "--root",
        str(candidates),
        "--evidence",
        str(output),
        "--run-id",
        "123",
        "--bump",
        "major",
        "--previous",
        "3.2.4",
        "--output",
        str(destination),
    ]
    assert promotion.main(args) == 0
    assert destination.read_bytes() == support.canonical(approval)
    assert promotion.main(args) == 1
    assert destination.read_bytes() == support.canonical(approval)


@pytest.mark.parametrize("command", ["verify", "pypi-preflight", "verify-pypi", "github"])
def test_every_promotion_cli_revalidates_approval_before_any_write(
    approval_boundary, tmp_path, monkeypatch, command
):
    candidates, output, run, approval = approval_boundary
    monkeypatch.chdir(tmp_path)
    events = []
    monkeypatch.setattr(promotion, "check_run_provenance", lambda run_id: run)
    monkeypatch.setattr(promotion, "read_approval", lambda *args: approval)
    actual_verify = promotion.verify_approval

    def verify(*args):
        result = actual_verify(*args)
        events.append("approval-verified")
        return result

    def github_preflight(record):
        assert events == ["approval-verified"]
        events.append("github-preflight")

    def pypi_preflight(candidate, record, pending):
        assert events == ["approval-verified", "github-preflight"]
        events.append("pypi-preflight")
        pending.mkdir()
        shutil.copyfile(next((candidate / "dist").glob("*.whl")), pending / "candidate.whl")
        return {}

    def publish(*args):
        assert events == ["approval-verified", "github-preflight"]
        events.append("github-publish")
        return {}

    monkeypatch.setattr(promotion, "verify_approval", verify)
    monkeypatch.setattr(promotion, "github_preflight", github_preflight)
    monkeypatch.setattr(promotion, "pypi_preflight", pypi_preflight)
    monkeypatch.setattr(promotion, "verify_pypi", lambda *_: {"verified": True})
    monkeypatch.setattr(promotion, "publish_github", publish)
    monkeypatch.setenv("GITHUB_OUTPUT", str(tmp_path / "step-output"))
    result = tmp_path / "result.json"
    args = [
        command,
        "--root",
        str(candidates),
        "--evidence",
        str(output),
        "--run-id",
        "123",
        "--bump",
        "major",
        "--previous",
        "3.2.4",
        "--approval-commit",
        "c" * 40,
        "--approval-path",
        "releases/v4-0-0.json",
        "--output",
        str(result),
    ]
    assert promotion.main(args) == 0
    report = support.read_json(result)
    assert report["source"] == run["head_sha"] and report["approval_commit"] == "c" * 40
    if command == "pypi-preflight":
        assert (tmp_path / "step-output").read_text(encoding="utf-8") == "pending=true\n"
    events.clear()
    approval["bump"] = "minor"
    assert promotion.main(args) == 1
    assert events == []  # No preflight mutation or publication after refusal.


def test_verify_pypi_requires_both_unyanked_exact_public_files(pair, monkeypatch):
    _, candidates, _, _ = pair
    record = support.verify_candidate(candidates / "a", "a")
    rows = [
        {"filename": name, "url": "https://files.pythonhosted.org/" + name, "yanked": False}
        for name in sorted(support.distribution_names(record["version"]))
    ]
    monkeypatch.setattr(promotion, "public_json", lambda *_: {"urls": rows})
    downloads = []
    monkeypatch.setattr(promotion, "verify_public_file", lambda *args: downloads.append(args))
    result = promotion.verify_pypi(record)
    assert set(result) == support.distribution_names(record["version"])
    assert downloads == [
        (row["url"], record["files"]["dist/" + row["filename"]], {"files.pythonhosted.org"})
        for row in rows
    ]
    rows[0]["yanked"] = True
    with pytest.raises(support.ReleaseError, match="yanked"):
        promotion.verify_pypi(record)
    rows.pop()
    with pytest.raises(support.ReleaseError, match="inventory"):
        promotion.verify_pypi(record)
