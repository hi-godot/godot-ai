@tool
extends Node

## Retained capsule dependency path. The canonical v4 tree has no embedded
## v3 fallback; keeping this path must never initiate a downgrade.
static func available() -> bool:
	return false


func start() -> void:
	queue_free()
