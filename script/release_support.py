"""Dependency-free validation shared by qualification and release promotion.

Run this code from the reviewed workflow checkout, never from downloaded
candidate artifacts. Downloaded JSON is data, not an executable approval.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import zipfile
from email.parser import BytesParser
from importlib.machinery import SourceFileLoader
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "hi-godot/godot-ai"
QUALIFICATION_WORKFLOW = ".github/workflows/release-qualification.yml"
SHA = re.compile(r"[0-9a-f]{40}")
DIGEST = re.compile(r"[0-9a-f]{64}")
SEMVER = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")
RELEASE_NAMES = frozenset(
    {
        "godot-ai-v4-plugin.zip",
        "godot-ai-v4-plugin.manifest.json",
        "godot-ai-v4-plugin.manifest.sig",
        "godot-ai-plugin.zip",
        "godot-ai-plugin.zip.sha256",
        "godot-ai-plugin.zip.sha256.sig",
    }
)
VERIFIER_PATHS = ("script/v4-release", "src/godot_ai/release_verify.py")
MAX_FILE_BYTES = 128 * 1024 * 1024
MAX_JSON_BYTES = 8 * 1024 * 1024
PLATFORMS = ("ubuntu-latest", "macos-latest", "windows-latest")
PYTHONS = ("3.11", "3.14")


class ReleaseError(ValueError):
    """An input fails the publication contract."""


def require(condition: Any, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


def canonical(value: Any) -> bytes:
    return (
        json.dumps(
            value, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False
        )
        + "\n"
    ).encode("utf-8")


def strict_json(raw: bytes) -> Any:
    def pairs(items):
        result = dict(items)
        require(len(result) == len(items), "duplicate JSON key")
        return result

    def constant(value):
        raise ReleaseError(f"invalid JSON constant: {value}")

    require(len(raw) <= MAX_JSON_BYTES, "JSON exceeds size bound")
    try:
        return json.loads(raw, object_pairs_hook=pairs, parse_constant=constant)
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise ReleaseError("invalid JSON") from exc


def regular(path: Path) -> None:
    info = path.lstat()
    require(
        stat.S_ISREG(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 0x400),
        f"not a regular file: {path}",
    )
    require(0 < info.st_size <= MAX_FILE_BYTES, f"file size out of bounds: {path}")


def fingerprint(path: Path) -> dict[str, Any]:
    regular(path)
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"sha256": digest, "size": path.stat().st_size}


def read_json(path: Path, *, canonical_required: bool = True) -> Any:
    regular(path)
    require(path.stat().st_size <= MAX_JSON_BYTES, "JSON exceeds size bound")
    raw = path.read_bytes()
    result = strict_json(raw)
    require(not canonical_required or raw == canonical(result), "non-canonical JSON")
    return result


def inventory(root: Path) -> dict[str, dict[str, Any]]:
    info = root.lstat()
    require(
        stat.S_ISDIR(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 0x400),
        f"not a plain directory: {root}",
    )
    result = {}
    for directory, dirs, files in os.walk(root, followlinks=False):
        for name in dirs:
            info = (Path(directory) / name).lstat()
            require(
                stat.S_ISDIR(info.st_mode) and not (getattr(info, "st_file_attributes", 0) & 0x400),
                "linked or reparse directory in artifact",
            )
        for name in files:
            path = Path(directory) / name
            result[path.relative_to(root).as_posix()] = fingerprint(path)
    return dict(sorted(result.items()))


def version_tuple(version: str) -> tuple[int, int, int]:
    require(isinstance(version, str) and SEMVER.fullmatch(version), "version must be X.Y.Z")
    return tuple(map(int, version.split(".")))


def next_version(previous: str, bump: str) -> str:
    """Advance a published version by exactly one semantic step.

    B carries A's next patch number during qualification, but that number is
    not reserved: the next patch publication is a fresh reviewed A under it.
    """
    major, minor, patch = version_tuple(previous)
    require(bump in {"patch", "minor", "major"}, "unknown semantic bump")
    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return f"{major}.{minor}.{patch}"


def git(repo: Path, *args: str) -> bytes:
    return subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True).stdout


def validate_sources(repo: Path, a: str, b: str, va: str, vb: str) -> None:
    require(
        isinstance(a, str) and SHA.fullmatch(a) and isinstance(b, str) and SHA.fullmatch(b),
        "sources must be full commit SHAs",
    )
    major, minor, patch = version_tuple(va)
    require(
        version_tuple(vb) == (major, minor, patch + 1),
        "B must be the immediately following patch version",
    )
    require(
        git(repo, "rev-list", "--parents", "-n", "1", b).decode().split() == [b, a],
        "B must be an immediate, single-parent child of A",
    )
    config = "plugin/addons/godot_ai/plugin.cfg"
    readme = "plugin/addons/godot_ai/README.md"
    changes = git(repo, "diff", "--name-only", a, b).decode().splitlines()
    require(
        set(changes) == {"pyproject.toml", config, readme},
        "B may only change the two versions and remove the bundled README",
    )
    for path, pattern in (
        ("pyproject.toml", rb'(?m)^version = "([^"\r\n]+)"$'),
        (config, rb'(?m)^version="([^"\r\n]+)"$'),
    ):
        before, after = (git(repo, "show", f"{source}:{path}") for source in (a, b))
        old, new = re.findall(pattern, before), re.findall(pattern, after)
        require(old == [va.encode()] and new == [vb.encode()], "source version mismatch")
        require(
            re.sub(pattern, b"VERSION", before) == re.sub(pattern, b"VERSION", after),
            f"B contains a non-version change in {path}",
        )
    require(
        git(repo, "diff", "--name-status", a, b, "--", readme).decode().strip() == f"D\t{readme}",
        "B must delete A's bundled README",
    )


B_COMMIT_ENV = {
    "GIT_AUTHOR_NAME": "godot-ai release",
    "GIT_AUTHOR_EMAIL": "release@godot-ai.invalid",
    "GIT_AUTHOR_DATE": "2000-01-01T00:00:00Z",
    "GIT_COMMITTER_NAME": "godot-ai release",
    "GIT_COMMITTER_EMAIL": "release@godot-ai.invalid",
    "GIT_COMMITTER_DATE": "2000-01-01T00:00:00Z",
}


def prepare_b(repo: Path, a: str, va: str) -> str:
    """Commit A's qualification-only child B and return its SHA.

    B is A with the two version fields at A's next patch and without the
    bundled README, exactly what ``validate_sources`` accepts. The commit is
    made under fixed identity and dates in a disposable worktree, so the same
    A always yields the same B; it is created locally and never pushed here.
    """
    require(isinstance(a, str) and SHA.fullmatch(a) is not None, "A must be a full commit SHA")
    vb = next_version(va, "patch")
    config = "plugin/addons/godot_ai/plugin.cfg"
    readme = "plugin/addons/godot_ai/README.md"
    with tempfile.TemporaryDirectory(prefix="godot-ai-prepare-b-") as temporary:
        worktree = Path(temporary) / "b"
        git(repo, "worktree", "add", "--detach", "--quiet", str(worktree), a)
        try:
            for path, pattern in (
                ("pyproject.toml", rb'(?m)^version = "([^"\r\n]+)"$'),
                (config, rb'(?m)^version="([^"\r\n]+)"$'),
            ):
                before = (worktree / path).read_bytes()
                require(re.findall(pattern, before) == [va.encode()], f"{path} is not at {va}")
                after = re.sub(
                    pattern, lambda m: m.group(0).replace(va.encode(), vb.encode()), before
                )
                (worktree / path).write_bytes(after)
            require((worktree / readme).is_file(), "A has no bundled README to remove")
            (worktree / readme).unlink()
            git(worktree, "add", "-A", "--", "pyproject.toml", config, readme)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(worktree),
                    "commit",
                    "--quiet",
                    "-m",
                    f"qualification-only child B: {vb}",
                ],
                check=True,
                capture_output=True,
                env={**os.environ, **B_COMMIT_ENV},
            )
            b = git(worktree, "rev-parse", "HEAD").decode().strip()
        finally:
            git(repo, "worktree", "remove", "--force", str(worktree))
    validate_sources(repo, a, b, va, vb)
    return b


def distribution_names(version: str) -> set[str]:
    version_tuple(version)
    return {f"godot_ai-{version}-py3-none-any.whl", f"godot_ai-{version}.tar.gz"}


def check_distribution_metadata(path: Path, version: str) -> None:
    """A renamed wheel/sdist is not evidence of the package identity inside it."""
    if path.suffix == ".whl":
        raw = wheel_metadata(path)
    else:
        with tarfile.open(path, "r:gz") as archive:
            name = f"godot_ai-{version}/PKG-INFO"
            members = [m for m in archive.getmembers() if m.name == name]
            require(
                len(members) == 1 and members[0].isfile() and members[0].size < MAX_JSON_BYTES,
                "sdist needs regular PKG-INFO",
            )
            stream = archive.extractfile(members[0])
            require(stream is not None, "missing sdist metadata")
            raw = stream.read(MAX_JSON_BYTES)
    message = BytesParser().parsebytes(raw)
    require(
        message.get_all("Name") == ["godot-ai"] and message.get_all("Version") == [version],
        "distribution identity mismatch",
    )


def wheel_metadata(path: Path) -> bytes:
    """Read the wheel's own metadata, not nested vendored distributions."""
    with zipfile.ZipFile(path) as archive:
        names = [
            name
            for name in archive.namelist()
            if name.count("/") == 1 and name.endswith(".dist-info/METADATA")
        ]
        require(len(names) == 1, "wheel needs exactly one top-level METADATA")
        info = archive.getinfo(names[0])
        require(info.file_size < MAX_JSON_BYTES, "wheel metadata exceeds bound")
        return archive.read(names[0])


def verifier():
    spec = importlib.util.spec_from_file_location("release_verifier", ROOT / VERIFIER_PATHS[1])
    require(spec is not None and spec.loader is not None, "trusted verifier unavailable")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def release_producer():
    """Load the reviewed producer independently of installed candidate code."""
    loader = SourceFileLoader("release_producer", str(ROOT / "script/v4-release"))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    producer = importlib.util.module_from_spec(spec)
    loader.exec_module(producer)
    return producer


def sign_candidate(root: Path, repo: Path, source: str, version: str, key: Path) -> None:
    """Sign prebuilt bytes using only reviewed tooling and immutable git blobs."""
    require(isinstance(source, str) and SHA.fullmatch(source), "invalid source SHA")
    version_tuple(version)
    producer = release_producer()
    expected = (REPOSITORY, "stable", "v" + version, version, source)
    release = root / "release"
    require(
        set(inventory(release)) == {producer.ASSET_NAME, producer.MANIFEST_NAME},
        "signing input must be exactly the unsigned canonical pair",
    )
    manifest = producer._validate_manifest(
        (release / producer.MANIFEST_NAME).read_bytes(), expected
    )
    producer._verify_archive((release / producer.ASSET_NAME).read_bytes(), manifest)
    snapshot = producer._snapshot_commit(repo, source, version)
    expected_inventory = [
        {"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
        for name, data in snapshot
    ]
    require(
        manifest["inventory"] == expected_inventory,
        "unsigned plugin differs from the reviewed source",
    )
    producer.sign_release(
        release / producer.MANIFEST_NAME, release / producer.SIGNATURE_NAME, key, expected
    )
    producer.build_migration_capsule(
        repo,
        release,
        key,
        tuple(
            release / name
            for name in (producer.ASSET_NAME, producer.MANIFEST_NAME, producer.SIGNATURE_NAME)
        ),
        expected,
    )


def package_candidate(root: Path, repo: Path, source: str, version: str) -> None:
    require(SHA.fullmatch(source), "invalid source SHA")
    version_tuple(version)
    require(
        git(repo, "rev-parse", "HEAD").decode().strip() == source,
        "build checkout differs from candidate source",
    )
    require(
        not git(repo, "status", "--porcelain", "--untracked-files=no").strip(),
        "build checkout contains tracked changes",
    )
    config = tomllib.loads(git(repo, "show", f"{source}:pyproject.toml").decode())
    require(config["project"]["version"] == version, "Python source version mismatch")
    require(not root.exists(), "candidate output must be new")
    # The release primitive requires HEAD == local tag == source. These refs
    # exist only in the disposable build checkout and are never pushed.
    tag = "v" + version
    tagged = subprocess.run(
        ["git", "-C", str(repo), "rev-parse", "--verify", tag], capture_output=True, check=False
    )
    if tagged.returncode:
        git(repo, "tag", tag, source)
    else:
        require(tagged.stdout.decode().strip() == source, "existing local tag has another source")
    subprocess.run(
        [
            sys.executable,
            str(ROOT / "script/v4-release"),
            "package",
            "--repo-root",
            str(repo),
            "--output-dir",
            str(root / "release"),
            "--channel",
            "stable",
            "--tag",
            "v" + version,
            "--version",
            version,
            "--source-commit",
            source,
        ],
        check=True,
    )
    subprocess.run(
        [sys.executable, "-m", "build", "--outdir", str(root / "dist")], cwd=repo, check=True
    )
    for path in VERIFIER_PATHS:
        target = root / "verifier" / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(git(repo, "show", f"{source}:{path}"))


def verify_signed_assets(root: Path, record: dict[str, Any]) -> None:
    verify = verifier()
    expected = (REPOSITORY, "stable", record["tag"], record["version"], record["source"])
    verify.verify_release(
        root / "godot-ai-v4-plugin.zip",
        root / "godot-ai-v4-plugin.manifest.json",
        root / "godot-ai-v4-plugin.manifest.sig",
        expected,
    )
    checksum = (root / "godot-ai-plugin.zip.sha256").read_bytes()
    digest = fingerprint(root / "godot-ai-plugin.zip")["sha256"]
    require(checksum == f"{digest}  godot-ai-plugin.zip\n".encode(), "capsule checksum mismatch")
    verify._verify_signature(
        checksum, (root / "godot-ai-plugin.zip.sha256.sig").read_bytes(), verify.PUBLIC_KEY_PEM
    )
    with zipfile.ZipFile(root / "godot-ai-plugin.zip") as archive:
        require(len(archive.namelist()) == len(set(archive.namelist())), "duplicate capsule path")
        for name in (
            "godot-ai-v4-plugin.zip",
            "godot-ai-v4-plugin.manifest.json",
            "godot-ai-v4-plugin.manifest.sig",
        ):
            member = f"addons/godot_ai/migration_payload/{name}"
            require(
                archive.getinfo(member).file_size == (root / name).stat().st_size,
                "embedded canonical artifact size mismatch",
            )
            require(
                archive.read(member) == (root / name).read_bytes(),
                "capsule does not embed the exact canonical artifact",
            )


def candidate_record(
    root: Path,
    candidate: str,
    source: str,
    version: str,
    workflow_sha: str,
    run_id: str,
    run_attempt: int,
) -> dict[str, Any]:
    require(candidate in {"a", "b"}, "unknown candidate")
    require(
        isinstance(source, str)
        and SHA.fullmatch(source)
        and isinstance(workflow_sha, str)
        and SHA.fullmatch(workflow_sha),
        "invalid source SHA",
    )
    require(isinstance(run_id, str) and re.fullmatch(r"[1-9][0-9]*", run_id), "invalid run ID")
    require(type(run_attempt) is int and run_attempt >= 1, "invalid run attempt")
    expected = (
        {f"release/{name}" for name in RELEASE_NAMES}
        | {f"dist/{name}" for name in distribution_names(version)}
        | {f"verifier/{name}" for name in VERIFIER_PATHS}
    )
    actual = inventory(root)
    actual.pop("evidence.json", None)
    require(set(actual) == expected, "candidate inventory must contain exactly approved files")
    for name in distribution_names(version):
        check_distribution_metadata(root / "dist" / name, version)
    result = {
        "schema": 2,
        "repository": REPOSITORY,
        "channel": "stable",
        "candidate": candidate,
        "source": source,
        "version": version,
        "tag": "v" + version,
        "workflow_sha": workflow_sha,
        "run_id": run_id,
        "run_attempt": run_attempt,
        "spki_sha256": verifier().PUBLIC_KEY_SPKI_SHA256,
        "files": actual,
    }
    verify_signed_assets(root / "release", result)
    return result


def verify_candidate(root: Path, candidate: str) -> dict[str, Any]:
    record = read_json(root / "evidence.json")
    require(isinstance(record, dict), "candidate evidence must be an object")
    keys = {
        "schema",
        "repository",
        "channel",
        "candidate",
        "source",
        "version",
        "tag",
        "workflow_sha",
        "run_id",
        "run_attempt",
        "spki_sha256",
        "files",
    }
    require(set(record) == keys, "candidate evidence has missing or unknown fields")
    expected = candidate_record(
        root,
        candidate,
        record["source"],
        record["version"],
        record["workflow_sha"],
        record["run_id"],
        record["run_attempt"],
    )
    # JSON equality must not treat true as 1 or 1.0 as 1 in nested evidence.
    require(canonical(record) == canonical(expected), "candidate evidence mismatch")
    return record


def validate_run(run: dict[str, Any], workflow_sha: str, run_id: str, attempt: int) -> None:
    require(type(attempt) is int and attempt >= 1, "invalid qualification run attempt")
    require(
        type(run.get("id")) is int
        and run["id"] == int(run_id)
        and type(run.get("run_attempt")) is int
        and run["run_attempt"] == attempt,
        "qualification run identity or attempt mismatch",
    )
    require(
        run.get("status") == "completed" and run.get("conclusion") == "success",
        "qualification run has not succeeded",
    )
    require(
        run.get("path") == QUALIFICATION_WORKFLOW
        and run.get("event") == "workflow_dispatch"
        and run.get("head_branch") == "main"
        and run.get("head_sha") == workflow_sha,
        "qualification workflow provenance mismatch",
    )
    require(
        run.get("repository", {}).get("full_name") == REPOSITORY
        and run.get("head_repository", {}).get("full_name") == REPOSITORY,
        "qualification must run in the canonical repository",
    )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    version = commands.add_parser("next-version")
    version.add_argument("--previous", required=True)
    version.add_argument("--bump", choices=("patch", "minor", "major"), required=True)
    sources = commands.add_parser("validate-sources")
    sources.add_argument("--repo", type=Path, default=ROOT)
    for name in ("a", "b", "version-a"):
        sources.add_argument("--" + name, required=True)
    sources.add_argument("--version-b", default=None, help="defaults to A's next patch")
    prepare = commands.add_parser(
        "prepare-b", help="commit the qualification-only child of A and print its SHA"
    )
    prepare.add_argument("--repo", type=Path, default=ROOT)
    prepare.add_argument("--a", required=True)
    prepare.add_argument("--version-a", required=True)
    seal = commands.add_parser("seal")
    seal.add_argument("--root", type=Path, required=True)
    for name in ("candidate", "source", "version", "workflow-sha", "run-id"):
        seal.add_argument("--" + name, required=True)
    seal.add_argument("--run-attempt", type=int, required=True)
    verify = commands.add_parser("verify")
    verify.add_argument("--root", type=Path, required=True)
    verify.add_argument("--candidate", choices=("a", "b"), required=True)
    sign = commands.add_parser("sign")
    sign.add_argument("--root", type=Path, required=True)
    sign.add_argument("--repo", type=Path, default=ROOT)
    sign.add_argument("--source", required=True)
    sign.add_argument("--version", required=True)
    sign.add_argument("--key", type=Path, required=True)
    package = commands.add_parser("package")
    package.add_argument("--root", type=Path, required=True)
    package.add_argument("--repo", type=Path, required=True)
    package.add_argument("--source", required=True)
    package.add_argument("--version", required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "next-version":
            print(next_version(args.previous, args.bump))
        elif args.command == "validate-sources":
            version_b = args.version_b or next_version(args.version_a, "patch")
            validate_sources(args.repo, args.a, args.b, args.version_a, version_b)
        elif args.command == "prepare-b":
            b = prepare_b(args.repo, args.a, args.version_a)
            print(b)
            print(
                f"push it for the run: git push origin {b}:refs/heads/qualify/v{args.version_a}-b",
                file=sys.stderr,
            )
        elif args.command == "seal":
            output = args.root / "evidence.json"
            record = candidate_record(
                args.root,
                args.candidate,
                args.source,
                args.version,
                args.workflow_sha,
                args.run_id,
                args.run_attempt,
            )
            with output.open("xb") as stream:
                stream.write(canonical(record))
        elif args.command == "sign":
            sign_candidate(args.root, args.repo, args.source, args.version, args.key)
        elif args.command == "package":
            package_candidate(args.root.resolve(), args.repo.resolve(), args.source, args.version)
        else:
            verify_candidate(args.root, args.candidate)
    except (ReleaseError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"release validation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
