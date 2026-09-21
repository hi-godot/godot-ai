@tool
extends Node

## Retained capsule path: Godot can finish an old parser's dependency list
## while loading the new plugin. Migration is complete in the canonical tree;
## the verified capsule carries the active implementation at this same path.
func start() -> void:
	queue_free()
