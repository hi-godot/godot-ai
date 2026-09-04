"""The exact uvx pin must imply an exact reviewed security-runtime boundary."""

from __future__ import annotations

import tomllib
from importlib.metadata import PackageNotFoundError
from pathlib import Path

import pytest
import yaml

from godot_ai.runtime_dependencies import RUNTIME_DEPENDENCIES, verify_runtime_dependencies

ROOT = Path(__file__).resolve().parents[2]


def test_pyproject_exactly_pins_every_checked_runtime_distribution() -> None:
    with (ROOT / "pyproject.toml").open("rb") as file:
        project = tomllib.load(file)["project"]
    dependencies = project["dependencies"]

    assert project["requires-python"] == ">=3.11,<3.15"
    assert {item for item in dependencies if "==" in item} >= {
        f"{name}=={expected}" for name, expected in RUNTIME_DEPENDENCIES.items()
    }


def test_build_and_promotion_tooling_is_exactly_pinned() -> None:
    with (ROOT / "pyproject.toml").open("rb") as file:
        configuration = tomllib.load(file)

    assert configuration["build-system"]["requires"] == ["setuptools==84.0.0"]
    assert configuration["project"]["optional-dependencies"]["build"] == [
        "build==1.6.0",
        "pyinstaller==6.22.2",
    ]
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    assert 'python -m pip install "build==1.6.0"' in workflow
    assert "pip install --upgrade pip build" not in workflow


def test_ci_covers_every_advertised_python_minor() -> None:
    workflow = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")

    assert 'python-version: ["3.11", "3.12", "3.13", "3.14"]' in workflow


def test_ci_python_matrix_runs_every_desktop_os_at_floor_or_ceiling() -> None:
    """The matrix is two axes, not a product: every interpreter on Linux, and
    every OS with platform-specific code at the floor and/or the ceiling."""
    workflow = yaml.safe_load(
        (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
    )
    matrix = workflow["jobs"]["python-tests"]["strategy"]["matrix"]
    cells = {(os_name, version) for os_name in matrix["os"] for version in matrix["python-version"]}
    cells |= {(row["os"], row["python-version"]) for row in matrix["include"]}

    assert {version for os_name, version in cells if os_name == "ubuntu-latest"} == {
        "3.11",
        "3.12",
        "3.13",
        "3.14",
    }
    assert {version for os_name, version in cells if os_name == "windows-latest"} == {
        "3.11",
        "3.14",
    }
    assert {version for os_name, version in cells if os_name == "macos-latest"} == {"3.14"}
    # The Codecov and architecture-gate steps are keyed to this exact cell.
    assert ("ubuntu-latest", "3.13") in cells


def test_cli_checks_runtime_contract_before_importing_framework_paths() -> None:
    source = (ROOT / "src" / "godot_ai" / "__init__.py").read_text(encoding="utf-8")
    check = source.index("    verify_runtime_dependencies()")

    assert check < source.index("        from godot_ai.attach.main import main")
    assert check < source.index("        import fastmcp")


def test_current_test_runtime_matches_release_contract() -> None:
    verify_runtime_dependencies()


def test_runtime_contract_reports_every_missing_or_changed_distribution() -> None:
    def wrong_version(name: str) -> str:
        return "missing" if name == "mcp" else "0.0.0"

    with pytest.raises(RuntimeError, match="fastmcp==0.0.0") as raised:
        verify_runtime_dependencies(wrong_version)

    assert "mcp==missing" in str(raised.value)
    assert "websockets==0.0.0" in str(raised.value)


def test_runtime_contract_converts_missing_metadata_to_closed_failure() -> None:
    def missing_metadata(name: str) -> str:
        if name == "fastmcp":
            raise PackageNotFoundError(name)
        return RUNTIME_DEPENDENCIES[name]

    with pytest.raises(RuntimeError, match=r"fastmcp==missing"):
        verify_runtime_dependencies(missing_metadata)
