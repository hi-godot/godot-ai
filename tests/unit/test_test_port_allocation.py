"""Keep backend restart ports out of other pytest workers' allocations."""

import json
import socket
import subprocess
import sys
from pathlib import Path

from tests.conftest import allocate_free_ports


def test_released_port_is_not_reallocated_by_another_worker(tmp_path, monkeypatch):
    claims = tmp_path / "claims"
    claims.mkdir()
    monkeypatch.setenv("GODOT_AI_TEST_PORT_CLAIMS", str(claims))
    with socket.socket() as first, socket.socket() as second:
        first.bind(("127.0.0.1", 0))
        second.bind(("127.0.0.1", 0))
        candidates = [first.getsockname()[1], second.getsockname()[1]]

    # Force the OS's permitted reuse of the same now-closed port in two
    # separate workers, without depending on ephemeral allocation luck.
    worker = """
import json
import socket
import sys
sys.path[:] = json.loads(sys.argv[2])
from tests.conftest import allocate_free_ports

candidates = iter(json.loads(sys.argv[1]))
class CandidateSocket(socket.socket):
    def bind(self, address):
        host, port = address
        return super().bind((host, next(candidates) if port == 0 else port))

socket.socket = CandidateSocket
print(json.dumps(allocate_free_ports(1)))
"""

    def allocate_in_worker():
        root = Path(__file__).resolve().parents[2]
        completed = subprocess.run(
            [sys.executable, "-c", worker, json.dumps(candidates), json.dumps(sys.path)],
            cwd=root,
            capture_output=True, text=True, check=True, timeout=30,
        )
        return json.loads(completed.stdout)[0]

    original = allocate_in_worker()
    with socket.socket() as restarted:
        restarted.bind(("127.0.0.1", original))
    other_worker = allocate_in_worker()

    assert original == candidates[0]
    assert other_worker == candidates[1]
    with socket.socket() as restarted:
        restarted.bind(("127.0.0.1", original))


def test_port_batch_is_distinct_and_released():
    ports = allocate_free_ports(3)
    assert len(set(ports)) == 3
    for port in ports:
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", port))
