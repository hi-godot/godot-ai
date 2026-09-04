import hashlib
import re

import pytest

from script import qualification_engine as engine
from script import release_support as support


@pytest.mark.parametrize(
    ("system", "row"),
    [("Linux", "ubuntu-latest"), ("Darwin", "macos-latest"), ("Windows", "windows-latest")],
)
def test_host_row_is_derived_from_real_platform(monkeypatch, system, row):
    monkeypatch.setattr(engine.platform, "system", lambda: system)
    assert engine.host_row() == row


def test_unknown_host_is_refused(monkeypatch):
    monkeypatch.setattr(engine.platform, "system", lambda: "unknown")
    with pytest.raises(support.ReleaseError, match="unsupported qualification host"):
        engine.host_row()


def test_manifest_pins_all_six_distinct_official_executables():
    manifest = support.read_json(engine.MANIFEST, canonical_required=False)
    assert set(manifest["builds"]) == {"4.7.0", "4.7.2"}
    digests = set()
    for version, rows in manifest["builds"].items():
        assert set(rows) == set(support.PLATFORMS)
        for os_label, pin in rows.items():
            assert engine.build_pin(version, os_label) == pin
            assert set(pin) == {"archive", "archive_sha256", "executable", "sha256", "size"}
            assert 100_000_000 < pin["size"] < 512_000_000
            assert pin["archive"].startswith(f"Godot_v{version.removesuffix('.0')}-stable_")
            assert pin["archive"].endswith(".zip")
            assert pin["executable"]
            assert re.fullmatch("[0-9a-f]{64}", pin["archive_sha256"])
            assert re.fullmatch("[0-9a-f]{64}", pin["sha256"])
            digests.add(pin["sha256"])
    assert len(digests) == 6


@pytest.mark.parametrize(("version", "os_label"), [("4.7.1", "macos-latest"), ("4.7.2", "other")])
def test_unpinned_build_is_refused(version, os_label):
    with pytest.raises(support.ReleaseError, match="no reviewed executable pin"):
        engine.build_pin(version, os_label)


def test_unsupported_pin_schema_is_refused(monkeypatch):
    monkeypatch.setattr(support, "read_json", lambda *args, **kwargs: {"schema": 2})
    with pytest.raises(support.ReleaseError, match="unsupported Godot pin schema"):
        engine.build_pin("4.7.2", "macos-latest")


def test_executable_bytes_must_match_reviewed_pin(monkeypatch, tmp_path):
    executable = tmp_path / "godot"
    executable.write_bytes(b"fixture executable")
    digest = hashlib.sha256(executable.read_bytes()).hexdigest()
    monkeypatch.setattr(
        engine,
        "build_pin",
        lambda *args: {"sha256": digest, "archive_sha256": "a" * 64, "size": 18},
    )
    monkeypatch.setattr(engine, "host_row", lambda: "ubuntu-latest")
    assert engine.verify_executable(executable, "4.7.0") == {
        "path": str(executable.resolve()),
        "sha256": digest,
        "size": 18,
        "archive_sha256": "a" * 64,
    }
    executable.write_bytes(b"changed executable")
    with pytest.raises(support.ReleaseError, match="SHA-256 differs"):
        engine.verify_executable(executable, "4.7.0")
    executable.write_bytes(b"wrong size")
    with pytest.raises(support.ReleaseError, match="size/type differs"):
        engine.verify_executable(executable, "4.7.0")


@pytest.mark.parametrize("version", ["4.7.0", "4.7.2"])
def test_evidence_identity_is_bound_to_platform_version_and_bytes(version):
    pin = engine.build_pin(version, "macos-latest")
    identity = {**pin, "version": f"{version.removesuffix('.0')}.stable.official.fixture"}
    engine.validate_identity(identity, version, "macos-latest")
    for field, value in (
        ("sha256", "b" * 64),
        ("archive_sha256", "c" * 64),
        ("size", 1),
        ("size", True),
        ("version", None),
        ("version", "4.6.stable.official.wrong"),
    ):
        with pytest.raises(support.ReleaseError, match="Godot evidence"):
            engine.validate_identity({**identity, field: value}, version, "macos-latest")
    with pytest.raises(support.ReleaseError, match="Godot evidence"):
        engine.validate_identity(identity, version, "windows-latest")
    with pytest.raises(support.ReleaseError, match="missing pinned Godot identity"):
        engine.validate_identity(None, version, "macos-latest")
