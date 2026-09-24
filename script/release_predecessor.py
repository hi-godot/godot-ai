"""Verify an unmodified public predecessor updates into sealed candidate A.

This is separate release evidence, not an A/B qualification row. Only the
external project and transport driver are generated; neither add-on is patched.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.parse
from pathlib import Path
from typing import Any

from script import release_promotion as public
from script import release_qualification as qualification
from script import release_support as support
from script import runtime_qualification as runtime

CASE_ID = "exact-published-predecessor-to-a"
GITHUB_HOSTS = {
    "github.com",
    "release-assets.githubusercontent.com",
    "objects.githubusercontent.com",
}
MANIFEST = "godot-ai-v4-plugin.manifest.json"


def download(url: str, path: Path, size: int, digest: str | None, hosts: set[str]) -> dict:
    support.require(
        type(size) is int and 0 < size <= support.MAX_FILE_BYTES, "invalid public artifact size"
    )
    support.require(digest is None or support.DIGEST.fullmatch(digest), "invalid public digest")
    actual_size, actual_digest = 0, hashlib.sha256()
    path.parent.mkdir(parents=True, exist_ok=True)
    with public.open_public_artifact(url, hosts) as response, path.open("xb") as output:
        public.validate_public_url(response.url, hosts)
        while chunk := response.read(1024 * 1024):
            actual_size += len(chunk)
            support.require(actual_size <= size, "public artifact exceeds declared size")
            actual_digest.update(chunk)
            output.write(chunk)
    actual = {"size": actual_size, "sha256": actual_digest.hexdigest()}
    support.require(
        actual_size == size and (digest is None or actual["sha256"] == digest),
        "public artifact digest or size mismatch",
    )
    return {"url": url, **actual}


def public_source(version: str) -> str:
    support.version_tuple(version)
    base = f"repos/{support.REPOSITORY}/git"
    obj = public.gh(f"{base}/ref/tags/v{version}")["object"]
    for _ in range(5):
        support.require(
            isinstance(obj, dict) and support.SHA.fullmatch(str(obj.get("sha", ""))),
            "invalid public tag object",
        )
        if obj.get("type") == "commit":
            return obj["sha"]
        support.require(obj.get("type") == "tag", "public tag does not identify a commit")
        obj = public.gh(f"{base}/tags/{obj['sha']}")["object"]
    raise support.ReleaseError("public tag nesting exceeds bound")


def fetch_predecessor(version: str, destination: Path) -> dict:
    source = public_source(version)
    release = public.gh(f"repos/{support.REPOSITORY}/releases/tags/v{version}")
    support.require(
        release.get("tag_name") == "v" + version
        and not release.get("draft")
        and not release.get("prerelease"),
        "predecessor is not a public stable release",
    )
    assets = release.get("assets", [])
    support.require(
        len(assets) == 6 and {row["name"] for row in assets} == support.RELEASE_NAMES,
        "public predecessor asset inventory differs",
    )
    files = {}
    for row in assets:
        digest = row.get("digest")
        if digest is not None:
            support.require(
                isinstance(digest, str) and digest.startswith("sha256:"),
                "unsupported public asset digest",
            )
            digest = digest.removeprefix("sha256:")
        files["release/" + row["name"]] = download(
            row["browser_download_url"],
            destination / "release" / row["name"],
            row["size"],
            digest,
            GITHUB_HOSTS,
        )
    record = {"version": version, "tag": "v" + version, "source": source}
    support.verify_signed_assets(destination / "release", record)
    metadata = public.public_json(f"https://pypi.org/pypi/godot-ai/{version}/json")
    distributions = metadata.get("urls", [])
    support.require(
        len(distributions) == 2
        and {row["filename"] for row in distributions} == support.distribution_names(version),
        "public distribution inventory differs",
    )
    for row in distributions:
        support.require(not row.get("yanked"), "public predecessor distribution is yanked")
        path = destination / "dist" / row["filename"]
        files["dist/" + row["filename"]] = download(
            row["url"],
            path,
            row["size"],
            row["digests"]["sha256"],
            {"files.pythonhosted.org"},
        )
        support.check_distribution_metadata(path, version)
    support.require(
        public_source(version) == source, "public predecessor tag moved during download"
    )
    return {**record, "files": files, "spki_sha256": support.verifier().PUBLIC_KEY_SPKI_SHA256}


def validate_inputs(
    candidate: Path, python_row: Path, previous: str, os_label: str
) -> tuple[dict, list]:
    support.require(
        os_label in support.PLATFORMS and os_label == runtime.engine.host_row(),
        "predecessor row differs from actual host",
    )
    python = runtime.current_python_version()
    support.require(python in support.PYTHONS, "unsupported predecessor Python row")
    record = support.verify_candidate(candidate, "a")
    support.require(
        record["source"] == record["workflow_sha"], "candidate A is not reviewed workflow source"
    )
    old, new = support.version_tuple(previous), support.version_tuple(record["version"])
    support.require(
        old[0] == new[0] == 4 and old < new, "predecessor must be an earlier v4 release"
    )
    row = support.read_json(python_row / "row.json")
    support.require(
        row.get("kind") == "python"
        and row.get("status") == "passed"
        and row.get("os") == os_label
        and row.get("python") == python
        and row.get("candidates", {}).get("a") == support.fingerprint(candidate / "evidence.json"),
        "retained Python row is not bound to candidate A and this platform",
    )
    dependencies = qualification.dependency_inventory(python_row / "packages")
    support.require(row.get("dependencies") == dependencies, "retained Python dependencies changed")
    wheel = f"godot_ai-{record['version']}-py3-none-any.whl"
    support.require(
        support.fingerprint(python_row / "packages" / wheel) == record["files"]["dist/" + wheel],
        "retained candidate wheel differs from sealed A",
    )
    return record, dependencies


def verify_update(
    project: Path, predecessor: Path, candidate: Path, previous: dict, record: dict
) -> dict:
    manifests = [
        support.read_json(root / "release" / MANIFEST) for root in (predecessor, candidate)
    ]
    expected_old, expected_new = [
        runtime.release_verify.inventory_tree_hash(value) for value in manifests
    ]
    state = project / runtime.UPDATE_STATE
    marker_path = state / "pending.json"
    marker = support.read_json(marker_path, canonical_required=False)
    expected_marker = {
        "status": "success",
        "clients_migrated": True,
        "from_version": previous["version"],
        "to_version": record["version"],
        "manifest_sha256": support.fingerprint(candidate / "release" / MANIFEST)["sha256"],
        "expected_tree_sha256": expected_new,
    }
    support.require(
        marker.get("clients_migrated") is True
        and all(marker.get(key) == value for key, value in expected_marker.items()),
        "predecessor update marker differs from signed identities",
    )
    live = project / "addons/godot_ai"
    support.require(
        support.inventory(live) == runtime._manifest_tree(candidate),
        "live tree is not exact candidate A",
    )
    backups = state / "backup"
    support.require(
        backups.is_dir()
        and sorted(path.name for path in backups.iterdir()) == [previous["version"]],
        "predecessor backup inventory differs",
    )
    backup = backups / previous["version"]
    support.require(
        runtime.release_verify.hash_tree(backup)["tree_sha256"] == expected_old,
        "retained backup differs from signed public predecessor",
    )
    support.require(
        str(marker.get("backup_root", ""))
        .replace("\\", "/")
        .rstrip("/")
        .endswith("backup/" + previous["version"]),
        "update marker names another backup",
    )
    for name in ("lock.json", "stage", "quarantine"):
        support.require(not (state / name).exists(), "predecessor update retained " + name)
    return {
        "update_marker": support.fingerprint(marker_path),
        "update_state": expected_marker,
        "live_tree": support.inventory(live),
        "live_tree_sha256": expected_new,
        "backup_tree_sha256": expected_old,
        "backup_tree": support.inventory(backup),
    }


def isolated_environment(root: Path, index: str) -> dict[str, str]:
    environment = runtime._isolated_environment(root, index)
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        environment.pop(name, None)
    app_data = root / "app-data"
    app_data.mkdir()
    environment["APPDATA"] = str(app_data)
    return environment


def dependency_environment() -> dict[str, str]:
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("PIP_", "UV_", "PYTHON", "GODOT_AI_"))
        and key not in {"GH_TOKEN", "GITHUB_TOKEN"}
    }
    environment.update(
        PIP_CONFIG_FILE=os.devnull,
        PIP_DISABLE_PIP_VERSION_CHECK="1",
        PYTHONNOUSERSITE="1",
        GODOT_AI_DISABLE_TELEMETRY="true",
    )
    return environment


def retain_predecessor_dependencies(predecessor: Path, previous: dict, output: Path) -> list:
    packages = output / "predecessor-packages"
    packages.mkdir()
    wheel = predecessor / "dist" / f"godot_ai-{previous['version']}-py3-none-any.whl"
    qualification.execute(
        [
            sys.executable,
            "-I",
            "-m",
            "pip",
            "--isolated",
            "download",
            "--no-cache-dir",
            "--only-binary=:all:",
            "--index-url",
            "https://pypi.org/simple",
            "--dest",
            str(packages),
            str(wheel),
        ],
        output / "predecessor-resolve.log",
        cwd=output,
        environment=dependency_environment(),
    )
    rows = qualification.dependency_inventory(packages)
    for row in rows:
        actual = {key: row[key] for key in ("size", "sha256")}
        if row["filename"] == wheel.name:
            expected = previous["files"]["dist/" + wheel.name]
            support.require(
                actual == {key: expected[key] for key in actual},
                "resolved predecessor wheel differs from public bytes",
            )
            continue
        metadata = public.public_json(
            "https://pypi.org/pypi/"
            + urllib.parse.quote(row["name"], safe="")
            + "/"
            + urllib.parse.quote(row["version"], safe="")
            + "/json"
        )
        matches = [
            item
            for item in metadata.get("urls", [])
            if item.get("filename") == row["filename"] and not item.get("yanked")
        ]
        support.require(len(matches) == 1, "predecessor dependency absent or yanked on PyPI")
        item = matches[0]
        public.validate_public_url(item["url"], {"files.pythonhosted.org"})
        support.require(
            actual == {"size": item["size"], "sha256": item["digests"]["sha256"]},
            "predecessor dependency differs from public PyPI bytes",
        )
    support.require(
        any(row["filename"] == wheel.name for row in rows),
        "predecessor resolution omitted its wheel",
    )
    return rows


def merge_dependency_files(source: Path, rows: list, destination: Path) -> None:
    for row in rows:
        name = row["filename"]
        support.require(
            Path(name).name == name and name.endswith(".whl"), "invalid dependency filename"
        )
        expected = {key: row[key] for key in ("size", "sha256")}
        support.require(
            support.fingerprint(source / name) == expected,
            "retained dependency changed before merge",
        )
        target = destination / name
        if target.exists():
            support.require(
                support.fingerprint(target) == expected,
                "conflicting retained dependency filename: " + name,
            )
        else:
            shutil.copyfile(source / name, target)
            support.require(support.fingerprint(target) == expected, "copied dependency changed")


def verify_offline_resolution(report: dict, dependencies: list, version: str) -> None:
    allowed = {row["filename"]: row for row in dependencies}
    installed = report.get("install", [])
    support.require(isinstance(installed, list) and installed, "empty offline installation report")
    names = set()
    found_release = False
    for item in installed:
        download = item.get("download_info", {})
        url = urllib.parse.urlsplit(download.get("url", ""))
        filename = urllib.parse.unquote(url.path).rsplit("/", 1)[-1]
        metadata = item.get("metadata", {})
        name = re.sub(r"[-_.]+", "-", str(metadata.get("name", ""))).lower()
        row = allowed.get(filename, {})
        support.require(
            url.scheme == "file"
            and row
            and name not in names
            and name == row["name"]
            and metadata.get("version") == row["version"]
            and download.get("archive_info", {}).get("hashes", {}).get("sha256") == row["sha256"],
            "offline resolution differs from its retained dependency closure",
        )
        names.add(name)
        if name == "godot-ai":
            support.require(row["version"] == version, "offline installed release version differs")
            found_release = True
    support.require(found_release, "offline report omitted the release")


def offline_preflight(
    packages: Path, version: str, work: Path, output: Path, dependencies: list
) -> dict:
    target = work / ("install-" + version)
    log = output / ("offline-" + version + ".log")
    environment = dependency_environment()
    qualification.execute(
        [sys.executable, "-m", "venv", str(target)], log, cwd=work, environment=environment
    )
    python = str(qualification.environment_python(target))
    wheel = packages / f"godot_ai-{version}-py3-none-any.whl"
    resolution = output / ("offline-" + version + ".json")
    qualification.execute(
        [
            python,
            "-I",
            "-m",
            "pip",
            "--isolated",
            "install",
            "--no-index",
            "--no-cache-dir",
            "--only-binary=:all:",
            "--find-links",
            str(packages),
            "--report",
            str(resolution),
            str(wheel),
        ],
        log,
        cwd=work,
        environment=environment,
    )
    verify_offline_resolution(
        support.read_json(resolution, canonical_required=False), dependencies, version
    )
    for args in (
        ["-m", "pip", "check"],
        ["-c", f"import importlib.metadata as m; assert m.version('godot-ai') == {version!r}"],
    ):
        qualification.execute([python, "-I", *args], log, cwd=work, environment=environment)
    return {
        "status": "passed",
        "wheel": support.fingerprint(wheel),
        "resolution": support.fingerprint(resolution),
    }


def run_update(
    candidate: Path,
    python_row: Path,
    dependencies: list,
    predecessor: Path,
    previous: dict,
    record: dict,
    godot: str,
    godot_version: str,
    output: Path,
) -> dict:
    executable = shutil.which(godot) if not Path(godot).is_absolute() else godot
    support.require(
        executable is not None and Path(executable).is_file(), "Godot executable missing"
    )
    engine = runtime.engine.verify_executable(Path(executable), godot_version)
    executable = engine["path"]
    actual_version = runtime._validate_godot_version(str(executable), godot_version)
    support.require(
        runtime._free_port(runtime.HTTP_PORT) and runtime._free_port(runtime.WS_PORT),
        "predecessor qualification ports are busy",
    )
    with tempfile.TemporaryDirectory(
        prefix="godot-ai-predecessor-", ignore_cleanup_errors=True
    ) as temporary:
        work = Path(temporary).resolve()
        packages, project = output / "packages", work / "project"
        packages.mkdir()
        project.mkdir()
        candidate_dependencies = [
            row
            for row in dependencies
            if row["name"] != "godot-ai" or row["version"] == record["version"]
        ]
        predecessor_dependencies = retain_predecessor_dependencies(predecessor, previous, output)
        merge_dependency_files(python_row / "packages", candidate_dependencies, packages)
        merge_dependency_files(output / "predecessor-packages", predecessor_dependencies, packages)
        index_inventory = qualification.dependency_inventory(packages)
        dependency_evidence = {
            "closures": {
                "candidate": candidate_dependencies,
                "predecessor": predecessor_dependencies,
            },
            "index_inventory": index_inventory,
            "offline_installs": {
                version: offline_preflight(packages, version, work, output, closure)
                for version, closure in (
                    (previous["version"], predecessor_dependencies),
                    (record["version"], candidate_dependencies),
                )
            },
        }
        certificate, key = runtime._tls_material(work / "tls")
        with runtime.retained_index(packages, index_inventory) as (index, requests):
            environment = isolated_environment(work / "environment", index)
            uvx = shutil.which("uvx", path=environment.get("PATH"))
            support.require(uvx is not None, "uvx is required for predecessor qualification")
            runtime._write_client_pin(Path(environment["CODEX_HOME"]), uvx, previous["version"])
            (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
            command = [sys.executable, str(support.ROOT / "script/v4-release"), "install"]
            for flag, filename in (
                ("archive", "godot-ai-v4-plugin.zip"),
                ("manifest", MANIFEST),
                ("signature", "godot-ai-v4-plugin.manifest.sig"),
            ):
                command += ["--" + flag, str(predecessor / "release" / filename)]
            for flag, value in (
                ("repository", support.REPOSITORY),
                ("channel", "stable"),
                ("tag", previous["tag"]),
                ("version", previous["version"]),
                ("source", previous["source"]),
            ):
                command += ["--expected-" + flag, value]
            command += ["--project-root", str(project)]
            runtime._execute_sensitive(
                command,
                output / "install-predecessor.log",
                cwd=work,
                environment=environment,
                secrets=(index,),
            )
            support.require(
                support.inventory(project / "addons/godot_ai")
                == runtime._manifest_tree(predecessor),
                "installed predecessor tree differs from signed public bytes",
            )
            runtime._write_project(project, certificate, previous["version"], record["version"])
            with runtime.private_release_origin(
                candidate / "release",
                support.inventory(candidate / "release"),
                version=record["version"],
                certificate=certificate,
                private_key=key,
            ) as release:
                environment.update(release.environment())
                environment.update(
                    PRIVATE_HTTPS_PORT=str(release.proxy_port),
                    PRIVATE_HTTPS_CERTIFICATE=str(certificate),
                )
                bridge_log = work / "attached-bridge.log"
                bridge = runtime.AttachedBridge(
                    runtime._bridge_command(uvx, previous["version"]),
                    environment,
                    project,
                    runtime._capability_directory(environment),
                    previous["version"],
                    record["version"],
                    bridge_log,
                )
                private_values = (
                    release.token,
                    index,
                    runtime._private_index_capability(index),
                    runtime.ORIGIN,
                )
                editor_output = None
                primary_error = None
                try:
                    with bridge:
                        try:
                            completed = subprocess.run(
                                runtime._editor_command(executable, project),
                                cwd=work,
                                env=environment,
                                capture_output=True,
                                timeout=runtime.TIMEOUT_SECONDS,
                                check=False,
                            )
                        except subprocess.TimeoutExpired as error:
                            editor_output = (error.stdout or b"") + (error.stderr or b"")
                            raise
                        editor_output = completed.stdout + completed.stderr
                        support.require(
                            len(editor_output) <= support.MAX_FILE_BYTES,
                            "runtime diagnostic output exceeds artifact size bound",
                        )
                        runtime._write_secret_free_log(
                            output / "godot.log",
                            editor_output or b"qualification diagnostic was empty\n",
                            private_values,
                        )
                        support.require(
                            completed.returncode == 0, "public predecessor update failed"
                        )
                        runtime._wait_for_runtime_result(
                            project / "runtime-result.json", runtime.TIMEOUT_SECONDS
                        )
                except BaseException as error:
                    primary_error = error
                    raise
                finally:
                    runtime._retain_runtime_diagnostics(
                        project, bridge_log, output, private_values, editor_output, primary_error
                    )
                support.require(
                    not bridge.fault and bridge.ok_before_update >= 1 and bridge.served_b,
                    "same attached predecessor bridge did not serve both versions",
                )
                support.require(
                    release.downloads
                    == ["godot-ai-v4-plugin.zip", MANIFEST, "godot-ai-v4-plugin.manifest.sig"],
                    "update did not download exact canonical triple",
                )
            runtime._wait_for_ports_free(
                runtime.HTTP_PORT, runtime.WS_PORT, timeout=runtime.EDITOR_EXIT_TIMEOUT_SECONDS
            )
            capability_dir = runtime._capability_directory(environment)
            runtime._wait_for_capability_release(capability_dir)
            runtime._scrub_private_material(key, capability_dir)
        result = runtime._read_runtime_result(project)
        support.require(
            result.get("status") == "passed" and result.get("attached_bridge_served_b") is True,
            "predecessor driver did not report a passed attached-bridge update",
        )
        support.require(
            result.get("from_version") == previous["version"]
            and result.get("to_version") == record["version"],
            "driver reported different versions",
        )
        config = (Path(environment["CODEX_HOME"]) / "config.toml").read_text(encoding="utf-8")
        support.require(
            f"godot-ai=={record['version']}" in config and index not in config,
            "updated client pin does not name candidate A cleanly",
        )
        evidence = verify_update(project, predecessor, candidate, previous, record)
        private_values = (
            release.token,
            index,
            runtime._private_index_capability(index),
            runtime.ORIGIN,
        )
        support.require(
            not any(secret in json.dumps(result) for secret in private_values),
            "private qualification value leaked into runtime result",
        )
        runtime._require_values_absent(project, private_values)
        runtime._require_values_absent(output, private_values)
        support.require(
            support.verify_candidate(candidate, "a") == record,
            "candidate A changed during predecessor validation",
        )
        return {
            "id": CASE_ID,
            "status": "passed",
            "from_version": previous["version"],
            "to_version": record["version"],
            "runtime_result": result,
            "godot": {**engine, "version": actual_version},
            "attached_bridge": bridge.report(),
            "backend_stopped": True,
            "index_artifacts_requested": sorted(set(requests)),
            "index_inventory": index_inventory,
            "dependency_evidence": dependency_evidence,
            **evidence,
        }


def predecessor_row(
    candidate: Path,
    python_row: Path,
    previous_version: str,
    godot: str,
    godot_version: str,
    output: Path,
    os_label: str,
) -> None:
    record, dependencies = validate_inputs(candidate, python_row, previous_version, os_label)
    support.require(
        godot_version in qualification.RUNTIME_GODOT_VERSIONS, "unsupported predecessor Godot row"
    )
    support.require(not output.exists(), "predecessor output already exists")
    output.mkdir(parents=True)
    report: dict[str, Any] = {
        "schema": 1,
        "kind": "predecessor",
        "status": "failed",
        "required_skips": 0,
        "os": os_label,
        "python": runtime.current_python_version(),
        "godot_version": godot_version,
        "platform": platform.platform(),
        "previous_version": previous_version,
        "candidate": support.fingerprint(candidate / "evidence.json"),
        "source": record["source"],
        "version": record["version"],
        "run_id": record["run_id"],
        "run_attempt": record["run_attempt"],
        "python_row": support.fingerprint(python_row / "row.json"),
        "cases": [],
    }
    try:
        with tempfile.TemporaryDirectory(prefix="godot-ai-public-predecessor-") as temporary:
            predecessor = Path(temporary)
            previous = fetch_predecessor(previous_version, predecessor)
            report["predecessor"] = previous
            case = run_update(
                candidate,
                python_row,
                dependencies,
                predecessor,
                previous,
                record,
                godot,
                godot_version,
                output,
            )
            support.require(
                case.get("id") == CASE_ID and case.get("status") == "passed",
                "predecessor runtime did not provide the required passed case",
            )
            report["cases"].append(case)
        report["status"] = "passed"
    finally:
        report["files"] = support.inventory(output)
        (output / "row.json").write_bytes(support.canonical(report))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--python-row", type=Path, required=True)
    parser.add_argument("--previous-version", required=True)
    parser.add_argument("--godot", required=True)
    parser.add_argument("--godot-version", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--os", choices=support.PLATFORMS, required=True)
    args = parser.parse_args(argv)
    try:
        predecessor_row(
            args.candidate.resolve(),
            args.python_row.resolve(),
            args.previous_version,
            args.godot,
            args.godot_version,
            args.output.resolve(),
            args.os,
        )
    except (support.ReleaseError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"predecessor validation refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
