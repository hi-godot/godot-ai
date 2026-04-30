# Godot AI — Testing Strategy

*Updated 2026-04-16*

This document defines how Godot AI should prove that new capability is real, stable, and safe to extend.

Use the related docs for adjacent concerns:

- [implementation-plan.md](implementation-plan.md) for active priorities
- [packaging-distribution.md](packaging-distribution.md) for release-smoke install coverage

---

## Quality Standard

New capability should not count as shipped just because it works once in a local editor.

The minimum bar is:

- clear tool contract
- automated coverage where the behavior is deterministic
- at least one real-project smoke path for meaningful editor workflows
- error behavior that is intentional and testable

---

## Test Layers

### Unit tests

Use unit tests for:

- request validation
- protocol serialization
- pagination
- session routing
- readiness checks
- error mapping
- runtime handler behavior that does not require a live editor

### Integration tests

Use integration tests for:

- tool orchestration against mocked or controlled plugin responses
- reconnect behavior
- stale reference handling
- partial batch failures
- runtime tool behavior on the Python/server side

### Contract tests

Use contract tests for the plugin/server boundary:

- handshake and versioning
- command envelope shape
- response and error schema
- readiness and capability signaling
- log and job payload consistency

### Godot-side test suites

Use in-editor GDScript suites for:

- scene and node mutation behavior
- signal, autoload, input, and filesystem handlers
- runtime tools like run/stop and screenshots
- any behavior that depends on actual Godot editor APIs or undo semantics

Built-in guardrails:

- **Zero-assertion detection**: the runner flags any test that completes with 0 assertions as a failure. This catches tests that silently `return` early (e.g. when `scene_root == null`) without exercising any logic.
- **Resilient discovery**: if a `.gd` file fails to parse (duplicate methods, syntax errors, wrong base class), the remaining suites still load and run. Failing files are reported in `load_errors` with a reason string.
- **Suite isolation**: each suite receives a fresh `ctx.duplicate()` so `suite_setup()` mutations cannot leak between suites.
- **CI static check**: `script/ci-check-gdscript` runs `godot --check-only` against every `.gd` file before the editor test run, catching parse errors at the gate.

### End-to-end and release-smoke tests

Run real-project smoke tests for:

- opening a project
- connecting the plugin
- creating or mutating scenes and nodes
- attaching scripts
- running and stopping the project
- reading logs or screenshots
- exporting or otherwise exercising the release surface

### Interactive self-update smoke

Self-update changes require a local interactive smoke because the crash fixed in #250 does not reproduce in headless Godot CI. Run:

```bash
script/local-self-update-smoke
```

The harness prepares a disposable project from the current branch as v(N), builds a synthetic v(N+1) release ZIP with a typed Dict/Array `_exit_tree` trigger, forces the Update banner to install the local ZIP, records the pre-run macOS DiagnosticReports baseline, and launches Godot. The operator step is only to click Update in the dock.

Passing criteria:

- the editor process stays alive without manual or programmatic restart
- the installed fixture plugin version advances to v(N+1)
- `user://godot_ai_update/` is consumed after install
- no new `Godot*.ips` appears on macOS
- the vNext `_exit_tree` trigger does not print during the update window

Treat this as release-blocking local coverage for self-update, plugin reload handoff, and install/extract changes. It is not a replacement for headless CI; it covers the interactive editor path that CI currently cannot exercise reliably.

---

## What New Tool Families Should Add

The expected coverage depends on the surface:

- simple read tools need unit and integration coverage
- write tools need unit coverage plus Godot-side behavioral tests
- runtime or release tools need smoke coverage in addition to targeted tests
- batch or multi-step tools need explicit partial-failure coverage

If a tool has undo semantics, readiness constraints, or cross-session behavior, those should be tested directly rather than hand-waved in the docs.

---

## CI Expectations

The CI stack should exercise at least four tiers:

- Python unit and integration tests (3 OS x 2 Python versions)
- Godot-side editor test suites (3 OS via `chickensoft-games/setup-godot@v2` on GitHub Actions runners) — **headless**; no rendering
- release-surface smoke, especially install and packaging paths once distribution work is active (3 OS)
- local interactive self-update smoke for update/reload/extract changes (`script/local-self-update-smoke`)
- **pixel-level capture smoke** for tools that cross the editor → game-process boundary (3 OS). The `game-capture-smoke-{linux,macos,windows}` jobs launch Godot with a real rendering driver (`xvfb-run -a ... godot --rendering-driver opengl3` on Linux, windowed on macOS and Windows), play `test_project/capture_smoke.tscn` (four colored quadrants), round-trip `editor_screenshot(source="game")` through the debugger-channel bridge, decode the returned PNG with Pillow, and assert the centre of each quadrant matches the expected color within tolerance. Catches regressions in the `_mcp_game_helper` autoload registration, the `DEFERRED_RESPONSE` dispatcher path, and the `McpConnection.send_deferred_response` reply pipeline — none of which are exercised by the headless Godot test suite.

### CI hardening measures

- **GDScript validation**: `script/ci-check-gdscript` runs after `--import` and before the editor launches. It scans the import log for `SCRIPT ERROR` / `Parse Error` lines and fails the build immediately if any GDScript file has syntax errors. This catches broken scripts before the test runner starts.
- **Step timeouts**: test and smoke steps have `timeout-minutes` set to prevent CI hangs from frozen Godot processes.
- **Filesystem scan settling**: `script/ci-godot-tests` includes a short sleep after editor startup so the filesystem scan completes and test discovery finds all suites.
- **Resilient test discovery**: `test_handler.gd` catches per-file load errors during `_discover_suites()`. A broken test file does not prevent the rest of the suite from running; errors are reported in the response alongside successful results.
- **Regression diagnostics**: `script/ci-find-regression-range` helps identify which commits introduced a CI regression by binary-searching recent history.

This should stay aligned with the release work in [packaging-distribution.md](packaging-distribution.md).

---

## Future Extensions

Once the project starts targeting more polished game-production workflows, add more verification where it matters:

- screenshot-based regression checks for visibly important surfaces
- runtime-performance spot checks for new diagnostics tools
- benchmark-project smoke checks, especially for the roguelite slice in [implementation-plan.md](implementation-plan.md)

The goal is not maximal test volume. The goal is enough structured proof that the tool surface can keep growing without turning flaky.
