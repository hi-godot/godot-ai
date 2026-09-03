"""Ephemeral loopback PEP 503 index serving only retained qualification wheels.

The unguessable path is process-local authorization, never written to evidence.
No public-index fallback, arbitrary filesystem serving, or access logs.
"""

from __future__ import annotations

import contextlib
import hashlib
import html
import os
import re
import secrets
import stat
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

from script import release_support as support


@contextlib.contextmanager
def retained_index(packages: Path, dependencies: list[dict]):
    prefix = "/" + secrets.token_hex(32)
    support.require(dependencies, "empty private index")
    for row in dependencies:
        support.require(
            isinstance(row.get("filename"), str)
            and re.fullmatch(r"[A-Za-z0-9_.+-]+\.whl", row["filename"])
            and isinstance(row.get("name"), str)
            and re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", row["name"])
            and type(row.get("size")) is int
            and 0 < row["size"] <= support.MAX_FILE_BYTES
            and isinstance(row.get("sha256"), str)
            and re.fullmatch(r"[a-f0-9]{64}", row["sha256"]),
            "invalid private index artifact identity",
        )
    files = {row["filename"]: row for row in dependencies}
    support.require(len(files) == len(dependencies), "duplicate index filenames")
    support.require(
        support.inventory(packages)
        == {name: {"size": row["size"], "sha256": row["sha256"]} for name, row in files.items()},
        "private index differs from retained dependency inventory",
    )
    routes = {}
    for name in sorted({row["name"] for row in dependencies}):
        links = [
            f'<a href="../../files/{quote(row["filename"])}#sha256={row["sha256"]}">'
            f"{html.escape(row['filename'])}</a>"
            for row in dependencies
            if row["name"] == name
        ]
        routes[f"{prefix}/simple/{name}/"] = ("\n".join(links) + "\n").encode()
    requests: list[str] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_args):
            pass  # Never print authorization URLs, including on errors.

        def do_GET(self):
            self.serve_artifact(head_only=False)

        def do_HEAD(self):
            # uv probes wheel metadata with HEAD before downloading. The same
            # authorization and digest checks apply; HEAD is not download proof.
            self.serve_artifact(head_only=True)

        def serve_artifact(self, *, head_only):
            # Decode once: generated links encode local-version '+' as '%2B'.
            # The exact inventory lookup below still rejects decoded separators.
            path = unquote(urlsplit(self.path).path)
            if path in routes:
                payload = routes[path]
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
            elif path.startswith(prefix + "/files/"):
                name = path.removeprefix(prefix + "/files/")
                if name not in files:
                    self.send_error(404)
                    return
                expected = files[name]
                # A mutated wheel must fail closed even after startup's scan.
                target = packages / name
                try:
                    if not stat.S_ISREG(target.lstat().st_mode):
                        raise OSError("artifact is no longer a regular file")
                    descriptor = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
                    with os.fdopen(descriptor, "rb") as stream:
                        current = os.fstat(stream.fileno())
                        if not stat.S_ISREG(current.st_mode) or current.st_size != expected["size"]:
                            raise OSError("artifact identity changed")
                        payload = stream.read(expected["size"] + 1)
                except OSError:
                    self.send_error(409)
                    return
                if {"size": len(payload), "sha256": hashlib.sha256(payload).hexdigest()} != {
                    key: expected[key] for key in ("size", "sha256")
                }:
                    self.send_error(409)
                    return
                if not head_only:
                    requests.append(name)
                self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
            else:
                self.send_error(404)
                return
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            if not head_only:
                self.wfile.write(payload)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}{prefix}/simple/", requests
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        support.require(not thread.is_alive(), "private index did not stop")
