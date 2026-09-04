# Native GLES environment/undo shutdown reproduction

This standalone Godot project contains **no Godot AI code**. It reproduces
the 349,524-byte GL texture diagnostics investigated during PR #949. It is
diagnostic evidence, not a release qualification test or a waiver.

Copy this directory to a disposable location before running it: the native
control plugin writes `main.tscn`, edits that scene in memory and quits its
own editor. Do not enable the control plugin in a user project.

```sh
CONTROL_COUNT=1 CONTROL_CLEAR=immediate CONTROL_FREE=queued \
  /path/to/Godot --editor --path /path/to/disposable-copy \
  --rendering-method gl_compatibility --verbose
```

Use a graphical editor, not `--headless`. Wait for `CONTROL COMPLETE` and
normal process exit. A parse error, failed assertion, absent completion
marker, timeout or forced termination invalidates the reproduction.

The control assigns an Environment/Sky/ProceduralSkyMaterial to a native
WorldEnvironment using EditorUndoRedoManager, records its resource references,
removes the node and immediately clears the undo history. No WebSocket,
backend, dispatcher, Godot AI handler or candidate payload participates.

## Observed controls — macOS, September 3, 2026 UTC

Each row used one environment and exited normally. Counts below are only
the exact `leaked 349524 bytes` diagnostic, not a claim of zero other output.

| Official Godot build | `CONTROL_CLEAR` | `CONTROL_FREE` | Texture warnings |
|---|---|---|---|
| 4.7.2 | immediate | queued | 2 |
| 4.7.2 | deferred | queued | 0 |
| 4.7.2 | none | queued | 0 |
| 4.7.2 | immediate | immediate | 2 |
| 4.7.0 | immediate | queued | 2 |

`deferred` waits two process frames before clearing history. `none` retains
the history until editor exit. The original eight-environment immediate-clear
run emitted sixteen warnings. The single unclaimed `Node` StringName at exit
also occurs in native-only controls and is a separate diagnostic.

This isolates an engine-native reproduction and a cleanup-timing interaction.
The repeated-run measurements below now demonstrate accumulating engine
texture accounting; they do not establish an independently measured GPU-driver
allocation size or equivalent behavior on other operating systems.
In particular, the no-warning controls are **not** permission to split the
full suite, add arbitrary waits to production or suppress the diagnostic.

The Godot AI combined-suite bisection narrowed the same warning to running
`environment` and then `gridmap` in one synchronous test request: environment
cleanup queues node deletion while gridmap teardown clears the shared undo
history. Environment plus input, environment plus game_helper, and gridmap
alone did not reproduce it. All diagnostic filters were confined to a
disposable clone and removed before the unchanged full-suite regression run.

Local source/log evidence: `/private/tmp/godot-native-env-undo.RSY4FG`, including
`matrix-summary.log` and the five version/clear/free logs. Pair-bisection logs
are under `/private/tmp/godot-ai-release-build.szEA2o/gles-pair-*.log`.
The retained project was copied into another fresh directory and verified on
4.7.2: `/private/tmp/godot-native-env-durable.EQx13z/editor.log` records normal
completion and the same two warnings, without earlier errors.
These temporary development logs are not the immutable qualification bundle.

## Repeated growth and direct RenderingServer control

Optional `CONTROL_BATCHES` repeats the operation (default 1, maximum 10), with
250 ms between batches. `CONTROL_IDLE` waits after the last batch (default 3,
maximum 60 seconds). `CONTROL MEMORY` emits the engine's texture/video memory
and object/resource counters before the run, after each batch and after idle.
`CONTROL_COUNT` is bounded to 1–16. These are diagnostic limits, not release
thresholds.

For a smaller control, `CONTROL_DIRECT_SKY=1` replaces each environment/undo
operation with native `sky_create`, `sky_set_radiance_size(..., 128)` and
`free_rid`. All RIDs are created before any are freed. This mode uses no
WorldEnvironment, material, undo action or Godot AI code. `CONTROL_CLEAR=deferred`
waits two frames before freeing the RIDs; otherwise they are freed immediately.

```sh
CONTROL_DIRECT_SKY=1 CONTROL_COUNT=8 CONTROL_BATCHES=10 CONTROL_CLEAR=immediate \
  /path/to/Godot --editor --path /path/to/disposable-copy \
  --rendering-method gl_compatibility --verbose
```

On official macOS Godot 4.7.2, ten batches of eight operations produced:

| Native operation | Cleanup | Texture-counter increment per batch | Shutdown texture warnings |
|---|---|---:|---:|
| environment/undo, 256-pixel sky | immediate | 5,592,384 bytes | 160 × 349,524 bytes |
| environment/undo, 256-pixel sky | deferred | 0 | 0 |
| direct 128-pixel sky RID | immediate | 1,398,080 bytes | 160 × 87,380 bytes |
| direct 128-pixel sky RID | deferred | 0 | 0 |

The immediate controls grew by the same increment in every batch; three seconds
of idle did not reduce the final counter. This is not merely a shutdown-only
warning, but both the counter and warning share engine accounting, so they are
not two independent measurements of actual VRAM. Logs, exact control source
and machine-readable measurements are retained under
`/private/tmp/godot-native-env-growth.O7PktR`.

A retained-source rerun accumulated **55,923,840 bytes** in the environment
control and retained the entire counter increase after **60 seconds idle**.
The direct-RID control also reproduced on official Godot **4.7.0**, accumulating
13,980,800 bytes over 80 skies and emitting the same 160 × 87,380-byte warnings.
The revised default single-environment control still reproduces its original
two warnings. Every row completed normally without an earlier parse error;
see `retained-matrix.log` and its three named logs in that evidence directory.

The smaller `direct_sky.gd` also runs **without the editor**:

```sh
CONTROL_CLEAR=immediate /path/to/Godot --path /path/to/disposable-copy \
  --script res://direct_sky.gd --rendering-method gl_compatibility --verbose
```

It creates eight sky RIDs, marks their radiance size dirty, frees them and
quits after three seconds. On 4.7.2 this adds 1,398,080 counter bytes and emits
16 × 87,380-byte warnings; `CONTROL_CLEAR=deferred` adds zero and emits none.
Both runs exit normally. Logs: `direct-game-immediate.log` and
`direct-game-deferred.log`. The same immediate-free result also passed the
normal-exit reproduction checks on 4.7.0 (`direct-game-floor.log`).
This removes the remaining editor/test-runner
context from the reproduction; no Godot AI code is present.

### Source-supported hypothesis, not a validated engine patch

The pinned [4.7.2 GLES sky implementation](https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/gles3/rasterizer_scene_gles3.cpp#L543)
adds changed skies to a raw-pointer dirty list. Its
[free path](https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/gles3/rasterizer_scene_gles3.cpp#L4051)
releases existing sky textures and the RID without visibly unlinking that list;
the later dirty pass allocates radiance and raw-radiance textures. This supports
the hypothesis that a sky freed before that pass leaves stale queued work.
The direct-RID reproduction and size-dependent increments fit that mechanism;
an instrumented engine or reviewed fix is still needed to verify it.

The [GLES utility counters](https://github.com/godotengine/godot/blob/4.7.2-stable/drivers/gles3/storage/utilities.cpp#L411)
come from allocation caches, and the destructor reports entries remaining in
those same caches. Do not equate the printed number with an independent driver
measurement or assert that the impact is harmless.

Next disposition: engine review and a justified correction/explicit release
decision. No upstream issue or engine fix is claimed by this document. No
production workaround, diagnostic suppression or gate waiver was introduced.
