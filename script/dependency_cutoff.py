"""The release's fixed dependency upload cutoff, shared by qualification steps."""

from __future__ import annotations

import configparser
import datetime as dt
import re
import shutil
import urllib.parse
import zipfile
from pathlib import Path

from script import release_support as support


def timestamp(value: str) -> dt.datetime:
    support.require(
        isinstance(value, str)
        and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", value),
        "dependency upload time must be a UTC RFC 3339 timestamp",
    )
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise support.ReleaseError("invalid dependency upload timestamp") from exc


def from_config(text: str) -> str:
    config = configparser.ConfigParser(interpolation=None)
    config.optionxform = str
    try:
        config.read_string(text)
        support.require(not config.defaults(), "plugin cutoff cannot come from DEFAULT values")
        value = config.get("plugin", "dependency_cutoff", fallback="")
        support.require(
            len(value) >= 2 and value.startswith('"') and value.endswith('"'),
            "dependency cutoff must be a quoted string",
        )
        value = value[1:-1]
    except configparser.Error as exc:
        raise support.ReleaseError("invalid plugin dependency cutoff configuration") from exc
    support.require(
        re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", value),
        "dependency cutoff must have UTC second precision",
    )
    timestamp(value)
    return value


def from_source(source: Path) -> str:
    return from_config((source / "plugin/addons/godot_ai/plugin.cfg").read_text())


def from_candidate(candidate: Path) -> str:
    # Callers first verify the candidate inventory and signed archive.
    with zipfile.ZipFile(candidate / "release/godot-ai-v4-plugin.zip") as archive:
        return from_config(archive.read("addons/godot_ai/plugin.cfg").decode("utf-8"))


def uv_args(cutoff: str) -> list[str]:
    timestamp(cutoff)
    # Our own distribution is uploaded after preparation; dependencies are not exempt.
    return ["--exclude-newer", cutoff, "--exclude-newer-package", "godot-ai=false"]


def compile_requirements(requirements, cutoff, output, python, environment, execute):
    """Resolve before pip downloads or installs, retaining a hashed lock as evidence."""
    uv = shutil.which("uv", path=environment.get("PATH"))
    support.require(uv is not None, "uv is required to enforce the release dependency cutoff")
    source = output.with_suffix(".in")
    source.write_text("\n".join(requirements) + "\n", encoding="utf-8")
    execute(
        [
            uv,
            "pip",
            "compile",
            str(source),
            "--python",
            python,
            "--no-config",
            "--no-sources",
            "--no-build",
            "--default-index",
            "https://pypi.org/simple",
            "--index-strategy",
            "first-index",
            "--keyring-provider",
            "disabled",
            *(uv_args(cutoff) if cutoff is not None else []),
            "--generate-hashes",
            "--no-header",
            "--no-annotate",
            "--output-file",
            str(output),
        ],
        output.with_suffix(".log"),
        cwd=output.parent,
        environment=environment,
    )


def capture_upload_times(dependencies: list[dict], cutoff: str | None) -> dict[str, str]:
    from script import release_promotion as promotion

    result = {}
    for row in dependencies:
        if row["name"] == "godot-ai":
            continue
        metadata = promotion.public_json(
            "https://pypi.org/pypi/"
            + urllib.parse.quote(row["name"], safe="")
            + "/"
            + urllib.parse.quote(row["version"], safe="")
            + "/json"
        )
        matches = [entry for entry in metadata["urls"] if entry["filename"] == row["filename"]]
        support.require(len(matches) == 1, "retained dependency absent from public PyPI")
        entry = matches[0]
        support.require(
            not entry.get("yanked")
            and entry["size"] == row["size"]
            and entry["digests"]["sha256"] == row["sha256"],
            "retained dependency differs from public PyPI",
        )
        result[row["filename"]] = entry["upload_time_iso_8601"]
    validate_upload_times(dependencies, result, cutoff)
    return result


def validate_upload_times(dependencies: list[dict], uploads: dict, cutoff: str | None) -> None:
    limit = timestamp(cutoff) if cutoff is not None else None
    expected = {row["filename"] for row in dependencies if row["name"] != "godot-ai"}
    own = {row["filename"] for row in dependencies if row["name"] == "godot-ai"}
    support.require(
        isinstance(uploads, dict) and expected <= set(uploads) <= expected | own,
        "dependency upload-time evidence is missing or unexpected",
    )
    for filename, value in uploads.items():
        uploaded = timestamp(value)
        support.require(
            filename in own or limit is None or uploaded <= limit,
            "dependency was uploaded after the release cutoff",
        )


def predecessor_cutoff(candidate: Path) -> str | None:
    return historical_archive_cutoff(candidate / "release/godot-ai-v4-plugin.zip")


def historical_archive_cutoff(path: Path) -> str | None:
    """Only historical archives may omit the policy; malformed present values fail."""
    with zipfile.ZipFile(path) as archive:
        text = archive.read("addons/godot_ai/plugin.cfg").decode("utf-8")
    config = configparser.ConfigParser(interpolation=None)
    try:
        config.read_string(text)
    except configparser.Error as exc:
        raise support.ReleaseError("invalid predecessor plugin configuration") from exc
    return from_config(text) if config.has_option("plugin", "dependency_cutoff") else None


def build_distributions(repo: Path, output: Path, config: dict, cutoff: str) -> None:
    """Build without a second, unconstrained PEP 517 dependency resolution."""
    import os
    import sys
    import tempfile

    from script import release_public_verify as public
    from script import release_qualification as qualification

    requirements = config.get("build-system", {}).get("requires")
    support.require(
        isinstance(requirements, list)
        and requirements
        and all(
            isinstance(item, str) and item and not item.startswith("-") for item in requirements
        ),
        "source build requirements are missing or invalid",
    )
    evidence = output.parent / (output.name + "-build-evidence")
    evidence.mkdir()
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("UV_", "PIP_", "PYTHON", "GODOT_AI_"))
        and key not in {"GH_TOKEN", "GITHUB_TOKEN"}
    }
    environment.update(
        PIP_CONFIG_FILE=os.devnull,
        PIP_DISABLE_PIP_VERSION_CHECK="1",
        PYTHONNOUSERSITE="1",
        GODOT_AI_DISABLE_TELEMETRY="true",
    )
    lock = evidence / "requirements.txt"
    compile_requirements(
        [*requirements, "build==1.6.1", "wheel==0.46.3"],
        cutoff,
        lock,
        sys.executable,
        environment,
        qualification.execute,
    )
    with tempfile.TemporaryDirectory(prefix="godot-ai-build-") as temporary:
        target = Path(temporary).resolve() / "venv"
        log = evidence / "build.log"
        qualification.execute(
            [sys.executable, "-m", "venv", str(target)], log, cwd=repo, environment=environment
        )
        python = str(qualification.environment_python(target))
        report = evidence / "install.json"
        qualification.execute(
            [
                python,
                "-I",
                "-m",
                "pip",
                "--isolated",
                "install",
                "--force-reinstall",
                "--index-url",
                "https://pypi.org/simple",
                "--require-hashes",
                "-r",
                str(lock),
                "--report",
                str(report),
            ],
            log,
            cwd=repo,
            environment=environment,
        )
        resolved = public.verify_resolution(
            public.read_resolution(report),
            {"version": "", "files": {}},
            cutoff,
            require_release=False,
        )
        (evidence / "dependency-evidence.json").write_bytes(
            support.canonical(
                {
                    "dependency_cutoff": cutoff,
                    "resolutions": resolved,
                }
            )
        )
        qualification.execute(
            [
                python,
                "-I",
                "-m",
                "build",
                "--no-isolation",
                "--outdir",
                str(output / "dist"),
            ],
            log,
            cwd=repo,
            environment=environment,
        )


def resolve_private_runtime(index: str, version: str, cutoff: str | None, work: Path) -> list[str]:
    """Resolve in memory; never retain a private index capability in diagnostics."""
    import os
    import subprocess
    import sys

    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("UV_", "PIP_", "PYTHON"))
    }
    uv = shutil.which("uv", path=environment.get("PATH"))
    support.require(uv is not None, "uv is required for retained runtime resolution")
    requirements = work / "runtime.in"
    requirements.write_text(f"godot-ai=={version}\n", encoding="utf-8")
    try:
        result = subprocess.run(
            [
                uv,
                "pip",
                "compile",
                str(requirements),
                "--python",
                sys.executable,
                "--no-config",
                "--no-sources",
                "--no-build",
                "--no-cache",
                "--default-index",
                index,
                "--index-strategy",
                "first-index",
                "--keyring-provider",
                "disabled",
                "--no-header",
                "--no-annotate",
                *(uv_args(cutoff) if cutoff is not None else []),
            ],
            cwd=work,
            env=environment,
            capture_output=True,
            text=True,
            timeout=2400,
        )
    except (OSError, subprocess.SubprocessError):
        raise support.ReleaseError("retained runtime resolver failed to run") from None
    # Even a resolver's error can include its authorized URL. Keep only a fixed error.
    support.require(result.returncode == 0, "retained runtime resolution failed")
    selected = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r"([A-Za-z0-9_.-]+)==([A-Za-z0-9.!+_-]+)", line)
        support.require(match is not None, "unexpected retained runtime resolution syntax")
        selected.append(re.sub(r"[-_.]+", "-", match[1]).lower() + "==" + match[2])
    support.require(selected and len(selected) == len(set(selected)), "invalid runtime resolution")
    return sorted(selected)
