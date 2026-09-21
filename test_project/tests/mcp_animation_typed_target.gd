@tool
extends Node3D

## Test fixture: typed properties no stock node exposes, so the animation
## coercion and interpolation regressions can target a real property.
## `cell` is the Vector3i destination for the int32-range test; `quat` is the
## Quaternion destination for the rotation-contract test.

@export var cell: Vector3i = Vector3i.ZERO
@export var quat: Quaternion = Quaternion.IDENTITY
