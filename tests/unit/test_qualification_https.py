"""Real TLS/CONNECT tests for the private qualification release origin."""

import http.client
import json
import os
import socket
import ssl
import time

import pytest

from script import qualification_https as https
from script import release_support as support
from script.qualification_https import ASSET_PATH, ORIGIN_HOST, RELEASE_PATH, private_release_origin
from tests._qualification_https_fixture import make_tls_material


@pytest.fixture(scope="module")
def tls_material(tmp_path_factory):
    return make_tls_material(tmp_path_factory.mktemp("private-release-tls"))


def release_fixture(root):
    for name in support.RELEASE_NAMES:
        (root / name).write_bytes(b"x" * 512 if name.endswith(".sig") else name.encode())
    return support.inventory(root)


def request(
    endpoint, certificate, path=RELEASE_PATH, *, method="GET", headers=None, host=ORIGIN_HOST
):
    context = ssl.create_default_context(cafile=str(certificate))
    connection = http.client.HTTPSConnection(
        "127.0.0.1", endpoint.proxy_port, context=context, timeout=5
    )
    connection.set_tunnel(host, 443)
    try:
        connection.request(
            method,
            path,
            headers=headers
            if headers is not None
            else {
                "Authorization": "Bearer " + endpoint.token,
            },
        )
        response = connection.getresponse()
        return response.status, response.read(), dict(response.headers)
    finally:
        connection.close()


def test_origin_serves_exact_bytes_over_verified_tls_and_keeps_token_private(
    tmp_path, tls_material, capsys
):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        environment = endpoint.environment()
        assert environment["GODOT_AI_QUALIFICATION_RELEASE"] == "1"
        assert endpoint.token not in repr(endpoint)
        assert endpoint.token not in environment["GODOT_AI_QUALIFICATION_RELEASE_URL"]
        code, payload, _ = request(endpoint, certificate)
        assert code == 200
        metadata = json.loads(payload)
        assert metadata["tag_name"] == "v4.0.1"
        assert {row["name"] for row in metadata["assets"]} == support.RELEASE_NAMES
        for row in metadata["assets"]:
            path = ASSET_PATH + row["name"]
            code, empty, headers = request(endpoint, certificate, path, method="HEAD")
            assert code == 200 and empty == b""
            assert int(headers["Content-Length"]) == inventory[row["name"]]["size"]
            code, body, _ = request(endpoint, certificate, path)
            assert code == 200 and body == (tmp_path / row["name"]).read_bytes()
        assert sorted(endpoint.downloads) == sorted(support.RELEASE_NAMES)
        code, body, _ = request(endpoint, certificate, method="HEAD")
        assert code == 200 and body == b""
    with pytest.raises(OSError):
        socket.create_connection(("127.0.0.1", endpoint.proxy_port), timeout=1)
    assert capsys.readouterr() == ("", "")


@pytest.mark.parametrize(
    "headers",
    [
        {},
        {"Authorization": "Bearer wrong"},
        {"Authorization": "x" * 129},
        {"Authorization": "Bearer ü"},
    ],
)
def test_origin_refuses_missing_wrong_or_malformed_authorization(tmp_path, tls_material, headers):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        for method in ("GET", "HEAD"):
            assert request(endpoint, certificate, method=method, headers=headers)[0] == 401
        assert endpoint.downloads == []


@pytest.mark.parametrize(
    "path",
    [
        "/",
        "/assets/../private-key.pem",
        "/assets/%2e%2e/private-key.pem",
        "/assets/godot-ai-plugin.zip?token=wrong",
        "/releases/latest?x=1",
        "https://elsewhere.invalid/assets/godot-ai-plugin.zip",
    ],
)
def test_origin_never_serves_unknown_or_noncanonical_paths(tmp_path, tls_material, path):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        headers = {"Authorization": "Bearer " + endpoint.token, "Host": ORIGIN_HOST}
        assert request(endpoint, certificate, path, headers=headers)[0] == 404
        assert endpoint.downloads == []


def test_origin_rejects_other_connect_targets_host_spoofing_and_untrusted_certificates(
    tmp_path, tls_material
):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    other_certificate, _ = make_tls_material(tmp_path.parent / (tmp_path.name + "-other"))
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        with pytest.raises(OSError, match="403"):
            request(endpoint, certificate, host="example.com")
        with pytest.raises(ssl.SSLCertVerificationError):
            request(endpoint, other_certificate)
        headers = {"Authorization": "Bearer " + endpoint.token, "Host": "example.com"}
        assert request(endpoint, certificate, headers=headers)[0] == 400
        assert request(endpoint, certificate)[0] == 200
        assert endpoint.downloads == []


@pytest.mark.parametrize("mutation", ["delete", "size", "same-size", "directory", "symlink"])
def test_origin_revalidates_assets_after_startup(tmp_path, tls_material, mutation):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    name = "godot-ai-plugin.zip"
    path = tmp_path / name
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        if mutation == "size":
            path.write_bytes(b"changed")
        elif mutation == "same-size":
            path.write_bytes(b"z" * inventory[name]["size"])
        else:
            path.unlink()
            if mutation == "directory":
                path.mkdir()
            elif mutation == "symlink":
                try:
                    path.symlink_to(tls_material[0])
                except OSError:
                    pytest.skip("symlink creation is unavailable to this Windows account")
        for method in ("GET", "HEAD"):
            assert request(endpoint, certificate, ASSET_PATH + name, method=method)[0] == 409
        assert endpoint.downloads == []


@pytest.mark.parametrize(
    "invalid", ["version", "names", "size", "digest", "extra-field", "changed-file"]
)
def test_origin_rejects_invalid_inventory_before_listening(tmp_path, tls_material, invalid):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    version = "3.2.4" if invalid == "version" else "4.0.1"
    name = "godot-ai-plugin.zip"
    if invalid == "names":
        inventory.pop(name)
    elif invalid == "size":
        inventory[name]["size"] = True
    elif invalid == "digest":
        inventory[name]["sha256"] = "not-a-digest"
    elif invalid == "extra-field":
        inventory[name]["authority"] = "no"
    elif invalid == "changed-file":
        (tmp_path / name).write_bytes(b"changed")
    with pytest.raises(support.ReleaseError):
        with private_release_origin(
            tmp_path, inventory, version=version, certificate=certificate, private_key=key
        ):
            pytest.fail("invalid private origin started")


@pytest.mark.parametrize("duplicate", ["Authorization", "Host"])
def test_origin_rejects_duplicate_authority_headers(tmp_path, tls_material, duplicate):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        connection = http.client.HTTPSConnection(
            "127.0.0.1",
            endpoint.proxy_port,
            context=ssl.create_default_context(cafile=str(certificate)),
            timeout=5,
        )
        connection.set_tunnel(ORIGIN_HOST, 443)
        try:
            connection.putrequest("GET", RELEASE_PATH)
            connection.putheader("Authorization", "Bearer " + endpoint.token)
            connection.putheader(
                duplicate,
                "Bearer " + endpoint.token if duplicate == "Authorization" else ORIGIN_HOST,
            )
            connection.endheaders()
            response = connection.getresponse()
            assert response.status == (401 if duplicate == "Authorization" else 400)
            response.read()
        finally:
            connection.close()
        assert endpoint.downloads == []


def test_origin_plaintext_access_is_not_a_tls_or_authentication_fallback(tmp_path, tls_material):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        connection = http.client.HTTPConnection("127.0.0.1", endpoint.proxy_port, timeout=5)
        try:
            connection.request("GET", RELEASE_PATH)
            response = connection.getresponse()
            assert response.status == 501
            assert b"tag_name" not in response.read()
        finally:
            connection.close()
        assert endpoint.downloads == []


def test_origin_bounds_an_incomplete_tls_client_during_shutdown(
    tmp_path, tls_material, monkeypatch
):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    monkeypatch.setattr(https, "IO_TIMEOUT", 0.2)
    pending = None
    started = time.monotonic()
    try:
        with private_release_origin(
            tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
        ) as endpoint:
            pending = socket.create_connection(("127.0.0.1", endpoint.proxy_port), timeout=2)
            pending.sendall(f"CONNECT {ORIGIN_HOST}:443 HTTP/1.0\r\n\r\n".encode())
            response = b""
            while b"\r\n\r\n" not in response:
                chunk = pending.recv(1024)
                assert chunk
                response += chunk
            assert response.startswith(b"HTTP/1.0 200")
            # Do not send a TLS ClientHello. Context shutdown must still finish.
        assert time.monotonic() - started < 2
    finally:
        if pending is not None:
            pending.close()


@pytest.mark.parametrize("inside_tls", [False, True])
def test_origin_has_an_absolute_deadline_even_when_headers_keep_trickling(
    tmp_path, tls_material, monkeypatch, inside_tls
):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    monkeypatch.setattr(https, "IO_TIMEOUT", 0.5)
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:
        pending = socket.create_connection(("127.0.0.1", endpoint.proxy_port), timeout=2)
        try:
            if inside_tls:
                pending.sendall(f"CONNECT {ORIGIN_HOST}:443 HTTP/1.0\r\n\r\n".encode())
                response = b""
                while b"\r\n\r\n" not in response:
                    chunk = pending.recv(1024)
                    assert chunk
                    response += chunk
                assert response.startswith(b"HTTP/1.0 200")
                context = ssl.create_default_context(cafile=str(certificate))
                pending = context.wrap_socket(pending, server_hostname=ORIGIN_HOST)
                pending.sendall(f"GET {RELEASE_PATH} HTTP/1.0\r\nX-Trickle: ".encode())
            else:
                pending.sendall(f"CONNECT {ORIGIN_HOST}:443 HTTP/1.0\r\nX-Trickle: ".encode())
            pending.settimeout(0.01)
            stopped = False
            deadline = time.monotonic() + 1.5
            while time.monotonic() < deadline:
                try:
                    pending.sendall(b"x")
                    try:
                        if pending.recv(1024) == b"":
                            stopped = True
                            break
                    except socket.timeout:
                        pass
                except OSError:
                    stopped = True
                    break
                time.sleep(0.02)
            assert stopped, "a trickling client extended the absolute connection budget"
        finally:
            pending.close()


def test_unexpected_handler_failure_fails_context_without_logging_secrets(
    tmp_path, tls_material, monkeypatch, capsys
):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    original = support.regular
    name = "godot-ai-plugin.zip"
    with pytest.raises(support.ReleaseError, match="private HTTPS shutdown failed"):
        with private_release_origin(
            tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
        ) as endpoint:

            def unexpected(path):
                if path == tmp_path / name:
                    raise RuntimeError(endpoint.token)
                return original(path)

            monkeypatch.setattr(support, "regular", unexpected)
            with pytest.raises(http.client.RemoteDisconnected):
                request(endpoint, certificate, ASSET_PATH + name)
            assert endpoint.downloads == []
    assert capsys.readouterr() == ("", "")


@pytest.mark.skipif(not hasattr(os, "mkfifo"), reason="POSIX FIFO replacement race")
def test_origin_rejects_a_fifo_replacement_without_blocking(tmp_path, tls_material, monkeypatch):
    inventory = release_fixture(tmp_path)
    certificate, key = tls_material
    name = "godot-ai-plugin.zip"
    target = tmp_path / name
    original_regular = support.regular
    original_open = os.open
    with private_release_origin(
        tmp_path, inventory, version="4.0.1", certificate=certificate, private_key=key
    ) as endpoint:

        def replace_after_check(path):
            original_regular(path)
            if path == target:
                path.unlink()
                os.mkfifo(path)

        def checked_open(path, flags, *args):
            if path == target:
                assert flags & os.O_NONBLOCK, "never open a raced FIFO in blocking mode"
            return original_open(path, flags, *args)

        monkeypatch.setattr(support, "regular", replace_after_check)
        monkeypatch.setattr(os, "open", checked_open)
        assert request(endpoint, certificate, ASSET_PATH + name)[0] == 409
        assert endpoint.downloads == []
