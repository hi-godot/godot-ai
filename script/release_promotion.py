"""Approve and resume publication of immutable release artifacts.

GitHub credentials are used only through gh. PyPI/public asset downloads never
receive those credentials. Each publishing job repeats verification before a
write; neither downloads nor executes candidate Python code.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

from script import release_support as support
from script.release_qualification import validate_rows


def gh(*args: str, allow_missing: bool = False) -> Any:
    result = subprocess.run(["gh", "api", *args], capture_output=True, check=False)
    if result.returncode:
        if allow_missing and b"HTTP 404" in result.stderr:
            return None
        raise support.ReleaseError("GitHub API request failed: " + result.stderr.decode())
    return support.strict_json(result.stdout)


def public_json(url: str, *, allow_missing: bool = False) -> Any:
    try:
        with open_public_artifact(url, {"pypi.org"}) as response:
            validate_public_url(response.url, {"pypi.org"})
            return support.strict_json(response.read(support.MAX_JSON_BYTES + 1))
    except urllib.error.HTTPError as exc:
        if exc.code == 404 and allow_missing:
            return None
        raise


def validate_public_url(url: str, hosts: set[str]) -> None:
    parsed = urllib.parse.urlsplit(url)
    support.require(
        parsed.scheme == "https"
        and parsed.hostname in hosts
        and parsed.username is None
        and parsed.password is None
        and parsed.port in {None, 443}
        and not parsed.fragment
        and not any(ord(character) <= 32 or ord(character) == 127 for character in url),
        "untrusted public artifact URL",
    )


class PublicArtifactRedirect(urllib.request.HTTPRedirectHandler):
    """Check each redirect before connecting, not after following it."""

    def __init__(self, hosts: set[str]):
        self.hosts = hosts

    def redirect_request(self, request, response, code, message, headers, newurl):
        validate_public_url(newurl, self.hosts)
        return super().redirect_request(request, response, code, message, headers, newurl)


def open_public_artifact(url: str, hosts: set[str]):
    validate_public_url(url, hosts)
    return urllib.request.build_opener(PublicArtifactRedirect(hosts)).open(url, timeout=120)


def verify_public_file(url: str, expected: dict[str, Any], hosts: set[str]) -> None:
    digest, size = hashlib.sha256(), 0
    with open_public_artifact(url, hosts) as response:
        # GitHub release URLs redirect to its signed asset CDN. Neither request
        # carries a token; reject destinations outside the public delivery roots.
        validate_public_url(response.url, hosts)
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            support.require(size <= expected["size"], "public artifact is oversized")
            digest.update(chunk)
    support.require(
        {"size": size, "sha256": digest.hexdigest()} == expected,
        "public artifact differs from approved bytes",
    )


def read_approval(commit: str, path: str) -> dict[str, Any]:
    support.require(support.SHA.fullmatch(commit), "approval must use a full commit SHA")
    support.require(
        re.fullmatch(r"[A-Za-z0-9_-]+(?:/[A-Za-z0-9_-]+)*\.json", path), "invalid approval path"
    )
    base = f"repos/{support.ATTESTATION_REPOSITORY}"
    comparison = gh(f"{base}/compare/{commit}...main")
    support.require(
        comparison.get("status") in {"ahead", "identical"},
        "approval commit is not on canonical attestation main",
    )
    entry = gh(f"{base}/contents/{path}?ref={commit}")
    support.require(
        entry.get("type") == "file"
        and entry.get("encoding") == "base64"
        and entry.get("size", 0) <= support.MAX_JSON_BYTES,
        "approval is not a bounded repository file",
    )
    import base64

    raw = base64.b64decode(entry["content"], validate=False)
    record = support.strict_json(raw)
    support.require(raw == support.canonical(record), "approval must be canonical JSON")
    return record


def check_run_provenance(run_id: str) -> dict[str, Any]:
    """Reject wrong/red runs before any cross-run artifact download."""
    support.require(re.fullmatch(r"[1-9][0-9]*", run_id), "invalid run ID")
    base = f"repos/{support.REPOSITORY}/actions/runs/{run_id}"
    run = gh(base)
    support.require(
        isinstance(run.get("head_sha"), str) and support.SHA.fullmatch(run["head_sha"]),
        "invalid workflow source",
    )
    support.validate_run(run, run["head_sha"], run_id, run.get("run_attempt"))
    jobs, page = [], 1
    while True:
        result = gh(f"{base}/attempts/{run['run_attempt']}/jobs?per_page=100&page={page}")
        batch = result.get("jobs", [])
        jobs.extend(batch)
        support.require(len(jobs) <= 1000, "unexpected qualification job count")
        if len(jobs) >= result.get("total_count", 0):
            break
        support.require(batch, "incomplete qualification job response")
        page += 1
    support.require(
        jobs
        and all(
            job.get("status") == "completed" and job.get("conclusion") == "success" for job in jobs
        ),
        "every qualification job must succeed",
    )
    support.require(
        any(job.get("name") == "Require complete release evidence" for job in jobs),
        "complete qualification gate did not run",
    )
    return run


def approval_payload(
    root: Path,
    evidence_root: Path,
    run: dict[str, Any],
    bump: str,
    previous: str,
) -> dict[str, Any]:
    candidates = {name: support.verify_candidate(root / name, name) for name in ("a", "b")}
    a, b = candidates["a"], candidates["b"]
    support.require(a["source"] == a["workflow_sha"], "A must be the reviewed workflow source")
    for key in ("workflow_sha", "run_id", "run_attempt"):
        support.require(a[key] == b[key], "A and B come from different qualification runs")
    support.validate_run(run, a["workflow_sha"], a["run_id"], a["run_attempt"])
    support.require(
        a["version"] == support.next_version(previous, bump),
        "candidate A does not match requested bump",
    )
    evidence = support.inventory(evidence_root)
    qualification = support.read_json(evidence_root / "qualification.json")
    expected_qualification = {
        "schema": 2,
        "status": "qualified",
        "required_skips": 0,
        "run_id": a["run_id"],
        "run_attempt": a["run_attempt"],
        "workflow_sha": a["workflow_sha"],
        "candidates": {
            name: support.fingerprint(root / name / "evidence.json") for name in ("a", "b")
        },
        "files": {name: meta for name, meta in evidence.items() if name != "qualification.json"},
    }
    support.require(
        support.canonical(qualification) == support.canonical(expected_qualification),
        "complete qualification evidence is missing or has changed",
    )
    validate_rows(evidence_root, qualification["candidates"])
    return {
        "schema": 2,
        "repository": support.REPOSITORY,
        "bump": bump,
        "previous_version": previous,
        "candidates": candidates,
        "qualification": evidence,
    }


def verify_approval(
    root: Path,
    evidence_root: Path,
    approval: dict[str, Any],
    run: dict[str, Any],
    bump: str,
    previous: str,
) -> dict[str, Any]:
    expected = approval_payload(root, evidence_root, run, bump, previous)
    support.require(
        support.canonical(approval) == support.canonical(expected),
        "approval does not name this exact candidate and qualification evidence set",
    )
    return expected["candidates"]["a"]


def pypi_preflight(candidate: Path, record: dict[str, Any], pending: Path) -> dict[str, Any]:
    """Resume after partial upload, but only when existing public bytes match."""
    support.require(not pending.exists(), "pending upload directory already exists")
    names = support.distribution_names(record["version"])
    metadata = public_json(
        f"https://pypi.org/pypi/godot-ai/{record['version']}/json", allow_missing=True
    )
    urls = metadata.get("urls", []) if metadata is not None else []
    existing = {row["filename"]: row for row in urls}
    support.require(
        len(existing) == len(urls) and set(existing) <= names,
        "PyPI version contains unexpected or duplicate files",
    )
    verified = {}
    for name, row in existing.items():
        expected = record["files"][f"dist/{name}"]
        support.require(
            row.get("digests", {}).get("sha256") == expected["sha256"]
            and row.get("size") == expected["size"]
            and not row.get("yanked"),
            "existing PyPI distribution does not match approval",
        )
        verify_public_file(row["url"], expected, {"files.pythonhosted.org"})
        verified[name] = {"url": row["url"], **expected}
    pending.mkdir(parents=True)
    for name in sorted(names - set(existing)):
        shutil.copyfile(candidate / "dist" / name, pending / name)
    return verified


def verify_pypi(record: dict[str, Any]) -> dict[str, Any]:
    metadata = public_json(f"https://pypi.org/pypi/godot-ai/{record['version']}/json")
    urls = metadata["urls"]
    support.require(
        len(urls) == 2
        and {row["filename"] for row in urls} == support.distribution_names(record["version"]),
        "public PyPI inventory is incomplete or unexpected",
    )
    result = {}
    for row in urls:
        expected = record["files"]["dist/" + row["filename"]]
        support.require(not row.get("yanked"), "public distribution is yanked")
        verify_public_file(row["url"], expected, {"files.pythonhosted.org"})
        result[row["filename"]] = {"url": row["url"], **expected}
    return result


def github_preflight(record: dict[str, Any]) -> dict[str, Any] | None:
    base = f"repos/{support.REPOSITORY}"
    ref = gh(f"{base}/git/ref/tags/{record['tag']}", allow_missing=True)
    if ref is not None:
        # The workflow creates lightweight refs. Do not silently replace an
        # annotated tag or a ref pointing somewhere else during recovery.
        support.require(
            ref.get("object")
            == {
                "type": "commit",
                "sha": record["source"],
                "url": f"https://api.github.com/{base}/git/commits/{record['source']}",
            },
            "existing release tag does not point to approved source",
        )
    release = gh(f"{base}/releases/tags/{record['tag']}", allow_missing=True)
    if release is not None:
        support.require(
            ref is not None and not release["prerelease"], "existing release identity mismatch"
        )
        assets = release["assets"]
        support.require(
            len(assets) == len({row["name"] for row in assets})
            and {row["name"] for row in assets} <= support.RELEASE_NAMES,
            "GitHub release contains unexpected assets",
        )
        for row in assets:
            expected = record["files"]["release/" + row["name"]]
            support.require(
                row["size"] == expected["size"]
                and row.get("digest") == "sha256:" + expected["sha256"],
                "existing GitHub asset differs from approval",
            )
        support.require(
            release["draft"] or len(assets) == 6, "public release has an incomplete asset set"
        )
    return release


def publish_github(candidate: Path, record: dict[str, Any]) -> dict[str, Any]:
    verify_pypi(record)
    release = github_preflight(record)
    base = f"repos/{support.REPOSITORY}"
    if gh(f"{base}/git/ref/tags/{record['tag']}", allow_missing=True) is None:
        gh(
            "--method",
            "POST",
            f"{base}/git/refs",
            "-f",
            f"ref=refs/tags/{record['tag']}",
            "-f",
            f"sha={record['source']}",
        )
    if release is None:
        release = gh(
            "--method",
            "POST",
            f"{base}/releases",
            "-f",
            f"tag_name={record['tag']}",
            "-f",
            f"target_commitish={record['source']}",
            "-F",
            "draft=true",
            "-F",
            "prerelease=false",
            "-f",
            f"name=Godot AI {record['version']}",
            "-f",
            "body=See the version-pinned migration guide: "
            f"https://github.com/{support.REPOSITORY}/blob/{record['source']}/docs/v4-migration.md",
        )
    existing = {row["name"] for row in release["assets"]}
    missing = sorted(support.RELEASE_NAMES - existing)
    if missing:
        subprocess.run(
            [
                "gh",
                "release",
                "upload",
                record["tag"],
                "--repo",
                support.REPOSITORY,
                *(str(candidate / "release" / name) for name in missing),
            ],
            check=True,
        )
    verified = github_preflight(record)
    support.require(
        verified is not None and len(verified["assets"]) == 6, "GitHub upload incomplete"
    )
    if verified["draft"]:
        verified = gh(
            "--method",
            "PATCH",
            f"{base}/releases/{verified['id']}",
            "-F",
            "draft=false",
            "-f",
            "make_latest=true",
        )
    result = {}
    for row in verified["assets"]:
        expected = record["files"]["release/" + row["name"]]
        verify_public_file(
            row["browser_download_url"],
            expected,
            {"github.com", "release-assets.githubusercontent.com", "objects.githubusercontent.com"},
        )
        result[row["name"]] = {"url": row["browser_download_url"], **expected}
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command",
        choices=(
            "run-provenance",
            "make-approval",
            "verify",
            "pypi-preflight",
            "verify-pypi",
            "github",
        ),
    )
    parser.add_argument("--root", type=Path, default=Path("candidates"))
    parser.add_argument("--evidence", type=Path, default=Path("qualification"))
    parser.add_argument("--approval-commit")
    parser.add_argument("--approval-path")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--bump", choices=("major", "minor", "patch"))
    parser.add_argument("--previous")
    parser.add_argument("--output", type=Path, default=Path("publication.json"))
    args = parser.parse_args(argv)
    try:
        run = check_run_provenance(args.run_id)
        if args.command == "run-provenance":
            return 0
        if args.command == "make-approval":
            support.require(
                args.bump and args.previous, "approval draft requires previous version and bump"
            )
            draft = approval_payload(args.root, args.evidence, run, args.bump, args.previous)
            support.require(
                draft["candidates"]["a"]["run_id"] == args.run_id, "candidate run ID mismatch"
            )
            with args.output.open("xb") as stream:
                stream.write(support.canonical(draft))
            print(
                "Wrote approval draft only; a human must review and commit it "
                "in the attestation repository."
            )
            return 0
        support.require(
            all((args.approval_commit, args.approval_path, args.bump, args.previous)),
            "promotion requires an approval, previous version, and bump",
        )
        approval = read_approval(args.approval_commit, args.approval_path)
        record = verify_approval(args.root, args.evidence, approval, run, args.bump, args.previous)
        support.require(record["run_id"] == args.run_id, "candidate run ID mismatch")
        github_preflight(record)
        result = {
            "version": record["version"],
            "source": record["source"],
            "approval_commit": args.approval_commit,
            "approval_path": args.approval_path,
        }
        if args.command == "pypi-preflight":
            result["pypi"] = pypi_preflight(args.root / "a", record, Path("pending-pypi"))
            if os.environ.get("GITHUB_OUTPUT"):
                with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
                    pending = bool(list(Path("pending-pypi").iterdir()))
                    output.write(f"pending={'true' if pending else 'false'}\n")
        elif args.command == "verify-pypi":
            result["pypi"] = verify_pypi(record)
        elif args.command == "github":
            result["github"] = publish_github(args.root / "a", record)
            result["pypi"] = verify_pypi(record)
        args.output.write_bytes(support.canonical(result))
    except (support.ReleaseError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"publication refused: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
