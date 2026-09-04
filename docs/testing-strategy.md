# Godot AI — Testing Strategy

*Updated 2026-09-03*

This document defines how Godot AI should prove that new capability is real, stable, and safe to extend.

Use the related docs for adjacent concerns:

- [testing.md](testing.md) for how to write and run GDScript test suites
  (authoring guide + `McpTestSuite` API reference) — this document covers
  test-layer policy and CI expectations, not authoring
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
- **Suite isolation**: each suite receives `ctx.duplicate(true)`, isolating nested
  Dictionary and Array mutations. Object references in the context remain shared,
  so suites must not retain mutations to the undo manager or log buffer.
- **CI static check**: `script/ci-check-gdscript` scans a single `godot --headless --import` run's log for `SCRIPT ERROR` / `Parse Error` lines before the editor test run, catching parse errors at the gate (it fails rather than passes when the import log is empty or the binary is missing).

### End-to-end and release-smoke tests

Run real-project smoke tests for:

- opening a project
- connecting the plugin
- creating or mutating scenes and nodes
- attaching scripts
- running and stopping the project
- reading logs or screenshots
- exporting or otherwise exercising the release surface

### Self-update tests

The updater is one in-editor GDScript path ([self-update.md](self-update.md)),
so its mandatory coverage is small and fixed:

- `test_project/tests/test_update_installer.gd` — the verifier and installer
  as pure functions with an injected fixture key pair: signature, identity,
  archive and inventory rejections, stage hashing, marker states, rollback and
  repair decisions;
- the Python verifier/installer unit tests behind `script/v4-release`;
- the three real-editor scenarios in
  `tests/integration/test_self_update_upgrade_paths.py`: a signed v4-to-v4
  update restarts into a working server, a final-v3 install crosses the
  capsule, and a tampered live tree after a swap is rolled back. They need
  `GODOT_BIN` and otherwise skip.

The real-editor scenarios run on Linux on every pull request and on all three
desktop OSes nightly, and the release pipeline's A-to-B row runs the first one
on the exact signed candidate on every OS before publication.

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

- Python unit and integration tests on Python 3.11, 3.12, 3.13, and 3.14 on
  Linux, macOS, and Windows so platform-specific process, path, lease, and
  updater behavior is exercised at every supported Python version
- Godot-side editor test suites on Linux, macOS, and Windows at the supported
  Godot 4.7 floor. Separate Linux 4.5 and 4.6 rows prove that unsupported
  editors parse the entry script, refuse v4 before construction, and preserve
  the add-on tree and `project.godot` without creating capability state.
- release-surface smoke, especially install and packaging paths once distribution work is active (3 OS)
- the retained
  [one-time pre-v4 updater evidence](verification/pre-v4-updater-one-time-evidence.md).
  It source-classified all 104 tags into 24 behavior classes and ran 29 selected
  runtime rows on macOS/Godot 4.7. Historical releases remain immutable and
  unsupported after the v4 boundary. Recurring CI tests one canonical v4 tree,
  the signed transition-capsule shape, and the exact final-v3 one-click bridge;
  it does not download every older release on every commit.
- **pixel-level capture smoke** for tools that cross the editor → game-process boundary (3 OS). The `game-capture-smoke-{linux,macos,windows}` jobs launch Godot with a real rendering driver (`xvfb-run -a ... godot --rendering-driver opengl3` on Linux, windowed on macOS and Windows), play `test_project/capture_smoke.tscn` (four colored quadrants), round-trip `editor_screenshot(source="game")` through the debugger-channel bridge, decode the returned PNG with Pillow, and assert the centre of each quadrant matches the expected color within tolerance. Catches regressions in the `_mcp_game_helper` autoload registration, the `DEFERRED_RESPONSE` dispatcher path, and the `McpConnection.send_deferred_response` reply pipeline — none of which are exercised by the headless Godot test suite.
- **live port-conflict smoke** for the port-8000 occupant classification + recovery machinery (3 OS), which the GDScript unit tests can only cover with mocked OS interactions. `script/ci-stale-server-smoke` plants a process on the HTTP port, launches a real headless editor, and asserts the plugin's observable behavior from the editor log. The `stale-server-smoke` jobs run `--mode stale`: a godot-ai server simulator with an authenticated, mismatched version. Startup alone has no destructive authorization, so the plugin must refuse adoption, leave the process alive, and present an actionable incompatible-server state; an explicit Dock recovery intent is the only path allowed to spend kill/restart authority. The sibling `foreign-server-smoke` jobs run `--mode foreign`: a non-godot-ai listener (404s on `/godot-ai/status`) receives the same no-kill treatment and a suggested free port. The `stale-compatible-reload-smoke` jobs run `--mode stale-compatible-reload`: a real current-version external server is paired with a matching-version durable record naming a dead PID; the plugin must adopt it as external, preserve it through `editor_reload_plugin`, register a distinct replacement session, and answer a post-reload editor probe. Kept as separate jobs so a prior mode's listener cannot bleed into the next scenario.

  Ownership migration is intentionally conservative: an older installation may
  have persisted only its now-dead launcher PID. After upgrading, a surviving
  compatible server with that unprovable record is adopted as **external**, so
  the plugin relinquishes teardown/restart rights instead of risking a kill of
  an unrelated process. Servers spawned after the fix heal their record to the
  authoritative live PID during the startup health watch.

### CI hardening measures

- **GDScript validation**: `script/ci-check-gdscript` runs after `--import` and before the editor launches. It scans the import log for `SCRIPT ERROR` / `Parse Error` lines and fails the build immediately if any GDScript file has syntax errors. Godot 4.7 is strict; unsupported 4.5/4.6 behavior is covered by the separate inert-refusal smoke rather than by running the v4 suite there.
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
