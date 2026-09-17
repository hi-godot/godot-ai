"""Run launchers against fake clients so tests never start a paid agent session."""

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("remote", [False, True])
def test_powershell_launcher_preserves_task_and_selects_checkout(tmp_path: Path, remote: bool):
    pwsh = shutil.which("pwsh")
    if not pwsh:
        pytest.skip("PowerShell is not installed")
    (tmp_path / "script").mkdir()
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs/poteto-session.md").write_text("fixture", encoding="utf-8")
    launcher = tmp_path / "script/poteto.ps1"
    shutil.copyfile(ROOT / "script/poteto.ps1", launcher)
    task = 'Keep $HOME, $(exit 9), `quotes`, "double quotes", & and spaces literal.'
    runner = tmp_path / "run.ps1"
    runner.write_text(
        "function global:claude {\n"
        "  [pscustomobject]@{arguments=@($args); cwd=(Get-Location).Path} | "
        "ConvertTo-Json -Compress\n"
        "  $global:LASTEXITCODE = 0\n"
        "}\n"
        "$options = @{Client='claude'; Task=$env:PSTACK_TEST_TASK}\n"
        "if ($env:PSTACK_TEST_REMOTE -eq '1') { $options.Remote=$true }\n"
        "& $env:PSTACK_TEST_LAUNCHER @options\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [pwsh, "-NoProfile", "-File", str(runner)],
        env={
            **os.environ,
            "PSTACK_TEST_TASK": task,
            "PSTACK_TEST_REMOTE": "1" if remote else "0",
            "PSTACK_TEST_LAUNCHER": str(launcher),
        },
        capture_output=True,
        text=True,
        check=True,
    )
    payload = json.loads(result.stdout)
    assert Path(payload["cwd"]).resolve() == tmp_path.resolve()
    arguments = payload["arguments"]
    assert arguments[:-1] == (["--remote-control", "Godot AI poteto"] if remote else [])
    assert arguments[-1].endswith("\n\nTask:\n" + task)
    assert "docs/poteto-session.md" in arguments[-1]


@pytest.mark.parametrize("client,remote", [("codex", False), ("claude", False), ("claude", True)])
def test_bash_launcher_preserves_task_and_remote_arguments(
    tmp_path: Path, client: str, remote: bool
):
    bash = shutil.which("bash")
    if os.name == "nt":
        git = shutil.which("git")
        candidate = Path(git).resolve().parents[1] / "bin/bash.exe" if git else None
        bash = str(candidate) if candidate and candidate.is_file() else None
    if not bash:
        pytest.skip("A native Bash installation is not available")
    (tmp_path / "script").mkdir()
    (tmp_path / "docs").mkdir()
    (tmp_path / "docs/poteto-session.md").write_text("fixture", encoding="utf-8")
    launcher = tmp_path / "script/poteto"
    shutil.copyfile(ROOT / "script/poteto", launcher)
    binary = tmp_path / "bin"
    binary.mkdir()
    fake = binary / client
    fake.write_text('#!/bin/bash\nprintf "%s\\0" "$PWD" "$@"\n', encoding="utf-8", newline="\n")
    fake.chmod(0o755)
    task = 'Keep $HOME, $(exit 9), `quotes`, "double quotes", & and spaces literal.'
    result = subprocess.run(
        [
            bash,
            "-c",
            'export PATH="/usr/bin:/bin:$PATH"; bin=$1; shift; '
            'if command -v cygpath >/dev/null; then bin=$(cygpath -u "$bin"); fi; '
            'export PATH="$bin:$PATH"; exec "$BASH" "$@"',
            "test",
            binary.as_posix(),
            launcher.as_posix(),
            client,
            *(["--remote"] if remote else []),
            task,
        ],
        check=True,
        capture_output=True,
    )
    fields = result.stdout.decode().split("\0")
    assert fields[-1] == ""
    assert fields[1:-2] == (["--remote-control", "Godot AI poteto"] if remote else [])
    assert fields[-2].endswith("\n\nTask:\n" + task)
    assert "docs/poteto-session.md" in fields[-2]
    assert fields[0].replace("\\", "/").endswith(tmp_path.name)
