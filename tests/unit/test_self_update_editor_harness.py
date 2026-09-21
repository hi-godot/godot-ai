"""Restart-safe launch arguments and useful, bounded CI progress."""

from __future__ import annotations

import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from godot_ai.transport.capability import CapabilityRecord
from tests.integration import _self_update_fixture as fixture


@pytest.mark.parametrize("headless", [False, True])
@pytest.mark.parametrize("allow_headless", [False, True])
@pytest.mark.parametrize("restart", [False, True])
def test_editor_launch_and_progress(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str],
    headless: bool, allow_headless: bool, restart: bool,
) -> None:
    project = tmp_path / "project"
    project.mkdir()
    now = [0]
    probe_calls = []
    captured = {}

    class Process:
        pid = 4321
        returncode = None

        def poll(self):
            if restart or now[0] >= 32:
                self.returncode = 0
            return self.returncode

    def popen(command, **kwargs):
        captured.update(command=command, **kwargs)
        kwargs["stdout"].write("fixture stdout\nfixture stderr\n")
        return Process()

    def tick(seconds):
        assert seconds in (0.05, 0.25)
        now[0] += 16
        if now[0] >= 32:
            (project / "complete").touch()

    monkeypatch.setenv("GODOT_AI_ALLOW_HEADLESS", "ambient")
    monkeypatch.setattr(fixture.subprocess, "Popen", popen)
    monkeypatch.setattr(fixture.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(fixture.time, "sleep", tick)
    monkeypatch.setattr(fixture, "load_smoke_script", lambda: SimpleNamespace(
        diagnostic_reports_snapshot=lambda: set(),
    ))
    (project / fixture.POST_UPDATE_STATUS_FILE).touch()
    if restart:
        (project / "_test_restarted_editor.log").write_text("replacement output\n")
    output = fixture.run_godot_editor(
        project, "godot", headless=headless, allow_headless=allow_headless,
        live_probe=lambda: probe_calls.append(True),
        restart_completion_file="complete" if restart else None,
        environment={"PRIVATE_TEST_SENTINEL": "must-not-be-logged"},
    )
    assert output.startswith("fixture stdout\nfixture stderr\n")
    if restart:
        assert output.endswith("replacement editor log:\nreplacement output\n")
    else:
        assert output == "fixture stdout\nfixture stderr\n"
    assert probe_calls == [True]
    assert (project / fixture.POST_UPDATE_TOOL_PROBE_FILE).is_file()
    command = captured["command"]
    assert "--headless" not in command
    if headless:
        assert command[1:5] == ["--display-driver", "headless", "--audio-driver", "Dummy"]
    else:
        assert "--display-driver" not in command and "--audio-driver" not in command
    assert captured["stderr"] == subprocess.STDOUT
    assert captured["env"].get("GODOT_AI_ALLOW_HEADLESS") == (
        "1" if allow_headless else None
    )
    progress = capsys.readouterr().out
    assert "started editor pid=4321" in progress
    assert "authenticated_probe=True" in progress
    assert f"initial editor {'exited(0)' if restart else 'running'}" in progress
    assert f"restart_complete={'False' if restart else 'n/a'}" in progress
    assert "must-not-be-logged" not in progress


def test_timeout_reports_progress_without_suppressing_failure(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, capsys: pytest.CaptureFixture[str],
) -> None:
    now = [0]
    stopped = []

    class Process:
        pid = 4321
        returncode = None

        def poll(self):
            return None

        def terminate(self):
            stopped.append("terminate")

        def wait(self, timeout):
            assert timeout == 5
            if stopped[-1] == "terminate":
                raise subprocess.TimeoutExpired("godot", timeout)

        def kill(self):
            stopped.append("kill")

    def tick(_seconds):
        now[0] += 16

    monkeypatch.setattr(fixture.subprocess, "Popen", lambda *a, **kw: Process())
    monkeypatch.setattr(fixture.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(fixture.time, "sleep", tick)
    monkeypatch.setattr(fixture, "load_smoke_script", lambda: SimpleNamespace(
        diagnostic_reports_snapshot=lambda: set(),
    ))
    with pytest.raises(AssertionError, match="timed out after 20 seconds"):
        fixture.run_godot_editor(tmp_path, "godot", allow_headless=True, timeout=20)
    assert stopped == ["terminate", "kill"]
    assert "remaining=4s" in capsys.readouterr().out


@pytest.mark.asyncio
@pytest.mark.parametrize("capability_env", ["LOCALAPPDATA", "GODOT_AI_CAPABILITY_DIR"])
async def test_attached_agent_uses_python_and_the_editors_isolated_environment(
    monkeypatch, tmp_path, capability_env
):
    import fastmcp
    from fastmcp.client import transports

    environment = {
        capability_env: str(tmp_path / "private storage"),
        "CODEX_HOME": str(tmp_path / "codex"),
        "GODOT_AI_MODE": "user",
    }
    monkeypatch.setenv(capability_env, "unrelated-user-storage")
    monkeypatch.setenv("ATTACHED_AGENT_INHERITED_SENTINEL", "preserved")
    agent = fixture.AttachedAgent(
        tmp_path, 18000, 19500, capability_dir=tmp_path, environment=environment
    )
    captured = {}
    capability = CapabilityRecord("h" * 64, "a" * 64, "b" * 32)
    (tmp_path / fixture.PRE_INSTANCE_ID_FILE).write_text(
        capability.instance_nonce, encoding="utf-8"
    )
    monkeypatch.setattr(fixture, "read_capabilities", lambda *_args: capability)

    def transport(**kwargs):
        captured.update(kwargs)
        return object()

    class Client:
        def __init__(self, *_args, **_kwargs):
            pass

        async def __aenter__(self):
            agent._stop.set()
            return self

        async def __aexit__(self, *_args):
            pass

    monkeypatch.setattr(transports, "StdioTransport", transport)
    monkeypatch.setattr(fastmcp, "Client", Client)
    await agent._poll()

    assert captured["command"] == fixture.sys.executable
    assert captured["args"][:3] == ["-m", "godot_ai", "attach"]
    for name, value in environment.items():
        assert captured["env"][name] == value
    assert captured["env"]["GODOT_AI_DISABLE_TELEMETRY"] == "true"
    assert captured["env"]["ATTACHED_AGENT_INHERITED_SENTINEL"] == "preserved"


@pytest.fixture
def receipt_agent(monkeypatch, tmp_path):
    import fastmcp
    from fastmcp.client import transports

    agent = fixture.AttachedAgent(tmp_path, 18969, 19969, capability_dir=tmp_path, environment={})
    capability = CapabilityRecord("h" * 64, "a" * 64, "b" * 32)
    monkeypatch.setattr(fixture, "read_capabilities", lambda *_args: capability)
    entered = []

    class Client:
        def __init__(self, *_args, **_kwargs):
            pass

        async def __aenter__(self):
            entered.append(True)
            agent._stop.set()
            return self

        async def __aexit__(self, *_args):
            pass

    monkeypatch.setattr(fastmcp, "Client", Client)
    monkeypatch.setattr(transports, "StdioTransport", lambda **_kwargs: object())
    return agent, capability.instance_nonce, entered


@pytest.mark.asyncio
@pytest.mark.parametrize("error", [FileNotFoundError(2, "absent"), PermissionError(13, "sharing")])
async def test_receipt_retry_requires_matching_nonce(monkeypatch, receipt_agent, error):
    agent, nonce, entered = receipt_agent
    attempts = iter([error, "", "stale", nonce[:8], nonce])
    sleeps = []

    def read(_path, **_kwargs):
        result = next(attempts)
        if isinstance(result, Exception):
            raise result
        return result

    async def sleep(seconds):
        assert entered == []
        sleeps.append(seconds)

    monkeypatch.setattr(Path, "read_text", read)
    monkeypatch.setattr(fixture.asyncio, "sleep", sleep)
    await agent._poll()
    assert entered == [True]
    assert sleeps == [0.25] * 4


@pytest.mark.asyncio
async def test_persistent_receipt_denial_fails_at_original_deadline(monkeypatch, receipt_agent):
    agent, _nonce, entered = receipt_agent
    now = [0.0]
    attempts = []

    def read(_path, **_kwargs):
        attempts.append(now[0])
        raise PermissionError(13, "private path and content must not leak")

    async def sleep(_seconds):
        now[0] += 61

    monkeypatch.setattr(Path, "read_text", read)
    monkeypatch.setattr(fixture.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(fixture.asyncio, "sleep", sleep)
    expected = (r"matching capabilities; last pre-instance receipt read: "
                r"PermissionError \(errno=13\)")
    with pytest.raises(AssertionError, match=expected) as failure:
        await agent._poll()
    assert "private" not in str(failure.value)
    assert attempts == [0, 61]
    assert entered == []


@pytest.mark.asyncio
async def test_other_receipt_io_failure_is_not_retried(monkeypatch, receipt_agent):
    agent, _nonce, entered = receipt_agent

    def read(_path, **_kwargs):
        raise OSError(5, "device error")

    monkeypatch.setattr(Path, "read_text", read)
    with pytest.raises(OSError, match="device error"):
        await agent._poll()
    assert entered == []


@pytest.mark.asyncio
@pytest.mark.skipif(fixture.sys.platform != "win32", reason="Windows sharing semantics")
async def test_native_receipt_sharing_violation_retries_until_handle_released(
    monkeypatch, receipt_agent,
):
    import _winapi

    agent, nonce, entered = receipt_agent
    receipt = agent.project_dir / fixture.PRE_INSTANCE_ID_FILE
    receipt.write_text(nonce, encoding="utf-8")
    handle = _winapi.CreateFile(
        str(receipt), _winapi.GENERIC_READ | _winapi.GENERIC_WRITE,
        0, 0, _winapi.OPEN_EXISTING, 0, 0,
    )
    sleeps = []

    async def sleep(seconds):
        assert entered == []
        nonlocal handle
        sleeps.append(seconds)
        _winapi.CloseHandle(handle)
        handle = None

    monkeypatch.setattr(fixture.asyncio, "sleep", sleep)
    try:
        with pytest.raises(PermissionError):
            receipt.read_text(encoding="utf-8")
        await agent._poll()
    finally:
        if handle is not None:
            _winapi.CloseHandle(handle)
    assert sleeps == [0.25]
    assert entered == [True]


@pytest.mark.asyncio
@pytest.mark.parametrize("record_present", [True, False])
async def test_receipt_timeout_reports_nonce_mismatch_without_secrets(
    monkeypatch, receipt_agent, record_present,
):
    agent, nonce, entered = receipt_agent
    now = [0.0]
    stale_nonce = "private-stale-nonce"
    (agent.project_dir / fixture.PRE_INSTANCE_ID_FILE).write_text(stale_nonce, encoding="utf-8")
    if not record_present:
        monkeypatch.setattr(fixture, "read_capabilities", lambda *_args: None)

    async def sleep(_seconds):
        now[0] += 61

    monkeypatch.setattr(fixture.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(fixture.asyncio, "sleep", sleep)
    with pytest.raises(AssertionError, match="never published matching capabilities") as failure:
        await agent._poll()
    message = str(failure.value)
    assert ("capability seen but pre-instance nonce mismatched" in message) is record_present
    assert stale_nonce not in message
    assert nonce not in message
    assert now[0] == 122
    assert entered == []


@pytest.mark.asyncio
@pytest.mark.parametrize("elapsed", [120, 122])
async def test_expired_receipt_wait_does_no_more_io(monkeypatch, receipt_agent, elapsed):
    agent, _nonce, entered = receipt_agent
    now = [0.0]
    discoveries = []
    reads = []

    def discover(*_args):
        discoveries.append(now[0])
        return None

    def read(_path, **_kwargs):
        reads.append(now[0])
        raise PermissionError(13, "sensitive receipt path")

    async def sleep(_seconds):
        now[0] += elapsed

    monkeypatch.setattr(fixture, "read_capabilities", discover)
    monkeypatch.setattr(Path, "read_text", read)
    monkeypatch.setattr(fixture.time, "monotonic", lambda: now[0])
    monkeypatch.setattr(fixture.asyncio, "sleep", sleep)
    with pytest.raises(AssertionError, match=r"PermissionError \(errno=13\)") as failure:
        await agent._poll()
    assert discoveries == [0]
    assert reads == [0]
    assert "sensitive" not in str(failure.value)
    assert entered == []


@pytest.mark.asyncio
@pytest.mark.parametrize("slow_operation", ["discovery", "receipt"])
async def test_late_matching_receipt_cannot_start_client(
    monkeypatch, receipt_agent, slow_operation,
):
    agent, nonce, entered = receipt_agent
    now = [0.0]
    discoveries = []
    reads = []

    def discover(*_args):
        discoveries.append(now[0])
        if slow_operation == "discovery":
            now[0] = 120
        return CapabilityRecord("h" * 64, "a" * 64, nonce)

    def read(_path, **_kwargs):
        reads.append(now[0])
        now[0] = 120
        return nonce

    monkeypatch.setattr(fixture, "read_capabilities", discover)
    monkeypatch.setattr(Path, "read_text", read)
    monkeypatch.setattr(fixture.time, "monotonic", lambda: now[0])
    with pytest.raises(AssertionError, match="never published matching capabilities") as failure:
        await agent._poll()
    assert discoveries == [0]
    assert reads == ([] if slow_operation == "discovery" else [0])
    assert "nonce mismatched" not in str(failure.value)
    assert entered == []


@pytest.mark.asyncio
async def test_stopped_receipt_wait_does_no_io(monkeypatch, receipt_agent):
    agent, _nonce, entered = receipt_agent
    agent._stop.set()
    def unexpected(*_args, **_kwargs):
        pytest.fail("stopped receipt wait must not discover or read")
    monkeypatch.setattr(fixture, "read_capabilities", unexpected)
    monkeypatch.setattr(Path, "read_text", unexpected)
    with pytest.raises(AssertionError, match="never published matching capabilities"):
        await agent._poll()
    assert entered == []
