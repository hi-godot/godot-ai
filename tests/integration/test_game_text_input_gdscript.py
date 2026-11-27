"""Headless Godot verification for GameHelper text input (`type_text` and `input_key` unicode)."""

from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest

GODOT_BOOT_TIMEOUT_S = 60  # headless Godot boot+script 等待上限；同類等待面見 tests/unit/test_ci_game_capture_smoke.py timeout=60.0

from tests.integration._self_update_fixture import PLUGIN_ROOT, godot_bin_or_skip

pytestmark = pytest.mark.editor

PROJECT_SETTINGS = """\
config_version=5

[application]
config/name="game-text-input-check"
"""

CHECK_SCRIPT = """\
extends SceneTree

const GameHelper := preload("res://addons/godot_ai/runtime/game_helper.gd")

var _failures: Array[String] = []
var _ran := false


func _check(cond: bool, msg: String) -> void:
	if not cond:
		_failures.append(msg)
		push_error("ASSERT FAILED: %s" % msg)


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	_run_checks()
	return true


func _run_checks() -> void:
	var scene := Control.new()
	scene.name = "Main"
	root.add_child(scene)
	current_scene = scene

	var helper := GameHelper.new()
	root.add_child(helper)

	var line := LineEdit.new()
	line.name = "ChatLine"
	scene.add_child(line)

	var submitted_texts: Array[String] = []
	line.text_submitted.connect(func(t: String) -> void: submitted_texts.append(t))

	line.grab_focus()
	_check(line.has_focus(), "ChatLine should hold GUI focus")

	# 1. type_text into LineEdit with ASCII + CJK + punctuation + submit=true
	var r1: Dictionary = helper._game_type_text({"text": "Hello 世界! 123", "submit": true})
	_check(bool(r1.get("sent", false)), "type_text should report sent=true: %s" % str(r1))
	_check(int(r1.get("characters_typed", 0)) == 13, "characters_typed should be 13, got %s" % str(r1))
	_check(bool(r1.get("submitted", false)), "submitted should be true")
	_check(str(r1.get("focus_owner", "")) == "/Main/ChatLine", "focus_owner should be /Main/ChatLine, got %s" % str(r1.get("focus_owner", "")))
	_check(line.text == "Hello 世界! 123", "LineEdit.text expected 'Hello 世界! 123', got '%s'" % line.text)
	_check(submitted_texts.size() == 1 and submitted_texts[0] == "Hello 世界! 123", "LineEdit.text_submitted should fire with typed text, got %s" % str(submitted_texts))

	# 2. input_key with unicode (int, float from JSON, and single-char string; empty key allowed)
	line.text = ""
	line.edit()
	var k1: Dictionary = helper._game_input_key({"key": "A", "pressed": true, "unicode": 97.0})
	var k1_up: Dictionary = helper._game_input_key({"key": "A", "pressed": false})
	var k2: Dictionary = helper._game_input_key({"key": "", "pressed": true, "unicode": "你"})
	var k3: Dictionary = helper._game_input_key({"key": "B", "pressed": true, "unicode": 66})
	var k3_up: Dictionary = helper._game_input_key({"key": "B", "pressed": false})
	_check(bool(k1.get("sent", false)) and int(k1.get("unicode", -1)) == 97, "k1 failed: %s" % str(k1))
	_check(bool(k1_up.get("sent", false)) and not k1_up.has("unicode"), "k1_up should omit unicode: %s" % str(k1_up))
	_check(bool(k2.get("sent", false)) and int(k2.get("unicode", -1)) == 0x4F60, "k2 failed: %s" % str(k2))
	_check(bool(k3.get("sent", false)) and int(k3.get("unicode", -1)) == 66, "k3 failed: %s" % str(k3))
	_check(bool(k3_up.get("sent", false)), "k3_up failed")
	_check(line.text == "a你B", "LineEdit.text after input_key unicode expected 'a你B', got '%s'" % line.text)

	# 3. type_text into TextEdit with CRLF normalization + Tab + CJK
	var editor := TextEdit.new()
	editor.name = "ChatBox"
	scene.add_child(editor)
	editor.grab_focus()
	var r2: Dictionary = helper._game_type_text({"text": "Line1\\r\\nLine2\\t中文", "submit": false})
	_check(bool(r2.get("sent", false)), "TextEdit type_text failed: %s" % str(r2))
	_check(str(r2.get("focus_owner", "")) == "/Main/ChatBox", "focus_owner should be /Main/ChatBox, got %s" % str(r2.get("focus_owner", "")))
	_check(editor.text == "Line1\\nLine2\\t中文", "TextEdit.text expected 'Line1\\nLine2\\t中文', got '%s'" % editor.text)

	# 4. Event construction checks (keycodes, shift_pressed, error handling)
	var built: Dictionary = helper._build_type_text_events({"text": "aA你"})
	_check(built.has("events") and built.events.size() == 6, "expected 6 events for 3 chars")
	if built.has("events") and built.events.size() == 6:
		var ev_a: InputEventKey = built.events[0]
		var ev_A: InputEventKey = built.events[2]
		var ev_zh: InputEventKey = built.events[4]
		_check(ev_a.keycode == KEY_A and ev_a.unicode == 97 and not ev_a.shift_pressed, "lowercase 'a' event mismatch")
		_check(ev_A.keycode == KEY_A and ev_A.unicode == 65 and ev_A.shift_pressed, "uppercase 'A' event mismatch")
		_check(ev_zh.keycode == KEY_NONE and ev_zh.unicode == 0x4F60 and not ev_zh.shift_pressed, "CJK '你' event mismatch")

	var bad_empty: Dictionary = helper._build_type_text_events({"text": ""})
	_check(not bool(bad_empty.reply.get("sent", true)), "empty text must fail")
	var bad_ctrl: Dictionary = helper._build_type_text_events({"text": "a\\u0007b"})
	_check(not bool(bad_ctrl.reply.get("sent", true)), "control char must fail")
	var bad_key: Dictionary = helper._build_key_event({"key": "NotARealKey", "unicode": 97})
	_check(not bool(bad_key.reply.get("sent", true)), "unknown key must fail even with unicode")
	var bad_uni: Dictionary = helper._build_key_event({"key": "A", "unicode": "ab"})
	_check(not bool(bad_uni.reply.get("sent", true)), "multi-char unicode string must fail")

	if _failures.is_empty():
		print("GAME_TEXT_INPUT_OK")
		quit(0)
	else:
		print("GAME_TEXT_INPUT_FAIL: %d" % _failures.size())
		quit(1)
"""


def test_game_helper_text_input_in_headless_godot(tmp_path: Path) -> None:
    """Verify GameHelper._game_type_text and _game_input_key unicode against real LineEdit/TextEdit."""
    godot = godot_bin_or_skip()
    project = tmp_path / "game-text-input-project"
    project.mkdir()
    (project / "project.godot").write_text(PROJECT_SETTINGS, encoding="utf-8")

    addons = project / "addons"
    addons.mkdir()
    shutil.copytree(PLUGIN_ROOT, addons / "godot_ai")

    (project / "check.gd").write_text(CHECK_SCRIPT, encoding="utf-8")

    result = subprocess.run(
        [godot, "--headless", "--path", str(project), "--script", "res://check.gd"],
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=GODOT_BOOT_TIMEOUT_S,
    )

    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "GAME_TEXT_INPUT_OK" in result.stdout, output
