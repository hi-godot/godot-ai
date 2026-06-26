@tool
class_name McpToolNodeFixture
extends Node

## Throwaway fixture for the pre-construction base-type gate regression test.
## @tool + class_name + extends Node: in the editor context can_instantiate()
## returns true, so _instantiate_resource() must reject it via the native
## base-type check BEFORE calling scr.new(). The old construct-then-reject path
## ran _init() and then leaked the orphan Node it never frees (Node is not
## ref-counted). init_count proves whether _init() ran.
##
## Like the other mcp_*_fixture.gd files, the filename does NOT start with
## `test_`, so the suite runner ignores it as a suite while Godot still
## registers the global class_name so the test can reference it by type.

static var init_count: int = 0


func _init() -> void:
	init_count += 1
