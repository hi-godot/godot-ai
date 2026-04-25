"""Tests for the `__version__` attribute's resolution order."""

from __future__ import annotations

import importlib
import importlib.metadata
import tomllib
from pathlib import Path


def _pyproject_version() -> str:
    pyproject = Path(__file__).resolve().parent.parent.parent / "pyproject.toml"
    with pyproject.open("rb") as f:
        return tomllib.load(f)["project"]["version"]


def test_version_matches_pyproject():
    ## Editable installs freeze their dist-info METADATA at the version
    ## that was current when the venv was created, so relying on
    ## importlib.metadata silently drifts from the source tree after
    ## every version bump. Anchoring __version__ to pyproject keeps
    ## session_list's server_version honest.
    import godot_ai

    assert godot_ai.__version__ == _pyproject_version()


def test_resolve_version_prefers_pyproject_over_metadata(tmp_path, monkeypatch):
    from godot_ai import _resolve_version

    repo_root = tmp_path / "repo"
    pkg_dir = repo_root / "src" / "godot_ai"
    pkg_dir.mkdir(parents=True)
    (repo_root / "pyproject.toml").write_text('[project]\nversion = "7.0.0"\n')
    fake_pkg_file = pkg_dir / "__init__.py"
    fake_pkg_file.write_text("")

    ## Even if installed-metadata disagrees, pyproject wins when present.
    import godot_ai

    monkeypatch.setattr(godot_ai, "_pkg_version", lambda _name: "9.9.9")

    assert _resolve_version(fake_pkg_file) == "7.0.0"


def test_resolve_version_falls_back_to_metadata_when_pyproject_missing(tmp_path, monkeypatch):
    from godot_ai import _resolve_version

    repo_root = tmp_path / "repo"
    pkg_dir = repo_root / "src" / "godot_ai"
    pkg_dir.mkdir(parents=True)
    fake_pkg_file = pkg_dir / "__init__.py"
    fake_pkg_file.write_text("")

    import godot_ai

    monkeypatch.setattr(godot_ai, "_pkg_version", lambda _name: "9.9.9")

    assert _resolve_version(fake_pkg_file) == "9.9.9"


def test_resolve_version_falls_back_to_placeholder_when_nothing_available(tmp_path, monkeypatch):
    from godot_ai import _resolve_version

    repo_root = tmp_path / "repo"
    pkg_dir = repo_root / "src" / "godot_ai"
    pkg_dir.mkdir(parents=True)
    fake_pkg_file = pkg_dir / "__init__.py"
    fake_pkg_file.write_text("")

    def raise_not_found(_name: str) -> str:
        raise importlib.metadata.PackageNotFoundError("godot-ai")

    import godot_ai

    monkeypatch.setattr(godot_ai, "_pkg_version", raise_not_found)

    assert _resolve_version(fake_pkg_file) == "0+unknown"


def test_resolve_version_skips_malformed_pyproject(tmp_path, monkeypatch):
    ## Corrupt / half-written pyproject shouldn't propagate a TOMLDecodeError
    ## on import — fall through to metadata.
    from godot_ai import _resolve_version

    repo_root = tmp_path / "repo"
    pkg_dir = repo_root / "src" / "godot_ai"
    pkg_dir.mkdir(parents=True)
    (repo_root / "pyproject.toml").write_text("[project\nversion = malformed")
    fake_pkg_file = pkg_dir / "__init__.py"
    fake_pkg_file.write_text("")

    import godot_ai

    monkeypatch.setattr(godot_ai, "_pkg_version", lambda _name: "9.9.9")

    assert _resolve_version(fake_pkg_file) == "9.9.9"
