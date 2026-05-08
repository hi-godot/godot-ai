# Screenshot-driven testing

Notes for AI agents (and humans) on getting `editor_screenshot` to work the
first time, instead of looping through "autoload never registered its debugger
capture within 20s" timeouts.

## Pick the right `source`

| Goal | `source` | Notes |
|------|----------|-------|
| Verify in-editor UI / inspector / dock layout | `viewport` | Captures the editor's 2D view directly — no debugger bridge, always works. |
| Verify a 3D scene framing as the editor camera sees it | `viewport` | Same path, no game subprocess required. |
| Verify a running game's framebuffer (menus that exist at runtime, gameplay state, particle effects, runtime UI animations) | `game` | Requires the game subprocess + `_mcp_game_helper` autoload + a `project_run`-driven play cycle. |
| Verify a specific `Camera3D` view without playing | `cinematic` (where supported) | Doesn't require Play. |

**Default to `viewport` when in doubt.** `source="game"` is only the right
answer when the thing you want to see only exists in the *running* game.

## Recipe: testing a runtime UI option (e.g. main menu)

```
1. editor_state                              -> confirm session, current_scene, readiness="ready"
2. project_run(mode="current",               -> autosave=False so MCP scene mutations stay in memory
              autosave=False)
3. poll editor_state every ~500ms            -> wait until is_playing=true AND game_capture_ready=true
4. (interact via available write tools as    -> e.g. node_set_property, batch_execute,
    needed for the scenario being tested)       ui_manage, theme_manage
5. editor_screenshot(source="game",          -> request the capture
                     max_resolution=1280)
6. project_manage(op="stop")                 -> always stop the run when done
```

`game_capture_ready` is the deterministic readiness signal — it flips true
*only* after the game-side autoload's `mcp:hello` beacon arrives, which means
the debugger channel is wired up and `mcp:take_screenshot` will land. Do not
sleep-and-pray; poll this field.

## Pre-flight checklist (when `source="game"` keeps timing out)

1. **Is `_mcp_game_helper` actually in the project's autoload list?**
   - Open `Project Settings → Autoload`, or grep `project.godot` for
     `_mcp_game_helper="*res://addons/godot_ai/runtime/game_helper.gd"`.
   - If missing: disable + re-enable the Godot AI plugin in Project Settings →
     Plugins. Re-enabling fires `_ensure_game_helper_autoload()` which writes
     the entry and persists it via `ProjectSettings.save()`.
2. **Was the game launched via `project_run`?**
   - `editor_screenshot(source="game")` requires `_game_run_active=true` on
     the editor side, which is only set by `project_run`. F5-from-keyboard
     plays the game but `mcp:hello` from that play cycle is *explicitly
     ignored*, and you will time out.
3. **Is the right session active?**
   - Multi-editor / multi-worktree setups: call `session_activate` (or pass
     `session_id` per call) so the screenshot routes to the editor whose game
     is actually running.
4. **Did the game subprocess actually boot?**
   - Look at the Godot Output panel for
     `[godot_ai game_helper] registered mcp capture (debugger active=true, logger=true)`.
     If that line never prints, the autoload didn't run. If
     `debugger active=false`, you're in a headless / custom-main-loop /
     exported build where the debugger channel is off.
5. **Did the game crash during boot?**
   - `logs_read` (or `logs_read source="game"`) surfaces any `print`/error
     output the game emitted before dying. A crashed game can never beacon.

## Decision tree for the timeout error

`Game-side autoload never registered its debugger capture within 20s`:

- `is_playing` was **false** when you called `editor_screenshot`?
  → The game wasn't running. Call `project_run` first and poll readiness.
- `is_playing=true` but `game_capture_ready` stayed **false**?
  → Either the autoload isn't in `project.godot` (item 1 above), or the
    project was launched outside `project_run` (item 2), or the game's
    `_ready` errored before reaching the `mcp:hello` send (check `logs_read
    source="game"`).
- Worked once, fails on second attempt within the same play cycle?
  → Did you `project_manage(op="stop")` and forget to `project_run` again?
    Each new run rotates a token; the readiness flag is reset on
    `begin_game_run()`.

## Things to prefer over screenshots, when possible

Screenshots are the slowest, flakiest assertion surface — they require
rendering, encoding, and a live debugger bridge, and any of those can fail
intermittently. When you can, assert on **state** instead of pixels:

- `node_get_properties` to read the actual visible/visibility/text/etc. of a
  Control after the menu opens.
- `print()` from the game's `_pressed()` handler — game prints are forwarded
  back over `mcp:log_batch` and surface in `logs_read source="game"`. The AI
  can grep for `"menu_opened"` instead of trying to OCR a screenshot.
- `node_find` with a query like "find a Control named MainMenu that's
  visible" — gives a yes/no without ever rendering.

Reach for `source="game"` screenshots when the assertion is genuinely
visual (layout, colors, particle bursts, animation poses) and skip them
when state inspection would do.

## Reproducing the timeout deterministically

`script/local-game-capture-diag` (developer-facing, runs against your local
editor) walks through the full bridge end-to-end against the currently-open
scene and prints diagnostics on failure. Use it when you can't tell whether
the bug is in your project, in the plugin, or in the AI's calling pattern.

`script/ci-game-capture-smoke` is the CI equivalent — it requires the
fixture scene `test_project/capture_smoke.tscn` and asserts pixel colors at
known coordinates.
