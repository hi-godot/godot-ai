"""Listen to named automatic clip chains on an actual editor preview player."""

from __future__ import annotations

import cmath
import math
import shutil
import struct
import wave
from itertools import groupby
from pathlib import Path

import pytest

from tests.integration._native_mcp_editor import _backend, _editor, _isolate_editor, _receipt
from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor

RATE = 8000
WINDOW = 128
PLAYER = "/Music/Player"
SCENE = "res://music.tscn"
PROOF = ".auto-advance-test"
TONES = {
    "fanfare": (250, 375),
    "buildup": (625, 750),
    "battle-a": (1000, 1125),
    "battle-b": (1375, 1500),
}
# Durations in analysis windows. The two distinct halves mark every battle loop.
PARTS = {
    "fanfare": (("fanfare", 40),),
    "buildup": (("buildup", 48),),
    "battle": (("battle-a", 16), ("battle-b", 16)),
}
CLIPS = [
    {"name": "fanfare", "stream_path": "res://music/fanfare.wav", "next_clip": "buildup"},
    {"name": "buildup", "stream_path": "res://music/buildup.wav", "next_clip": "battle"},
    {"name": "battle", "stream_path": "res://music/battle.wav"},
]
TRANSITIONS = [
    {
        "from": outgoing,
        "to": incoming,
        "when": when,
        "start_at": "start",
        "fade": "disabled",
        "fade_beats": 1.0,
    }
    for outgoing, incoming, when in (
        ("fanfare", "buildup", "end"),
        ("buildup", "battle", "end"),
        ("battle", "buildup", "immediate"),
    )
]


def _write_project(project: Path, http_port: int, ws_port: int) -> None:
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    bootstrap = project / "addons/auto_advance_probe"
    bootstrap.mkdir()
    shutil.copyfile(
        Path(__file__).with_name("_interactive_auto_advance_driver.gd"), bootstrap / "driver.gd"
    )
    (bootstrap / "plugin.cfg").write_text(
        '[plugin]\nname="Auto-advance test"\nscript="driver.gd"\n', encoding="utf-8"
    )
    (project / PROOF).mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Adaptive auto-advance regression"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/auto_advance_probe/plugin.cfg")\n'
        f"[auto_advance_test]\nhttp_port={http_port}\nws_port={ws_port}\n"
        f"[audio]\ndriver/mix_rate={RATE}\n",
        encoding="utf-8",
    )
    (project / "music.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Music" type="Node"]\n\n'
        '[node name="Player" type="AudioStreamPlayer" parent="."]\n',
        encoding="utf-8",
    )
    (project / "music").mkdir()
    for name, parts in PARTS.items():
        with wave.open(str(project / "music" / f"{name}.wav"), "wb") as output:
            output.setparams((2, 2, RATE, 0, "NONE", "not compressed"))
            for tone, duration in parts:
                output.writeframes(
                    b"".join(
                        struct.pack(
                            "<hh",
                            *(
                                round(8192 * math.sin(math.tau * hz * frame / RATE))
                                for hz in TONES[tone]
                            ),
                        )
                        for frame in range(duration * WINDOW)
                    )
                )


def _audible_runs(path: Path, expected_frames: int) -> list[tuple[str, float]]:
    frames = list(struct.iter_unpack("<ff", path.read_bytes()))
    assert len(frames) == expected_frames
    kernels = {
        hz: tuple(cmath.exp(math.tau * 1j * hz * frame / RATE) for frame in range(WINDOW))
        for frequencies in TONES.values()
        for hz in frequencies
    }
    labels = []
    for offset in range(0, len(frames) - WINDOW + 1, WINDOW):
        block = frames[offset : offset + WINDOW]
        channels = []
        for channel in range(2):
            strengths = {
                name: 2
                * abs(
                    sum(
                        frame[channel] * weight
                        for frame, weight in zip(block, kernels[frequencies[channel]])
                    )
                )
                / WINDOW
                for name, frequencies in TONES.items()
            }
            peak = max(strengths, key=strengths.get)
            channels.append(peak if strengths[peak] > 0.06 else None)
        labels.append(channels[0] if channels[0] == channels[1] else None)
    runs = []
    for label, group in groupby(enumerate(labels), key=lambda item: item[1]):
        windows = [index for index, _ in group]
        if label is not None and len(windows) >= 3:
            runs.append((label, windows[0] * WINDOW / RATE))
    return runs


def _assert_audible_chain(
    runs: list[tuple[str, float]], *, starts_with_fanfare: bool
) -> list[float]:
    order = [cue for cue, _ in runs]
    assert order.count("buildup") == 1, runs
    if starts_with_fanfare:
        assert order[:2] == ["fanfare", "buildup"] and order.count("fanfare") == 1, runs
    else:
        assert "fanfare" not in order and order[0] in {"battle-a", "battle-b"}, runs
        assert all(cue.startswith("battle-") for cue in order[: order.index("buildup")]), runs
    battle = runs[order.index("buildup") + 1 :]
    assert [cue for cue, _ in battle[:5]] == [
        "battle-a",
        "battle-b",
        "battle-a",
        "battle-b",
        "battle-a",
    ], runs
    origin = battle[0][1]
    boundaries = [battle[index][1] - origin for index in (2, 4)]
    period = sum(length for _, length in PARTS["battle"]) * WINDOW / RATE
    assert boundaries == pytest.approx([period, 2 * period], abs=2 * WINDOW / RATE)
    return boundaries


async def _audio(tool, op, **params):
    return await tool("audio_manage", op=op, params=params)


async def _arm_take(proof: Path, name: str, pid: int) -> None:
    (proof / "capture.request").write_text(name, encoding="utf-8")
    assert (await _receipt(proof / f"{name}-ready.json"))["pid"] == pid


async def _check_take(proof: Path, name: str, expected: list[str], path: str, pid: int) -> dict:
    take = await _receipt(proof / f"{name}-audio.json")
    assert take["pid"] == pid and take["rate"] == RATE and take["discarded_frames"] == 0, take
    assert [visit["clip"] for visit in take["visits"]] == expected, take
    for visit in take["visits"]:
        assert (
            visit["player_id"] == take["player_id"] and visit["playback_id"] == take["playback_id"]
        )
        assert visit["score_path"] == path
    runs = _audible_runs(proof / f"{name}-stereo.f32", take["frames"])
    wraps = _assert_audible_chain(runs, starts_with_fanfare=(expected[0] == "fanfare"))
    print(f"{name}: stereo onset runs {runs}, battle loop boundaries relative to onset {wraps}")
    return take


async def test_saved_auto_advance_chain_and_manual_return_mix_on_one_playback(
    tmp_path, monkeypatch
):
    godot = godot_bin_or_skip()
    _isolate_editor(monkeypatch, tmp_path / "editor-profile", godot)
    project = tmp_path / "project"
    proof = project / PROOF
    scores = {"chain": ("res://chain.tres", "fanfare"), "manual": ("res://manual.tres", "battle")}
    async with _backend() as (client, http_port, ws_port):
        _write_project(project, http_port, ws_port)
        originals = {path: path.read_bytes() for path in (project / "music").glob("*.wav")}
        async with _editor(client, godot, project, tmp_path / "create.log") as (tool, first):
            assert (await tool("filesystem_manage", op="scan", params={}))["scan_completed"]
            for clip in CLIPS:
                path = clip["stream_path"]
                imported = await tool("filesystem_manage", op="import_get", params={"path": path})
                configured = await tool(
                    "filesystem_manage",
                    op="import_set",
                    params={
                        "path": path,
                        "expected_revision": imported["revision"],
                        "options": {
                            "compress/mode": 0,
                            "edit/loop_mode": 2 if clip["name"] == "battle" else 1,
                        },
                    },
                )
                assert configured["import_succeeded"], configured
            sidecars = {
                path: path.read_bytes() for path in (project / "music").glob("*.wav.import")
            }
            assert len(originals) == len(sidecars) == 3
            saved_bytes = {}
            for path, initial in scores.values():
                created = await _audio(
                    tool,
                    "interactive_create",
                    path=path,
                    clips=CLIPS,
                    initial_clip=initial,
                    transitions=TRANSITIONS,
                )
                assert created["type"] == "AudioStreamInteractive" and created["undoable"] is False
                score = project / path.removeprefix("res://")
                saved_bytes[score] = score.read_bytes()

        (proof / "capture.request").touch()
        async with _editor(client, godot, project, tmp_path / "preview.log") as (tool, fresh):
            assert (
                fresh["editor_pid"] != first["editor_pid"]
                and fresh["session_id"] != first["session_id"]
            )
            print(
                f"Godot {fresh['godot_version']} "
                f"{first['session_id']} (PID {first['editor_pid']}) -> "
                f"{fresh['session_id']} (PID {fresh['editor_pid']})"
            )
            pid = fresh["editor_pid"]
            for path, initial in scores.values():
                saved = await _audio(tool, "interactive_get", path=path)
                assert saved["initial_clip"] == initial and saved["transitions"] == TRANSITIONS, (
                    saved
                )
                assert saved["clips"] == [
                    {
                        **clip,
                        "bpm": 0.0,
                        "beats_per_bar": 0,
                        **({"auto_advance": "enabled"} if "next_clip" in clip else {}),
                    }
                    for clip in CLIPS
                ]

            assert (await tool("scene_open", path=SCENE))["switched"]
            scene_file = project / SCENE.removeprefix("res://")
            takes = {}
            for name, (path, initial) in scores.items():
                assert (
                    await _audio(tool, "player_set_stream", player_path=PLAYER, stream_path=path)
                )["stream_path"] == path
                assert (await tool("scene_save"))["path"] == SCENE
                scene_bytes = scene_file.read_bytes()
                await _arm_take(proof, name, pid)
                assert (await _audio(tool, "play", player_path=PLAYER))["playing"]
                assert (await _receipt(proof / f"{name}-started.json"))["clip"] == initial
                if name == "manual":
                    assert (await _receipt(proof / f"{name}-switch-ready.json"))["pid"] == pid
                    switched = await _audio(
                        tool, "interactive_switch", player_path=PLAYER, clip="buildup"
                    )
                    assert (
                        switched["previous_clip"] == "battle"
                        and switched["requested_clip"] == "buildup"
                    )
                takes[name] = await _check_take(
                    proof, name, [initial, "buildup", "battle"], path, pid
                )
                if name == "chain":
                    assert not (await _audio(tool, "stop", player_path=PLAYER))["playing"]
                assert scene_file.read_bytes() == scene_bytes

            path, _ = scores["manual"]
            await _arm_take(proof, "reentry", pid)
            assert (await _receipt(proof / "reentry-started.json"))["clip"] == "battle"
            assert (await _receipt(proof / "reentry-switch-ready.json"))["pid"] == pid
            switched = await _audio(tool, "interactive_switch", player_path=PLAYER, clip="buildup")
            assert switched["previous_clip"] == "battle", switched
            reentry = await _check_take(
                proof, "reentry", ["battle", "buildup", "battle"], path, pid
            )
            assert reentry["playback_id"] == takes["manual"]["playback_id"]
            assert (
                reentry["player_id"] == takes["manual"]["player_id"] == takes["chain"]["player_id"]
            )
            assert not (await _audio(tool, "stop", player_path=PLAYER))["playing"]
            assert scene_file.read_bytes() == scene_bytes

        for path, original in (originals | sidecars | saved_bytes).items():
            assert path.read_bytes() == original, path
