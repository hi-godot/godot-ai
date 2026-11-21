"""Verify saved adaptive music and real stereo mixer timing through Godot."""

from __future__ import annotations

import cmath
import math
import shutil
import struct
import wave
from pathlib import Path
from statistics import median

import pytest
from fastmcp.exceptions import ToolError

from tests.integration._native_mcp_editor import _backend, _editor, _isolate_editor, _receipt
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
FILL_CLIP = {"name": "combat_stinger", "stream_path": "res://music/combat_stinger.wav"}
FILL_TONES = ((1000, 0.22), (1125, 0.27))
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


def _write_fill(path: Path) -> None:
    with wave.open(str(path), "wb") as output:
        output.setparams((2, 2, RATE, 0, "NONE", "not compressed"))
        output.writeframes(
            b"".join(
                struct.pack(
                    "<hh",
                    *(
                        round(32767 * gain * math.sin(math.tau * hz * frame / RATE))
                        for hz, gain in FILL_TONES
                    ),
                )
                for frame in range(RATE // 2)
            )
        )


def _write_project(project: Path, http_port: int, ws_port: int, *, with_fill: bool) -> None:
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    shutil.copytree(FIXTURES, project / "music")
    if with_fill:
        _write_fill(project / FILL_CLIP["stream_path"].removeprefix("res://"))
    else:
        shutil.copyfile(
            FIXTURES / "exploration.ogg", project / EARLY_BEAT_END.removeprefix("res://")
        )
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


def _measure_stereo_envelopes(capture: Path, timing: dict, *, with_fill: bool):
    frames = list(struct.iter_unpack("<ff", capture.read_bytes()))
    assert timing["rate"] == timing["requested_at_frame"] == RATE, timing
    assert timing["clip_before_request"] == 0 and timing["clip_after_capture"] == 1, timing
    assert len(frames) == RATE * 4

    # Each source contributes a different spectral line on each channel.
    # The 128-frame window contains an integer number of cycles of every tone.
    window = 128
    frequencies = [250, 375, 625, 875]
    nominal = [0.34, 0.24, 0.29, 0.31]
    baseline_windows = [(0.5, 0.9)] * 2 + [(3.7, 3.9)] * 2
    if with_fill:
        frequencies.extend(hz for hz, _ in FILL_TONES)
        nominal.extend(gain for _, gain in FILL_TONES)
        baseline_windows.extend([(2.1, 2.4)] * 2)
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
        for channel, (start, end) in enumerate(baseline_windows)
    ]
    assert baseline == pytest.approx(nominal, abs=0.025)
    gains = [
        tuple(amplitude / full for amplitude, full in zip(row, baseline)) for row in amplitudes
    ]

    # One 256-frame capture/mixer block plus one spectral window allows for
    # decoder look-ahead, the envelope threshold, and the analysis window.
    tolerance = (timing["block"] + window) / RATE
    return times, gains, tolerance


def _assert_native_crossfade(capture: Path, timing: dict, *, with_fill: bool) -> dict:
    times, gains, tolerance = _measure_stereo_envelopes(capture, timing, with_fill=with_fill)
    onsets, completions = [], []
    for channel in range(2):
        onset = next(
            time for time, gain in zip(times, gains) if time >= 1 and gain[channel + 2] > 0.02
        )
        completion = next(
            time for time, gain in zip(times, gains) if time >= 2.0 and gain[channel] < 0.02
        )
        onsets.append(onset)
        completions.append(completion)
    combat_start = 2.5 if with_fill else 2.0
    assert onsets == pytest.approx([combat_start] * 2, abs=tolerance)
    exploration_end = 2.125 if with_fill else 3.0
    assert completions == pytest.approx([exploration_end] * 2, abs=tolerance)
    measurement = {
        "onsets_left_right": onsets,
        "completions_left_right": completions,
        "tolerance_seconds": tolerance,
    }
    if with_fill:
        fill_onsets = [
            next(time for time, gain in zip(times, gains) if time >= 1 and gain[channel] > 0.02)
            for channel in (4, 5)
        ]
        fill_ends = [
            next(time for time, gain in zip(times, gains) if time >= 2.25 and gain[channel] < 0.02)
            for channel in (4, 5)
        ]
        assert fill_onsets == pytest.approx([2.0, 2.0], abs=tolerance)
        assert fill_ends == pytest.approx([2.5, 2.5], abs=tolerance)
        assert (
            max(max(gain[4:]) for time, gain in zip(times, gains) if time >= 2.5 + tolerance) < 0.02
        )
        combat_full = [
            next(time for time, gain in zip(times, gains) if time >= 2.5 and gain[channel] > 0.98)
            for channel in (2, 3)
        ]
        assert combat_full == pytest.approx([2.625, 2.625], abs=tolerance)
        measurement.update(
            fill_onsets_left_right=fill_onsets,
            fill_ends_left_right=fill_ends,
            combat_full_left_right=combat_full,
        )
        check_points = (
            (0.75, 1, 0, 0),
            (1.5, 1, 0, 0),
            (2.25, 0, 0, 1),
            (2.75, 0, 1, 0),
            (3.25, 0, 1, 0),
            (3.75, 0, 1, 0),
        )
    else:
        check_points = (
            (0.75, 1, 0),
            (1.5, 1, 0),
            (2.25, 0.75, 0.25),
            (2.5, 0.5, 0.5),
            (2.75, 0.25, 0.75),
            (3.25, 0, 1),
        )
    envelope = {}
    for time, *expected_gains in check_points:
        closest = min(range(len(times)), key=lambda index: abs(times[index] - time))
        observed = gains[closest]
        assert observed == pytest.approx(
            [gain for gain in expected_gains for _ in range(2)], abs=0.065
        )
        envelope[time] = tuple(round(value, 3) for value in observed)
    measurement["envelope"] = envelope
    return measurement


def _assert_implicit_native_fill_fade(capture: Path, timing: dict) -> dict:
    times, gains, tolerance = _measure_stereo_envelopes(capture, timing, with_fill=True)
    onset = [
        next(time for time, gain in zip(times, gains) if time >= 2 and gain[ch] > 0.02)
        for ch in (2, 3)
    ]
    full = [
        next(time for time, gain in zip(times, gains) if time >= 2.5 and gain[ch] > 0.98)
        for ch in (2, 3)
    ]
    assert onset == pytest.approx([2.5, 2.5], abs=tolerance)
    assert full == pytest.approx([3.5, 3.5], abs=tolerance)
    combat_gains = {}
    for time, expected in ((2.75, 0.25), (3.0, 0.5), (3.25, 0.75)):
        closest = min(range(len(times)), key=lambda index: abs(times[index] - time))
        assert gains[closest][2:4] == pytest.approx([expected, expected], abs=0.065)
        combat_gains[time] = tuple(round(gain, 3) for gain in gains[closest][2:4])
    return {"onset_left_right": onset, "full_left_right": full, "combat_gains": combat_gains}


@pytest.mark.parametrize("with_fill", [False, True], ids=["crossfade", "one-shot-fill"])
async def test_saved_adaptive_score_switches_the_same_player_and_mixes_on_the_bar(
    tmp_path, monkeypatch, with_fill
):
    godot = godot_bin_or_skip()
    _isolate_editor(monkeypatch, tmp_path / "editor-profile", godot)
    project = tmp_path / "project"
    clips = CLIPS + [FILL_CLIP] if with_fill else CLIPS
    transitions = TRANSITIONS
    expected_clips = [{**clip, "bpm": 120.0, "beats_per_bar": 4} for clip in CLIPS]
    if with_fill:
        transitions = [
            {**TRANSITIONS[0], "filler_clip": FILL_CLIP["name"], "fade_beats": 0.25},
            TRANSITIONS[1],
        ]
        expected_clips.append({**FILL_CLIP, "bpm": 0.0, "beats_per_bar": 0})
    async with _backend() as (client, http_port, ws_port):
        _write_project(project, http_port, ws_port, with_fill=with_fill)
        source_bytes = {path: path.read_bytes() for path in (project / "music").iterdir()}
        async with _editor(client, godot, project, tmp_path / "create.log") as (tool, first):
            assert (await tool("filesystem_manage", op="scan", params={}))["scan_completed"]
            tempo = {"bpm": 120.0, "bar_beats": 4}
            import_settings = {
                clip["stream_path"]: {**tempo, "beat_count": 12, "loop": True} for clip in CLIPS
            }
            if with_fill:
                import_settings[FILL_CLIP["stream_path"]] = {
                    "compress/mode": 0,
                    "edit/loop_mode": 1,
                }
            else:
                import_settings[EARLY_BEAT_END] = {**tempo, "beat_count": 6, "loop": False}
            for path, options in import_settings.items():
                before = await tool("filesystem_manage", op="import_get", params={"path": path})
                after = await tool(
                    "filesystem_manage",
                    op="import_set",
                    params={
                        "path": path,
                        "expected_revision": before["revision"],
                        "options": options,
                    },
                )
                assert after["import_succeeded"], after
            sidecar_bytes = {
                path: path.read_bytes() for path in (project / "music").glob("*.import")
            }
            assert len(source_bytes) == len(sidecar_bytes) == len(import_settings)
            if with_fill:
                for mode in (None, "disabled", "out"):
                    rejected = f"rejected-{mode or 'default'}.tres"
                    invalid_transition = {**transitions[0]}
                    if mode is None:
                        del invalid_transition["fade"]
                    else:
                        invalid_transition["fade"] = mode
                    with pytest.raises(
                        ToolError, match="Specify fade 'in' or 'cross' with filler_clip"
                    ):
                        await tool(
                            "audio_manage",
                            op="interactive_create",
                            params={
                                "path": f"res://{rejected}",
                                "clips": clips,
                                "transitions": [invalid_transition],
                            },
                        )
                    assert not (project / rejected).exists()
            else:
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
                    "clips": clips,
                    "initial_clip": "exploration",
                    "transitions": transitions,
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
            assert saved["clips"] == expected_clips
            assert saved["transitions"] == transitions
            timing = await _receipt(probe / "timing.json")
            assert timing["pid"] == fresh["editor_pid"]
            measurement = _assert_native_crossfade(
                probe / "stereo.f32", timing, with_fill=with_fill
            )
            # Characterize known engine versions without requiring the same
            # native fade after Godot changes it. Public checks run on all versions.
            if with_fill and fresh["godot_version"].split("-", 1)[0] in {"4.7", "4.7.0", "4.7.2"}:
                for mode in ("disabled", "out"):
                    baseline_timing = await _receipt(probe / f"native-{mode}-timing.json")
                    assert baseline_timing["pid"] == fresh["editor_pid"]
                    measurement[f"native_{mode}"] = _assert_implicit_native_fill_fade(
                        probe / f"native-{mode}-stereo.f32",
                        baseline_timing,
                    )

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
            assert observations[0]["clip"] == "exploration"
            if with_fill:
                switches = (("exploration", "combat", (FILL_CLIP["name"], "combat")),)
            else:
                switches = (
                    ("exploration", "combat", ("combat",)),
                    ("combat", "exploration", ("exploration",)),
                )
            for current, target, expected in switches:
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
                for name in expected:
                    observed = await _receipt(probe / f"preview-{len(observations)}.json")
                    assert observed["clip"] == name, observed
                    observations.append(observed)
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
    print(f"Preview clips on one playback instance: {[item['clip'] for item in observations]}")
