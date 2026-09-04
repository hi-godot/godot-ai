"""Use real disposable processes on every desktop CI row; no Godot mock."""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

import pytest

from script import qualification_resources as resources


def test_real_child_measurement_cli_and_dead_identity(tmp_path: Path):
    ready = tmp_path / "ready"
    child = subprocess.Popen(
        [
            sys.executable,
            "-u",
            "-c",
            "import sys; from pathlib import Path; "
            "Path(sys.argv[1]).write_text('ready', encoding='utf-8'); sys.stdin.buffer.read()",
            str(ready),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + 10
        while not ready.exists():
            assert child.poll() is None, child.communicate(timeout=5)
            assert time.monotonic() < deadline, "child did not become ready"
            time.sleep(0.01)
        binding = resources.bind_process(child.pid)
        result = resources.sample_process(binding)
        assert result["pid"] == child.pid
        assert result["rss_bytes"] > 0 and result["threads"] >= 1
        if sys.platform == "win32":
            assert result["handles"] > 0 and result["file_descriptors"] is None
        else:
            assert result["file_descriptors"] >= 3 and result["handles"] is None
        output = tmp_path / "samples.jsonl"
        command = [
            sys.executable,
            "-m",
            "script.qualification_resources",
            "--process",
            f"child={child.pid}",
            "--output",
            str(output),
            "--count",
            "2",
            "--interval",
            "0.01",
        ]
        run = subprocess.run(command, capture_output=True, timeout=15)
        assert run.returncode == 0, run.stderr
        rows = [json.loads(line) for line in output.read_text(encoding="utf-8").splitlines()]
        assert [row["event"] for row in rows] == ["header", "sample", "sample", "complete"]
        assert rows[-1]["status"] == "measured"
        assert rows[1]["processes"]["child"]["created_at"] == binding.created_at
        if os.name != "nt":
            assert output.stat().st_mode & 0o777 == 0o600
        child.communicate(b"", timeout=10)
        assert child.returncode == 0
        with pytest.raises(resources.ResourceError, match="unavailable|identity changed|dead"):
            resources.sample_process(binding)
    finally:
        if child.poll() is None:
            child.kill()
        child.communicate(timeout=10)


def test_real_closed_target_retains_error_not_success(tmp_path):
    output = tmp_path / "error.jsonl"
    # A PID may theoretically be reused; retain and use the exact identity in
    # the other test. This CLI row proves an impossible PID refuses cleanly.
    run = subprocess.run(
        [
            sys.executable,
            "-m",
            "script.qualification_resources",
            "--process",
            "gone=999999999",
            "--output",
            str(output),
        ],
        capture_output=True,
        timeout=15,
    )
    assert run.returncode == 2
    assert [
        json.loads(line)["event"] for line in output.read_text(encoding="utf-8").splitlines()
    ] == ["error"]
