"""Exercise WAV loop analysis, import and playback in fresh Godot processes."""

from __future__ import annotations

import asyncio
import base64
import json
import math
import shutil
import socket
import struct
import subprocess
import sys
import wave
from contextlib import asynccontextmanager, suppress
from pathlib import Path

import httpx2
import psutil
import pytest
import uvicorn
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

from godot_ai.asgi import hardened_uvicorn_config
from godot_ai.server import create_server
from godot_ai.transport.capability import generate_capabilities
from tests.conftest import isolate_capability_directory
from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor

SOURCE = "res://loop.wav"
RATE = 8000
FIXTURE_PERIOD = 600


def _loopback_client(**kwargs):
    return httpx2.AsyncClient(trust_env=False, **kwargs)


@asynccontextmanager
async def _backend():
    capabilities = generate_capabilities()
    with socket.socket() as http, socket.socket() as ws:
        http.bind(("127.0.0.1", 0))
        ws.bind(("127.0.0.1", 0))
        http_port, ws_port = http.getsockname()[1], ws.getsockname()[1]
        app = create_server(
            capabilities=capabilities, http_port=http_port, ws_port=ws_port, ws_socket=ws
        )
        server = uvicorn.Server(
            uvicorn.Config(
                app.http_app(json_response=True),
                log_level="warning",
                **hardened_uvicorn_config(access_log=False),
            )
        )
        task = asyncio.create_task(server.serve(sockets=[http]))
        try:
            async with asyncio.timeout(15):
                while not server.started:
                    assert not task.done(), "MCP backend exited during startup"
                    await asyncio.sleep(0.05)
            transport = StreamableHttpTransport(
                f"http://127.0.0.1:{http_port}/mcp",
                headers={"Authorization": f"Bearer {capabilities.http}"},
                httpx_client_factory=_loopback_client,
            )
            async with Client(transport, timeout=330) as client:
                yield client, http_port, ws_port
        finally:
            server.should_exit = True
            await asyncio.wait_for(task, 15)


def _isolate_editor(monkeypatch, root: Path, godot: str) -> None:
    binary_dir = Path(godot).resolve().parent
    possible_portable_dirs = [binary_dir]
    if sys.platform == "darwin" and binary_dir.name == "MacOS":
        possible_portable_dirs.append(binary_dir.parents[2])
    if any(
        (directory / marker).exists()
        for directory in possible_portable_dirs
        for marker in ("_sc_", "._sc_")
    ):
        pytest.skip("Portable Godot overrides editor profile isolation")
    for key in (
        "APPDATA",
        "HOME",
        "USERPROFILE",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_CACHE_HOME",
    ):
        directory = root / key.lower()
        directory.mkdir(parents=True)
        monkeypatch.setenv(key, str(directory))
    isolate_capability_directory(monkeypatch, root / "local")
    monkeypatch.setenv("GODOT_AI_ALLOW_HEADLESS", "1")
    monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")
    monkeypatch.setenv("GODOT_AI_MODE", "dev")


def _stop_owned_processes(owned) -> None:
    for process in owned:
        if process.is_running():
            try:
                process.terminate()
            except psutil.NoSuchProcess:
                continue
    _, survivors = psutil.wait_procs(owned, timeout=5)
    for process in survivors:
        try:
            process.kill()
        except psutil.NoSuchProcess:
            continue
    _, survivors = psutil.wait_procs(survivors, timeout=5)
    assert not survivors, survivors


@asynccontextmanager
async def _editor(client, godot: str, project: Path, log: Path):
    with log.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(
            [godot, "--headless", "--editor", "--path", str(project)],
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        launcher = psutil.Process(process.pid)
        owned = {launcher}
        try:
            try:
                async with asyncio.timeout(60):
                    while True:
                        assert process.poll() is None, "Godot exited before connecting"
                        with suppress(psutil.NoSuchProcess):
                            owned.update(launcher.children(recursive=True))
                        sessions = (await client.call_tool("session_manage", {"op": "list"})).data
                        if sessions["sessions"]:
                            (session,) = sessions["sessions"]
                            assert Path(session["project_path"]).resolve() == project.resolve(), (
                                session
                            )
                            identity = psutil.Process(session["editor_pid"])
                            assert identity in owned or launcher in identity.parents(), session
                            owned.add(identity)
                            if session["readiness"] in {"ready", "no_scene"}:
                                break
                        await asyncio.sleep(0.2)
            except (AssertionError, TimeoutError) as exc:
                raise AssertionError(log.read_text(encoding="utf-8", errors="replace")) from exc

            async def tool(name, /, **arguments):
                assert process.poll() is None and identity.is_running(), log
                result = await client.call_tool(
                    name, {**arguments, "session_id": session["session_id"]}
                )
                return result.data

            yield tool, session
            assert (await tool("editor_manage", op="quit"))["status"] == "quitting"
            assert await asyncio.to_thread(process.wait, 15) == 0
        finally:
            with suppress(psutil.NoSuchProcess):
                owned.update(launcher.children(recursive=True))
            await asyncio.to_thread(_stop_owned_processes, owned)
            await asyncio.to_thread(process.wait, 5)


def _write_project(project: Path, http_port: int, ws_port: int) -> None:
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    bootstrap = project / "addons/loop_probe"
    bootstrap.mkdir()
    (bootstrap / "plugin.cfg").write_text(
        '[plugin]\nname="WAV loop test"\nscript="capture.gd"\n', encoding="utf-8"
    )
    shutil.copyfile(Path(__file__).with_name("_wav_loop_capture.gd"), bootstrap / "capture.gd")
    (project / ".loop-test").mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="WAV loop regression"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/loop_probe/plugin.cfg")\n'
        f"[loop_test]\nhttp_port={http_port}\nws_port={ws_port}\n"
        f"[audio]\ndriver/mix_rate={RATE}\n",
        encoding="utf-8",
    )


async def test_wav_loop_analysis_reimports_and_plays_both_channels(tmp_path, monkeypatch):
    godot = godot_bin_or_skip()
    _isolate_editor(monkeypatch, tmp_path / "editor-profile", godot)
    project = tmp_path / "project"
    # Slight drift distinguishes adjacent periods while keeping useful seams.
    samples = [
        (
            8000 + round(7000 * math.sin(math.tau * frame / FIXTURE_PERIOD)) + frame,
            -8000 + round(4500 * math.cos(2 * math.tau * frame / FIXTURE_PERIOD)) - frame,
        )
        for frame in range(2201)
    ]
    async with _backend() as (client, http_port, ws_port):
        _write_project(project, http_port, ws_port)
        wav = project / "loop.wav"
        with wave.open(str(wav), "wb") as stream:
            stream.setparams((2, 2, RATE, 0, "NONE", "not compressed"))
            stream.writeframes(b"".join(struct.pack("<hh", *frame) for frame in samples))
        original = wav.read_bytes()
        sidecar = project / "loop.wav.import"
        async with _editor(client, godot, project, tmp_path / "analysis.log") as (tool, initial):
            assert (await tool("filesystem_manage", op="scan", params={}))["scan_completed"]
            import_before = sidecar.read_bytes()
            (imported_wav,) = (project / ".godot/imported").glob("loop.wav-*.sample")
            imported_before = imported_wav.read_bytes()
            wide = await tool(
                "audio_manage",
                op="wav_loop_find",
                params={
                    "source_path": SOURCE,
                    "min_loop_seconds": 0.05,
                    "max_candidates": 3,
                },
            )
            assert wide["source_path"] == SOURCE and wide["sample_rate"] == RATE, wide
            assert wide["channels"] == 2 and len(wide["candidates"]) == 3, wide
            bounds = [(item["start_frame"], item["end_frame"]) for item in wide["candidates"]]
            assert len(set(bounds)) == 3, wide
            start, end = bounds[0]
            assert 0 < start < end < len(samples), wide
            period = end - start
            assert wide["candidates"][0]["frame_count"] == period
            assert wav.read_bytes() == original and sidecar.read_bytes() == import_before
            assert imported_wav.read_bytes() == imported_before
            description = await tool("filesystem_manage", op="import_get", params={"path": SOURCE})
            assert description["importer"] == "wav" and description["import_valid"] is True, (
                description
            )

            # This interior fixture wraps to begin+1 after emitting end in
            # Godot's native PCM mixer. A mix block boundary can behave differently.
            options = {
                "edit/loop_mode": 2,
                "edit/loop_begin": start - 1,
                "edit/loop_end": end - 1,
                "compress/mode": 0,
                "edit/trim": False,
                "edit/normalize": False,
                "force/max_rate": False,
                "force/mono": False,
                "force/8_bit": False,
            }
            edited = await tool(
                "filesystem_manage",
                op="import_set",
                params={
                    "path": SOURCE,
                    "options": options,
                    "expected_revision": description["revision"],
                },
            )
            assert edited["settings_committed"] and edited["import_succeeded"], edited
            assert edited["revision"] != description["revision"], edited

        # The native resampler has two startup history frames. The fixture
        # then expects two full rounds and the beginning of the next round.
        expected = (
            [(0, 0)] * 2 + samples[:end] + samples[start:end] * 2 + samples[start : start + 16]
        )
        marker = project / ".loop-test/capture.request"
        marker.write_text(str(len(expected)), encoding="utf-8")
        async with _editor(client, godot, project, tmp_path / "playback.log") as (tool, fresh):
            assert (
                fresh["editor_pid"] != initial["editor_pid"]
                and fresh["session_id"] != initial["session_id"]
            )
            reopened = await tool("filesystem_manage", op="import_get", params={"path": SOURCE})
            assert (
                reopened["revision"] == edited["revision"] and reopened["import_valid"] is True
            ), reopened
            assert all(reopened["options"][key] == value for key, value in options.items()), (
                reopened
            )
            capture = project / ".loop-test/capture.json"
            async with asyncio.timeout(10):
                while not capture.is_file():
                    await asyncio.sleep(0.05)
            receipt = json.loads(capture.read_text(encoding="utf-8"))
            assert receipt["pid"] == fresh["editor_pid"]
            assert receipt["stereo"] and receipt["playing"] and receipt["format"] == 1
            assert receipt["sample_rate"] == receipt["mixer_rate"] == RATE
            assert (receipt["loop_mode"], receipt["loop_begin"], receipt["loop_end"]) == (
                1,
                start - 1,
                end - 1,
            )
            observed = list(
                struct.iter_unpack("<hh", base64.b64decode(receipt["pcm"], validate=True))
            )
            assert observed == expected
            print(
                f"Godot {fresh['godot_version']} "
                f"{initial['session_id']} (PID {initial['editor_pid']}) -> "
                f"{fresh['session_id']} (PID {fresh['editor_pid']})"
            )
            print(
                f"Candidate bounds {bounds}, imported {start - 1}/{end - 1}, {len(observed)} frames"
            )
            for offset in (2 + end, 2 + end + period, 2 + end + 2 * period):
                print(
                    f"Wrap at captured frame {offset}, {end - 1} -> {start}: "
                    f"{observed[offset - 1]} -> {observed[offset]}"
                )
    assert wav.read_bytes() == original
