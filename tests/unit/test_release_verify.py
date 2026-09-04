"""Contracts for ``godot_ai.release_verify`` and the closed-editor installer.

Every release here is built and signed in-test with a fresh 2048-bit RSA key
so no test depends on OpenSSL or on the production signing key; the module
under test learns the fixture key through the same ``PUBLIC_KEY_PEM`` seam the
release pipeline's own tests use.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import subprocess
import sys
import zipfile
from pathlib import Path
from types import SimpleNamespace

import pytest
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa

from godot_ai import release_verify as verify
from tests.unit.test_v4_release import v4_release

ROOT = Path(__file__).resolve().parents[2]
PRODUCTION_KEY = verify.PUBLIC_KEY_PEM
IDENTITY = (verify.REPOSITORY, "stable", "v4.0.0", "4.0.0", "f" * 40)
PLUGIN_FILES: dict[str, bytes] = {
    "plugin.cfg": b'[plugin]\nname="Godot AI"\nversion="4.0.0"\n',
    "plugin.gd": b"@tool\nextends EditorPlugin\n",
    "utils/update_installer.gd": b"extends RefCounted\n",
    "utils/empty.gd": b"",
}
OLD_FILES: dict[str, bytes] = {
    "plugin.cfg": b'[plugin]\nversion="3.2.4"\n',
    "old-only.gd": b"extends RefCounted\n",
    "utils/legacy.gd": b"# legacy\n",
}


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _pem(private) -> str:
    return (
        private.public_key()
        .public_bytes(serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo)
        .decode("ascii")
    )


def _sign(private, raw: bytes) -> bytes:
    return private.sign(raw, padding.PKCS1v15(), hashes.SHA256())


def _entries(files: dict[str, bytes]) -> list[tuple[str, bytes]]:
    return sorted(
        ((verify.PLUGIN_PREFIX + path, data) for path, data in files.items()),
        key=lambda entry: entry[0].encode("utf-8"),
    )


def _zip_bytes(
    entries: list[tuple[str, bytes]],
    *,
    date_time: tuple[int, ...] = verify.FIXED_TIME,
    compress_type: int = zipfile.ZIP_STORED,
    create_system: int = 3,
) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_STORED, allowZip64=False) as archive:
        for name, data in entries:
            info = zipfile.ZipInfo(name, date_time)
            info.compress_type = compress_type
            info.create_system = create_system
            info.external_attr = verify.FIXED_MODE << 16
            archive.writestr(info, data)
    return buffer.getvalue()


def _manifest(archive: bytes, entries: list[tuple[str, bytes]], identity=IDENTITY) -> dict:
    return {
        "schema_version": 1,
        "repository": identity[0],
        "channel": identity[1],
        "tag": identity[2],
        "version": identity[3],
        "source_commit": identity[4],
        "asset": {"name": verify.ASSET_NAME, "size": len(archive), "sha256": _sha256(archive)},
        "inventory": [
            {"path": name, "size": len(data), "sha256": _sha256(data)} for name, data in entries
        ],
    }


def _publish(
    root: Path, private, archive_data: bytes, manifest: dict, *, raw: bytes | None = None
) -> SimpleNamespace:
    root.mkdir(parents=True, exist_ok=True)
    archive = root / verify.ASSET_NAME
    archive.write_bytes(archive_data)
    raw = verify._canonical(manifest) if raw is None else raw
    manifest_path = root / verify.MANIFEST_NAME
    manifest_path.write_bytes(raw)
    signature = root / verify.SIGNATURE_NAME
    signature.write_bytes(_sign(private, raw))
    return SimpleNamespace(
        archive=archive,
        manifest_path=manifest_path,
        signature=signature,
        raw=raw,
        manifest=manifest,
        paths=(archive, manifest_path, signature),
    )


def _release(root: Path, private, files=PLUGIN_FILES, identity=IDENTITY) -> SimpleNamespace:
    entries = _entries(files)
    data = _zip_bytes(entries)
    return _publish(root, private, data, _manifest(data, entries, identity))


def _files(files: dict[str, bytes]) -> dict[str, dict[str, object]]:
    return {path: {"size": len(data), "sha256": _sha256(data)} for path, data in files.items()}


@pytest.fixture(scope="module")
def keys() -> SimpleNamespace:
    private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    return SimpleNamespace(private=private, public=_pem(private))


@pytest.fixture
def trusted(keys, monkeypatch) -> SimpleNamespace:
    monkeypatch.setattr(verify, "PUBLIC_KEY_PEM", keys.public)
    monkeypatch.setattr(v4_release, "PUBLIC_KEY_PEM", keys.public)
    return keys


@pytest.fixture
def release(trusted, tmp_path) -> SimpleNamespace:
    return _release(tmp_path / "release", trusted.private)


# --- signature -------------------------------------------------------------


def test_signature_over_a_canonical_manifest_verifies_with_a_fresh_key(release, trusted):
    verify._verify_signature(release.raw, release.signature.read_bytes(), trusted.public)
    assert verify.verify_release(*release.paths, IDENTITY) == release.manifest


def test_signature_from_another_key_is_rejected(release, trusted):
    forged = _sign(rsa.generate_private_key(public_exponent=65537, key_size=2048), release.raw)
    with pytest.raises(verify.ReleaseError, match="verification failed"):
        verify._verify_signature(release.raw, forged, trusted.public)
    release.signature.write_bytes(forged)
    with pytest.raises(verify.ReleaseError, match="verification failed"):
        verify.verify_release(*release.paths, IDENTITY)


@pytest.mark.parametrize("position", [0, 100, 255])
def test_one_altered_signature_byte_is_rejected(release, trusted, position):
    signature = bytearray(release.signature.read_bytes())
    signature[position] ^= 0x01
    with pytest.raises(verify.ReleaseError, match="verification failed"):
        verify._verify_signature(release.raw, bytes(signature), trusted.public)
    release.signature.write_bytes(bytes(signature))
    with pytest.raises(verify.ReleaseError, match="verification failed"):
        verify.verify_release(*release.paths, IDENTITY)


def test_a_manifest_that_differs_from_the_signed_bytes_is_rejected(release, trusted):
    altered = release.raw.replace(b'"' + b"f" * 40 + b'"', b'"' + b"e" * 40 + b'"', 1)
    assert altered != release.raw
    with pytest.raises(verify.ReleaseError, match="verification failed"):
        verify._verify_signature(altered, release.signature.read_bytes(), trusted.public)
    # Still canonical and self-consistent, so only the signature can catch it.
    release.manifest_path.write_bytes(altered)
    with pytest.raises(verify.ReleaseError, match="verification failed"):
        verify.verify_release(*release.paths, (*IDENTITY[:4], "e" * 40))


@pytest.mark.parametrize(
    "mutate",
    [
        lambda signature: signature[:-1],
        lambda signature: signature + b"\0",
        lambda signature: b"\0" * verify.SIGNATURE_SIZE,
        lambda signature: b"",
    ],
)
def test_a_signature_of_the_wrong_size_for_the_key_is_rejected(release, trusted, mutate):
    wrong = mutate(release.signature.read_bytes())
    with pytest.raises(verify.ReleaseError, match="expected exactly 256 bytes"):
        verify._verify_signature(release.raw, wrong, trusted.public)
    if wrong:
        release.signature.write_bytes(wrong)
        with pytest.raises(verify.ReleaseError, match="expected exactly 256 bytes"):
            verify.verify_release(*release.paths, IDENTITY)


def test_production_key_is_rsa_4096_so_its_signatures_are_512_bytes():
    with pytest.raises(verify.ReleaseError, match="expected exactly 512 bytes"):
        verify._verify_signature(b"manifest\n", b"\0" * 256, PRODUCTION_KEY)
    with pytest.raises(verify.ReleaseError, match="verification failed"):
        verify._verify_signature(b"manifest\n", b"\0" * 512, PRODUCTION_KEY)


def test_non_rsa_or_malformed_public_keys_are_rejected(release):
    signature = release.signature.read_bytes()
    elliptic = _pem(ec.generate_private_key(ec.SECP256R1()))
    with pytest.raises(verify.ReleaseError, match="expected an RSA public key"):
        verify._verify_signature(release.raw, signature, elliptic)
    with pytest.raises(verify.ReleaseError, match="PEM SubjectPublicKeyInfo"):
        verify._verify_signature(release.raw, signature, "-----BEGIN PUBLIC KEY-----\nnope\n")


def test_importing_the_server_package_never_imports_cryptography():
    code = (
        "import sys, godot_ai, godot_ai.release_verify; "
        "loaded = sorted(name for name in sys.modules if name.startswith('cryptography')); "
        "assert not loaded, loaded"
    )
    subprocess.run([sys.executable, "-c", code], check=True, cwd=ROOT)


# --- every other check, one representative each ---------------------------


def test_non_canonical_manifest_encoding_is_rejected(trusted, tmp_path):
    entries = _entries(PLUGIN_FILES)
    data = _zip_bytes(entries)
    manifest = _manifest(data, entries)
    pretty = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")
    release = _publish(tmp_path / "release", trusted.private, data, manifest, raw=pretty)
    with pytest.raises(verify.ReleaseError, match="not canonical JSON"):
        verify.verify_release(*release.paths, IDENTITY)


@pytest.mark.parametrize("raw", [b'{"x":1,"x":2}\n', b'{"x":NaN}\n', b'{"x":Infinity}\n'])
def test_manifest_json_is_strict(raw):
    with pytest.raises(verify.ReleaseError):
        verify._strict_json(raw, "manifest")


@pytest.mark.parametrize(
    ("field", "value", "message"),
    [
        ("repository", "evil/godot-ai", "repository"),
        ("channel", "beta", "stable-only"),
        ("tag", "v4.0.1", "matching v4 tag"),
        ("version", "3.9.9", "matching v4 tag"),
        ("source_commit", "F" * 40, "40 lowercase hex"),
    ],
)
def test_identity_keys_are_checked_even_when_signed(trusted, tmp_path, field, value, message):
    entries = _entries(PLUGIN_FILES)
    data = _zip_bytes(entries)
    manifest = _manifest(data, entries)
    manifest[field] = value
    release = _publish(tmp_path / "release", trusted.private, data, manifest)
    with pytest.raises(verify.ReleaseError, match=message):
        verify.verify_release(*release.paths, IDENTITY)


def test_release_identity_must_match_the_explicit_expectation(release):
    with pytest.raises(verify.ReleaseError, match="does not match the explicit expectation"):
        verify.verify_release(*release.paths, (*IDENTITY[:4], "0" * 40))


def test_archive_bytes_must_match_the_signed_asset(release):
    release.archive.write_bytes(release.archive.read_bytes() + b"\0")
    with pytest.raises(verify.ReleaseError, match="size or SHA-256 differs"):
        verify.verify_release(*release.paths, IDENTITY)


def test_asset_name_is_fixed(trusted, tmp_path):
    entries = _entries(PLUGIN_FILES)
    data = _zip_bytes(entries)
    manifest = _manifest(data, entries)
    manifest["asset"]["name"] = "other.zip"
    release = _publish(tmp_path / "release", trusted.private, data, manifest)
    with pytest.raises(verify.ReleaseError, match="manifest.asset.name"):
        verify.verify_release(*release.paths, IDENTITY)


@pytest.mark.parametrize(
    ("path", "message"),
    [
        ("addons/godot_ai/../escape.gd", "unsafe path component"),
        ("addons/other/plugin.gd", "beneath addons/godot_ai/"),
        ("addons/godot_ai/CON.gd", "reserved path component"),
        ("addons/godot_ai/PLUGIN.GD", "case/Unicode-colliding"),
        ("addons/godot_ai/utils", "file/ancestor collision"),
    ],
)
def test_unsafe_inventory_paths_are_rejected_even_when_signed(trusted, tmp_path, path, message):
    entries = sorted(
        [*_entries(PLUGIN_FILES), (path, b"x")], key=lambda entry: entry[0].encode("utf-8")
    )
    data = _zip_bytes(entries)
    release = _publish(tmp_path / "release", trusted.private, data, _manifest(data, entries))
    with pytest.raises(verify.ReleaseError, match=message):
        verify.verify_release(*release.paths, IDENTITY)


def test_archive_entries_must_exactly_match_the_inventory(trusted, tmp_path):
    entries = _entries(PLUGIN_FILES)
    data = _zip_bytes([*entries, ("addons/godot_ai/zz_extra.gd", b"extra")])
    release = _publish(tmp_path / "release", trusted.private, data, _manifest(data, entries))
    with pytest.raises(verify.ReleaseError, match="do not exactly match the sorted inventory"):
        verify.verify_release(*release.paths, IDENTITY)


@pytest.mark.parametrize(
    "metadata",
    [
        {"date_time": (2024, 1, 1, 0, 0, 0)},
        {"compress_type": zipfile.ZIP_DEFLATED},
        {"create_system": 0},
    ],
)
def test_non_canonical_zip_metadata_is_rejected(trusted, tmp_path, metadata):
    entries = _entries(PLUGIN_FILES)
    data = _zip_bytes(entries, **metadata)
    release = _publish(tmp_path / "release", trusted.private, data, _manifest(data, entries))
    with pytest.raises(verify.ReleaseError, match="unsafe or non-canonical ZIP metadata"):
        verify.verify_release(*release.paths, IDENTITY)


def test_plugin_cfg_version_must_match_the_signed_manifest(trusted, tmp_path):
    files = {**PLUGIN_FILES, "plugin.cfg": b'[plugin]\nversion="4.0.1"\n'}
    release = _release(tmp_path / "release", trusted.private, files)
    with pytest.raises(verify.ReleaseError, match="version differs from signed manifest"):
        verify.verify_release(*release.paths, IDENTITY)


def test_stage_verified_release_extracts_the_exact_tree_once(release, tmp_path):
    destination = tmp_path / "stage"
    plugin, digest, manifest = verify.stage_verified_release(*release.paths, IDENTITY, destination)

    assert plugin == destination / "addons" / "godot_ai"
    assert digest == _sha256(release.raw)
    assert verify.hash_tree(plugin) == {
        "files": _files(PLUGIN_FILES),
        "tree_sha256": verify.inventory_tree_hash(manifest),
    }
    with pytest.raises(verify.ReleaseError, match="destination already exists"):
        verify.stage_verified_release(*release.paths, IDENTITY, destination)


# --- closed-editor install --------------------------------------------------


def _project(root: Path, files: dict[str, bytes] | None = OLD_FILES) -> Path:
    project = root / "project"
    project.mkdir(parents=True)
    (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    for path, data in (files or {}).items():
        target = project.joinpath("addons", "godot_ai", *path.split("/"))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
    return project.resolve()


def _install_args(release, project: Path) -> list[str]:
    return [
        "install",
        "--archive",
        str(release.archive),
        "--manifest",
        str(release.manifest_path),
        "--signature",
        str(release.signature),
        "--expected-repository",
        IDENTITY[0],
        "--expected-channel",
        IDENTITY[1],
        "--expected-tag",
        IDENTITY[2],
        "--expected-version",
        IDENTITY[3],
        "--expected-source",
        IDENTITY[4],
        "--project-root",
        str(project),
    ]


def _marker(project: Path) -> dict:
    return json.loads((project / "addons/.godot_ai_update/pending.json").read_text(encoding="utf-8"))


def test_install_swaps_the_old_tree_for_the_signed_tree_and_retains_a_backup(
    release, tmp_path, capsys
):
    project = _project(tmp_path)
    update = project / "addons/.godot_ai_update"
    live = project / "addons/godot_ai"
    backup = update / "backup/3.2.4"

    assert v4_release.main(_install_args(release, project)) == 0

    expected_line = f"OK: installed exact v4 tree 4.0.0; retained 3.2.4 at {backup}\n"
    assert capsys.readouterr().out == expected_line
    expected_tree = verify.inventory_tree_hash(release.manifest)
    assert verify.hash_tree(live) == {"files": _files(PLUGIN_FILES), "tree_sha256": expected_tree}
    assert verify.hash_tree(backup)["files"] == _files(OLD_FILES)
    assert _marker(project) == {
        "status": "success",
        "from_version": "3.2.4",
        "to_version": "4.0.0",
        "replace_owned_mismatches": True,
        "manifest_sha256": _sha256(release.raw),
        "expected_tree_sha256": expected_tree,
        "backup_root": str(backup),
    }
    for name in (".gdignore", ".gitignore"):
        assert (update / name).read_bytes() == b"*\n"
    assert not (update / "stage").exists()
    assert not (update / "lock.json").exists()
    assert not (update / "quarantine").exists()


def test_install_into_a_fresh_project_records_no_backup(release, tmp_path, capsys):
    project = _project(tmp_path, files=None)

    assert v4_release.main(_install_args(release, project)) == 0

    assert capsys.readouterr().out == "OK: installed exact v4 tree 4.0.0\n"
    assert verify.hash_tree(project / "addons/godot_ai")["files"] == _files(PLUGIN_FILES)
    marker = _marker(project)
    assert (marker["status"], marker["from_version"], marker["backup_root"]) == ("success", "", "")
    assert not (project / "addons/.godot_ai_update/backup").exists()


def test_install_replaces_a_retained_backup_of_the_same_version(release, tmp_path):
    project = _project(tmp_path)
    stale = project / "addons/.godot_ai_update/backup/3.2.4"
    stale.mkdir(parents=True)
    (stale / "stale.gd").write_bytes(b"stale\n")

    assert v4_release.main(_install_args(release, project)) == 0

    assert verify.hash_tree(stale)["files"] == _files(OLD_FILES)
    assert _marker(project)["status"] == "success"


def test_install_rolls_back_when_the_swapped_tree_does_not_verify(release, tmp_path):
    project = _project(tmp_path)
    update = project / "addons/.godot_ai_update"
    live = project / "addons/godot_ai"

    def tamper(swapped: Path) -> None:
        assert swapped == live
        (swapped / "plugin.gd").write_bytes(b"tampered\n")

    with pytest.raises(v4_release.ReleaseError, match="install rolled back"):
        v4_release.install_verified_release(
            *release.paths, IDENTITY, project, _after_swap_hook=tamper
        )

    assert verify.hash_tree(live)["files"] == _files(OLD_FILES)
    quarantine = update / "quarantine"
    assert (quarantine / "plugin.gd").read_bytes() == b"tampered\n"
    marker = _marker(project)
    assert marker["status"] == "rolled_back"
    assert "differs from expected" in marker["reason"]
    assert marker["from_version"] == "3.2.4" and marker["to_version"] == "4.0.0"
    assert marker["backup_root"] == str(update / "backup/3.2.4")
    assert marker["quarantine_root"] == str(quarantine)
    assert not (update / "backup/3.2.4").exists()
    assert not (update / "stage").exists()
    assert not (update / "lock.json").exists()


def test_install_rollback_on_a_fresh_project_leaves_no_live_tree(release, tmp_path):
    project = _project(tmp_path, files=None)

    def plant(swapped: Path) -> None:
        (swapped / "extra.gd").write_bytes(b"")

    with pytest.raises(v4_release.ReleaseError, match="install rolled back"):
        v4_release.install_verified_release(
            *release.paths, IDENTITY, project, _after_swap_hook=plant
        )

    assert not (project / "addons/godot_ai").exists()
    assert (project / "addons/.godot_ai_update/quarantine/extra.gd").is_file()
    marker = _marker(project)
    assert (marker["status"], marker["from_version"], marker["backup_root"]) == (
        "rolled_back",
        "",
        "",
    )


def test_install_refuses_a_lock_held_by_another_live_process(release, tmp_path):
    project = _project(tmp_path)
    update = project / "addons/.godot_ai_update"
    update.mkdir(parents=True)
    lock = update / "lock.json"
    holder = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"])
    try:
        lock.write_text(json.dumps({"pid": holder.pid}), encoding="utf-8")
        with pytest.raises(v4_release.ReleaseError, match=f"held by live process {holder.pid}"):
            v4_release.install_verified_release(*release.paths, IDENTITY, project)
        assert json.loads(lock.read_text(encoding="utf-8")) == {"pid": holder.pid}
    finally:
        holder.kill()
        holder.wait()

    assert verify.hash_tree(project / "addons/godot_ai")["files"] == _files(OLD_FILES)
    assert not (update / "backup").exists()
    assert not (update / "pending.json").exists()
    assert not (update / "stage").exists()


@pytest.mark.parametrize("kind", ["dead", "self", "garbage"])
def test_install_replaces_a_lock_that_no_other_live_process_holds(release, tmp_path, kind):
    project = _project(tmp_path)
    update = project / "addons/.godot_ai_update"
    update.mkdir(parents=True)
    if kind == "dead":
        finished = subprocess.Popen([sys.executable, "-c", "pass"])
        finished.wait()
        content = json.dumps({"pid": finished.pid})
    elif kind == "self":
        content = json.dumps({"pid": os.getpid()})
    else:
        content = "{not json"
    (update / "lock.json").write_text(content, encoding="utf-8")

    assert v4_release.main(_install_args(release, project)) == 0

    assert _marker(project)["status"] == "success"
    assert not (update / "lock.json").exists()


def test_install_refuses_an_unverifiable_release_before_touching_the_project(
    release, tmp_path, capsys
):
    project = _project(tmp_path)
    release.signature.write_bytes(bytes(256))

    assert v4_release.main(_install_args(release, project)) == 1

    assert "verification failed" in capsys.readouterr().err
    assert verify.hash_tree(project / "addons/godot_ai")["files"] == _files(OLD_FILES)
    assert not (project / "addons/.godot_ai_update").exists()


def test_install_requires_a_godot_project(release, tmp_path):
    with pytest.raises(v4_release.ReleaseError, match="project.godot"):
        v4_release.install_verified_release(*release.paths, IDENTITY, tmp_path / "nowhere")
    assert not (tmp_path / "nowhere").exists()


def test_install_refuses_a_live_tree_without_a_readable_version(release, tmp_path):
    files = {"plugin.gd": b"@tool\n"}
    project = _project(tmp_path, files=files)

    with pytest.raises(v4_release.ReleaseError, match="plugin.cfg"):
        v4_release.install_verified_release(*release.paths, IDENTITY, project)

    assert verify.hash_tree(project / "addons/godot_ai")["files"] == _files(files)
    assert not (project / "addons/.godot_ai_update/stage").exists()
    assert not (project / "addons/.godot_ai_update/pending.json").exists()


def test_installer_never_references_the_transaction_actor():
    source = (ROOT / "script/v4-release").read_text(encoding="utf-8")
    assert "update_transaction" not in source
    assert "recovery-root" not in source
