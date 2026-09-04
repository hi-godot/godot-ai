"""Run and retain exact-artifact qualification, without signing or publishing."""

from __future__ import annotations

import argparse
import contextlib
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from script import qualification_engine as engine
from script import release_support as support

TEST_REQUIREMENTS = (
    "pytest==9.1.1",
    "pytest-xdist==3.8.0",
    "pytest-asyncio==1.4.0",
    "pytest-cov==7.1.0",
    "hypothesis==6.167.1",
    "pillow==12.3.0",
    "setuptools==84.0.0",
    "wheel==0.46.3",
    "pyyaml==6.0.3",
    "psutil==7.2.2",
)
GODOT_BUILDS = ("4.7.0",)
RUNTIME_PYTHONS = ("3.11",)
# One extra real-editor row at the newest supported engine on Linux, so a
# 4.7.x regression is caught before publication without tripling the matrix.
EXTRA_RUNTIME_ROWS = (("ubuntu-latest", "3.11", "4.7.2"),)

# The release gate is the exact-artifact Python rows plus one real-editor
# A -> B hot update per desktop OS. Failpoint/crash and storm matrices are
# nightly diagnostics (.github/workflows/nightly-diagnostics.yml), not rows
# that complete-qualification requires.
MANDATORY_CASES = {"runtime": frozenset({"exact-a-to-b-hot-update"})}
# The lean updater keeps its marker and retained backup beside the live tree.
UPDATE_STATE_PREFIX = "addons/.godot_ai_update/"


def validate_mandatory_cases(kind: str, cases: Any) -> None:
    required = MANDATORY_CASES.get(kind)
    support.require(required is not None, "unknown qualification case kind")
    support.require(isinstance(cases, list) and cases, "mandatory runtime cases are missing")
    found: dict[str, dict[str, Any]] = {}
    for case in cases:
        support.require(isinstance(case, dict), "qualification case must be an object")
        case_id = case.get("id")
        support.require(
            isinstance(case_id, str) and case_id in required and case_id not in found,
            "unexpected or duplicate qualification case",
        )
        support.require(case.get("status") == "passed", "mandatory runtime case failed")
        found[case_id] = case
    support.require(set(found) == required, "mandatory qualification cases are missing")


def required_row_keys() -> set[tuple[str, str, str, str | None]]:
    keys = {
        (kind, os_label, python, godot)
        for os_label in support.PLATFORMS
        for kind, versions, godots in (
            ("python", support.PYTHONS, (None,)),
            ("runtime", RUNTIME_PYTHONS, GODOT_BUILDS),
        )
        for python in versions
        for godot in godots
    }
    keys.update(
        ("runtime", os_label, python, godot) for os_label, python, godot in EXTRA_RUNTIME_ROWS
    )
    return keys


def validate_rows(output: Path, bindings: dict[str, Any]) -> dict[str, Any]:
    """Every required row must be present, passed, and bound to these candidates."""
    required = required_row_keys()
    found = {}
    for path in sorted(output.glob("*/row.json")):
        row = support.read_json(path)
        key = (
            row.get("kind"),
            row.get("os"),
            row.get("python"),
            row.get("godot_version") if row.get("kind") == "runtime" else None,
        )
        support.require(
            key in required and key not in found, "unexpected or duplicate evidence row"
        )
        support.require(
            row.get("status") == "passed" and row.get("candidates") == bindings,
            "failed row or row bound to different candidates",
        )
        actual = support.inventory(path.parent)
        actual.pop("row.json")
        support.require(row.get("files") == actual, "qualification row inventory mismatch")
        if row["kind"] == "python":
            support.require(
                row.get("dependencies") == dependency_inventory(path.parent / "packages"),
                "resolved dependency inventory mismatch",
            )
            support.require(
                set(row.get("installs", {})) == {"a", "b"}
                and all(
                    item.get("status") == "passed" and item.get("managed_tree")
                    for item in row["installs"].values()
                ),
                "documented exact-artifact installs are missing or failed",
            )
            support.require(set(row.get("tests", {})) == {"a"}, "missing candidate A tests")
            for summary in row["tests"].values():
                support.require(
                    summary.get("tests", 0) > 0
                    and summary.get("failures") == 0
                    and summary.get("errors") == 0,
                    "Python row is not green",
                )
        else:
            support.require(
                type(row.get("required_skips")) is int and row["required_skips"] == 0,
                "required qualification test skipped",
            )
            validate_mandatory_cases(row["kind"], row.get("cases"))
            if row["kind"] == "runtime":
                hot_update = next(
                    case for case in row["cases"] if case["id"] == "exact-a-to-b-hot-update"
                )
                engine.validate_identity(hot_update.get("godot"), row["godot_version"], row["os"])
        found[key] = row
    missing = required - set(found)
    support.require(
        not missing,
        "missing mandatory qualification rows: "
        + ", ".join(
            "/".join(value for value in key if value is not None) for key in sorted(missing)
        ),
    )
    return found


def complete(candidates: Path, output: Path) -> None:
    records = {name: support.verify_candidate(candidates / name, name) for name in ("a", "b")}
    bindings = {name: support.fingerprint(candidates / name / "evidence.json") for name in records}
    validate_rows(output, bindings)
    a = records["a"]
    record = {
        "schema": 2,
        "status": "qualified",
        "required_skips": 0,
        "run_id": a["run_id"],
        "run_attempt": a["run_attempt"],
        "workflow_sha": a["workflow_sha"],
        "candidates": bindings,
        "files": support.inventory(output),
    }
    with (output / "qualification.json").open("xb") as stream:
        stream.write(support.canonical(record))


def execute(command: list[str], log: Path, *, cwd: Path, environment: dict[str, str]) -> None:
    with log.open("ab") as stream:
        stream.write(support.canonical({"command": command, "cwd": str(cwd)}))
        stream.flush()
        result = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            stdout=stream,
            stderr=subprocess.STDOUT,
            timeout=2400,
            check=False,
        )
    support.require(result.returncode == 0, f"qualification command failed; see {log}")


def environment_python(root: Path) -> Path:
    return root / ("Scripts/python.exe" if os.name == "nt" else "bin/python")


@contextlib.contextmanager
def candidate_test_source(
    source: Path, commit: str, target: Path, log: Path, environment: dict[str, str]
):
    """Give B its own immutable test/fixture context, never A's version metadata.

    Unit tests include explicit source-based subprocess fixtures. They are
    development tests, not the separate frozen-runtime qualification proof.
    Their context must nevertheless match the installed candidate being tested.
    """
    support.require(support.SHA.fullmatch(commit), "invalid test source commit")
    support.require(not target.exists(), "test source directory already exists")
    command = ["git", "-C", str(source), "worktree"]
    execute(
        [*command, "add", "--detach", str(target), commit],
        log,
        cwd=source,
        environment=environment,
    )
    try:
        support.require(
            support.git(target, "rev-parse", "HEAD").decode().strip() == commit,
            "test source checkout differs from candidate",
        )
        yield target
    finally:
        # Only the fresh temporary worktree this context created is removed.
        # Tests may leave generated fixtures there; no user checkout is reused.
        execute(
            [*command, "remove", "--force", str(target)],
            log,
            cwd=source,
            environment=environment,
        )


def dependency_inventory(root: Path) -> list[dict[str, Any]]:
    """Capture the actual wheel artifacts, including platform-specific dependencies."""
    from email.parser import BytesParser

    rows = []
    for name, digest in support.inventory(root).items():
        support.require(
            "/" not in name and name.endswith(".whl"),
            "dependency directory must contain only wheel files",
        )
        metadata = BytesParser().parsebytes(support.wheel_metadata(root / name))
        support.require(
            len(metadata.get_all("Name", [])) == 1 and len(metadata.get_all("Version", [])) == 1,
            "ambiguous dependency identity",
        )
        rows.append(
            {
                "name": re.sub(r"[-_.]+", "-", metadata["Name"]).lower(),
                "version": metadata["Version"],
                "filename": name,
                **digest,
            }
        )
    support.require(rows, "empty dependency inventory")
    return rows


def closed_install(
    candidate: Path,
    record: dict[str, Any],
    work: Path,
    output: Path,
    environment: dict[str, str],
) -> dict[str, Any]:
    """Run the documented installer, not merely extract its ZIP.

    This is the closed-editor install row, NOT the final-v3 one-click bridge
    or the separate Godot A-to-B hot-update qualification.
    """
    project = work / "project"
    project.mkdir(parents=True)
    (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    release = candidate / "release"
    command = [
        sys.executable,
        str(support.ROOT / "script/v4-release"),
        "install",
        "--archive",
        str(release / "godot-ai-v4-plugin.zip"),
        "--manifest",
        str(release / "godot-ai-v4-plugin.manifest.json"),
        "--signature",
        str(release / "godot-ai-v4-plugin.manifest.sig"),
        "--expected-repository",
        support.REPOSITORY,
        "--expected-channel",
        "stable",
        "--expected-tag",
        record["tag"],
        "--expected-version",
        record["version"],
        "--expected-source",
        record["source"],
        "--project-root",
        str(project),
    ]
    execute(command, output, cwd=work, environment=environment)
    manifest = support.read_json(release / "godot-ai-v4-plugin.manifest.json")
    expected = {
        row["path"]: {key: row[key] for key in ("size", "sha256")} for row in manifest["inventory"]
    }
    installed = support.inventory(project)
    installed.pop("project.godot")
    # Whatever the installer keeps under its own state directory is its
    # business; every other byte in the project must be exactly the manifest.
    managed = {
        path: row for path, row in installed.items() if not path.startswith(UPDATE_STATE_PREFIX)
    }
    support.require(managed == expected, "documented installer produced a different tree")
    return {"status": "passed", "managed_tree": managed}


def python_row(candidates: Path, source: Path, output: Path, os_label: str) -> None:
    support.require(os_label in support.PLATFORMS, "unknown platform row")
    python_version = f"{sys.version_info.major}.{sys.version_info.minor}"
    support.require(python_version in support.PYTHONS, "unsupported Python row")
    support.require(not output.exists(), "qualification output already exists")
    records = {name: support.verify_candidate(candidates / name, name) for name in ("a", "b")}
    support.require(
        support.git(source, "rev-parse", "HEAD").decode().strip() == records["a"]["source"],
        "test source is not candidate A",
    )
    support.require(
        not support.git(source, "status", "--porcelain", "--untracked-files=no").strip(),
        "candidate test source contains tracked changes",
    )
    support.validate_sources(
        source,
        records["a"]["source"],
        records["b"]["source"],
        records["a"]["version"],
        records["b"]["version"],
    )
    output.mkdir(parents=True)
    packages = output / "packages"
    packages.mkdir()
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("UV_", "PIP_", "PYTHON", "GODOT_AI_"))
    }
    environment.update(
        {
            "GODOT_AI_DISABLE_TELEMETRY": "true",
            "PIP_CONFIG_FILE": os.devnull,
            "PIP_DISABLE_PIP_VERSION_CHECK": "1",
            "PYTHONNOUSERSITE": "1",
        }
    )
    report: dict[str, Any] = {
        "schema": 2,
        "kind": "python",
        "status": "failed",
        "os": os_label,
        "python": python_version,
        "python_build": sys.version,
        "machine": platform.machine(),
        "platform": platform.platform(),
        "candidates": {
            name: support.fingerprint(candidates / name / "evidence.json") for name in records
        },
        "tests": {},
    }
    try:
        # Resolve once for A, then use only these retained bytes for both A and B.
        # B's source validation forbids dependency changes.
        wheel_a = candidates / "a/dist" / f"godot_ai-{records['a']['version']}-py3-none-any.whl"
        execute(
            [
                sys.executable,
                "-m",
                "pip",
                "download",
                "--only-binary=:all:",
                "--index-url",
                "https://pypi.org/simple",
                "--dest",
                str(packages),
                str(wheel_a),
                *TEST_REQUIREMENTS,
            ],
            output / "resolve.log",
            cwd=source,
            environment=environment,
        )
        wheel_b = candidates / "b/dist" / f"godot_ai-{records['b']['version']}-py3-none-any.whl"
        shutil.copyfile(wheel_b, packages / wheel_b.name)
        report["dependencies"] = dependency_inventory(packages)
        with tempfile.TemporaryDirectory(prefix="godot-ai-python-qualification-") as temporary:
            work = Path(temporary).resolve()
            ## B is A plus two version fields minus the bundled README: its
            ## wheel must install from the retained index (the runtime row
            ## updates into it), but its sdist and its test run would only
            ## repeat A's evidence.
            for name in ("a", "b"):
                version = records[name]["version"]
                for package_type in ("wheel", "sdist") if name == "a" else ("wheel",):
                    target = work / f"{name}-{package_type}"
                    execute(
                        [sys.executable, "-m", "venv", str(target)],
                        output / "install.log",
                        cwd=work,
                        environment=environment,
                    )
                    python = str(environment_python(target))
                    execute(
                        [
                            python,
                            "-m",
                            "pip",
                            "install",
                            "--no-index",
                            "--find-links",
                            str(packages),
                            *TEST_REQUIREMENTS,
                        ],
                        output / "install.log",
                        cwd=work,
                        environment=environment,
                    )
                    filename = (
                        f"godot_ai-{version}-py3-none-any.whl"
                        if package_type == "wheel"
                        else f"godot_ai-{version}.tar.gz"
                    )
                    execute(
                        [
                            python,
                            "-m",
                            "pip",
                            "install",
                            "--no-index",
                            "--find-links",
                            str(packages),
                            "--no-build-isolation",
                            str(candidates / name / "dist" / filename),
                        ],
                        output / "install.log",
                        cwd=work,
                        environment=environment,
                    )
                    execute(
                        [
                            python,
                            "-I",
                            "-c",
                            "import importlib.metadata as m; "
                            f"assert m.version('godot-ai') == {version!r}; "
                            "import godot_ai; from pathlib import Path; "
                            "assert Path(godot_ai.__file__).resolve().is_relative_to("
                            f"{str(target)!r})",
                        ],
                        output / "install.log",
                        cwd=work,
                        environment=environment,
                    )
                    execute(
                        [python, "-I", "-m", "godot_ai", "--version"],
                        output / "install.log",
                        cwd=work,
                        environment=environment,
                    )
                    if package_type == "wheel" and name == "a":
                        junit = output / f"{name}-pytest.xml"
                        # Override the development pythonpath so tests import the
                        # installed wheel. Godot fixture tests are run separately;
                        # they deliberately build provisional, patched artifacts.
                        execute(
                            [
                                python,
                                "-m",
                                "pytest",
                                "-v",
                                "-n",
                                "auto",
                                "-o",
                                "pythonpath=",
                                "--junitxml",
                                str(junit),
                                "tests/unit",
                                "tests/integration",
                            ],
                            output / f"{name}-pytest.log",
                            cwd=source,
                            environment=environment,
                        )
                        suites = ET.parse(junit).getroot().iter("testsuite")
                        summary = {key: 0 for key in ("tests", "failures", "errors", "skipped")}
                        for suite in suites:
                            for key in summary:
                                summary[key] += int(suite.get(key, "0"))
                        support.require(
                            summary["tests"] > 0
                            and summary["failures"] == 0
                            and summary["errors"] == 0,
                            "Python tests did not pass",
                        )
                        report["tests"][name] = summary
            # The closed-editor installer runs no Python of its own: it verifies,
            # stages and swaps the signed tree from the candidate directory alone.
            report["installs"] = {
                name: closed_install(
                    candidates / name,
                    records[name],
                    work / f"{name}-install",
                    output / f"{name}-documented-install.log",
                    environment,
                )
                for name in ("a", "b")
            }
        # Environment-inapplicable development tests may skip; this report does
        # not grant the separate zero-required-skip runtime qualification gate.
        report["status"] = "passed"
    finally:
        report["files"] = support.inventory(output)
        (output / "row.json").write_bytes(support.canonical(report))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", type=Path)
    parser.add_argument("--source", type=Path, default=support.ROOT)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--os", choices=support.PLATFORMS)
    parser.add_argument("--complete", action="store_true")
    args = parser.parse_args(argv)
    try:
        support.require(args.candidates and args.output, "candidates and output are required")
        if args.complete:
            complete(args.candidates.resolve(), args.output.resolve())
        else:
            python_row(
                args.candidates.resolve(), args.source.resolve(), args.output.resolve(), args.os
            )
    except (support.ReleaseError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f"qualification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
