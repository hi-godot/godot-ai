"""Verify saved adaptive music and real stereo mixer timing through Godot."""

from __future__ import annotations

import asyncio
import cmath
import json
import math
import shutil
import struct
from pathlib import Path
from statistics import median

import pytest
from fastmcp.exceptions import ToolError

from tests.integration._native_mcp_editor import _backend, _editor, _isolate_editor
from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor

# Original six-second stereo pilot tones, retained as Ogg Vorbis fixtures.
FIXTURES = Path(__file__).with_name("fixtures") / "adaptive_music"
RATE = 8000
SCENE = "res://music.tscn"
SCORE = "res://score.tres"
PLAYER = "/Music/Player"
EARLY_BEAT_END = "res://music/early_beat_end.ogg"
CLIPS = [
    {"name": "exploration", "stream_path": "res://music/exploration.ogg"},
    {"name": "combat", "stream_path": "res://music/combat.ogg"},
]
TRANSITIONS = [
    {
        "from": "exploration",
        "to": "combat",
        "when": "next_bar",
        "start_at": "start",
        "fade": "cross",
        "fade_beats": 2.0,
    },
    {
        "from": "combat",
        "to": "exploration",
        "when": "next_beat",
        "start_at": "start",
        "fade": "cross",
        "fade_beats": 0.5,
    },
]


def _write_project(project: Path, http_port: int, ws_port: int) -> None:
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    shutil.copytree(FIXTURES, project / "music")
    shutil.copyfile(FIXTURES / "exploration.ogg", project / EARLY_BEAT_END.removeprefix("res://"))
    bootstrap = project / "addons/adaptive_probe"
    bootstrap.mkdir()
    for name in ("driver", "capture"):
        shutil.copyfile(
            Path(__file__).with_name(f"_interactive_music_{name}.gd"), bootstrap / f"{name}.gd"
        )
    (bootstrap / "plugin.cfg").write_text(
        '[plugin]\nname="Adaptive music test"\nscript="driver.gd"\n', encoding="utf-8"
    )
    (project / ".adaptive-test").mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Adaptive music regression"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/adaptive_probe/plugin.cfg")\n'
        f"[adaptive_test]\nhttp_port={http_port}\nws_port={ws_port}\n"
        f"[audio]\ndriver/mix_rate={RATE}\n",
        encoding="utf-8",
    )
    (project / "music.tscn").write_text(
        '[gd_scene format=3]\n\n[node name="Music" type="Node"]\n\n'
        '[node name="Player" type="AudioStreamPlayer" parent="."]\n',
        encoding="utf-8",
    )


async def _receipt(path: Path) -> dict:
    async with asyncio.timeout(10):
        while True:
            try:
                return json.loads(path.read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                await asyncio.sleep(0.05)


def _assert_native_crossfade(capture: Path, timing: dict) -> dict:
    frames = list(struct.iter_unpack("<ff", capture.read_bytes()))
    assert timing["rate"] == timing["requested_at_frame"] == RATE, timing
    assert timing["clip_before_request"] == 0 and timing["clip_after_capture"] == 1, timing
    assert len(frames) == RATE * 7 // 2

    # Each source contributes a different spectral line on each channel.
    # The 128-frame window contains an integer number of cycles of every tone.
    window = 128
    frequencies = (250, 375, 625, 875)
    tones = [
        tuple(cmath.exp(math.tau * 1j * hz * i / RATE) for i in range(window)) for hz in frequencies
    ]
    times = [(offset + window / 2) / RATE for offset in range(0, len(frames) - window + 1, window)]
    amplitudes = []
    for offset in range(0, len(frames) - window + 1, window):
        block = frames[offset : offset + window]
        amplitudes.append(
            [
                2
                * abs(sum(frame[channel % 2] * weight for frame, weight in zip(block, tone)))
                / window
                for channel, tone in enumerate(tones)
            ]
        )
    baseline = [
        median(row[channel] for time, row in zip(times, amplitudes) if start <= time <= end)
        for channel, (start, end) in enumerate(((0.5, 0.9), (0.5, 0.9), (3.2, 3.4), (3.2, 3.4)))
    ]
    assert baseline == pytest.approx([0.34, 0.24, 0.29, 0.31], abs=0.025)
    gains = [
        tuple(amplitude / full for amplitude, full in zip(row, baseline)) for row in amplitudes
    ]

    # One 256-frame capture/mixer block plus one spectral window allows for
    # decoder look-ahead, the envelope threshold, and the analysis window.
    tolerance = (timing["block"] + window) / RATE
    onsets, completions = [], []
    for channel in range(2):
        onset = next(
            time for time, gain in zip(times, gains) if time >= 1 and gain[channel + 2] > 0.02
        )
        completion = next(
            time for time, gain in zip(times, gains) if time >= 2.5 and gain[channel] < 0.02
        )
        onsets.append(onset)
        completions.append(completion)
    assert onsets == pytest.approx([2.0, 2.0], abs=tolerance)
    assert completions == pytest.approx([3.0, 3.0], abs=tolerance)

    envelope = {}
    for time, combat in ((0.75, 0), (1.5, 0), (2.25, 0.25), (2.5, 0.5), (2.75, 0.75), (3.25, 1)):
        closest = min(range(len(times)), key=lambda index: abs(times[index] - time))
        observed = gains[closest]
        assert observed == pytest.approx([1 - combat, 1 - combat, combat, combat], abs=0.065)
        envelope[time] = tuple(round(value, 3) for value in observed)
    return {
        "onsets_left_right": onsets,
        "completions_left_right": completions,
        "tolerance_seconds": tolerance,
        "envelope": envelope,
    }


async def test_saved_adaptive_score_switches_the_same_player_and_mixes_on_the_bar(
    tmp_path, monkeypatch
):
    godot = godot_bin_or_skip()
    _isolate_editor(monkeypatch, tmp_path / "editor-profile", godot)
    project = tmp_path / "project"
    async with _backend() as (client, http_port, ws_port):
        _write_project(project, http_port, ws_port)
        source_bytes = {path: path.read_bytes() for path in (project / "music").glob("*.ogg")}
        async with _editor(client, godot, project, tmp_path / "create.log") as (tool, first):
            assert (await tool("filesystem_manage", op="scan", params={}))["scan_completed"]
            import_settings = {clip["stream_path"]: (12, True) for clip in CLIPS}
            import_settings[EARLY_BEAT_END] = (6, False)
            for path, (beats, loop) in import_settings.items():
                before = await tool("filesystem_manage", op="import_get", params={"path": path})
                after = await tool(
                    "filesystem_manage",
                    op="import_set",
                    params={
                        "path": path,
                        "expected_revision": before["revision"],
                        "options": {
                            "bpm": 120.0,
                            "bar_beats": 4,
                            "beat_count": beats,
                            "loop": loop,
                        },
                    },
                )
                assert after["import_succeeded"], after
            sidecar_bytes = {
                path: path.read_bytes() for path in (project / "music").glob("*.import")
            }
            assert len(source_bytes) == len(sidecar_bytes) == len(import_settings)
            with pytest.raises(
                ToolError, match="Beat Count that ends before its non-looping audio"
            ):
                await tool(
                    "audio_manage",
                    op="interactive_create",
                    params={
                        "path": "res://rejected.tres",
                        "clips": [{**CLIPS[0], "stream_path": EARLY_BEAT_END}, CLIPS[1]],
                        "transitions": [{**TRANSITIONS[0], "when": "end"}],
                    },
                )
            assert not (project / "rejected.tres").exists()
            created = await tool(
                "audio_manage",
                op="interactive_create",
                params={
                    "path": SCORE,
                    "clips": CLIPS,
                    "initial_clip": "exploration",
                    "transitions": TRANSITIONS,
                },
            )
            assert created["path"] == SCORE and created["type"] == "AudioStreamInteractive", created
            assert created["undoable"] is False
            score_bytes = (project / "score.tres").read_bytes()

        probe = project / ".adaptive-test"
        (probe / "capture.request").touch()
        async with _editor(client, godot, project, tmp_path / "preview.log") as (tool, fresh):
            assert (
                fresh["editor_pid"] != first["editor_pid"]
                and fresh["session_id"] != first["session_id"]
            )
            saved = await tool("audio_manage", op="interactive_get", params={"path": SCORE})
            assert (
                saved["type"] == "AudioStreamInteractive" and saved["initial_clip"] == "exploration"
            )
            assert saved["clips"] == [{**clip, "bpm": 120.0, "beats_per_bar": 4} for clip in CLIPS]
            assert saved["transitions"] == TRANSITIONS
            timing = await _receipt(probe / "timing.json")
            assert timing["pid"] == fresh["editor_pid"]
            measurement = _assert_native_crossfade(probe / "stereo.f32", timing)

            assert (await tool("scene_open", path=SCENE))["switched"]
            assigned = await tool(
                "audio_manage",
                op="player_set_stream",
                params={
                    "player_path": PLAYER,
                    "stream_path": SCORE,
                },
            )
            assert assigned["stream_path"] == SCORE
            assert (await tool("scene_save"))["path"] == SCENE
            scene_bytes = (project / "music.tscn").read_bytes()
            assert (await tool("audio_manage", op="play", params={"player_path": PLAYER}))[
                "playing"
            ]
            observations = [await _receipt(probe / "preview-0.json")]
            for index, (current, target) in enumerate(
                (("exploration", "combat"), ("combat", "exploration")), 1
            ):
                switched = await tool(
                    "audio_manage",
                    op="interactive_switch",
                    params={
                        "player_path": PLAYER,
                        "clip": target,
                    },
                )
                assert (
                    switched["previous_clip"] == current and switched["requested_clip"] == target
                ), switched
                assert switched["undoable"] is False
                observations.append(await _receipt(probe / f"preview-{index}.json"))
            assert [item["clip"] for item in observations] == [
                "exploration",
                "combat",
                "exploration",
            ]
            for key in ("player_id", "playback_id"):
                assert len({item[key] for item in observations}) == 1
            assert all(
                item["pid"] == fresh["editor_pid"] and item["stream_path"] == SCORE
                for item in observations
            )
            assert (await tool("audio_manage", op="stop", params={"player_path": PLAYER}))[
                "playing"
            ] is False

        assert (project / "score.tres").read_bytes() == score_bytes
        assert (project / "music.tscn").read_bytes() == scene_bytes
        for path, before in (source_bytes | sidecar_bytes).items():
            assert path.read_bytes() == before, path
    print(
        f"Godot {fresh['godot_version']} {first['session_id']} (PID {first['editor_pid']}) -> "
        f"{fresh['session_id']} (PID {fresh['editor_pid']})"
    )
    print(
        f"Requested at frame {timing['requested_at_frame']}, measured stereo envelope {measurement}"
    )
