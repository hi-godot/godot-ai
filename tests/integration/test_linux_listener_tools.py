"""Linux startup uses procfs even when desktop sandboxes omit PATH tools."""

from __future__ import annotations

import sys

import pytest

from tests.integration.test_unix_startup import run_probe

pytestmark = pytest.mark.editor


@pytest.mark.skipif(sys.platform != "linux", reason="Live Linux procfs")
@pytest.mark.parametrize("available", ["", "ss", "lsof"])
def test_linux_proc_proves_listener_and_process_without_path_tools(tmp_path, available):
    commands = tmp_path / "bin"
    commands.mkdir()
    marker = tmp_path / "unexpected-tool"
    if available:
        tool = commands / available
        tool.write_text(f'#!/bin/sh\nprintf called > "{marker}"\nexit 1\n')
        tool.chmod(0o700)
    result = run_probe(
        tmp_path,
        """    var original := OS.get_environment("PATH")
    OS.set_environment("PATH", OS.get_environment("TEST_TOOL_PATH"))
    var pid := OS.get_process_id()
    var listener := TCPServer.new()
    var port := 0
    for candidate in range(32000, 33000):
        if listener.listen(candidate, "127.0.0.1") == OK:
            port = candidate
            break
    result["port"] = port
    result["problem"] = Ports.listener_tools_problem()
    result["alive"] = Ports.pid_alive(pid)
    result["parent"] = Ports.process_parent(pid)
    result["commandline"] = Ports.process_commandline(pid)
    result["snapshot"] = Ports.capture_process_snapshot(pid)
    result["fingerprint"] = Ports.process_fingerprint(pid)
    result["occupied"] = Ports.is_port_in_use(port)
    result["listeners"] = Ports.find_all_pids_on_port(port)
    result["pid"] = pid
    listener.stop()
    result["free"] = not Ports.is_port_in_use(port)
    OS.set_environment("PATH", original)
""",
        environment={"TEST_TOOL_PATH": str(commands)},
    )
    assert not marker.exists()
    assert result["port"] > 0
    assert result["problem"] == ""
    assert result["alive"] is True and result["parent"] > 0
    assert "driver.gd" in result["commandline"]
    assert str(result["pid"]) in result["snapshot"]
    assert len(result["fingerprint"]) == 64
    assert result["occupied"] is True and result["free"] is True
    assert result["pid"] in result["listeners"]
