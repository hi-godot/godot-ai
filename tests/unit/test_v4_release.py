"""Offline contracts for the deterministic, signed v4 release primitive."""

from __future__ import annotations

import base64
import hashlib
import importlib.machinery
import importlib.util
import json
import shutil
import stat
import subprocess
import threading
import zipfile
from pathlib import Path
from typing import Any

import pytest

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "script" / "v4-release"
loader = importlib.machinery.SourceFileLoader("v4_release", str(SCRIPT))
spec = importlib.util.spec_from_loader(loader.name, loader)
v4_release = importlib.util.module_from_spec(spec)
loader.exec_module(v4_release)

IDENTITY = (v4_release.REPOSITORY, "stable", "v4.0.0", "4.0.0")


def _run(*command: str, cwd: Path | None = None) -> bytes:
    return subprocess.run(command, cwd=cwd, check=True, capture_output=True).stdout


def _keys(root: Path, name: str = "release") -> tuple[Path, str]:
    private = root / f"{name}.pem"
    _run(
        "openssl",
        "genpkey",
        "-algorithm",
        "RSA",
        "-pkeyopt",
        "rsa_keygen_bits:4096",
        "-out",
        str(private),
    )
    public = (
        _run("openssl", "pkey", "-in", str(private), "-pubout")
        .decode("ascii")
        .replace("\r\n", "\n")
    )
    return private, public


def _repository(root: Path, public_key: str) -> tuple[Path, str]:
    repo = root / "repo"
    plugin = repo / "plugin/addons/godot_ai"
    (plugin / "utils").mkdir(parents=True)
    (plugin / "plugin.cfg").write_text('[plugin]\nversion="4.0.0"\n', encoding="utf-8")
    (plugin / "plugin.gd").write_text("@tool\nextends EditorPlugin\n", encoding="utf-8")
    (plugin / "utils/update_manager.gd").write_text(
        f'const RELEASE_SIGNING_PUBLIC_KEY_PEM := """{public_key}"""\n', encoding="utf-8"
    )
    shutil.copyfile(
        ROOT / "plugin/addons/godot_ai/utils/uv_resolution_policy.gd",
        plugin / "utils/uv_resolution_policy.gd",
    )
    shutil.copytree(ROOT / "migration_bridge", repo / "migration_bridge")
    (repo / "pyproject.toml").write_text(
        '[project]\nname="godot-ai"\nversion="4.0.0"\n', encoding="utf-8"
    )
    _run("git", "init", "-q", cwd=repo)
    _run("git", "config", "user.email", "release-test@example.invalid", cwd=repo)
    _run("git", "config", "user.name", "Release Test", cwd=repo)
    _run("git", "add", "plugin", "migration_bridge", "pyproject.toml", cwd=repo)
    _run("git", "commit", "-q", "-m", "fixture", cwd=repo)
    source = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    _run("git", "tag", "v4.0.0", cwd=repo)
    return repo, source


def test_standalone_key_matches_the_pre_v4_updater_key():
    source = ROOT / "plugin/addons/godot_ai/utils/update_manager.gd"
    v4_release._validate_embedded_public_key(source.read_bytes())
    assert (
        v4_release.PUBLIC_KEY_SPKI_SHA256
        == hashlib.sha256(
            base64.b64decode("".join(v4_release.PUBLIC_KEY_PEM.splitlines()[1:-1]))
        ).hexdigest()
    )


def test_standalone_key_validation_accepts_a_crlf_checkout():
    source = ROOT / "plugin/addons/godot_ai/utils/update_manager.gd"
    lf_source = source.read_bytes().replace(b"\r\n", b"\n")
    v4_release._validate_embedded_public_key(lf_source.replace(b"\n", b"\r\n"))


def test_standalone_key_validation_rejects_ambiguous_line_endings():
    source = ROOT / "plugin/addons/godot_ai/utils/update_manager.gd"
    with pytest.raises(v4_release.ReleaseError, match="unsupported line endings"):
        v4_release._validate_embedded_public_key(source.read_bytes().replace(b"\n", b"\r"))


def test_release_packager_enforces_the_signed_plugin_uv_trust_root():
    source = ROOT / "plugin/addons/godot_ai/utils/uv_resolution_policy.gd"
    v4_release._validate_uv_resolution_policy(source.read_bytes())
    counterfeit = source.read_text(encoding="utf-8").replace(
        'const PUBLIC_INDEX := "https://pypi.org/simple"',
        'const PUBLIC_INDEX := "https://counterfeit.invalid/simple"',
    )
    with pytest.raises(v4_release.ReleaseError, match="uv resolver policy"):
        v4_release._validate_uv_resolution_policy(counterfeit.encode())


@pytest.mark.parametrize("version", [(3, 10), (3, 15), (2, 99), (4, 0)])
def test_release_cli_rejects_unqualified_python_bounds(version):
    with pytest.raises(v4_release.ReleaseError, match="Python 3.11 through 3.14"):
        v4_release._require_supported_python(version)


@pytest.mark.parametrize("version", [(3, 11), (3, 14)])
def test_release_cli_accepts_qualified_python_bounds(version):
    v4_release._require_supported_python(version)


def test_release_cli_checks_python_before_command_parsing(monkeypatch, capsys):
    def reject_runtime():
        raise v4_release.ReleaseError("unqualified runtime")

    monkeypatch.setattr(v4_release, "_require_supported_python", reject_runtime)
    monkeypatch.setattr(
        v4_release,
        "_parser",
        lambda: pytest.fail("parsed a command under an unqualified runtime"),
    )

    assert v4_release.main(["verify"]) == 1
    assert "unqualified runtime" in capsys.readouterr().err


@pytest.fixture(scope="module")
def signed_release(tmp_path_factory):
    root = tmp_path_factory.mktemp("v4-release")
    private, public = _keys(root)
    repo, source = _repository(root, public)
    original_key = v4_release.PUBLIC_KEY_PEM
    original_verify_key = v4_release._verify.PUBLIC_KEY_PEM
    v4_release.PUBLIC_KEY_PEM = public
    first, second = root / "first", root / "second"
    try:
        outputs = v4_release.build_release(repo, first, private, *IDENTITY[1:], source)
        outputs_again = v4_release.build_release(repo, second, private, *IDENTITY[1:], source)
        yield {
            "root": root,
            "private": private,
            "public": public,
            "repo": repo,
            "source": source,
            "outputs": outputs,
            "outputs_again": outputs_again,
            "expected": (*IDENTITY, source),
        }
    finally:
        v4_release.PUBLIC_KEY_PEM = original_key
        v4_release._verify.PUBLIC_KEY_PEM = original_verify_key


def test_build_is_deterministic_and_emits_one_archive_shape(signed_release):
    outputs = signed_release["outputs"]
    assert {path.name for path in outputs} == {
        v4_release.ASSET_NAME,
        v4_release.MANIFEST_NAME,
        v4_release.SIGNATURE_NAME,
    }
    assert {path.name for path in outputs[0].parent.iterdir()} == {path.name for path in outputs}
    assert [path.read_bytes() for path in outputs] == [
        path.read_bytes() for path in signed_release["outputs_again"]
    ]
    archive, manifest_path, _signature = outputs
    manifest = json.loads(manifest_path.read_bytes())
    assert manifest_path.read_bytes() == v4_release._canonical(manifest)
    with zipfile.ZipFile(archive) as package:
        infos = package.infolist()
    assert [info.filename for info in infos] == [row["path"] for row in manifest["inventory"]]
    assert all(not info.is_dir() and info.date_time == v4_release.FIXED_TIME for info in infos)
    assert all(info.create_system == 3 for info in infos)
    assert all(info.external_attr >> 16 == stat.S_IFREG | 0o644 for info in infos)
    assert archive.stat().st_size <= v4_release.MAX_ARCHIVE_SIZE
    assert manifest_path.stat().st_size <= v4_release.MAX_MANIFEST_SIZE
    assert manifest["asset"] == {
        "name": v4_release.ASSET_NAME,
        "size": archive.stat().st_size,
        "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
    }


def test_signing_streams_both_payloads_without_openssl_output_paths(
    signed_release, tmp_path, monkeypatch
):
    # Python handles these paths on Windows; OpenSSL's file API may not.
    output = tmp_path / ("nested-release-" + "x" * 100) / ("candidate-" + "x" * 60)
    calls = []
    original = v4_release._openssl

    def observe(*args, input_bytes=None):
        assert args == ("-sign", str(signed_release["private"].resolve()))
        assert isinstance(input_bytes, bytes)
        calls.append(input_bytes)
        return original(*args, input_bytes=input_bytes)

    monkeypatch.setattr(v4_release, "_openssl", observe)
    outputs = v4_release.build_release_set(
        signed_release["repo"],
        output,
        signed_release["private"],
        *IDENTITY[1:],
        signed_release["source"],
    )
    by_name = {path.name: path for path in outputs}
    assert calls == [
        by_name[v4_release.MANIFEST_NAME].read_bytes(),
        by_name[v4_release.LEGACY_CHECKSUM_NAME].read_bytes(),
    ]
    for payload, name in zip(
        calls, (v4_release.SIGNATURE_NAME, v4_release.LEGACY_SIGNATURE_NAME), strict=True
    ):
        v4_release._verify_signature(payload, by_name[name].read_bytes(), signed_release["public"])


def test_release_set_adds_one_deterministic_signed_v3_migration_capsule(signed_release, tmp_path):
    first = tmp_path / "release-set-first"
    second = tmp_path / "release-set-second"
    arguments = (
        signed_release["repo"],
        signed_release["private"],
        *IDENTITY[1:],
        signed_release["source"],
    )
    outputs = v4_release.build_release_set(arguments[0], first, *arguments[1:])
    repeated = v4_release.build_release_set(arguments[0], second, *arguments[1:])
    expected_names = {
        v4_release.ASSET_NAME,
        v4_release.MANIFEST_NAME,
        v4_release.SIGNATURE_NAME,
        v4_release.LEGACY_ASSET_NAME,
        v4_release.LEGACY_CHECKSUM_NAME,
        v4_release.LEGACY_SIGNATURE_NAME,
    }
    assert {path.name for path in outputs} == expected_names
    assert {path.name for path in first.iterdir()} == expected_names
    assert [path.read_bytes() for path in outputs] == [path.read_bytes() for path in repeated]

    by_name = {path.name: path for path in outputs}
    capsule = by_name[v4_release.LEGACY_ASSET_NAME]
    checksum = by_name[v4_release.LEGACY_CHECKSUM_NAME].read_bytes()
    signature = by_name[v4_release.LEGACY_SIGNATURE_NAME].read_bytes()
    digest = hashlib.sha256(capsule.read_bytes()).hexdigest()
    assert checksum == f"{digest}  {v4_release.LEGACY_ASSET_NAME}\n".encode("ascii")
    v4_release._verify_signature(checksum, signature, signed_release["public"])

    with zipfile.ZipFile(capsule) as package:
        names = package.namelist()
        assert names == sorted(names)
        assert package.read("addons/godot_ai/plugin.cfg").decode().count('version="4.0.0"') == 1
        for name in (
            v4_release.ASSET_NAME,
            v4_release.MANIFEST_NAME,
            v4_release.SIGNATURE_NAME,
        ):
            assert (
                package.read(f"{v4_release.MIGRATION_PAYLOAD_PREFIX}{name}")
                == by_name[name].read_bytes()
            )


def test_build_never_overwrites_an_existing_candidate(signed_release):
    outputs = signed_release["outputs"]
    before = [path.read_bytes() for path in outputs]

    with pytest.raises(v4_release.ReleaseError, match="immutable destination"):
        v4_release.build_release(
            signed_release["repo"],
            outputs[0].parent,
            signed_release["private"],
            *IDENTITY[1:],
            signed_release["source"],
        )

    assert [path.read_bytes() for path in outputs] == before


def test_interrupted_package_publication_leaves_unmixable_immutable_evidence(
    signed_release, tmp_path, monkeypatch
):
    output = tmp_path / "interrupted"
    real_link = v4_release.os.link
    calls = 0

    def interrupt_second_link(source: Path, destination: Path) -> None:
        nonlocal calls
        calls += 1
        if calls == 2:
            raise OSError("injected publication interruption")
        real_link(source, destination)

    with monkeypatch.context() as context:
        context.setattr(v4_release.os, "link", interrupt_second_link)
        with pytest.raises(v4_release.ReleaseError, match="use a new empty output directory"):
            v4_release.package_release(
                signed_release["repo"],
                output,
                *IDENTITY[1:],
                signed_release["source"],
            )

    archive = output / v4_release.ASSET_NAME
    frozen = archive.read_bytes()
    assert not (output / v4_release.MANIFEST_NAME).exists()
    with pytest.raises(v4_release.ReleaseError, match="immutable destination"):
        v4_release.package_release(
            signed_release["repo"],
            output,
            *IDENTITY[1:],
            signed_release["source"],
        )
    assert archive.read_bytes() == frozen


def test_standalone_verify_accepts_exact_explicit_identity(signed_release):
    underlying_key = v4_release._verify.PUBLIC_KEY_PEM
    v4_release.verify_release(*signed_release["outputs"], signed_release["expected"])
    assert v4_release._verify.PUBLIC_KEY_PEM == underlying_key


def test_release_limits_match_every_self_update_acceptor():
    assert v4_release.MAX_ARCHIVE_SIZE == 64 * 1024 * 1024
    assert v4_release.MAX_TREE_SIZE == v4_release.MAX_ARCHIVE_SIZE
    assert v4_release.MAX_MANIFEST_SIZE == 1024 * 1024
    manager = (ROOT / "plugin/addons/godot_ai/utils/update_manager.gd").read_text(encoding="utf-8")
    assert "const MAX_ARCHIVE_SIZE_BYTES := 64 * 1024 * 1024" in manager
    assert "const MAX_MANIFEST_SIZE_BYTES := 1024 * 1024" in manager
    assert "ASSET_NAME: MAX_ARCHIVE_SIZE_BYTES" in manager
    assert "MANIFEST_NAME: MAX_MANIFEST_SIZE_BYTES" in manager


def test_release_verifier_rejects_inputs_the_updater_cannot_receive(signed_release, tmp_path):
    manifest = json.loads(signed_release["outputs"][1].read_bytes())
    manifest["asset"]["size"] = v4_release.MAX_ARCHIVE_SIZE + 1
    with pytest.raises(v4_release.ReleaseError, match="manifest.asset.size"):
        v4_release._validate_manifest(v4_release._canonical(manifest), signed_release["expected"])

    oversized_manifest = tmp_path / v4_release.MANIFEST_NAME
    oversized_manifest.write_bytes(b"x" * (v4_release.MAX_MANIFEST_SIZE + 1))
    with pytest.raises(v4_release.ReleaseError, match=r"1\.\.1048576 bytes"):
        v4_release._read_bounded(oversized_manifest, v4_release.MAX_MANIFEST_SIZE)


def test_staging_uses_the_frozen_verified_archive_after_input_path_swap(
    signed_release, tmp_path, monkeypatch
):
    artifacts = tuple(tmp_path / path.name for path in signed_release["outputs"])
    for source, target in zip(signed_release["outputs"], artifacts, strict=True):
        shutil.copyfile(source, target)
    archive, manifest, signature = artifacts
    original_extract = v4_release._verify._extract_verified_archive

    def swap_then_extract(frozen: bytes, destination: Path) -> Path:
        with zipfile.ZipFile(archive, "w") as attacker:
            attacker.writestr(f"{v4_release.PLUGIN_PREFIX}../../escape", b"attacker")
        return original_extract(frozen, destination)

    monkeypatch.setattr(v4_release._verify, "PUBLIC_KEY_PEM", signed_release["public"])
    monkeypatch.setattr(v4_release._verify, "_extract_verified_archive", swap_then_extract)
    plugin, _digest, _release = v4_release._verify.stage_verified_release(
        archive,
        manifest,
        signature,
        signed_release["expected"],
        tmp_path / "stage",
    )

    assert (plugin / "plugin.gd").is_file()
    assert not (tmp_path / "stage/escape").exists()


def test_verified_stage_syncs_created_namespace_bottom_up(
    signed_release, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[Path] = []
    monkeypatch.setattr(v4_release._verify, "PUBLIC_KEY_PEM", signed_release["public"])
    monkeypatch.setattr(
        v4_release._verify,
        "_sync_directory",
        lambda path: calls.append(Path(path)),
    )
    destination = tmp_path / "stage"
    plugin, _digest, _manifest = v4_release._verify.stage_verified_release(
        *signed_release["outputs"], signed_release["expected"], destination
    )

    assert calls[0] == destination.parent
    staged = calls[1:]
    assert staged[-1] == destination
    assert plugin in staged
    assert staged.index(plugin) < staged.index(destination / "addons")
    assert staged.index(destination / "addons") < staged.index(destination)


def _old_project(root: Path) -> tuple[Path, dict[str, bytes]]:
    project = root / "project"
    addon = project / "addons/godot_ai"
    addon.mkdir(parents=True)
    (project / "project.godot").write_text('[application]\nconfig/name="old"\n')
    old = {
        "plugin.cfg": b'[plugin]\nversion="3.2.4"\n',
        "old-only.gd": b"extends RefCounted\n",
    }
    for relative, data in old.items():
        (addon / relative).write_bytes(data)
    return project, old


def _fresh_project(root: Path) -> Path:
    project = root / "project"
    project.mkdir()
    (project / "project.godot").write_text('[application]\nconfig/name="fresh"\n')
    return project


def test_install_atomically_creates_an_exact_tree_for_a_fresh_project(signed_release, tmp_path):
    project = _fresh_project(tmp_path)
    recovery = tmp_path / "recovery"

    backup = v4_release.install_verified_release(
        *signed_release["outputs"],
        signed_release["expected"],
        project,
        recovery,
        editors_closed=True,
        clients_and_backend_stopped=True,
    )

    manifest = json.loads(signed_release["outputs"][1].read_bytes())
    assert backup is None
    v4_release._verify_installed_tree(project / "addons/godot_ai", manifest)
    assert not recovery.exists()
    assert not (project / v4_release.MIGRATION_MARKER_RELATIVE).exists()


def test_fresh_install_cleanup_failure_preserves_committed_live_tree(
    signed_release, tmp_path, monkeypatch
):
    project = _fresh_project(tmp_path)
    recovery = tmp_path / "recovery"
    real_rmtree = v4_release.shutil.rmtree

    def fail_recovery_cleanup(path: Path, *args, **kwargs) -> None:
        if Path(path) == recovery:
            raise OSError("injected post-commit cleanup failure")
        real_rmtree(path, *args, **kwargs)

    monkeypatch.setattr(v4_release.shutil, "rmtree", fail_recovery_cleanup)
    assert (
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            recovery,
            editors_closed=True,
            clients_and_backend_stopped=True,
        )
        is None
    )

    manifest = json.loads(signed_release["outputs"][1].read_bytes())
    v4_release._verify_installed_tree(project / "addons/godot_ai", manifest)
    assert recovery.is_dir()
    assert not (recovery / "failed-v4-tree").exists()


def test_canonical_manifest_rejects_lone_surrogate_as_release_error() -> None:
    with pytest.raises(v4_release.ReleaseError, match="canonical JSON"):
        v4_release._canonical({"value": "\ud800"})


def test_install_replaces_the_whole_old_tree_and_retains_external_backup(signed_release, tmp_path):
    project, old = _old_project(tmp_path)
    recovery = tmp_path / "recovery"
    backup = v4_release.install_verified_release(
        *signed_release["outputs"],
        signed_release["expected"],
        project,
        recovery,
        editors_closed=True,
        clients_and_backend_stopped=True,
    )

    manifest = json.loads(signed_release["outputs"][1].read_bytes())
    v4_release._verify_installed_tree(project / "addons/godot_ai", manifest)
    assert not (project / "addons/godot_ai/old-only.gd").exists()
    assert backup == recovery / "retained-pre-v4-addon"
    backup_files = {
        path.relative_to(backup).as_posix(): path.read_bytes() for path in backup.iterdir()
    }
    assert backup_files == old
    assert project not in recovery.parents
    marker = project / v4_release.MIGRATION_MARKER_RELATIVE
    assert marker.read_bytes() == v4_release._canonical(
        v4_release._migration_marker_record(
            "3.2.4", signed_release["expected"][3], signed_release["expected"][4]
        )
    )
    if v4_release.os.name != "nt":
        assert stat.S_IMODE(marker.stat().st_mode) == 0o600


def test_install_requires_editor_closure_ack_and_external_unused_recovery(signed_release, tmp_path):
    project, _old = _old_project(tmp_path)

    def call(recovery, closed):
        return v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            recovery,
            editors_closed=closed,
            clients_and_backend_stopped=True,
        )

    with pytest.raises(v4_release.ReleaseError, match="editors-closed"):
        call(tmp_path / "unused", False)
    with pytest.raises(v4_release.ReleaseError, match="outside the entire project"):
        call(project / "recovery", True)
    occupied = tmp_path / "occupied"
    occupied.mkdir()
    with pytest.raises(v4_release.ReleaseError, match="already exists"):
        call(occupied, True)
    assert (project / "addons/godot_ai/old-only.gd").is_file()


def test_existing_tree_requires_clients_and_backend_stopped_ack(signed_release, tmp_path):
    project, _old = _old_project(tmp_path)

    with pytest.raises(v4_release.ReleaseError, match="clients-and-backend-stopped"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            tmp_path / "recovery",
            editors_closed=True,
            clients_and_backend_stopped=False,
        )

    assert (project / "addons/godot_ai/old-only.gd").is_file()
    assert not (project / v4_release.MIGRATION_MARKER_RELATIVE).exists()


@pytest.mark.skipif(v4_release.os.name == "nt", reason="POSIX namespace policy")
def test_migration_posix_policy_allows_only_root_owned_sticky_writable_dirs():
    directory = stat.S_IFDIR
    current = v4_release.os.getuid()
    other = current + 1

    assert v4_release._verify._safe_posix_ancestor(0, directory | 0o1777)
    assert v4_release._verify._safe_posix_ancestor(current, directory | 0o700)
    assert not v4_release._verify._safe_posix_ancestor(0, directory | 0o777)
    if current != 0:
        assert not v4_release._verify._safe_posix_ancestor(current, directory | 0o1777)
    assert not v4_release._verify._safe_posix_ancestor(other, directory | 0o700)


@pytest.mark.skipif(v4_release.os.name == "nt", reason="POSIX namespace policy")
def test_install_rejects_writable_posix_ancestor_before_mutation(signed_release, tmp_path):
    unsafe = tmp_path / "unsafe"
    project, _old = _old_project(unsafe)
    unsafe.chmod(0o777)
    try:
        with pytest.raises(v4_release.ReleaseError, match="unsafe POSIX ancestor"):
            v4_release.install_verified_release(
                *signed_release["outputs"],
                signed_release["expected"],
                project,
                tmp_path / "recovery",
                editors_closed=True,
                clients_and_backend_stopped=True,
            )
    finally:
        unsafe.chmod(0o700)
    assert (project / "addons/godot_ai/old-only.gd").is_file()
    assert not (tmp_path / "recovery").exists()


@pytest.mark.skipif(v4_release.os.name == "nt", reason="symlink fixture")
def test_install_rejects_linked_project_marker_before_mutation(signed_release, tmp_path):
    project, _old = _old_project(tmp_path)
    marker = project / "project.godot"
    outside = tmp_path / "outside-project.godot"
    marker.replace(outside)
    marker.symlink_to(outside)

    with pytest.raises(v4_release.ReleaseError, match="regular non-link file"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            tmp_path / "recovery",
            editors_closed=True,
            clients_and_backend_stopped=True,
        )
    assert (project / "addons/godot_ai/old-only.gd").is_file()
    assert not (tmp_path / "recovery").exists()


@pytest.mark.skipif(v4_release.os.name == "nt", reason="POSIX hard-link contract")
def test_install_rejects_hard_linked_old_tree_before_mutation(signed_release, tmp_path):
    project, _old = _old_project(tmp_path)
    linked = project / "addons/godot_ai/old-only.gd"
    external = tmp_path / "external-link"
    v4_release.os.link(linked, external)

    with pytest.raises(v4_release.ReleaseError, match="hard-linked file"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            tmp_path / "recovery",
            editors_closed=True,
            clients_and_backend_stopped=True,
        )
    assert linked.is_file()
    assert not (tmp_path / "recovery").exists()


def test_install_restores_old_tree_when_activation_rename_fails(
    signed_release, tmp_path, monkeypatch
):
    project, old = _old_project(tmp_path)
    recovery = tmp_path / "recovery"
    real_rename = v4_release.os.rename

    def fail_stage_activation(source, target):
        if Path(source).parent.parent.name == "stage":
            raise OSError("injected activation failure")
        return real_rename(source, target)

    monkeypatch.setattr(v4_release.os, "rename", fail_stage_activation)
    with pytest.raises(v4_release.ReleaseError, match="restored the old add-on"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            recovery,
            editors_closed=True,
            clients_and_backend_stopped=True,
        )
    addon = project / "addons/godot_ai"
    addon_files = {
        path.relative_to(addon).as_posix(): path.read_bytes() for path in addon.iterdir()
    }
    assert addon_files == old
    assert not recovery.exists()
    assert not (project / v4_release.MIGRATION_MARKER_RELATIVE).exists()


def test_install_syncs_complete_stage_before_first_live_tree_rename(
    signed_release, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project, _old = _old_project(tmp_path)
    events: list[str] = []
    real_sync_stage = v4_release._sync_staged_directories
    real_rename = v4_release._rename_tree

    def sync_stage(path: Path) -> None:
        events.append("sync_stage")
        real_sync_stage(path)

    def rename(source: Path, target: Path) -> None:
        events.append("rename")
        real_rename(source, target)

    monkeypatch.setattr(v4_release, "_sync_staged_directories", sync_stage)
    monkeypatch.setattr(v4_release, "_rename_tree", rename)
    v4_release.install_verified_release(
        *signed_release["outputs"],
        signed_release["expected"],
        project,
        tmp_path / "recovery",
        editors_closed=True,
        clients_and_backend_stopped=True,
    )

    assert events[0] == "sync_stage"
    assert events.count("rename") == 2


def test_install_restores_old_tree_when_first_post_rename_sync_fails(
    signed_release, tmp_path, monkeypatch
):
    project, old = _old_project(tmp_path)
    recovery = tmp_path / "recovery"
    real_sync = v4_release._sync_directory
    failed = False

    def fail_first_sync(path: Path) -> None:
        nonlocal failed
        if not failed and (recovery / "retained-pre-v4-addon").exists():
            failed = True
            raise OSError("injected post-rename sync failure")
        real_sync(path)

    monkeypatch.setattr(v4_release, "_sync_directory", fail_first_sync)
    with pytest.raises(v4_release.ReleaseError, match="restored the old add-on"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            recovery,
            editors_closed=True,
            clients_and_backend_stopped=True,
        )

    addon = project / "addons/godot_ai"
    assert {path.name: path.read_bytes() for path in addon.iterdir()} == old
    assert not recovery.exists()
    assert not (project / v4_release.MIGRATION_MARKER_RELATIVE).exists()


def test_fresh_install_failure_restores_absent_target_and_cleans_staging(
    signed_release, tmp_path, monkeypatch
):
    project = _fresh_project(tmp_path)
    recovery = tmp_path / "recovery"
    real_verify = v4_release._verify_installed_tree
    calls = 0

    def fail_live_verification(path: Path, manifest: dict[str, Any]) -> None:
        nonlocal calls
        calls += 1
        real_verify(path, manifest)
        if calls == 2:
            raise v4_release.ReleaseError("injected live verification failure")

    monkeypatch.setattr(v4_release, "_verify_installed_tree", fail_live_verification)
    with pytest.raises(v4_release.ReleaseError, match="fresh install failed"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            recovery,
            editors_closed=True,
            clients_and_backend_stopped=True,
        )

    assert not (project / "addons/godot_ai").exists()
    assert not recovery.exists()


def test_fresh_install_loser_never_quarantines_a_target_that_appeared(
    signed_release, tmp_path, monkeypatch
):
    project = _fresh_project(tmp_path)
    live = project / "addons/godot_ai"
    recovery = tmp_path / "loser-recovery"
    real_rename = v4_release._rename_tree

    def publish_winner_before_loser(source: Path, target: Path) -> None:
        if target == live:
            target.mkdir()
            (target / "winner.txt").write_text("winner\n")
        real_rename(source, target)

    monkeypatch.setattr(v4_release, "_rename_tree", publish_winner_before_loser)
    with pytest.raises(v4_release.ReleaseError, match="fresh install failed"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            recovery,
            editors_closed=True,
            clients_and_backend_stopped=True,
        )

    assert (live / "winner.txt").read_text(encoding="utf-8") == "winner\n"
    assert not recovery.exists()
    assert not (project / "addons/.godot-ai-v4-installing").exists()


def test_two_fresh_installers_have_one_exclusive_winner(signed_release, tmp_path, monkeypatch):
    project = _fresh_project(tmp_path)
    first_recovery = tmp_path / "first-recovery"
    second_recovery = tmp_path / "second-recovery"
    entered = threading.Event()
    release = threading.Event()
    real_extract = v4_release._extract_verified_archive
    first_call = True

    def pause_first_extract(data: bytes, destination: Path) -> Path:
        nonlocal first_call
        staged = real_extract(data, destination)
        if first_call:
            first_call = False
            entered.set()
            assert release.wait(3)
        return staged

    monkeypatch.setattr(v4_release, "_extract_verified_archive", pause_first_extract)
    results: list[Path | None] = []
    errors: list[BaseException] = []

    def first_install() -> None:
        try:
            results.append(
                v4_release.install_verified_release(
                    *signed_release["outputs"],
                    signed_release["expected"],
                    project,
                    first_recovery,
                    editors_closed=True,
                    clients_and_backend_stopped=True,
                )
            )
        except BaseException as exc:
            errors.append(exc)

    worker = threading.Thread(target=first_install)
    worker.start()
    assert entered.wait(3)
    with pytest.raises(v4_release.ReleaseError, match="exclusive claim"):
        v4_release.install_verified_release(
            *signed_release["outputs"],
            signed_release["expected"],
            project,
            second_recovery,
            editors_closed=True,
            clients_and_backend_stopped=True,
        )
    release.set()
    worker.join(5)

    assert not worker.is_alive()
    assert errors == []
    assert results == [None]
    manifest = json.loads(signed_release["outputs"][1].read_bytes())
    v4_release._verify_installed_tree(project / "addons/godot_ai", manifest)
    assert not second_recovery.exists()


def test_cleanup_sync_failure_does_not_turn_an_installed_tree_into_failure(
    signed_release, tmp_path, monkeypatch
):
    project, _old = _old_project(tmp_path)
    recovery = tmp_path / "recovery"
    real_sync = v4_release._sync_directory

    def fail_only_cleanup_sync(path: Path) -> None:
        if path == recovery and not (recovery / v4_release.ASSET_NAME).exists():
            raise OSError("injected cleanup-only sync failure")
        real_sync(path)

    monkeypatch.setattr(v4_release, "_sync_directory", fail_only_cleanup_sync)
    backup = v4_release.install_verified_release(
        *signed_release["outputs"],
        signed_release["expected"],
        project,
        recovery,
        editors_closed=True,
        clients_and_backend_stopped=True,
    )

    manifest = json.loads(signed_release["outputs"][1].read_bytes())
    assert backup == recovery / "retained-pre-v4-addon"
    v4_release._verify_installed_tree(project / "addons/godot_ai", manifest)


def test_package_is_credential_free_and_sign_consumes_frozen_manifest(
    signed_release, tmp_path, monkeypatch
):
    output = tmp_path / "split"
    with monkeypatch.context() as context:
        context.setattr(
            v4_release,
            "_openssl",
            lambda *_args: pytest.fail("credential-free packaging invoked OpenSSL"),
        )
        archive, manifest = v4_release.package_release(
            signed_release["repo"], output, *IDENTITY[1:], signed_release["source"]
        )
    assert {path.name for path in output.iterdir()} == {
        v4_release.ASSET_NAME,
        v4_release.MANIFEST_NAME,
    }
    frozen_manifest = manifest.read_bytes()
    signature = v4_release.sign_release(
        manifest,
        output / v4_release.SIGNATURE_NAME,
        signed_release["private"],
        signed_release["expected"],
    )
    assert manifest.read_bytes() == frozen_manifest
    v4_release.verify_release(archive, manifest, signature, signed_release["expected"])


def test_standalone_verify_does_not_execute_openssl(signed_release, monkeypatch):
    monkeypatch.setattr(
        v4_release,
        "_run",
        lambda *_args, **_kwargs: pytest.fail("standalone verification executed a subprocess"),
    )
    v4_release.verify_release(*signed_release["outputs"], signed_release["expected"])


def test_cli_build_and_verify_use_only_explicit_identity(signed_release, capsys):
    output = signed_release["root"] / "cli"
    build_args = [
        "build",
        "--repo-root",
        str(signed_release["repo"]),
        "--output-dir",
        str(output),
        "--private-key",
        str(signed_release["private"]),
        "--channel",
        "stable",
        "--tag",
        "v4.0.0",
        "--version",
        "4.0.0",
        "--source-commit",
        signed_release["source"],
    ]
    assert v4_release.main(build_args) == 0
    verify_args = [
        "verify",
        "--archive",
        str(output / v4_release.ASSET_NAME),
        "--manifest",
        str(output / v4_release.MANIFEST_NAME),
        "--signature",
        str(output / v4_release.SIGNATURE_NAME),
        "--expected-repository",
        v4_release.REPOSITORY,
        "--expected-channel",
        "stable",
        "--expected-tag",
        "v4.0.0",
        "--expected-version",
        "4.0.0",
        "--expected-source",
        signed_release["source"],
    ]
    assert v4_release.main(verify_args) == 0
    assert "exact tree verified" in capsys.readouterr().out


@pytest.mark.parametrize(
    ("index", "wrong"),
    [(0, "evil/godot-ai"), (1, "rc"), (2, "v4.0.1"), (3, "4.0.1"), (4, "0" * 40)],
)
def test_verify_rejects_every_wrong_expected_identity(signed_release, index, wrong):
    expected = list(signed_release["expected"])
    expected[index] = wrong
    with pytest.raises(v4_release.ReleaseError):
        v4_release.verify_release(*signed_release["outputs"], tuple(expected))


@pytest.mark.parametrize("target", range(3))
def test_verify_rejects_tampered_release_sidecars(signed_release, tmp_path, target):
    copies = []
    for source in signed_release["outputs"]:
        destination = tmp_path / source.name
        shutil.copyfile(source, destination)
        copies.append(destination)
    copies[target].write_bytes(copies[target].read_bytes() + b"tamper")
    with pytest.raises(v4_release.ReleaseError):
        v4_release.verify_release(*copies, signed_release["expected"])


@pytest.mark.parametrize("raw", [b'{"x":1,"x":2}\n', b'{"x":NaN}\n', b'{"x":Infinity}\n'])
def test_manifest_json_is_strict(raw):
    with pytest.raises(v4_release.ReleaseError):
        v4_release._strict_json(raw, "manifest")


@pytest.mark.parametrize(
    "name",
    ["CONIN$", "conout$", "COM¹", "COM²", "COM³", "LPT¹", "lpt²", "LPT³"],
)
def test_windows_extended_device_names_are_rejected(name):
    with pytest.raises(v4_release.ReleaseError, match="reserved path component"):
        v4_release._verify._safe_path(f"{v4_release.PLUGIN_PREFIX}{name}.gd", "fixture path")


def _zip(path: Path, entries: list[tuple[str, bytes, int, int]], *, create_system: int = 3) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        for name, data, mode, compression in entries:
            info = zipfile.ZipInfo(name, v4_release.FIXED_TIME)
            info.create_system = create_system
            info.external_attr = mode << 16
            info.compress_type = compression
            archive.writestr(info, data)


def _signed_fixture(
    root: Path,
    private_key: Path,
    source: str,
    entries: list[tuple[str, bytes, int, int]],
    inventory_entries: list[tuple[str, bytes]] | None = None,
    *,
    create_system: int = 3,
) -> tuple[Path, Path, Path]:
    archive = root / v4_release.ASSET_NAME
    manifest_path = root / v4_release.MANIFEST_NAME
    signature = root / v4_release.SIGNATURE_NAME
    _zip(archive, entries, create_system=create_system)
    inventory_entries = inventory_entries or [(name, data) for name, data, _mode, _zip in entries]
    inventory_entries.sort(key=lambda item: item[0])
    manifest: dict[str, Any] = {
        "schema_version": 1,
        "repository": v4_release.REPOSITORY,
        "channel": "stable",
        "tag": "v4.0.0",
        "version": "4.0.0",
        "source_commit": source,
        "asset": {
            "name": v4_release.ASSET_NAME,
            "size": archive.stat().st_size,
            "sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        },
        "inventory": [
            {"path": name, "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}
            for name, data in inventory_entries
        ],
    }
    manifest_path.write_bytes(v4_release._canonical(manifest))
    _run(
        "openssl",
        "dgst",
        "-sha256",
        "-sign",
        str(private_key),
        "-out",
        str(signature),
        str(manifest_path),
    )
    return archive, manifest_path, signature


def _plugin_config() -> bytes:
    return b'[plugin]\nversion="4.0.0"\n'


@pytest.mark.parametrize("attack", ["extra", "traversal", "case", "link", "compressed"])
def test_signed_but_unsafe_or_inexact_archives_are_rejected(signed_release, tmp_path, attack):
    regular = stat.S_IFREG | 0o644
    entries = [(v4_release.PLUGIN_CONFIG, _plugin_config(), regular, zipfile.ZIP_STORED)]
    inventory = None
    if attack == "extra":
        entries.append(
            (f"{v4_release.PLUGIN_PREFIX}extra.gd", b"extra", regular, zipfile.ZIP_STORED)
        )
        inventory = [(v4_release.PLUGIN_CONFIG, _plugin_config())]
    elif attack == "traversal":
        entries = [(f"{v4_release.PLUGIN_PREFIX}../escape", b"x", regular, zipfile.ZIP_STORED)]
    elif attack == "case":
        entries.append(
            (f"{v4_release.PLUGIN_PREFIX}Plugin.cfg", b"other", regular, zipfile.ZIP_STORED)
        )
    elif attack == "link":
        entries[0] = (v4_release.PLUGIN_CONFIG, b"target", stat.S_IFLNK | 0o777, zipfile.ZIP_STORED)
    else:
        entries[0] = (
            v4_release.PLUGIN_CONFIG,
            _plugin_config() * 100,
            regular,
            zipfile.ZIP_DEFLATED,
        )
    artifacts = _signed_fixture(
        tmp_path, signed_release["private"], signed_release["source"], entries, inventory
    )
    with pytest.raises(v4_release.ReleaseError):
        v4_release.verify_release(*artifacts, signed_release["expected"])


def test_signed_archive_rejects_non_unix_creator_metadata(signed_release, tmp_path):
    regular = stat.S_IFREG | 0o644
    artifacts = _signed_fixture(
        tmp_path,
        signed_release["private"],
        signed_release["source"],
        [(v4_release.PLUGIN_CONFIG, _plugin_config(), regular, zipfile.ZIP_STORED)],
        create_system=0,
    )

    with pytest.raises(v4_release.ReleaseError, match="non-canonical ZIP metadata"):
        v4_release.verify_release(*artifacts, signed_release["expected"])


def test_build_refuses_wrong_signing_key_before_publishing(signed_release, tmp_path):
    wrong_private, _public = _keys(tmp_path, "wrong")
    output = tmp_path / "output"
    with pytest.raises(v4_release.ReleaseError, match="manifest signature"):
        v4_release.build_release(
            signed_release["repo"],
            output,
            wrong_private,
            *IDENTITY[1:],
            signed_release["source"],
        )
    assert not list(output.iterdir())


def test_build_refuses_linked_plugin_content(signed_release, tmp_path):
    repo = tmp_path / "repo"
    shutil.copytree(signed_release["repo"], repo, symlinks=True)
    # The release reads Git objects, not the worktree. Create the linked entry
    # directly so this rejection test needs no Windows symlink privilege.
    target = repo / "link-target.txt"
    target.write_text("plugin.gd", encoding="utf-8")
    blob = _run("git", "hash-object", "-w", str(target), cwd=repo).decode().strip()
    _run(
        "git",
        "update-index",
        "--add",
        "--cacheinfo",
        f"120000,{blob},plugin/addons/godot_ai/untracked.gd",
        cwd=repo,
    )
    _run("git", "commit", "-q", "-m", "linked fixture", cwd=repo)
    source = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    _run("git", "tag", "-f", "v4.0.0", cwd=repo)
    with pytest.raises(v4_release.ReleaseError, match="non-regular Git entry"):
        v4_release.build_release(
            repo,
            tmp_path / "output",
            signed_release["private"],
            *IDENTITY[1:],
            source,
        )


def test_package_reads_exact_commit_and_ignores_all_workspace_bytes(signed_release, tmp_path):
    repo = tmp_path / "repo"
    shutil.copytree(signed_release["repo"], repo)
    committed = _run(
        "git",
        "show",
        f"{signed_release['source']}:plugin/addons/godot_ai/plugin.gd",
        cwd=repo,
    )
    (repo / ".git/info/exclude").write_text("plugin/addons/godot_ai/ignored.gd\n")
    (repo / "plugin/addons/godot_ai/plugin.gd").write_text("workspace mutation\n")
    (repo / "plugin/addons/godot_ai/untracked.gd").write_text("extends RefCounted\n")
    (repo / "plugin/addons/godot_ai/ignored.gd").write_text("ignored bytes\n")
    (repo / "pyproject.toml").write_text('[project]\nversion="9.9.9"\n', encoding="utf-8")

    archive, _manifest = v4_release.package_release(
        repo,
        tmp_path / "dirty-output",
        *IDENTITY[1:],
        signed_release["source"],
    )
    with zipfile.ZipFile(archive) as package:
        assert package.read(f"{v4_release.PLUGIN_PREFIX}plugin.gd") == committed
        assert f"{v4_release.PLUGIN_PREFIX}untracked.gd" not in package.namelist()
        assert f"{v4_release.PLUGIN_PREFIX}ignored.gd" not in package.namelist()
    with pytest.raises(v4_release.ReleaseError, match="HEAD, tag, and explicit"):
        v4_release.package_release(
            signed_release["repo"],
            tmp_path / "wrong-source-output",
            *IDENTITY[1:],
            "0" * 40,
        )


@pytest.mark.parametrize(
    ("pyproject", "message"),
    [
        ('[project]\nversion="4.0.1"\n', "does not match release version"),
        ('[project]\nname="godot-ai"\n', r"\[project\]\.version"),
        ("[project\n", "invalid TOML"),
    ],
)
def test_package_rejects_invalid_version_from_exact_source_commit(
    signed_release, tmp_path, pyproject, message
):
    repo = tmp_path / "repo"
    shutil.copytree(signed_release["repo"], repo)
    (repo / "pyproject.toml").write_text(pyproject, encoding="utf-8")
    _run("git", "add", "pyproject.toml", cwd=repo)
    _run("git", "commit", "-q", "-m", "change source metadata", cwd=repo)
    source = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    _run("git", "tag", "-f", "v4.0.0", cwd=repo)

    with pytest.raises(v4_release.ReleaseError, match=message):
        v4_release.package_release(
            repo,
            tmp_path / "output",
            *IDENTITY[1:],
            source,
        )


def test_package_rejects_source_commit_without_pyproject(signed_release, tmp_path):
    repo = tmp_path / "repo"
    shutil.copytree(signed_release["repo"], repo)
    _run("git", "rm", "-q", "pyproject.toml", cwd=repo)
    _run("git", "commit", "-q", "-m", "remove source metadata", cwd=repo)
    source = _run("git", "rev-parse", "HEAD", cwd=repo).decode().strip()
    _run("git", "tag", "-f", "v4.0.0", cwd=repo)

    with pytest.raises(v4_release.ReleaseError, match="expected one regular file"):
        v4_release.package_release(
            repo,
            tmp_path / "output",
            *IDENTITY[1:],
            source,
        )


def test_workspace_mutation_after_source_check_cannot_enter_package(
    signed_release, tmp_path, monkeypatch
):
    repo = tmp_path / "repo"
    shutil.copytree(signed_release["repo"], repo)
    plugin = repo / "plugin/addons/godot_ai/plugin.gd"
    committed = _run(
        "git",
        "show",
        f"{signed_release['source']}:plugin/addons/godot_ai/plugin.gd",
        cwd=repo,
    )
    validate = v4_release._validate_source

    def validate_then_mutate(*args):
        validate(*args)
        plugin.write_text("mutated after identity check\n")

    monkeypatch.setattr(v4_release, "_validate_source", validate_then_mutate)
    archive, _manifest = v4_release.package_release(
        repo, tmp_path / "output", *IDENTITY[1:], signed_release["source"]
    )
    with zipfile.ZipFile(archive) as package:
        assert package.read(f"{v4_release.PLUGIN_PREFIX}plugin.gd") == committed
