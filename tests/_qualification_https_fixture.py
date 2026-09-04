"""Disposable TLS material, never a release-signing key or system trust change."""

import contextlib
import shutil
import subprocess
from pathlib import Path

from script import release_support as support
from script.qualification_https import ORIGIN_HOST, private_release_origin


def make_tls_material(root: Path, host: str = ORIGIN_HOST) -> tuple[Path, Path]:
    root.mkdir(parents=True, exist_ok=True)
    certificate = root / "certificate.pem"
    key = root / "private-key.pem"
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-sha256",
            "-nodes",
            "-days",
            "1",
            "-subj",
            f"/CN={host}",
            "-addext",
            f"subjectAltName=DNS:{host}",
            "-keyout",
            str(key),
            "-out",
            str(certificate),
        ],
        check=True,
        capture_output=True,
        timeout=30,
    )
    return certificate, key


@contextlib.contextmanager
def signed_smoke_https_delivery(project: Path, version: str):
    """Use real network I/O in the explicitly disposable signed-update fixture.

    Its actor/server/client substitutions and disposable signing key remain;
    this is not an immutable production-candidate qualification helper.
    """
    from tests.integration._self_update_fixture import PLUGIN_ROOT, load_smoke_script

    smoke = load_smoke_script()
    manager = Path("utils/update_manager.gd")
    # Restore the production manager, removing the fixture's local-file I/O
    # substitutions entirely. The only patch left in A is its trust root: the
    # plugin verifies manifests in GDScript against the key embedded here, so
    # A must trust the disposable key that signed the served triple.
    shutil.copy2(PLUGIN_ROOT / manager, project / "addons/godot_ai" / manager)
    smoke.patch_release_signing_key(
        project / "addons/godot_ai" / manager,
        smoke.smoke_public_key_path(project).read_text(encoding="utf-8"),
    )
    assets = project.parent / "https-assets"
    assets.mkdir()
    for name in (smoke.SMOKE_ARCHIVE_NAME, smoke.SMOKE_MANIFEST_NAME, smoke.SMOKE_SIGNATURE_NAME):
        shutil.copy2(project / smoke.SMOKE_DIR / name, assets / name)
    # This test never exercises migration; the envelope's legacy triple is
    # inert synthetic data, not a signed final-v3 capsule or approval claim.
    for name in support.RELEASE_NAMES - {path.name for path in assets.iterdir()}:
        (assets / name).write_bytes(b"x" * 512 if name.endswith(".sig") else b"x")
    certificate, key = make_tls_material(project.parent / "https-tls")
    adapter = project / "_test_https_transport.gd"
    adapter.write_text(
        """@tool
extends Node

var certificate := X509Certificate.new()

func _enter_tree() -> void:
    assert(certificate.load(OS.get_environment("PRIVATE_HTTPS_CERTIFICATE")) == OK)
    get_tree().node_added.connect(_node_added)

func _node_added(node: Node) -> void:
    if not node is HTTPRequest:
        return
    var owner_node := node.get_parent()
    if owner_node == null or owner_node.get_script() == null:
        return
    if owner_node.get_script().resource_path != "res://addons/godot_ai/utils/update_manager.gd":
        return
    node.set_https_proxy("127.0.0.1", int(OS.get_environment("PRIVATE_HTTPS_PORT")))
    node.set_tls_options(TLSOptions.client(certificate))
    if not owner_node.activation_requested.is_connected(_downloaded):
        owner_node.activation_requested.connect(_downloaded)

func _downloaded(_package: Dictionary) -> void:
    print("SELF_UPDATE_TEST | HTTPS canonical triple downloaded")
""",
        encoding="utf-8",
    )
    config = project / "project.godot"
    text = config.read_text(encoding="utf-8")
    assert text.count("[autoload]\n") == 1
    config.write_text(
        text.replace(
            "[autoload]\n", '[autoload]\n_PrivateHttpsTransport="*res://_test_https_transport.gd"\n'
        ),
        encoding="utf-8",
    )
    with private_release_origin(
        assets, support.inventory(assets), version=version, certificate=certificate, private_key=key
    ) as endpoint:
        yield (
            endpoint,
            {
                **endpoint.environment(),
                "PRIVATE_HTTPS_PORT": str(endpoint.proxy_port),
                "PRIVATE_HTTPS_CERTIFICATE": str(certificate),
            },
        )
