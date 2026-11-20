"""Tests for WAV clipping ownership, staging and no-replace publication."""

from __future__ import annotations

import asyncio
import errno
import os
import struct
import subprocess
import threading
import wave
from dataclasses import replace
from datetime import timedelta
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers import _wav_clip
from godot_ai.handlers.audio import audio_wav_clip
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.sessions.registry import Session, SessionRegistry

SOURCE = "res://source.wav"
DESTINATION = "res://output.wav"
_STAGE_GLOB = ".godot-ai-wav-*.tmp"


@pytest.fixture
def clip_editor(tmp_path):
    root = tmp_path / "project"
    root.mkdir()
    (root / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    with wave.open(str(root / "source.wav"), "wb") as source:
        source.setparams((1, 2, 8000, 0, "NONE", "not compressed"))
        source.writeframes(struct.pack("<160h", *range(160)))

    registry = SessionRegistry()
    registry.register(
        Session(
            session_id="editor",
            godot_version="4.7.2",
            project_path=str(root),
            plugin_version="4.0.0",
        )
    )
    send = AsyncMock(return_value={"readiness": "playing"})
    runtime = DirectRuntime(registry, SimpleNamespace(send=send), session_id="editor")
    return runtime, registry, root, send


async def _clip(runtime, path=DESTINATION):
    return await audio_wav_clip(runtime, SOURCE, path, start_seconds=0.005, end_seconds=0.015)


async def test_wav_publication_refuses_a_competing_writer(clip_editor, monkeypatch):
    runtime, _, root, send = clip_editor
    original = (root / "source.wav").read_bytes()
    publish = _wav_clip._publish_clip

    def race(project, destination, clip):
        assert clip.path.parent == (project / destination).parent
        (project / destination).write_bytes(b"competing WAV")
        publish(project, destination, clip)

    monkeypatch.setattr(_wav_clip, "_publish_clip", race)
    with pytest.raises(GodotCommandError) as error:
        await _clip(runtime)

    assert error.value.code == "INVALID_PARAMS"
    assert error.value.data["reason"] == "destination_exists"
    assert (root / "output.wav").read_bytes() == b"competing WAV"
    assert (root / "source.wav").read_bytes() == original
    assert not list(root.glob(_STAGE_GLOB))
    send.assert_not_awaited()


async def test_wav_publication_has_no_non_atomic_fallback(clip_editor, monkeypatch):
    runtime, _, root, _ = clip_editor

    def unsupported(*args, **kwargs):
        raise OSError(errno.ENOTSUP, "atomic publication unsupported")

    primitive = "rename" if _wav_clip.os.name == "nt" else "link"
    monkeypatch.setattr(_wav_clip.os, primitive, unsupported)
    with pytest.raises(GodotCommandError) as error:
        await _clip(runtime)

    assert error.value.data["reason"] == "atomic_publish_unsupported"
    assert not (root / "output.wav").exists()
    assert not list(root.glob(_STAGE_GLOB))


async def test_failed_wav_worker_discards_its_partial_file(clip_editor, monkeypatch):
    runtime, _, root, _ = clip_editor

    def write_partial(source, output, **options):
        output.write(b"unfinished file")
        raise OSError(errno.ENOSPC, "out of space")

    monkeypatch.setattr(_wav_clip, "edit_pcm_wav", write_partial)
    with pytest.raises(GodotCommandError) as error:
        await _clip(runtime)

    assert error.value.data["reason"] == "wav_io_failed"
    assert not (root / "output.wav").exists()
    assert not list(root.glob(_STAGE_GLOB))


async def test_wav_cleanup_preserves_a_replaced_staging_entry(clip_editor, monkeypatch):
    runtime, _, root, _ = clip_editor
    publish = _wav_clip._publish_clip

    def replace_stage(project, destination, clip):
        clip.path.rename(root / "retained-owned-file.wav")
        clip.path.write_bytes(b"other writer's file")
        publish(project, destination, clip)

    monkeypatch.setattr(_wav_clip, "_publish_clip", replace_stage)
    with pytest.raises(GodotCommandError) as error:
        await _clip(runtime)

    assert error.value.data["reason"] == "publication_path_changed"
    assert not (root / "output.wav").exists()
    (replacement,) = root.glob(_STAGE_GLOB)
    assert replacement.read_bytes() == b"other writer's file"


@pytest.fixture
def hold_staged_clip(monkeypatch):
    async def hold():
        loop = asyncio.get_running_loop()
        staged = asyncio.Event()
        removed = asyncio.Event()
        release = threading.Event()
        stage = _wav_clip._stage_clip
        remove = _wav_clip._remove_stage
        caller_thread = threading.get_ident()

        def block_after_stage(*args):
            assert threading.get_ident() != caller_thread
            clip = stage(*args)
            loop.call_soon_threadsafe(staged.set)
            release.wait(timeout=5)
            return clip

        def observe_remove(*args):
            remove(*args)
            loop.call_soon_threadsafe(removed.set)

        monkeypatch.setattr(_wav_clip, "_stage_clip", block_after_stage)
        monkeypatch.setattr(_wav_clip, "_remove_stage", observe_remove)
        return staged, release, removed

    return hold


async def test_cancelled_wav_request_does_not_publish(clip_editor, hold_staged_clip):
    runtime, _, root, _ = clip_editor
    staged, release, removed = await hold_staged_clip()
    request = asyncio.create_task(_clip(runtime))
    try:
        await asyncio.wait_for(staged.wait(), timeout=5)
        assert list(root.glob(_STAGE_GLOB))
        request.cancel()
        with pytest.raises(asyncio.CancelledError):
            await request
    finally:
        release.set()
    await asyncio.wait_for(removed.wait(), timeout=5)
    assert not (root / "output.wav").exists()
    assert not list(root.glob(_STAGE_GLOB))


async def test_wav_does_not_publish_after_editor_reconnect(clip_editor, hold_staged_clip):
    runtime, registry, root, _ = clip_editor
    staged, release, _ = await hold_staged_clip()
    request = asyncio.create_task(_clip(runtime))
    try:
        await asyncio.wait_for(staged.wait(), timeout=5)
        original = registry.get("editor")
        registry.unregister("editor")
        registry.register(
            replace(original, connected_at=original.connected_at + timedelta(seconds=1))
        )
    finally:
        release.set()
    with pytest.raises(GodotCommandError) as error:
        await request

    assert error.value.code == "PLUGIN_DISCONNECTED"
    assert error.value.data["reason"] == "session_changed"
    assert not (root / "output.wav").exists()
    assert not list(root.glob(_STAGE_GLOB))


async def test_wav_rechecks_write_readiness_before_publication(clip_editor, hold_staged_clip):
    runtime, registry, root, send = clip_editor
    staged, release, _ = await hold_staged_clip()
    request = asyncio.create_task(_clip(runtime))
    try:
        await asyncio.wait_for(staged.wait(), timeout=5)
        registry.record_readiness("editor", "playing")
    finally:
        release.set()
    with pytest.raises(GodotCommandError) as error:
        await request

    assert error.value.code == "EDITOR_NOT_READY"
    assert error.value.data["sub_code"] == "EDITOR_PLAYING"
    send.assert_awaited_once()
    assert send.await_args.kwargs["command"] == "get_editor_state"
    assert send.await_args.kwargs["session_id"] == "editor"
    assert not (root / "output.wav").exists()
    assert not list(root.glob(_STAGE_GLOB))


async def test_wav_does_not_follow_linked_destination_directory(clip_editor, tmp_path):
    runtime, _, root, _ = clip_editor
    outside = tmp_path / "outside"
    outside.mkdir()
    linked = root / "linked"
    if os.name == "nt":
        subprocess.run(
            ["cmd", "/c", "mklink", "/J", str(linked), str(outside)],
            check=True,
            capture_output=True,
        )
    else:
        linked.symlink_to(outside, target_is_directory=True)

    try:
        with pytest.raises(GodotCommandError) as error:
            await _clip(runtime, "res://linked/output.wav")
    finally:
        if os.name == "nt":
            linked.rmdir()
        else:
            linked.unlink()

    assert error.value.data["reason"] == "linked_project_path"
    assert not list(outside.iterdir())
