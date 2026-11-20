"""Exercise native scene inheritance over MCP in two fresh Godot editors."""

from __future__ import annotations

import asyncio
import shutil
import socket
import subprocess
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from unittest.mock import Mock

import httpx2
import psutil
import pytest
import uvicorn
from fastmcp import Client
from fastmcp.client.transports import StreamableHttpTransport

from godot_ai.asgi import hardened_uvicorn_config
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.server import create_server
from godot_ai.transport.capability import generate_capabilities
from tests.conftest import isolate_capability_directory
from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor

BASE = "res://doors/DoorBase.tscn"
DERIVED = "res://doors/LockedDoor.tscn"
BUSY = "res://doors/BusyBaseDoor.tscn"
RACED = "res://doors/RacedDoor.tscn"
LATE = "res://doors/CommittedDoor.tscn"
ROOT_NODE = "/DoorBase"
BASE_TEXT = """[gd_scene format=3]

[sub_resource type="RectangleShape2D" id="RectangleShape2D_base"]
size = Vector2(20, 30)

[node name="DoorBase" type="Node2D"]

[node name="Override" type="Label" parent="."]
text = "base override target"

[node name="Inherits" type="Label" parent="."]
text = "original inherited text"

[node name="Body" type="StaticBody2D" parent="."]

[node name="Shape" type="CollisionShape2D" parent="Body"]
shape = SubResource("RectangleShape2D_base")

[node name="Visual" type="TextureRect" parent="."]
offset_right = 90.0
offset_bottom = 100.0
"""
COMPETING_SCENE = f'''[gd_scene format=3]

[ext_resource type="PackedScene" path="{BASE}" id="1"]

[node name="DoorBase" instance=ExtResource("1")]
process_priority = 29
'''.encode()


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
            capabilities=capabilities,
            http_port=http_port,
            ws_port=ws_port,
            ws_socket=ws,
        )
        server = uvicorn.Server(
            uvicorn.Config(
                app.http_app(json_response=True),
                host="127.0.0.1",
                port=http_port,
                log_level="warning",
                **hardened_uvicorn_config(access_log=False),
            )
        )
        task = asyncio.create_task(server.serve(sockets=[http]))
        try:
            async with asyncio.timeout(15):
                while not server.started:
                    assert not task.done(), "MCP backend exited before startup"
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


def _write_project(project: Path, http_port: int, ws_port: int) -> None:
    shutil.copytree(PLUGIN_ROOT, project / "addons" / "godot_ai")
    # Set the ports in the editor before enabling the actual plugin. A local
    # bootstrap avoids relying on the platform/version-specific settings filename.
    bootstrap = project / "addons" / "inheritance_test"
    bootstrap.mkdir()
    (bootstrap / "plugin.cfg").write_text(
        '[plugin]\nname="Inheritance test"\nscript="ports.gd"\n',
        encoding="utf-8",
    )
    shutil.copyfile(
        Path(__file__).with_name("_scene_inheritance_driver.gd"), bootstrap / "ports.gd"
    )
    (project / ".inheritance-test").mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Scene inheritance acceptance"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/inheritance_test/plugin.cfg")\n'
        f"[inheritance_test]\nhttp_port={http_port}\nws_port={ws_port}\n",
        encoding="utf-8",
    )
    base = project / BASE.removeprefix("res://")
    base.parent.mkdir()
    base.write_text(BASE_TEXT, encoding="utf-8")


def _remember_children(launcher: psutil.Process, owned: set[psutil.Process]) -> None:
    try:
        owned.update(launcher.children(recursive=True))
    except psutil.NoSuchProcess:
        # Children observed earlier can outlive the launcher and stay owned.
        pass


def _stop_editor_processes(owned: set[psutil.Process]) -> None:
    live = [process for process in owned if process.is_running()]
    for process in live:
        try:
            process.terminate()
        except psutil.NoSuchProcess:
            pass
    _, survivors = psutil.wait_procs(live, timeout=5)
    for process in survivors:
        try:
            process.kill()
        except psutil.NoSuchProcess:
            pass
    _, survivors = psutil.wait_procs(survivors, timeout=5)
    assert not survivors, f"Owned editor processes survived cleanup: {survivors}"


@pytest.mark.parametrize("launcher_survives", [True, False])
def test_editor_cleanup_kills_and_waits_for_editor_and_launcher(monkeypatch, launcher_survives):
    launcher = Mock(spec=psutil.Process)
    editor = Mock(spec=psutil.Process)
    launcher.children.side_effect = [
        [editor],
        [editor] if launcher_survives else psutil.NoSuchProcess(181),
    ]
    launcher.is_running.return_value = launcher_survives
    editor.is_running.return_value = True
    owned = {launcher}
    _remember_children(launcher, owned)
    _remember_children(launcher, owned)

    survivors = [launcher, editor] if launcher_survives else [editor]
    wait = Mock(side_effect=[([], survivors), (survivors, [])])
    monkeypatch.setattr(psutil, "wait_procs", wait)
    _stop_editor_processes(owned)

    for process in survivors:
        process.terminate.assert_called_once_with()
        process.kill.assert_called_once_with()
    if not launcher_survives:
        launcher.terminate.assert_not_called()
        launcher.kill.assert_not_called()
    assert set(wait.call_args_list[0].args[0]) == set(survivors)
    assert set(wait.call_args_list[1].args[0]) == set(survivors)


@asynccontextmanager
async def _editor(client: Client, project: Path, godot: str, log: Path):
    output_path = log.with_suffix(".output")
    with output_path.open("w", encoding="utf-8") as output:
        process = subprocess.Popen(
            [godot, "--headless", "--editor", "--path", str(project), "--log-file", str(log)],
            stdout=output,
            stderr=subprocess.STDOUT,
        )
        launcher = None
        owned = set()
        try:
            launcher = psutil.Process(process.pid)
            owned.add(launcher)
            try:
                async with asyncio.timeout(60):
                    while True:
                        assert process.poll() is None, f"Editor exited during startup. See {log}"
                        _remember_children(launcher, owned)
                        sessions = (await client.call_tool("session_manage", {"op": "list"})).data
                        if sessions["sessions"]:
                            assert len(sessions["sessions"]) == 1, sessions
                            session = sessions["sessions"][0]
                            assert Path(session["project_path"]).resolve() == project, session
                            identity = psutil.Process(session["editor_pid"])
                            assert identity == launcher or launcher in identity.parents(), session
                            owned.add(identity)
                            if session["readiness"] != "importing":
                                break
                        await asyncio.sleep(0.25)
            except (TimeoutError, AssertionError) as exc:
                output.flush()
                source = log if log.exists() else output_path
                lines = source.read_text(encoding="utf-8", errors="replace").splitlines()
                tail = "\n".join(lines[-60:])
                raise AssertionError(f"Godot editor startup failed for {project}\n{tail}") from exc

            async def tool(name, /, *, error=None, **arguments):
                assert process.poll() is None and identity.is_running(), (
                    f"Editor exited during {name}. See {log}"
                )
                result = await client.call_tool(
                    name,
                    {**arguments, "session_id": session["session_id"]},
                    raise_on_error=False,
                )
                if error is not None:
                    assert result.is_error, result
                    assert result.structured_content["error"]["code"] == error, result
                    return result.structured_content["error"]
                assert not result.is_error, result
                return result.data

            created = identity.create_time()
            print(
                f"Godot {session['godot_version']}, editor {identity.pid}, "
                f"started {created}, session {session['session_id']}, {session['project_path']}"
            )
            try:
                yield tool, (identity.pid, created, session["session_id"])
            finally:
                _remember_children(launcher, owned)
                assert (await tool("editor_manage", op="quit"))["status"] == "quitting"
                assert await asyncio.to_thread(process.wait, 15) == 0, log
                _, live = await asyncio.to_thread(psutil.wait_procs, [identity], timeout=5)
                assert not live, f"Editor {identity.pid} survived requested quit"
        finally:
            if launcher is not None:
                _remember_children(launcher, owned)
                await asyncio.to_thread(_stop_editor_processes, owned)
            await asyncio.to_thread(process.wait, 5)


async def _open(tool, path):
    assert (await tool("scene_open", path=path))["switched"] is True
    state = await tool("editor_state")
    assert state["current_scene"] == path and state["readiness"] == "ready", state


async def _text(tool, label):
    node = await tool("node_get_properties", path=f"{ROOT_NODE}/{label}", fields=["text"])
    assert [prop["name"] for prop in node["properties"]] == ["text"], node
    return node["properties"][0]["value"]


async def _names(tool):
    return {node["name"] for node in (await tool("scene_get_hierarchy"))["nodes"]}


async def _shape_size(tool):
    graph = await tool(
        "resource_manage",
        op="inspect",
        params={
            "node_path": f"{ROOT_NODE}/Body/Shape",
            "property": "shape",
            "depth": 0,
        },
    )
    (shape,) = graph["resources"]
    assert shape["type"] == "RectangleShape2D", graph
    size = shape["properties"]["size"]
    return size["x"], size["y"]


@asynccontextmanager
async def _hold_threaded_load(project: Path, path: str):
    controls = project / ".inheritance-test"
    request = controls / "hold"
    receipt = controls / "held"
    staged = controls / "pending"
    staged.write_text(path, encoding="utf-8")
    staged.rename(request)
    try:
        async with asyncio.timeout(10):
            while not receipt.exists() or not receipt.stat().st_size:
                await asyncio.sleep(0.05)
        assert receipt.read_text(encoding="utf-8") == "loaded", receipt
        yield
    finally:
        request.unlink()
        async with asyncio.timeout(10):
            while receipt.exists():
                await asyncio.sleep(0.05)


async def _check_publish_race_and_open_refusal(tool, project: Path, monkeypatch):
    from godot_ai.handlers import scene_inheritance

    directory = project / "doors"
    raced = project / RACED.removeprefix("res://")
    late = project / LATE.removeprefix("res://")
    original_tabs = await tool("scene_manage", op="get_roots")

    async with _hold_threaded_load(project, BASE):
        refusal = await tool(
            "scene_manage",
            op="inherit",
            params={"base_path": BASE, "path": BUSY},
            error="EDITOR_NOT_READY",
        )
    assert "resource load is already pending" in refusal["message"], refusal
    assert not (project / BUSY.removeprefix("res://")).exists()
    assert await tool("scene_manage", op="get_roots") == original_tabs
    assert not list(directory.glob(".godot-ai-inherit-*"))

    actual_publish = scene_inheritance._publish_scene
    writer_reached = False

    def publish_after_competing_writer(stage: Path, destination: Path) -> None:
        nonlocal writer_reached
        if destination == raced:
            # The staged scene is complete. Let a different process create
            # the exact destination before proceeding to the real syscall.
            assert b"instance=ExtResource(" in stage.read_bytes() and not destination.exists()
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    "import sys; open(sys.argv[1], 'xb').write(sys.stdin.buffer.read())",
                    str(destination),
                ],
                input=COMPETING_SCENE,
                timeout=10,
                check=True,
            )
            writer_reached = True
        actual_publish(stage, destination)

    with monkeypatch.context() as patch:
        patch.setattr(scene_inheritance, "_publish_scene", publish_after_competing_writer)
        race_refusal = await tool(
            "scene_manage",
            op="inherit",
            params={"base_path": BASE, "path": RACED},
            error="INVALID_PARAMS",
        )

    assert writer_reached and raced.read_bytes() == COMPETING_SCENE
    assert race_refusal["data"]["disk_committed"] is False, race_refusal
    assert race_refusal["data"]["reason"] == "destination_exists", race_refusal
    assert await tool("scene_manage", op="get_roots") == original_tabs
    assert not list(directory.glob(".godot-ai-inherit-*"))

    actual_send = DirectRuntime.send_command
    committed_bytes = b""

    async def contend_before_open(runtime, command, params=None, *args, **kwargs):
        if command != "inherit_scene_open" or params["path"] != LATE:
            return await actual_send(runtime, command, params, *args, **kwargs)
        nonlocal committed_bytes
        committed_bytes = late.read_bytes()
        async with _hold_threaded_load(project, LATE):
            return await actual_send(runtime, command, params, *args, **kwargs)

    with monkeypatch.context() as patch:
        patch.setattr(DirectRuntime, "send_command", contend_before_open)
        refusal = await tool(
            "scene_manage",
            op="inherit",
            params={"base_path": BASE, "path": LATE},
            error="EDITOR_NOT_READY",
        )

    assert refusal["data"]["disk_committed"] is True, refusal
    assert refusal["data"]["tab_opened"] is False, refusal
    assert "resource load is already pending" in refusal["message"], refusal
    assert refusal["data"]["path"] == LATE and refusal["data"]["base_path"] == BASE, refusal
    assert b"instance=ExtResource(" in committed_bytes and late.read_bytes() == committed_bytes
    assert await tool("scene_manage", op="get_roots") == original_tabs
    assert not list(directory.glob(".godot-ai-inherit-*"))


async def test_native_inheritance_survives_fresh_editor(tmp_path, monkeypatch):
    godot = godot_bin_or_skip()
    # Portable editors ignore the temporary user directories below. Refuse
    # before boot so fixture EditorSettings cannot reach that installation.
    executable_dir = Path(godot).resolve().parent
    marker_dirs = [executable_dir]
    if (
        sys.platform == "darwin"
        and executable_dir.name == "MacOS"
        and executable_dir.parent.name == "Contents"
    ):
        marker_dirs.append(executable_dir.parents[2])
    for directory in marker_dirs:
        assert not any((directory / mark).is_file() for mark in ("._sc_", "_sc_")), (
            f"Use a non-portable GODOT_BIN to isolate editor settings ({directory})"
        )
    project = tmp_path.resolve() / "inheritance"
    isolate_capability_directory(monkeypatch, tmp_path / "local")
    for variable in ("APPDATA", "HOME", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME"):
        directory = tmp_path / variable.lower()
        directory.mkdir(mode=0o700)
        monkeypatch.setenv(variable, str(directory))
    if sys.platform == "win32":
        temporary = tmp_path / "temp"
        temporary.mkdir()
        monkeypatch.setenv("TEMP", str(temporary))
        monkeypatch.setenv("TMP", str(temporary))
    monkeypatch.setenv("GODOT_AI_ALLOW_HEADLESS", "1")
    monkeypatch.setenv("GODOT_AI_DISABLE_TELEMETRY", "true")
    monkeypatch.setenv("GODOT_AI_MODE", "dev")
    monkeypatch.setenv("__GODOT_SHELL_ENV_SET", "1")

    async with _backend() as (client, http_port, ws_port):
        _write_project(project, http_port, ws_port)
        base = project / BASE.removeprefix("res://")
        derived = project / DERIVED.removeprefix("res://")
        saved_base = base.read_bytes()
        async with _editor(client, project, godot, tmp_path / "initial.log") as (tool, first):
            await _open(tool, BASE)
            original_tabs = (await tool("scene_manage", op="get_roots"))["scenes"]
            assert BASE in original_tabs and DERIVED not in original_tabs, original_tabs
            assert await _shape_size(tool) == (20, 30)
            await tool(
                "node_set_property", path=f"{ROOT_NODE}/Override", property="text", value="dirty"
            )
            await tool("node_create", type="Node", name="UnsavedOnly", parent_path=ROOT_NODE)
            fit = await tool(
                "resource_manage",
                op="physics_shape_autofit",
                params={
                    "path": f"{ROOT_NODE}/Body/Shape",
                    "source_path": f"{ROOT_NODE}/Visual",
                    "shape_type": "rectangle",
                },
            )
            assert fit["shape_created"] is False, fit
            assert await _shape_size(tool) == (90, 100)
            await _check_publish_race_and_open_refusal(tool, project, monkeypatch)
            assert await _text(tool, "Override") == "dirty"
            assert await _shape_size(tool) == (90, 100)
            assert "UnsavedOnly" in await _names(tool)
            assert base.read_bytes() == saved_base

            inherited = await tool(
                "scene_manage",
                op="inherit",
                params={
                    "base_path": BASE,
                    "path": DERIVED,
                },
            )
            assert inherited["path"] == DERIVED and inherited["base_path"] == BASE, inherited
            assert inherited["undoable"] is False and inherited["reason"], inherited
            tabs = await tool("scene_manage", op="get_roots")
            assert sorted(tabs["scenes"]) == sorted([*original_tabs, DERIVED]), tabs
            assert tabs["current_scene"] == DERIVED, tabs
            assert await _text(tool, "Override") == "base override target"
            assert await _shape_size(tool) == (20, 30)
            assert "UnsavedOnly" not in await _names(tool)
            assert base.read_bytes() == saved_base

            await _open(tool, BASE)
            assert await _text(tool, "Override") == "dirty"
            assert await _shape_size(tool) == (90, 100)
            assert "UnsavedOnly" in await _names(tool)
            refusal = await tool(
                "scene_manage", op="close", params={"path": BASE}, error="INVALID_PARAMS"
            )
            assert "unsaved changes" in refusal["message"]
            assert base.read_bytes() == saved_base

            initial_derived = derived.read_bytes()
            assert b'type="PackedScene"' in initial_derived
            assert b'path="res://doors/DoorBase.tscn"' in initial_derived
            assert b"instance=ExtResource(" in initial_derived
            refusal = await tool(
                "scene_manage",
                op="inherit",
                params={"base_path": BASE, "path": DERIVED},
                error="INVALID_PARAMS",
            )
            assert "already exists" in refusal["message"], refusal
            assert derived.read_bytes() == initial_derived
            assert base.read_bytes() == saved_base
            assert (await tool("editor_state"))["current_scene"] == BASE

            await _open(tool, DERIVED)
            await tool(
                "node_set_property", path=f"{ROOT_NODE}/Override", property="text", value="derived"
            )
            await tool("node_create", type="Node", name="LocalChild", parent_path=ROOT_NODE)
            assert (await tool("scene_save"))["path"] == DERIVED
            closed = await tool("scene_manage", op="close", params={"path": DERIVED})
            assert closed["path"] == DERIVED
            await _open(tool, DERIVED)
            assert await _text(tool, "Override") == "derived"
            assert "LocalChild" in await _names(tool)

            # Drop only the deliberately dirty base edits, then save a
            # different property and child to test propagation from disk.
            await _open(tool, BASE)
            assert (await tool("scene_open", path=BASE, force_reload=True))["switched"] is True
            assert await _text(tool, "Override") == "base override target"
            assert await _shape_size(tool) == (20, 30)
            await tool(
                "node_set_property",
                path=f"{ROOT_NODE}/Inherits",
                property="text",
                value="new base text",
            )
            await tool("node_create", type="Node", name="NewBaseChild", parent_path=ROOT_NODE)
            assert (await tool("scene_save"))["path"] == BASE
            saved_derived = derived.read_bytes()

        async with _editor(client, project, godot, tmp_path / "fresh.log") as (tool, second):
            assert first[:2] != second[:2] and first[2] != second[2], (first, second)
            await _open(tool, DERIVED)
            assert await _text(tool, "Override") == "derived"
            assert await _text(tool, "Inherits") == "new base text"
            assert await _shape_size(tool) == (20, 30)
            assert await _names(tool) == {
                "DoorBase",
                "Override",
                "Inherits",
                "Body",
                "Shape",
                "Visual",
                "NewBaseChild",
                "LocalChild",
            }
            assert derived.read_bytes() == saved_derived
