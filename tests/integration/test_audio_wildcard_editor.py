"""Measure wildcard precedence from stereo audio after public preview switches."""

from __future__ import annotations

import cmath
import math
import shutil
import struct
from pathlib import Path

import pytest

from tests.integration._interactive_preview_fixture import (
    PLAYER,
    PROOF,
    SCENE,
    arm_take,
    audio,
    write_capture_project,
)
from tests.integration._native_mcp_editor import _backend, _editor, _isolate_editor, _receipt
from tests.integration._self_update_fixture import godot_bin_or_skip

pytestmark = pytest.mark.editor

RATE = 48_000
WINDOW = 768  # 16 ms, a whole number of cycles for every pilot tone.
DRIVER_BLOCK = 4096  # AudioDriverDummy's callback block, in frames.
TOLERANCE = (DRIVER_BLOCK + WINDOW) / RATE
FIXTURES = Path(__file__).with_name("fixtures") / "adaptive_music"
TONES = {"cave": (1000, 1125), "stealth": (250, 375), "forest": (250, 375), "battle": (625, 875)}
CLIPS = [{"name": name, "stream_path": f"res://music/{name}.ogg"} for name in TONES]
RULES = [
    {
        "from": source,
        "to": target,
        "when": when,
        "start_at": "start",
        "fade": "disabled",
        "fade_beats": 1.0,
    }
    for source, target, when in (
        ("cave", "battle", "immediate"),
        ("stealth", "*", "next_beat"),
        ("*", "battle", "next_bar"),
        ("*", "*", "end"),
    )
]
CASES = {
    "exact": ("cave", "battle"),
    "source-wildcard": ("stealth", "battle"),
    "destination-wildcard": ("forest", "battle"),
    "fallback": ("cave", "stealth"),
}


def _write_assets(project: Path) -> None:
    music = project / "music"
    # Original 1,000/1,125 Hz stereo sine tones at 25% gain, 27,648 frames
    # at 8 kHz. Encoded once with FFmpeg libvorbis (quality 4), under the repo's MIT license.
    shutil.copyfile(FIXTURES.parent / "wildcard_cave.ogg", music / "cave.ogg")
    shutil.copyfile(FIXTURES / "exploration.ogg", music / "stealth.ogg")
    shutil.copyfile(FIXTURES / "exploration.ogg", music / "forest.ogg")
    shutil.copyfile(FIXTURES / "combat.ogg", music / "battle.ogg")


def _stereo_onsets(frames: list[tuple[float, float]], frequencies: tuple[int, int]) -> list[int]:
    onsets = []
    for channel, frequency in enumerate(frequencies):
        oscillator = [
            cmath.exp(math.tau * 1j * frequency * frame / RATE) for frame in range(WINDOW)
        ]
        previous_peak = None
        for offset in range(0, len(frames) - WINDOW + 1, WINDOW):
            block = frames[offset : offset + WINDOW]
            amplitude = (
                2
                * abs(sum(frame[channel] * weight for frame, weight in zip(block, oscillator)))
                / WINDOW
            )
            if amplitude < 0.08:
                previous_peak = None
                continue
            if previous_peak is not None:
                onsets.append(previous_peak)
                break
            previous_peak = offset
        else:
            pytest.fail(f"Missing {frequency} Hz tone on stereo channel {channel}")
    return onsets


def _assert_public_onset(
    capture: Path,
    take: dict,
    case: str,
    source: str,
    target: str,
    request_before: int,
    request_after: int,
) -> list[float]:
    frames = list(struct.iter_unpack("<ff", capture.read_bytes()))
    assert len(frames) == take["frames"]
    source_onsets = _stereo_onsets(frames, TONES[source])
    target_onsets = _stereo_onsets(frames, TONES[target])
    assert abs(source_onsets[0] - source_onsets[1]) <= WINDOW
    assert abs(target_onsets[0] - target_onsets[1]) <= WINDOW
    assert request_before <= request_after
    before_seconds = (request_before - max(source_onsets)) / RATE
    after_seconds = (request_after - min(source_onsets)) / RATE
    # Keep the public request inside the beat before 1.5 s, where the native
    # next beat and next bar produce distinguishable destination onsets.
    assert 1.0 < before_seconds <= after_seconds < 1.5 - TOLERANCE, (
        case,
        before_seconds,
        after_seconds,
    )
    measured = [(end - start) / RATE for start, end in zip(source_onsets, target_onsets)]
    if case == "exact":
        assert all(
            before_seconds - TOLERANCE <= time <= after_seconds + TOLERANCE for time in measured
        )
        assert max(measured) < 1.5 - TOLERANCE
    else:
        expected = {
            "source-wildcard": 1.5,
            "destination-wildcard": 2.0,
            "fallback": take["visits"][0]["length_seconds"],
        }[case]
        assert measured == pytest.approx([expected, expected], abs=TOLERANCE), (case, measured)
    return measured


async def test_wildcard_precedence_changes_actual_public_preview_audio(tmp_path, monkeypatch):
    godot = godot_bin_or_skip()
    _isolate_editor(monkeypatch, tmp_path / "editor-profile", godot)
    project = tmp_path / "project"
    proof = project / PROOF
    async with _backend() as (client, http_port, ws_port):
        write_capture_project(
            project,
            http_port,
            ws_port,
            rate=RATE,
            expected_visits=2,
            pre_switch_seconds=1.125,
            tail_seconds=0.5,
            measure_switch=True,
        )
        _write_assets(project)
        originals = {path: path.read_bytes() for path in (project / "music").iterdir()}
        score_bytes = {}
        async with _editor(client, godot, project, tmp_path / "create.log") as (tool, first):
            assert (await tool("filesystem_manage", op="scan", params={}))["scan_completed"]
            for clip in CLIPS:
                path = clip["stream_path"]
                imported = await tool("filesystem_manage", op="import_get", params={"path": path})
                options = {"bpm": 120.0, "bar_beats": 4, "beat_count": 0, "loop": False}
                configured = await tool(
                    "filesystem_manage",
                    op="import_set",
                    params={
                        "path": path,
                        "options": options,
                        "expected_revision": imported["revision"],
                    },
                )
                assert configured["import_succeeded"], configured
            sidecars = {path: path.read_bytes() for path in (project / "music").glob("*.import")}
            assert len(sidecars) == len(originals) == len(CLIPS)
            for case, (source, _) in CASES.items():
                score = f"res://{case}.tres"
                created = await audio(
                    tool,
                    "interactive_create",
                    path=score,
                    clips=CLIPS,
                    initial_clip=source,
                    transitions=RULES,
                )
                assert created["path"] == score and created["type"] == "AudioStreamInteractive"
                file = project / score.removeprefix("res://")
                score_bytes[file] = file.read_bytes()

        (proof / "capture.request").touch()
        async with _editor(client, godot, project, tmp_path / "preview.log") as (tool, fresh):
            pid = fresh["editor_pid"]
            assert pid != first["editor_pid"] and fresh["session_id"] != first["session_id"]
            print(
                f"Godot {fresh['godot_version']} {first['session_id']} -> "
                f"{fresh['session_id']} (PID {pid})"
            )
            assert (await tool("scene_open", path=SCENE))["switched"]
            player_ids = set()
            for case, (source, target) in CASES.items():
                score = f"res://{case}.tres"
                saved = await audio(tool, "interactive_get", path=score)
                assert saved["initial_clip"] == source and saved["type"] == "AudioStreamInteractive"
                assert saved["clips"] == [
                    {**clip, "bpm": 120.0, "beats_per_bar": 4} for clip in CLIPS
                ]
                rules = {(rule["from"], rule["to"]): rule for rule in saved["transitions"]}
                assert len(rules) == len(RULES)
                for rule in RULES:
                    expected = dict(rule)
                    if rule["from"] == "*":
                        expected["from_any"] = True
                    if rule["to"] == "*":
                        expected["to_any"] = True
                    assert rules[rule["from"], rule["to"]] == expected

                assigned = await audio(
                    tool, "player_set_stream", player_path=PLAYER, stream_path=score
                )
                assert assigned["stream_path"] == score
                assert (await tool("scene_save"))["path"] == SCENE
                scene_file = project / SCENE.removeprefix("res://")
                scene_bytes = scene_file.read_bytes()
                await arm_take(proof, case, pid)
                assert (await audio(tool, "play", player_path=PLAYER))["playing"]
                started = await _receipt(proof / f"{case}-started.json")
                assert started["clip"] == source and started["score_path"] == score
                before = await _receipt(proof / f"{case}-switch-ready.json")
                assert before["pid"] == pid
                switched = await audio(tool, "interactive_switch", player_path=PLAYER, clip=target)
                assert (
                    switched["previous_clip"] == source and switched["requested_clip"] == target
                ), switched
                (proof / f"{case}-switched.request").touch()
                after = await _receipt(proof / f"{case}-switched.json")
                assert after["pid"] == pid
                take = await _receipt(proof / f"{case}-audio.json")
                assert take["pid"] == pid and take["rate"] == RATE and take["discarded_frames"] == 0
                assert [visit["clip"] for visit in take["visits"]] == [source, target]
                for visit in take["visits"]:
                    assert (
                        visit["score_path"] == score
                        and visit["player_id"] == started["player_id"] == take["player_id"]
                    )
                    assert visit["playback_id"] == started["playback_id"] == take["playback_id"]
                player_ids.add(take["player_id"])
                measured = _assert_public_onset(
                    proof / f"{case}-stereo.f32",
                    take,
                    case,
                    source,
                    target,
                    before["frames"],
                    after["frames"],
                )
                print(f"{case} {source} -> {target}: stereo onset seconds {measured}")
                assert not (await audio(tool, "stop", player_path=PLAYER))["playing"]
                assert scene_file.read_bytes() == scene_bytes
            assert len(player_ids) == 1
        for path, original in (originals | sidecars | score_bytes).items():
            assert path.read_bytes() == original, path
