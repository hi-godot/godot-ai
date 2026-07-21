# GDScript Testing — Writing and Running Test Suites

The plugin ships an in-editor GDScript test framework: `McpTestSuite` (base
class: assertions + lifecycle hooks) and `McpTestRunner` (discovery, execution,
result collection), invoked via the `test_run` MCP tool. It runs against
**whatever project the connected editor has open** — godot-ai's own
`test_project/`, or **your game** (any project with the plugin enabled — see
[Testing your own game](#testing-your-own-game)).

Sources of truth:
[`test_suite.gd`](../plugin/addons/godot_ai/testing/test_suite.gd) (API),
[`test_runner.gd`](../plugin/addons/godot_ai/testing/test_runner.gd) (runner),
[`test_handler.gd`](../plugin/addons/godot_ai/handlers/test_handler.gd)
(discovery), [`tools/testing.py`](../src/godot_ai/tools/testing.py) (MCP
surface). CI policy and test-layer strategy live in
[testing-strategy.md](testing-strategy.md); test-hygiene rules for
contributors are in [AGENTS.md](../AGENTS.md).

## Skeleton

```gdscript
@tool
extends McpTestSuite

func suite_name() -> String:
	return "player"              # short id, used by test_run suite=...

func test_something() -> void:   # every test_* method runs, alphabetical order
	assert_eq(1 + 1, 2)
```

Save as `res://tests/test_player.gd` in the open project, then call `test_run`.
That's the whole loop.

## Discovery rules

- Scanned directory: `res://tests/` in the currently open project. Top level
  only — subdirectories are not scanned.
- Filename must match `test_*.gd`; the script must extend `McpTestSuite` and
  be instantiable.
- A file that fails to load (parse error, duplicate method, wrong base class)
  is reported in the response's `load_errors`; the remaining suites still run.
- Suites run sorted by `suite_name()`; within a suite, `test_*` methods run in
  alphabetical order.
- Test methods must be synchronous. The runner does not await coroutines — a
  test suspends at its first `await` and everything after it never runs
  (usually surfacing as a zero-assertion failure).

## Complete minimal example

Own-game flavor (`res://tests/test_player.gd`):

```gdscript
@tool
extends McpTestSuite

const PlayerScene := preload("res://player/player.tscn")

func suite_name() -> String:
	return "player"

func test_player_instantiates() -> void:
	var player = track(PlayerScene.instantiate())  # track() = freed after the test
	assert_true(player is CharacterBody2D, "player root should be a CharacterBody2D")

func test_speed_positive() -> void:
	var player = track(PlayerScene.instantiate())
	assert_gt(player.speed, 0.0, "speed must be positive")

func test_selected_node_readable() -> void:
	if EditorInterface.get_edited_scene_root() == null:
		skip("no scene open")   # unmet precondition — counts as skipped, not passed
		return
	assert_true(EditorInterface.get_edited_scene_root().name != "")
```

Contributor flavor: plugin handler suites `preload` the handler in
`suite_setup()` and assert on the `{"data": ...}` / `{"error": ...}` dict each
handler returns. Reference pattern:
[`test_project/tests/test_scene.gd`](../test_project/tests/test_scene.gd).

## API reference — `McpTestSuite`

Ordered as in `test_suite.gd`. Assertions latch on the first failure: later
assertions in the same test still increment the count but cannot overwrite the
failure message.

### Lifecycle and helpers

| Method | Behavior |
|---|---|
| `suite_name() -> String` | Override. Short suite id (e.g. `"scene"`), matched exactly by `test_run suite=...`. Default `"unnamed"`. |
| `suite_setup(ctx: Dictionary) -> void` | Override. Runs once before the suite. `ctx` is `{"undo_redo": EditorUndoRedoManager, "log_buffer": McpLogBuffer}`; each suite gets a fresh duplicate, so mutations can't leak between suites. |
| `setup() -> void` | Override. Runs before each test. |
| `teardown() -> void` | Override. Runs after each test. |
| `suite_teardown() -> void` | Override. Runs once after the suite. |
| `track(obj: Object) -> Object` | Register a plain Object or out-of-tree Node to be freed after the current test (and again after `suite_teardown`). RefCounted instances are accepted but ignored (they self-manage). Returns `obj` for inline use. |
| `skip(reason := "") -> void` | Mark the current test skipped (unmet precondition — no scene open, etc.). Skips count separately from passed/failed; a prior failed assertion always beats a later `skip()`. |
| `fail_setup(reason: String) -> void` | Call inside `suite_setup()` to abort the suite with a single suite-level failure (reported as test `<suite_setup>`) instead of N zero-assertion failures. |
| `skip_suite(reason: String) -> void` | Call inside `suite_setup()` to skip the whole suite with a single suite-level skip (reported as test `<suite_setup>`). |
| `skip_on_godot_lt(min_version: String, reason := "") -> bool` | Skip the current test when the running Godot is older than `"major.minor"`. Returns `true` when skipped, so: `if skip_on_godot_lt("4.6", "..."): return`. |
| `expect_script_error_containing(substring: String) -> void` | Allow one captured `SCRIPT ERROR` whose text contains `substring`. Only for negative-path tests that intentionally run invalid GDScript; any unexpected script error fails the test (`Aborted by SCRIPT ERROR: ...`). |
| `editor_undo(undo_redo: EditorUndoRedoManager) -> bool` | Undo the most recent action across the scene and global undo histories. Returns `false` when nothing was undone — assert on the return value. |
| `editor_redo(undo_redo: EditorUndoRedoManager) -> bool` | Redo mirror of `editor_undo`. |

### Assertions

Each records one assertion; `msg` is optional everywhere and replaces the
default failure message.

| Method | Passes when |
|---|---|
| `assert_true(condition, msg := "")` | `condition` is true |
| `assert_false(condition, msg := "")` | `condition` is false |
| `assert_eq(actual, expected, msg := "")` | `actual == expected` |
| `assert_ne(actual, not_expected, msg := "")` | `actual != not_expected` |
| `assert_gt(actual, threshold, msg := "")` | `actual > threshold` |
| `assert_has_key(dict, key, msg := "")` | `dict` is a Dictionary and has `key` (failure message lists the actual keys) |
| `assert_contains(haystack, needle, msg := "")` | String `haystack` contains `needle` as substring, or Array `haystack` has `needle` as element; any other haystack type fails |
| `assert_is_error(result, expected_code := "", msg := "")` | `result` has an `"error"` key; when `expected_code` is given, `result.error.code` must match it |

### Scene helpers

Underscore-prefixed convenience shared by the plugin's own suites (not a
stable public API): `_add_control(ctl_name: String, ctl: Control = null) ->
String` adds a Control (defaults to a new Panel) under the scene root and
returns its scene path (`""` when no scene is open); `_remove_control(path:
String)` removes it.

## Runner behavior and guardrails

- **Zero-assertion detection**: a test that completes with 0 assertions fails
  (`"likely skipped its logic"`). Use `skip("reason")` before any early
  `return` whose precondition can't be met.
- **Script-error capture**: any `SCRIPT ERROR` emitted during a test fails it
  unless allowlisted via `expect_script_error_containing`.
- **Failure beats skip**: a test that fails an assertion and then hits a
  `skip()` guard reports the failure.
- **Per-test cleanup**: `track()`-ed objects are freed after `teardown()`; any
  scene node whose name starts with `_McpTest` is freed after every test,
  anywhere in the tree, bypassing undo. Name throwaway scene nodes
  `_McpTest...` to get this for free.
- **Per-suite cleanup**: nodes added under the scene root during a suite and
  left behind are removed when the suite ends.
- **Suite isolation**: each suite receives a fresh `ctx.duplicate()`.
- **Resilient discovery**: broken `test_*.gd` files land in `load_errors`
  without stopping the rest of the run.

## Running tests

MCP tool `test_run` (120 s server-side timeout for the whole run):

```text
test_run                              # all suites — compact: counts + failures only
test_run suite=player                 # one suite (exact match on suite_name())
test_run test_name=speed              # only tests whose name contains "speed"
test_run exclude_test_name=slow,flaky # skip tests matching any comma-separated substring
test_run verbose=true                 # include every individual test result
test_run session_id=mygame@1a2b       # pin to one editor when several are connected
```

Re-fetch the last results without re-running: `test_manage(op="results_get")`
(accepts `verbose` in `params`), or read the resource `godot://test/results`.

### Result shape

```json
{
  "passed": 12, "failed": 1, "skipped": 2, "total": 15,
  "duration_ms": 240,
  "suites_run": ["player", "scene"], "suite_count": 2,
  "failures": [
    {"suite": "player", "test": "test_speed_positive",
     "passed": false, "message": "Expected 0.0 > 0.0", "assertion_count": 1}
  ],
  "edited_scene": "res://main.tscn"
}
```

- `failures` is present only when non-empty. `verbose=true` adds `results`
  with every test (skipped entries carry `"skipped": true` and the skip
  reason as `message`).
- `load_errors` (array of `"file (reason)"` strings) appears when any
  `test_*.gd` failed to load.
- `edited_scene` is always present. `scene_warning` appears when there are
  failures and the edited scene differs from the project's main scene — many
  suites assume the main scene is open, so `scene_open` it and re-run before
  treating those failures as real.
- A suite aborted by `fail_setup` / `skip_suite` reports one entry with
  `"test": "<suite_setup>"`.

## Testing your own game

Everything above works in any project with the plugin enabled: discovery is
`res://tests/` of whatever project the connected editor has open, and
`McpTestSuite` is a global class registered by the plugin. A typical loop with
an AI client: ask it to *"write a test suite for the player controller and run
it"* — it creates `res://tests/test_player.gd` (e.g. via `script_create`),
calls `test_run`, and iterates on the failures.

Constraints (tests run synchronously on the editor's main thread):

- Don't open modal dialogs, switch scenes, or start/stop the game from a test
  — these block or invalidate the runner mid-run. Test the validation paths
  synchronously and `skip()` on unmet preconditions (see the
  "validation only" sections in
  [`test_scene.gd`](../test_project/tests/test_scene.gd)).
- Keep per-test work small; the whole run must finish within `test_run`'s
  120 s timeout.
- Free what you create: `track()` for objects and out-of-tree nodes, or the
  `_McpTest*` name prefix for scene nodes.
