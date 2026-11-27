"""Fixtures for capturing stereo PCM from a pinned editor's preview player."""

from __future__ import annotations

import json
import math
import shutil
import struct
import wave
from pathlib import Path

from tests.integration._native_mcp_editor import _receipt
from tests.integration._self_update_fixture import PLUGIN_ROOT

PLAYER = "/Music/Player"
SCENE = "res://music.tscn"
PROOF = ".auto-advance-test"


def write_capture_project(
    project: Path, http_port: int, ws_port: int, *, rate: int, **settings
) -> None:
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    bootstrap = project / "addons/auto_advance_probe"
    bootstrap.mkdir()
    shutil.copyfile(
        Path(__file__).with_name("_interactive_auto_advance_driver.gd"), bootstrap / "driver.gd"
    )
    (bootstrap / "plugin.cfg").write_text(
        '[plugin]\nname="Audio preview capture"\nscript="driver.gd"\n', encoding="utf-8"
    )
    (project / PROOF).mkdir()
    capture_settings = "".join(f"{key}={json.dumps(value)}\n" for key, value in settings.items())
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Adaptive music preview regression"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/auto_advance_probe/plugin.cfg")\n'
        f"[auto_advance_test]\nhttp_port={http_port}\nws_port={ws_port}\n{capture_settings}"
        f"[audio]\ndriver/mix_rate={rate}\n",
        encoding="utf-8",
    )
    (project / SCENE.removeprefix("res://")).write_text(
        '[gd_scene format=3]\n\n[node name="Music" type="Node"]\n\n'
        '[node name="Player" type="AudioStreamPlayer" parent="."]\n',
        encoding="utf-8",
    )
    (project / "music").mkdir()


def write_stereo_wav(path: Path, rate: int, parts: list[tuple[int, tuple[int, int]]]) -> None:
    with wave.open(str(path), "wb") as output:
        output.setparams((2, 2, rate, 0, "NONE", "not compressed"))
        for frames, frequencies in parts:
            output.writeframes(
                b"".join(
                    struct.pack(
                        "<hh",
                        *(
                            round(8192 * math.sin(math.tau * hz * frame / rate))
                            for hz in frequencies
                        ),
                    )
                    for frame in range(frames)
                )
            )


async def audio(tool, op, **params):
    return await tool("audio_manage", op=op, params=params)


async def arm_take(proof: Path, name: str, pid: int) -> None:
    (proof / "capture.request").write_text(name, encoding="utf-8")
    assert (await _receipt(proof / f"{name}-ready.json"))["pid"] == pid
