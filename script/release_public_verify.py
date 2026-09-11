"""Verify public release bytes and fresh dependency installs without publishing."""

from __future__ import annotations

import argparse
import os
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import urllib.parse
import venv
from pathlib import Path
from typing import Any

from script import release_promotion as promotion
from script import release_qualification as qualification
from script import release_support as support


def verify_resolution(
    report: dict[str, Any], record: dict[str, Any], *, require_release: bool = True
) -> list[dict[str, Any]]:
    installed = report.get("install", [])
    support.require(bool(installed), "empty public dependency resolution")
    result = []
    found_release = False
    for item in installed:
        name, version = item["metadata"]["name"], item["metadata"]["version"]
        download = item["download_info"]
        url = download["url"]
        promotion.validate_public_url(url, {"files.pythonhosted.org"})
        metadata = promotion.public_json(
            "https://pypi.org/pypi/"
            + urllib.parse.quote(name, safe="")
            + "/"
            + urllib.parse.quote(version, safe="")
            + "/json"
        )
        matches = [entry for entry in metadata["urls"] if entry["url"] == url]
        support.require(
            len(matches) == 1 and not matches[0].get("yanked"),
            "resolved dependency is absent or yanked on public PyPI",
        )
        entry = matches[0]
        expected = {"sha256": entry["digests"]["sha256"], "size": entry["size"]}
        support.require(
            download["archive_info"]["hashes"]["sha256"] == expected["sha256"],
            "installed dependency digest differs from public PyPI",
        )
        if name.lower().replace("_", "-") == "godot-ai":
            support.require(
                not found_release and version == record["version"],
                "installed release version mismatch",
            )
            support.require(
                record["files"].get("dist/" + entry["filename"]) == expected,
                "installed release differs from qualified bytes",
            )
            found_release = True
        promotion.verify_public_file(url, expected, {"files.pythonhosted.org"})
        result.append({"name": name, "version": version, "url": url, **expected})
    support.require(
        found_release or not require_release, "public resolution did not install godot-ai"
    )
    return result


def read_resolution(path: Path) -> dict[str, Any]:
    return support.read_json(path, canonical_required=False)


def build_requirements(candidate: Path, version: str) -> list[str]:
    archive = candidate / "dist" / f"godot_ai-{version}.tar.gz"
    with tarfile.open(archive) as source:
        member = source.getmember(f"godot_ai-{version}/pyproject.toml")
        support.require(
            member.isfile() and member.size <= support.MAX_JSON_BYTES,
            "invalid source build metadata",
        )
        stream = source.extractfile(member)
        support.require(stream is not None, "source build metadata missing")
        requirements = tomllib.loads(stream.read().decode())["build-system"]["requires"]
    support.require(
        isinstance(requirements, list)
        and requirements
        and all(isinstance(value, str) and not value.startswith("-") for value in requirements),
        "invalid build requirements",
    )
    return requirements


def public_row(candidate: Path, output: Path, os_label: str) -> None:
    from script import qualification_engine as engine

    support.require(os_label == engine.host_row(), "public row differs from actual host")
    python_version = f"{sys.version_info.major}.{sys.version_info.minor}"
    support.require(python_version in {"3.11", "3.14"}, "unsupported public Python row")
    support.require(not output.exists(), "public verification output already exists")
    record = support.verify_candidate(candidate, "a")
    output.mkdir(parents=True)
    pypi = promotion.verify_pypi(record)
    release = promotion.github_preflight(record)
    support.require(release is not None and not release["draft"], "release is not public")
    migration = (
        f"https://github.com/{support.REPOSITORY}/blob/{record['source']}/docs/v4-migration.md"
    )
    support.require(migration in release["body"], "canonical migration link is missing")
    assets = {}
    for asset in release["assets"]:
        expected = record["files"]["release/" + asset["name"]]
        url = asset["browser_download_url"]
        promotion.verify_public_file(
            url, expected, {"github.com", "release-assets.githubusercontent.com"}
        )
        assets[asset["name"]] = {"url": url, **expected}
    resolutions = {}
    with tempfile.TemporaryDirectory(prefix="godot-ai-public-") as temporary:
        work = Path(temporary).resolve()
        environment = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("PIP_", "UV_", "PYTHON"))
            and key not in {"GH_TOKEN", "GITHUB_TOKEN"}
        }
        environment["GODOT_AI_DISABLE_TELEMETRY"] = "true"
        for kind in ("wheel", "sdist"):
            target = work / kind
            venv.EnvBuilder(with_pip=True).create(target)
            python = str(qualification.environment_python(target))
            if kind == "sdist":
                build_report = output / "build-resolution.json"
                qualification.execute(
                    [
                        python,
                        "-I",
                        "-m",
                        "pip",
                        "--isolated",
                        "install",
                        "--no-cache-dir",
                        "--force-reinstall",
                        "--index-url",
                        "https://pypi.org/simple",
                        "--report",
                        str(build_report),
                        *build_requirements(candidate, record["version"]),
                    ],
                    output / "build.log",
                    cwd=work,
                    environment=environment,
                )
                resolutions["build"] = verify_resolution(
                    read_resolution(build_report),
                    record,
                    require_release=False,
                )
            report = output / f"{kind}-resolution.json"
            command = [
                python,
                "-I",
                "-m",
                "pip",
                "--isolated",
                "install",
                "--no-cache-dir",
                "--index-url",
                "https://pypi.org/simple",
                "--report",
                str(report),
            ]
            command += ["--only-binary" if kind == "wheel" else "--no-binary", "godot-ai"]
            if kind == "sdist":
                command.append("--no-build-isolation")
            command.append("godot-ai==" + record["version"])
            qualification.execute(
                command, output / f"{kind}.log", cwd=work, environment=environment
            )
            resolutions[kind] = verify_resolution(read_resolution(report), record)
            for args in (
                ["-m", "pip", "check"],
                ["-m", "godot_ai", "--version"],
                [
                    "-c",
                    "import importlib.metadata as m; import godot_ai; from pathlib import Path; "
                    f"assert m.version('godot-ai') == {record['version']!r}; "
                    f"assert Path(godot_ai.__file__).resolve().is_relative_to({str(target)!r})",
                ],
            ):
                qualification.execute(
                    [python, "-I", *args], output / f"{kind}.log", cwd=work, environment=environment
                )
    result = {
        "schema": 1,
        "kind": "public",
        "status": "passed",
        "os": os_label,
        "python": python_version,
        "candidate": support.fingerprint(candidate / "evidence.json"),
        "version": record["version"],
        "source": record["source"],
        "pypi": pypi,
        "github": assets,
        "resolutions": resolutions,
    }
    (output / "row.json").write_bytes(support.canonical(result))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--os", required=True, choices=support.PLATFORMS)
    args = parser.parse_args(argv)
    try:
        public_row(args.candidate.resolve(), args.output.resolve(), args.os)
    except (
        support.ReleaseError,
        OSError,
        ValueError,
        KeyError,
        subprocess.CalledProcessError,
    ) as exc:
        print(f"public verification failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
