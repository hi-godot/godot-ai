# Physics shape follow-ups

## Deferred-worker lifecycle (PR #1040)

The `resource_manage(op="physics_shape_generate")` capability shipped in v4.0.4 through PR #1028, superseding PR #892 and resolving the core request from issue #868. The lifecycle follow-up does not change that API, its transform and validation rules, or its single-action undo/redo behavior.

The remaining defect was in the deferred driver. It was not registered with the process-wide `ScriptWork` ledger, so plugin script replacement could begin while its coroutine still owned old handler code. A lost connection could also end the frame loop without rolling back bodies created before the disconnect.

The driver now registers before its first frame yield and releases the registration on every normal or early exit. If the request is abandoned or its connection disappears before the undo action is committed, it removes and frees every partially created body. Once the action is committed, connection loss only drops the unavailable reply; the completed scene change and its undo history remain intact.

The driver also re-checks the scene root and each planned mesh and parent for validity before touching them. A node freed between frames therefore fails the request immediately with an error reply and a rollback, instead of raising a freed-instance error out of the coroutine and holding the work lease until the dispatcher timeout.

Regression coverage exercises the real driver through partial creation and synchronous connection exit, dispatcher abandonment, script-quiescence refusal and release, successful single-action undo/redo, invalid or detached reply targets after a completed commit, and a planned mesh, its parent or the scene root freed while the job is in flight.

## Generate options (issue #1053, items 1-3 and 7)

`physics_shape_generate` now accepts:

- `shape_type`: `box | sphere | capsule | cylinder | convex | trimesh` (or the
  matching class name). `convex` derives a `ConvexPolygonShape3D` hull from the
  mesh with `Mesh.create_convex_shape()`; `trimesh` derives a
  `ConcavePolygonShape3D` with `Mesh.create_trimesh_shape()`. Both bake the
  mesh's own scale into their vertices and keep the generated
  `CollisionShape3D` at an identity transform, so Godot never has to scale a
  hull or concave shape. A mesh with no faces fails the whole request before
  any mutation. `trimesh` is refused for `rigid` and `character` bodies — a
  concave shape only simulates on a static body or an area — and both hull
  types are refused under a non-uniformly scaled parent chain, like the round
  primitives.
- `body_type`: `static | area | rigid | character`.
- `reparent_mesh` (default `false`): when true the mesh moves under the
  generated body — `Body → [MeshInstance3D, CollisionShape3D]` — with its world
  transform preserved, so moving the body moves the visual. Undo restores the
  mesh's original parent, sibling index, transform and owner, and a failed
  batch restores any mesh it had already wrapped. `top_level` meshes are
  refused because their transform ignores the parent chain. In this mode the
  response's `mesh_path` is the post-move path
  (`/Parent/<Mesh>Collider/<Mesh>`).

Small generated collision offsets below `1e-6` snap to zero, so a centered
`CapsuleMesh` no longer leaves a `1.19e-07` Y offset in the transform.

Still open in issue #1053, intentionally out of scope here: `overwrite`,
mesh-class-aware auto-selection, and expanding inline sub-resources in
`node_get_properties`.
