"""Public MCP routing and local-read boundary for WAV loop analysis."""

from __future__ import annotations

import asyncio
import os
import struct
import subprocess
import threading
import wave

import pytest
import websockets

from godot_ai.handlers import _wav_loop_file, audio
from tests.conftest import perform_v4_handshake


def _prepare_project(project, rate):
    project.mkdir()
    (project / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    with wave.open(str(project / "tone.wav"), "wb") as output:
        output.setparams((1, 2, rate, 0, "NONE", "not compressed"))
        cycle = struct.pack("<4h", 0, 1000, 0, -1000)
        output.writeframes(cycle * (rate // 2))
    (project / "tone.wav.import").write_text("fixture import settings\n", encoding="utf-8")


@pytest.fixture
async def loop_stack(mcp_stack, mcp_ws_port, tmp_path):
    client, _ = mcp_stack
    active = tmp_path / "active"
    selected = tmp_path / "selected"
    _prepare_project(active, 4000)
    _prepare_project(selected, 8000)
    endpoint = f"ws://127.0.0.1:{mcp_ws_port}"
    async with websockets.connect(endpoint) as first, websockets.connect(endpoint) as second:
        await perform_v4_handshake(first, session_id="loop-active", project_path=str(active))
        await perform_v4_handshake(
            second, session_id="loop-selected", project_path=str(selected), readiness="playing"
        )
        await client.call_tool("session_activate", {"session_id": "loop-active"})
        yield client, active, selected


def _args(*, selected=True, source_path="res://tone.wav", **params):
    request = {"op": "wav_loop_find", "params": {"source_path": source_path, **params}}
    if selected:
        request["session_id"] = "loop-selected"
    return request


async def test_wav_loop_find_reads_pinned_project_while_editor_is_playing(loop_stack):
    client, active, selected = loop_stack
    original = {entry.name: entry.read_bytes() for entry in selected.iterdir()}

    result = await client.call_tool(
        "audio_manage", _args(start_seconds=0.25, end_seconds=1.5, max_candidates=1)
    )

    data = result.data
    assert data["source_path"] == "res://tone.wav"
    assert (data["sample_rate"], data["channels"], data["start_frame"], data["end_frame"]) == (
        8000,
        1,
        2000,
        12000,
    )
    (candidate,) = data["candidates"]
    assert 2000 <= candidate["start_frame"] < candidate["end_frame"] <= 12000
    assert candidate["end_frame"] - candidate["start_frame"] == candidate["frame_count"]
    assert candidate["frame_count"] >= 4000
    assert {entry.name: entry.read_bytes() for entry in selected.iterdir()} == original
    with wave.open(str(active / "tone.wav"), "rb") as source:
        assert source.getframerate() == 4000


async def test_wav_loop_find_keeps_active_session_snapshot_during_worker(loop_stack, monkeypatch):
    client, _, _ = loop_stack
    current_loop = asyncio.get_running_loop()
    main_thread = threading.get_ident()
    started = asyncio.Event()
    release = threading.Event()
    real_analysis = audio.analyze_project_wav

    def hold_analysis(*args, **kwargs):
        current_loop.call_soon_threadsafe(started.set)
        assert threading.get_ident() != main_thread
        assert release.wait(timeout=10), "analysis worker did not resume"
        return real_analysis(*args, **kwargs)

    monkeypatch.setattr(audio, "analyze_project_wav", hold_analysis)
    request = asyncio.create_task(client.call_tool("audio_manage", _args(selected=False)))
    try:
        await asyncio.wait_for(started.wait(), timeout=10)
        await client.call_tool("session_activate", {"session_id": "loop-selected"})
    finally:
        release.set()
    assert (await request).data["sample_rate"] == 4000


async def test_wav_loop_find_does_not_fall_back_when_pinned_editor_is_missing(loop_stack):
    client, _, _ = loop_stack
    args = {**_args(), "session_id": "unknown-editor"}

    result = await client.call_tool("audio_manage", args, raise_on_error=False)

    assert result.is_error
    error = result.structured_content["error"]
    assert error["code"] == "PLUGIN_DISCONNECTED"
    assert error["data"]["reason"] == "session_not_found"


async def test_wav_loop_find_refuses_results_after_source_path_is_replaced(loop_stack, monkeypatch):
    client, _, selected = loop_stack
    replacement = selected / "replacement.wav"
    replacement.write_bytes((selected / "tone.wav").read_bytes())
    resolve_source = _wav_loop_file._project_wav
    find_loops = _wav_loop_file.find_pcm_wav_loops
    replaced = False

    def replace_after_read(*args, **kwargs):
        nonlocal replaced
        result = find_loops(*args, **kwargs)
        replaced = True
        return result

    def resolve_current(root, requested, source_path):
        # Simulate a DAW atomically replacing the pathname. Windows may
        # prevent the actual rename while the source read handle is open.
        return resolve_source(root, replacement if replaced else requested, source_path)

    monkeypatch.setattr(_wav_loop_file, "find_pcm_wav_loops", replace_after_read)
    monkeypatch.setattr(_wav_loop_file, "_project_wav", resolve_current)
    result = await client.call_tool("audio_manage", _args(), raise_on_error=False)

    assert replaced and result.is_error
    error = result.structured_content["error"]
    assert error["code"] == "INVALID_PARAMS"
    assert error["data"]["reason"] == "source_changed"


async def test_wav_loop_find_refuses_wav_outside_selected_project(loop_stack):
    client, active, selected = loop_stack
    link = selected / "linked"
    if os.name == "nt":
        subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(link), str(active)],
            check=True,
            capture_output=True,
        )
    else:
        link.symlink_to(active, target_is_directory=True)
    try:
        result = await client.call_tool(
            "audio_manage", _args(source_path="res://linked/tone.wav"), raise_on_error=False
        )
    finally:
        if os.name == "nt":
            link.rmdir()
        else:
            link.unlink()

    assert result.is_error
    error = result.structured_content["error"]
    assert error["code"] == "VALUE_OUT_OF_RANGE"
    assert error["data"]["reason"] == "outside_project"


@pytest.mark.parametrize(
    "source_path", ["res://../active/tone.wav", "res://tone.wav:alternate.wav", "uid://tone.wav"]
)
async def test_wav_loop_find_requires_local_res_paths(loop_stack, source_path):
    client, _, _ = loop_stack
    result = await client.call_tool(
        "audio_manage", _args(source_path=source_path), raise_on_error=False
    )

    assert result.is_error
    assert result.structured_content["error"]["code"] == "VALUE_OUT_OF_RANGE"
