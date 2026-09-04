"""Private, default-port HTTPS release origin for qualification harnesses.

A single loopback CONNECT endpoint terminates TLS for one fixed .invalid
origin; it never forwards traffic. Clients must verify the supplied disposable
certificate and send the process-local bearer token inside TLS. No system
DNS, trust store, privileged port, candidate patch or public service is needed.
This serves retained bytes; it does not sign or approve a candidate.
"""

from __future__ import annotations

import contextlib
import hashlib
import hmac
import os
import secrets
import socket
import ssl
import stat
import threading
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

from script import release_support as support

ORIGIN_HOST = "release.qualification.invalid"
ORIGIN = f"https://{ORIGIN_HOST}"
RELEASE_PATH = "/releases/latest"
ASSET_PATH = "/assets/"
IO_TIMEOUT = 5.0


@dataclass(frozen=True)
class PrivateRelease:
    proxy_port: int
    token: str = field(repr=False)
    downloads: list[str] = field(default_factory=list, repr=False)

    def environment(self) -> dict[str, str]:
        return {
            "GODOT_AI_QUALIFICATION_RELEASE": "1",
            "GODOT_AI_QUALIFICATION_RELEASE_URL": ORIGIN + RELEASE_PATH,
            "GODOT_AI_QUALIFICATION_ASSET_PREFIX": ORIGIN + ASSET_PATH,
            "GODOT_AI_QUALIFICATION_TOKEN": self.token,
        }


@contextlib.contextmanager
def private_release_origin(
    assets: Path,
    inventory: dict[str, dict],
    *,
    version: str,
    certificate: Path,
    private_key: Path,
):
    support.require(support.version_tuple(version)[0] == 4, "private release must be v4")
    support.require(set(inventory) == support.RELEASE_NAMES, "private release needs six assets")
    expected = {}
    for name, value in inventory.items():
        support.require(
            isinstance(value, dict)
            and set(value) == {"size", "sha256"}
            and type(value["size"]) is int
            and 0 < value["size"] <= support.MAX_FILE_BYTES
            and isinstance(value["sha256"], str)
            and support.DIGEST.fullmatch(value["sha256"]),
            "invalid private release artifact identity",
        )
        expected[name] = dict(value)
    support.require(support.inventory(assets) == expected, "private release inventory mismatch")
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(certificate, private_key)
    token = secrets.token_hex(32)
    downloads: list[str] = []
    failures: list[str] = []
    metadata = support.canonical(
        {
            "tag_name": f"v{version}",
            "assets": [
                {
                    "name": name,
                    "size": expected[name]["size"],
                    "browser_download_url": ORIGIN + ASSET_PATH + name,
                }
                for name in sorted(expected)
            ],
        }
    )

    class QuietHandler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # Never retain request URLs, authorization or TLS exceptions.

        def handle(self):
            try:
                super().handle()
            except (ConnectionError, TimeoutError):
                pass  # A deadline or peer disconnect may interrupt a response.

    class OriginHandler(QuietHandler):
        def do_GET(self):
            self.serve(head_only=False)

        def do_HEAD(self):
            self.serve(head_only=True)

        def serve(self, *, head_only):
            authorization = self.headers.get_all("Authorization", [])
            hosts = self.headers.get_all("Host", [])
            if (
                len(authorization) != 1
                or len(authorization[0]) > 128
                or not hmac.compare_digest(authorization[0].encode(), ("Bearer " + token).encode())
            ):
                self.send_error(401)
                return
            if hosts not in ([ORIGIN_HOST], [ORIGIN_HOST + ":443"]):
                self.send_error(400)
                return
            name = self.path.removeprefix(ASSET_PATH)
            if self.path == RELEASE_PATH:
                payload = metadata
                content_type = "application/json"
            elif self.path.startswith(ASSET_PATH) and name in expected:
                path = assets / name
                identity = expected[name]
                try:
                    support.regular(path)
                    descriptor = os.open(
                        path,
                        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0),
                    )
                    with os.fdopen(descriptor, "rb") as stream:
                        info = os.fstat(stream.fileno())
                        if not stat.S_ISREG(info.st_mode) or info.st_size != identity["size"]:
                            raise OSError("retained asset changed")
                        payload = stream.read(identity["size"] + 1)
                    if {
                        "size": len(payload),
                        "sha256": hashlib.sha256(payload).hexdigest(),
                    } != identity:
                        raise OSError("retained asset changed")
                except (OSError, support.ReleaseError):
                    self.send_error(409)
                    return
                content_type = "application/octet-stream"
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if not head_only:
                self.wfile.write(payload)
                if self.path != RELEASE_PATH:
                    downloads.append(name)

    class ConnectHandler(QuietHandler):
        def do_CONNECT(self):
            if self.path != ORIGIN_HOST + ":443":
                self.send_error(403)
                return
            self.send_response(200, "Connection established")
            self.end_headers()
            self.wfile.flush()
            self.rfile.close()
            try:
                with context.wrap_socket(self.connection, server_side=True) as secure:
                    OriginHandler(secure, self.client_address, self.server)
            except OSError:
                pass  # Bad TLS, a timeout or a disconnected client grants no access.
            self.close_connection = True

    class Server(HTTPServer):
        request_queue_size = 8

        def get_request(self):
            connection, address = super().get_request()
            connection.settimeout(IO_TIMEOUT)
            # Per-read timeouts alone allow a client to trickle headers forever.
            # The duplicate survives wrap_socket detaching the original socket,
            # so this absolute deadline also bounds the TLS request and response.
            self.deadline_socket = connection.dup()

            def expire():
                with contextlib.suppress(OSError):
                    self.deadline_socket.shutdown(socket.SHUT_RDWR)

            self.deadline = threading.Timer(IO_TIMEOUT, expire)
            self.deadline.start()
            return connection, address

        def shutdown_request(self, request):
            self.deadline.cancel()
            self.deadline.join()
            self.deadline_socket.close()
            super().shutdown_request(request)

        def handle_error(self, _request, _address):
            failures.append("private HTTPS handler failed")

    # One bounded connection at a time: no unbounded per-request worker pool.
    server = Server(("127.0.0.1", 0), ConnectHandler)
    worker = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.05})
    worker.start()
    try:
        yield PrivateRelease(server.server_port, token, downloads)
    finally:
        server.shutdown()
        server.server_close()
        worker.join(timeout=IO_TIMEOUT + 1)
        support.require(not worker.is_alive() and not failures, "private HTTPS shutdown failed")
