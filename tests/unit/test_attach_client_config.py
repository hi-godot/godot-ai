from __future__ import annotations

import tomllib
from pathlib import Path

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

    assert entry["command"] == 'C:\\Users\\Agent "quoted"\\bin\\uvx.exe'
    assert entry["args"][:6] == [
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
