"""Fixed release cutoff parsing and real uv resolution against retained wheels."""

import hashlib
import os
import shutil
import subprocess
import sys
import zipfile

import pytest

from script import dependency_cutoff as policy
from script import release_support as support
from script.qualification_index import retained_index

CUTOFF = "2026-11-01T19:00:00Z"


@pytest.mark.parametrize(
    "value",
    [
        "",
        "2026-11-01",
        "2026-11-01T19:00:00.1Z",
        "2026-02-30T00:00:00Z",
        "2026-11-01T19:00:00+00:00",
    ],
)
def test_config_refuses_invalid_or_noncanonical_cutoff(value):
    with pytest.raises(support.ReleaseError):
        policy.from_config(f'[plugin]\ndependency_cutoff="{value}"\n')


def test_cutoff_parsing_and_artifact_fractional_precision():
    assert policy.from_config(f'[plugin]\ndependency_cutoff="{CUTOFF}"\n') == CUTOFF
    assert policy.timestamp("2026-11-01T18:59:59.123456Z") < policy.timestamp(CUTOFF)


def wheel(root, name, version, requires=()):
    normalized = name.replace("-", "_")
    filename = f"{normalized}-{version}-py3-none-any.whl"
    prefix = f"{normalized}-{version}.dist-info/"
    with zipfile.ZipFile(root / filename, "w") as archive:
        archive.writestr(
            prefix + "METADATA",
            f"Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n"
            + "".join(f"Requires-Dist: {requirement}\n" for requirement in requires),
        )
        archive.writestr(
            prefix + "WHEEL",
            "Wheel-Version: 1.0\nGenerator: cutoff-test\n"
            "Root-Is-Purelib: true\nTag: py3-none-any\n",
        )
        archive.writestr(prefix + "RECORD", "")
    payload = (root / filename).read_bytes()
    return dict(
        name=name,
        version=version,
        filename=filename,
        size=len(payload),
        sha256=hashlib.sha256(payload).hexdigest(),
    )


def test_real_uv_selects_old_leaf_and_exempts_new_own_package(tmp_path, monkeypatch):
    uv = shutil.which("uv")
    if uv is None:
        pytest.skip("real uv executable unavailable")
    packages = tmp_path / "packages"
    packages.mkdir()
    rows = [
        wheel(packages, "cutoff-leaf", "1.0"),
        wheel(packages, "cutoff-leaf", "2.0"),
        wheel(packages, "godot-ai", "99.0", ["cutoff-leaf>=1"]),
    ]
    uploads = {
        rows[0]["filename"]: "2026-10-31T12:00:00.123456Z",
        rows[1]["filename"]: "2026-11-02T12:00:00Z",
        rows[2]["filename"]: "2026-11-03T12:00:00Z",
    }
    source = tmp_path / "requirements.in"
    source.write_text("godot-ai==99.0\n")
    environment = {
        key: value
        for key, value in os.environ.items()
        if not key.startswith(("UV_", "PIP_", "PYTHON"))
    }

    def resolve(index):
        return subprocess.run(
            [
                uv,
                "pip",
                "compile",
                str(source),
                "--python",
                sys.executable,
                "--no-config",
                "--no-cache",
                "--no-build",
                "--default-index",
                index,
                *policy.uv_args(CUTOFF),
                "--generate-hashes",
                "--no-header",
                "--no-annotate",
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=60,
        )

    with retained_index(packages, rows, uploads) as (index, _):
        result = resolve(index)
    assert result.returncode == 0, result.stderr
    assert "cutoff-leaf==1.0" in result.stdout
    assert "cutoff-leaf==2.0" not in result.stdout
    assert "godot-ai==99.0" in result.stdout
    assert "--hash=sha256:" in result.stdout
    # Simulate an external index that omits timestamps, bypassing only our preflight.
    with monkeypatch.context() as patch:
        patch.setattr(policy, "validate_upload_times", lambda *_args: None)
        with retained_index(packages, rows, {}) as (index, _):
            missing = resolve(index)
    assert missing.returncode != 0
    assert "missing an upload date" in missing.stderr.lower()
    # The production index fails before starting if a dependency's timestamp is absent.
    with pytest.raises(support.ReleaseError, match="upload-time evidence"):
        with retained_index(packages, rows, {}):
            pytest.fail("index accepted missing timestamps")


def test_capture_binds_real_pypi_timestamp_to_exact_artifact(monkeypatch):
    from script import release_promotion

    row = dict(name="leaf", version="1", filename="leaf-1.whl", size=7, sha256="a" * 64)
    entry = dict(
        filename=row["filename"],
        size=7,
        digests={"sha256": "a" * 64},
        upload_time_iso_8601="2026-11-01T18:00:00.123456Z",
    )
    monkeypatch.setattr(release_promotion, "public_json", lambda _url: {"urls": [entry]})
    assert policy.capture_upload_times([row], CUTOFF) == {
        row["filename"]: entry["upload_time_iso_8601"]
    }
    entry["digests"]["sha256"] = "b" * 64
    with pytest.raises(support.ReleaseError, match="differs"):
        policy.capture_upload_times([row], CUTOFF)


@pytest.mark.parametrize(
    "text",
    [
        '[DEFAULT]\ndependency_cutoff="2026-11-01T19:00:00Z"\n[plugin]\n',
        '[plugin]\nDEPENDENCY_CUTOFF="2026-11-01T19:00:00Z"\n',
        "[plugin]\ndependency_cutoff=2026-11-01T19:00:00Z\n",
        '[plugin]\ndependency_cutoff=""2026-11-01T19:00:00Z""\n',
    ],
)
def test_config_does_not_accept_python_only_config_interpretations(text):
    with pytest.raises(support.ReleaseError):
        policy.from_config(text)


@pytest.mark.parametrize(
    "uploads", [{}, {"leaf.whl": "2026-11-02T00:00:00Z"}, {"leaf.whl": "unknown"}]
)
def test_artifact_evidence_refuses_missing_new_or_unknown_times(uploads):
    with pytest.raises(support.ReleaseError):
        policy.validate_upload_times([{"filename": "leaf.whl", "name": "leaf"}], uploads, CUTOFF)


def test_historical_absence_is_distinct_from_invalid_present_policy(tmp_path):
    path = tmp_path / "predecessor.zip"
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("addons/godot_ai/plugin.cfg", '[plugin]\nversion="4.0.0"\n')
    assert policy.historical_archive_cutoff(path) is None
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("addons/godot_ai/plugin.cfg", '[plugin]\ndependency_cutoff=""\n')
    with pytest.raises(support.ReleaseError):
        policy.historical_archive_cutoff(path)


def test_real_union_resolution_preserves_distinct_explicit_pins(tmp_path):
    if shutil.which("uv") is None:
        pytest.skip("real uv executable unavailable")
    packages = tmp_path / "packages"
    packages.mkdir()
    rows = [
        wheel(packages, "cutoff-leaf", "1.0"),
        wheel(packages, "cutoff-leaf", "2.0"),
        wheel(packages, "godot-ai", "98.0", ["cutoff-leaf==1.0"]),
        wheel(packages, "godot-ai", "99.0", ["cutoff-leaf==2.0"]),
    ]
    uploads = {row["filename"]: "2026-10-31T00:00:00Z" for row in rows if row["name"] != "godot-ai"}
    with retained_index(packages, rows, uploads) as (index, _):
        assert policy.resolve_private_runtime(index, "98.0", None, tmp_path) == [
            "cutoff-leaf==1.0",
            "godot-ai==98.0",
        ]
        assert policy.resolve_private_runtime(index, "99.0", CUTOFF, tmp_path) == [
            "cutoff-leaf==2.0",
            "godot-ai==99.0",
        ]
    # The retained input contains only a package pin; no capability URL is written.
    assert (tmp_path / "runtime.in").read_text(encoding="utf-8") == "godot-ai==99.0\n"


def test_build_uses_hashed_isolated_environment_without_second_resolution(tmp_path, monkeypatch):
    from script import release_public_verify as public
    from script import release_qualification as qualification

    repo = tmp_path / "repo"
    repo.mkdir()
    output = tmp_path / "candidate"
    calls = []
    monkeypatch.setattr(
        policy, "compile_requirements", lambda *args: calls.append(("compile", args))
    )
    monkeypatch.setattr(
        qualification,
        "execute",
        lambda command, *_args, **_kwargs: calls.append(("execute", command)),
    )
    monkeypatch.setattr(public, "read_resolution", lambda _: {})
    monkeypatch.setattr(public, "verify_resolution", lambda *_args, **_kwargs: [])
    policy.build_distributions(
        repo, output, {"build-system": {"requires": ["setuptools==84.2.1"]}}, CUTOFF
    )
    assert calls[0][0] == "compile" and calls[0][1][1] == CUTOFF
    commands = [args for kind, args in calls if kind == "execute"]
    assert "--require-hashes" in commands[1]
    assert "--no-isolation" in commands[2]
    assert commands[1][0] == commands[2][0]
    assert commands[1][0] != sys.executable


def test_private_resolver_timeout_does_not_expose_capability(tmp_path, monkeypatch):
    monkeypatch.setattr(shutil, "which", lambda *_args, **_kwargs: "/uv")
    secret = "http://127.0.0.1:1/private-capability/simple/"

    def timeout(command, **_kwargs):
        raise subprocess.TimeoutExpired(command, 2400)

    monkeypatch.setattr(subprocess, "run", timeout)
    with pytest.raises(support.ReleaseError) as error:
        policy.resolve_private_runtime(secret, "1.0", CUTOFF, tmp_path)
    assert "private-capability" not in str(error.value)
    assert str(error.value) == "retained runtime resolver failed to run"


def test_compile_requirements_without_uv_fails_before_writing_or_executing(tmp_path):
    missing_path = tmp_path / "empty-path"
    missing_path.mkdir()
    assert shutil.which("uv", path=str(missing_path)) is None
    output = tmp_path / "requirements.txt"
    calls = []
    with pytest.raises(support.ReleaseError, match="uv is required to enforce"):
        policy.compile_requirements(
            ["example==1.0"],
            CUTOFF,
            output,
            sys.executable,
            {"PATH": str(missing_path)},
            lambda *args, **kwargs: calls.append(args),
        )
    assert calls == []
    assert not output.exists()
    assert not output.with_suffix(".in").exists()
