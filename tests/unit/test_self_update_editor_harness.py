"""Restart-safe launch arguments and useful, bounded CI progress."""

from __future__ import annotations

import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

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
