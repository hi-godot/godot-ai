# Friction log — godot-ai MCP

Rolling log of pain points, surprises, and bugs hit while using the
godot-ai MCP server from AI clients. Append new entries at the top so the
most recent session is easiest to find; keep older entries around as a
record of what's been fixed vs. what keeps biting.

Each entry should include: date, what we were doing, what went wrong,
enough detail to reproduce, and — if known — a suggested fix. Entries
labelled "bug" are actual defects; "friction" entries are workflow rough
edges that aren't necessarily code bugs.

---

## 2026-04-19 — Smoking PR #78 (`logs_read source=game`)

Smoking PR #78 (`claude/add-game-logs-capture-gtE27`) against a live editor
running on `/Users/davidsarno/godot-assetlib-download-test/` — not the
worktree's own `test_project/`. The installed plugin was 1.0.1; the PR
code had to be rsync'd over from the worktree.

### bug — `push_error("msg")` / `push_warning("msg")` lose the user's text — FIXED in PR #78

`plugin/addons/godot_ai/runtime/game_logger.gd::_log_error` reads only the
`rationale` argument from Godot's `Logger` virtual. For the **single-arg**
common form `push_error("msg")` / `push_warning("msg")`, Godot puts the
user's string in `code` and leaves `rationale` empty. Captured text for
`push_warning("warn-game")`:

```json
{ "level": "warn", "text": " (core/variant/variant_utility.cpp:1034 @ push_warning)" }
```

Leading space because the format string is `"%s (%s)"` with empty
`rationale`; file pointing at Godot's own C++ source instead of the user's
GDScript; the string `"warn-game"` discarded entirely.

Suggested fix:

```gdscript
func _log_error(
    function: String, file: String, line: int,
    code: String,          # <-- rename from _code
    rationale: String,
    _editor_notify: bool, error_type: int, _script_backtraces: Array,
) -> void:
    var level := "warn" if error_type == 1 else "error"
    var message := rationale if not rationale.is_empty() else code
    var loc := ""
    if not file.is_empty():
        loc = "%s:%d @ %s" % [file, line, function] if not function.is_empty() else "%s:%d" % [file, line]
    var text := "%s (%s)" % [message, loc] if not loc.is_empty() else message
    _append(level, text)
```

Bonus: `script_backtraces` carries the real user-script caller — surface
it instead of (or alongside) Godot's internal C++ frame so errors point
agents back at the user script that raised them.

Two-arg form `push_error(code, rationale)` / `push_warning(code, rationale)`
works correctly — the defect only hits the common single-arg case.

Repro: `push_warning("warn-game"); push_error("err-game")` in `_ready()`,
`project_run`, `logs_read(source="game")` → lines 3-4 in the response.

### friction — `editor_reload_plugin` can't recover from newly-added files on disk — FIXED (editor_handler.gd now `fs.scan()` awaits before re-enabling)

Sequence that breaks: rsync PR plugin over an older installed copy (adds
new `.gd` files that declare `class_name`) → `editor_reload_plugin` →
`set_plugin_enabled(false)` succeeds, `set_plugin_enabled(true)` fails
with `Parse Error: Could not find type "GameLogBuffer" in the current
scope`. Godot's class-name registry hasn't seen the new files because the
filesystem hasn't been rescanned since they appeared.

Only recovery is kill + relaunch Godot. Worth either documenting, or
making `editor_reload_plugin` call
`EditorInterface.get_resource_filesystem().scan()` and await
`filesystem_changed` before the disable/enable toggle.

### bug — SEGV in `GameLogBuffer.get_range` on the first call after `editor_reload_plugin` — FIXED in PR #103 (explicit `_exit_tree` teardown; see issue #46)

Same session (see setup for smoking PR #78 Copilot fixes). Rsync'd new
plugin code on top of a running editor, called `editor_reload_plugin`
(disable + re-enable). Reload reported success, session came back as
`ready`. First `logs_read(source="game")` after the reload crashed Godot
with SIGSEGV:

```
GDScript backtrace (most recent call first):
    [0] get_range (res://addons/godot_ai/utils/game_log_buffer.gd:47)
    [1] _get_game_logs (res://addons/godot_ai/handlers/editor_handler.gd:99)
    [2] get_logs (res://addons/godot_ai/handlers/editor_handler.gd:62)
    [3] _call_handler (res://addons/godot_ai/dispatcher.gd:131)
```

Line 47 is `var size := _storage.size()` — the first statement of
`get_range`. The same code passes every GDScript unit test (53/53) on a
fresh editor launch. Only the post-reload first call crashes.

Almost certainly a symptom of **[#46 — Harden plugin against repeated
editor_reload_plugin state corruption](https://github.com/hi-godot/godot-ai/issues/46)**:
handler RefCounted instances built in `_enter_tree` don't get explicitly
released in `_exit_tree`; when Godot reloads the scripts the in-memory
vtables for still-referenced instances go stale, and the next method call
dispatches into freed memory. Worth adding this backtrace to #46 as
another repro datapoint.

Workaround: relaunch Godot after a reload when possible. Long-term fix
tracked in #46.

### friction — `--reload` uvicorn uses the root repo's src, not the worktree's — FIXED (`script/serve-this-worktree` + dock auto-detect; see issue #84)

Dev server was running as `python -m godot_ai ... --reload` with the
repo's editable install in `.venv`. `import godot_ai` resolves to
`/Users/davidsarno/Documents/godot-ai/src/godot_ai/` regardless of which
worktree I'm in. Had to kill and restart with `PYTHONPATH=<worktree>/src`
to get PR code into the server.

Addressed in two places:
- `script/serve-this-worktree` is the CLI one-liner (prepends
  `<worktree>/src` to `PYTHONPATH`, frees the port, starts `--reload`).
- The dock's **Start Dev Server** button now auto-detects a sibling
  `src/godot_ai/` on the walk-up from `res://` and exports
  `PYTHONPATH=<that>/src` for the spawn. On the root repo it matches the
  editable install and is a no-op; in a worktree it makes the button Do
  The Right Thing without any new UI.

### friction — `scene_create` briefly rejects with `EDITOR_NOT_READY: importing` — FIXED in PR #95 (retryable/state hints on EDITOR_NOT_READY)

Right after a `filesystem_write_text`, readiness flips to `importing` for
~1-2s while Godot reimports. `editor_state` still reports `no_scene`
during that window, so callers don't have a single source of truth to
poll. Retry-with-backoff works, but consider making `require_writable`
return a distinguishable retryable error (not just a generic
`EDITOR_NOT_READY`) so clients can back off without string-matching.

### what passed cleanly

- `logs_read source="game"` baseline empty shape (test #6)
- `logs_read` default plugin source — legacy `[str]` shape preserved (#7)
- `logs_read source="bogus"` → `ValueError: Invalid source 'bogus'` (#8)
- `offset` / `count` windowing (#10)
- `has_more` + `total_count` pagination (#11)
- Run rotation: stale `since_run_id` → `stale_run_id: true`, empty lines,
  fresh RID (#12)
- Fresh poll after second run returns only new-run entries (#13)
- `since_run_id` matching current run returns populated lines (#14)
- `source="all"` merges streams with plugin-first ordering; each entry
  carries `source: "plugin" | "game"` (#15)
- `logs_clear` clears plugin buffer, leaves game buffer intact (#16)
- Back-pressure: 2500-print loop → `total_count=2000` (cap),
  `dropped_count=505`, `editor_state` returned in 16ms,
  `performance_monitors_get` reported FPS=145 — no freeze (#17)
- Bonus: `editor_screenshot(source="game")` — 1108x623 captured from the
  game process, scaled to 512x287, round-trips visible ColorRect + Label
  content (exercises PR #76's debugger-bridge path)
