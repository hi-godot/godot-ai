"""Author and play a native Bézier rotation track in two real Godot processes."""

from __future__ import annotations

import math
import shutil
from pathlib import Path

import pytest

from tests.integration._native_mcp_editor import _backend, _editor, _isolate_editor, _receipt
from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor

SCENE = "res://doors.tscn"
PLAYER = {"player_path": "/Main/Player", "animation_name": "doors/open"}
TRACK_PATH = "Door:rotation:y"
PROOF = ".bezier-test"


def _write_project(project: Path, http_port: int, ws_port: int) -> None:
    shutil.copytree(PLUGIN_ROOT, project / "addons/godot_ai")
    bootstrap = project / "addons/bezier_probe"
    bootstrap.mkdir()
    shutil.copyfile(Path(__file__).with_name("_bezier_editor_driver.gd"), bootstrap / "driver.gd")
    (bootstrap / "plugin.cfg").write_text(
        '[plugin]\nname="Bézier editor probe"\nscript="driver.gd"\n', encoding="utf-8"
    )
    (project / PROOF).mkdir()
    (project / "project.godot").write_text(
        'config_version=5\n[application]\nconfig/name="Bézier animation regression"\n'
        '[editor_plugins]\nenabled=PackedStringArray("res://addons/bezier_probe/plugin.cfg")\n'
        f"[bezier_test]\nhttp_port={http_port}\nws_port={ws_port}\n",
        encoding="utf-8",
    )
    (project / "doors.tscn").write_text(
        """[gd_scene format=3]

[sub_resource type="Animation" id="open"]
resource_name = "open"
tracks/0/type = "value"
tracks/0/path = NodePath("Door:position:y")
tracks/0/interp = 1
tracks/0/keys = {
"times": PackedFloat32Array(0, 1),
"transitions": PackedFloat32Array(1, 1),
"update": 0,
"values": [4.0, 8.0]
}

[sub_resource type="AnimationLibrary" id="doors"]
_data = {&"open": SubResource("open")}

[node name="Main" type="Node3D"]

[node name="Rig" type="Node3D" parent="."]

[node name="Door" type="Node3D" parent="Rig"]

[node name="Player" type="AnimationPlayer" parent="."]
root_node = NodePath("../Rig")
callback_mode_process = 2
libraries = {&"doors": SubResource("doors")}
""",
        encoding="utf-8",
    )


async def _action(project: Path, session: dict, action: str) -> dict:
    proof = project / PROOF
    request = proof / "action.tmp"
    request.write_text(action, encoding="utf-8")
    request.replace(proof / "action.request")
    receipt = proof / "receipt.json"
    result = await _receipt(receipt)
    receipt.unlink()
    assert result["pid"] == session["editor_pid"] and result["scene"] == SCENE, result
    return result


async def _animation(tool, op: str, **params) -> dict:
    return await tool("animation_manage", op=op, params={**PLAYER, **params})


def _assert_tracks(animation: dict, neighbor: dict, keyframes: list[dict]) -> None:
    assert animation["name"] == "doors/open" and animation["track_count"] == 2, animation
    adjacent, curve = animation["tracks"]
    assert adjacent == neighbor
    assert curve["type"] == "bezier" and curve["path"] == TRACK_PATH and curve["key_count"] == 2
    for stored, supplied in zip(curve["keys"], keyframes, strict=True):
        assert stored["time"] == supplied["time"]
        assert stored["scalar_value"] == pytest.approx(supplied["value"])
        assert stored["in_handle"] == pytest.approx(supplied["in_handle"])
        assert stored["out_handle"] == pytest.approx(supplied["out_handle"])
        assert stored["value"] == pytest.approx(
            [supplied["value"], *supplied["in_handle"], *supplied["out_handle"]]
        )
        assert stored["transition"] == 1.0


async def _measure(tool, project: Path, session: dict) -> dict:
    assert (await _animation(tool, "play"))["animation_name"] == PLAYER["animation_name"]
    samples = await _action(project, session, "sample")
    await tool("animation_manage", op="stop", params={"player_path": PLAYER["player_path"]})
    assert samples["manual"] and samples["playing"], samples
    assert samples["animation"] == PLAYER["animation_name"], samples
    # The engine numerically inverts the time component of the cubic. Allow
    # its small search error while distinguishing these values from linear easing.
    assert samples["rotation_degrees"] == pytest.approx([14.0625, 75.9375], abs=0.001)
    assert samples["height"] == pytest.approx([5.0, 7.0], abs=0.001)
    print(f"{session['session_id']} PID {session['editor_pid']} measured {samples}")
    return samples


async def test_native_bezier_track_plays_after_undo_redo_save_and_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    godot = godot_bin_or_skip()
    _isolate_editor(monkeypatch, tmp_path / "profile", godot)
    project = tmp_path / "project"
    scene = project / "doors.tscn"
    keyframes = [
        {"time": 0.0, "value": 0.0, "in_handle": [0.0, 0.0], "out_handle": [1 / 3, 0.0]},
        {"time": 1.0, "value": math.pi / 2, "in_handle": [-1 / 3, 0.0], "out_handle": [0.0, 0.0]},
    ]

    async with _backend() as (client, http_port, ws_port):
        _write_project(project, http_port, ws_port)
        original = scene.read_bytes()
        async with _editor(client, godot, project, tmp_path / "author.log") as (tool, author):
            assert (await tool("scene_open", path=SCENE))["path"] == SCENE
            (neighbor,) = (await _animation(tool, "get"))["tracks"]
            assert neighbor["path"] == "Door:position:y"
            assert [key["value"] for key in neighbor["keys"]] == [4.0, 8.0]

            result = await _animation(
                tool, "add_bezier_track", track_path=TRACK_PATH, keyframes=keyframes
            )
            assert result["undoable"] is True and result["keyframe_count"] == 2, result
            authored = await _animation(tool, "get")
            _assert_tracks(authored, neighbor, keyframes)

            assert (await _action(project, author, "undo"))["changed"] is True
            assert (await _animation(tool, "get"))["tracks"] == [neighbor]
            assert (await _action(project, author, "redo"))["changed"] is True
            assert await _animation(tool, "get") == authored
            before = await _measure(tool, project, author)
            assert scene.read_bytes() == original
            assert (await tool("scene_save"))["path"] == SCENE
            saved = scene.read_bytes()
            assert b'tracks/1/type = "bezier"' in saved

        async with _editor(client, godot, project, tmp_path / "reopen.log") as (tool, reopened):
            assert reopened["session_id"] != author["session_id"]
            assert reopened["editor_pid"] != author["editor_pid"]
            assert (await tool("scene_open", path=SCENE))["path"] == SCENE
            _assert_tracks(await _animation(tool, "get"), neighbor, keyframes)
            after = await _measure(tool, project, reopened)
            assert after["rotation_degrees"] == pytest.approx(before["rotation_degrees"], abs=0.001)
            assert scene.read_bytes() == saved
