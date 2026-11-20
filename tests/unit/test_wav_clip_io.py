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


def _observe_directory_fds(monkeypatch, directory):
    descriptors = set()
    if os.name != "nt":
        actual_open = _wav_clip._open_project_directory
        expected = directory.stat()

        def observe_open(*args, **kwargs):
            anchor = actual_open(*args, **kwargs)
            if os.path.samestat(anchor.info, expected):
                assert anchor.fd is not None
                descriptors.add(anchor.fd)
            return anchor

        monkeypatch.setattr(_wav_clip, "_open_project_directory", observe_open)
    return descriptors


def _assert_directory_fds_closed(descriptors):
    if os.name != "nt":
        assert descriptors, "No descriptor observed for the output directory"
    for fd in descriptors:
        with pytest.raises(OSError) as error:
            os.fstat(fd)
        assert error.value.errno == errno.EBADF


async def test_successful_wav_export_releases_the_destination_directory(clip_editor, monkeypatch):
    runtime, _, root, _ = clip_editor
    directory = root / "clips"
    directory.mkdir()
    descriptors = _observe_directory_fds(monkeypatch, directory)

    result = await _clip(runtime, "res://clips/output.wav")

    _assert_directory_fds_closed(descriptors)
    moved = directory.rename(root / "relocated-clips")
    assert {entry.name for entry in moved.iterdir()} == {"output.wav"}
    with wave.open(str(moved / "output.wav"), "rb") as clip:
        assert clip.getnframes() == result["frame_count"] == 80


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

    monkeypatch.setattr(_wav_clip.DirectoryAnchor, "publish", unsupported)
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
        discarded = asyncio.Event()
        release = threading.Event()
        stage = _wav_clip._stage_clip
        discard = _wav_clip._discard_worker_result
        caller_thread = threading.get_ident()

        def block_after_stage(*args):
            assert threading.get_ident() != caller_thread
            clip = stage(*args)
            loop.call_soon_threadsafe(staged.set)
            assert release.wait(timeout=10), "test did not release the staged WAV"
            return clip

        def observe_discard(future):
            discard(future)
            discarded.set()

        monkeypatch.setattr(_wav_clip, "_stage_clip", block_after_stage)
        monkeypatch.setattr(_wav_clip, "_discard_worker_result", observe_discard)
        return staged, release, discarded

    return hold


async def test_cancelled_wav_request_does_not_publish(clip_editor, hold_staged_clip):
    runtime, _, root, _ = clip_editor
    staged, release, discarded = await hold_staged_clip()
    request = asyncio.create_task(_clip(runtime))
    try:
        await asyncio.wait_for(staged.wait(), timeout=5)
        assert list(root.glob(_STAGE_GLOB))
        request.cancel()
        with pytest.raises(asyncio.CancelledError):
            await request
    finally:
        release.set()
    await asyncio.wait_for(discarded.wait(), timeout=5)
    assert not (root / "output.wav").exists()
    assert not list(root.glob(_STAGE_GLOB))


@pytest.mark.skipif(os.name != "nt", reason="Windows directory sharing semantics")
async def test_windows_holds_directory_after_staged_file_is_closed(clip_editor, hold_staged_clip):
    runtime, _, root, _ = clip_editor
    directory = root / "clips"
    directory.mkdir()
    moved = root / "moved-clips"
    staged, release, _ = await hold_staged_clip()
    request = asyncio.create_task(_clip(runtime, "res://clips/output.wav"))
    try:
        # The worker has closed both WAV streams. The directory handle alone
        # prevents a move while the caller is waiting to publish.
        await asyncio.wait_for(staged.wait(), timeout=5)
        assert len(list(directory.glob(_STAGE_GLOB))) == 1
        with pytest.raises(PermissionError):
            directory.rename(moved)
    finally:
        release.set()

    result = await request
    assert result["frame_count"] == 80
    directory.rename(moved)
    assert {entry.name for entry in moved.iterdir()} == {"output.wav"}


@pytest.mark.parametrize("outcome", ["finish", "cancel", "write_error"])
async def test_wav_export_keeps_its_stage_in_the_original_directory(
    clip_editor,
    monkeypatch,
    outcome,
):
    runtime, _, root, _ = clip_editor
    destination = root / "clips"
    moved = root / "retained-clips"
    destination.mkdir()
    (destination / "original.txt").write_text("keep original", encoding="utf-8")
    original_source = (root / "source.wav").read_bytes()

    # Windows sharing denies a move while its directory anchor is held. On
    # POSIX moving an open directory succeeds, so check actual fd release.
    descriptors = _observe_directory_fds(monkeypatch, destination)

    loop = asyncio.get_running_loop()
    editing = asyncio.Event()
    discarded = asyncio.Event()
    continue_edit = threading.Event()
    actual_edit = _wav_clip.edit_pcm_wav
    actual_discard = _wav_clip._discard_worker_result

    def hold_edit(source, output, **options):
        loop.call_soon_threadsafe(editing.set)
        assert continue_edit.wait(timeout=10), "test did not release WAV edit"
        if outcome == "write_error":
            output.write(b"partial clip")
            raise OSError(errno.ENOSPC, "out of space")
        return actual_edit(source, output, **options)

    def observe_discard(future):
        actual_discard(future)
        discarded.set()

    monkeypatch.setattr(_wav_clip, "edit_pcm_wav", hold_edit)
    monkeypatch.setattr(_wav_clip, "_discard_worker_result", observe_discard)
    request = asyncio.create_task(_clip(runtime, "res://clips/output.wav"))
    try:
        await asyncio.wait_for(editing.wait(), timeout=10)
        (stage,) = destination.glob(_STAGE_GLOB)
        if os.name == "nt":
            with pytest.raises(PermissionError):
                destination.rename(moved)
            assert not moved.exists()
        else:
            assert descriptors, "No live descriptor observed for the output directory"
            destination.rename(moved)
            assert (moved / stage.name).is_file()
            destination.mkdir()
            (destination / "replacement.txt").write_text("keep replacement", encoding="utf-8")
        if outcome == "cancel":
            request.cancel()
            with pytest.raises(asyncio.CancelledError):
                await request
    finally:
        continue_edit.set()

    published = outcome == "finish" and os.name == "nt"
    if outcome == "cancel":
        await asyncio.wait_for(discarded.wait(), timeout=10)
    elif published:
        result = await request
        assert result["path"] == "res://clips/output.wav"
        assert result["frame_count"] == 80
    else:
        with pytest.raises(GodotCommandError) as error:
            await request
        if outcome == "write_error":
            assert error.value.data["reason"] == "wav_io_failed"
        else:
            assert error.value.code == "INVALID_PARAMS"
            assert error.value.data["reason"] == "publication_path_changed"

    # A completed, cancelled or failed operation must let the directory move
    # again. On POSIX the replacement must remain completely untouched.
    if os.name == "nt":
        destination.rename(moved)
    else:
        assert {entry.name for entry in destination.iterdir()} == {"replacement.txt"}
        assert (destination / "replacement.txt").read_text(encoding="utf-8") == "keep replacement"
        moved = moved.rename(root / "released-clips")
    _assert_directory_fds_closed(descriptors)
    expected = {"original.txt", "output.wav"} if published else {"original.txt"}
    assert {entry.name for entry in moved.iterdir()} == expected
    assert (moved / "original.txt").read_text(encoding="utf-8") == "keep original"
    assert (root / "source.wav").read_bytes() == original_source


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
