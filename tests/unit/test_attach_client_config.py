from __future__ import annotations

import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

from godot_ai.attach.main import _parser

_FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "test_project"
    / "tests"
    / "fixtures"
    / "attach_toml_samples.toml"
)


def test_gdscript_toml_fixture_round_trips_through_tomllib() -> None:
    parsed = tomllib.loads(_FIXTURE.read_text(encoding="utf-8"))
    entry = parsed["samples"]["uvx"]

    assert entry["command"] == "C:/Python313/pythonw.exe"
    assert entry["args"][0] == "-c"
    assert "creationflags=0x08000000" in entry["args"][1]
    assert entry["args"][2] == 'C:\\Users\\Agent "quoted"\\bin\\uvx.exe'
    assert entry["args"][3:9] == [
        "--link-mode",
        "copy",
        "--from",
        "godot-ai==3.0.6",
        "godot-ai",
        "attach",
    ]


def test_rendered_attach_argv_is_accepted_by_attach_parser() -> None:
    parsed = tomllib.loads(_FIXTURE.read_text(encoding="utf-8"))
    args = parsed["samples"]["uvx"]["args"]
    attach_index = args.index("attach")

    namespace = _parser().parse_args(args[attach_index + 1 :])

    assert namespace.port == 8123
    assert namespace.ws_port == 9623
    assert namespace.exclude_domains == "audio,particle"


@pytest.mark.skipif(sys.platform != "win32", reason="Windows consoleless launcher")
def test_windows_pythonw_bootstrap_preserves_stdio_for_hidden_child() -> None:
    parsed = tomllib.loads(_FIXTURE.read_text(encoding="utf-8"))
    bootstrap_args = parsed["samples"]["uvx"]["args"][:2]
    pythonw = Path(sys.executable).with_name("pythonw.exe")
    if not pythonw.is_file():
        pytest.skip("active Python has no sibling pythonw.exe")

    child = (
        "import sys; "
        "line=sys.stdin.readline().strip(); "
        "sys.stdout.write(line.upper()+'\\n'); sys.stdout.flush(); "
        "sys.stderr.write('stderr-ok\\n'); sys.stderr.flush()"
    )
    completed = subprocess.run(
        [str(pythonw), *bootstrap_args, sys.executable, "-c", child],
        input="mcp-pipe-ok\n",
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )

    assert completed.returncode == 0
    assert completed.stdout == "MCP-PIPE-OK\n"
    assert completed.stderr == "stderr-ok\n"
