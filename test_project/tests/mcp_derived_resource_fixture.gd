@tool
class_name McpDerivedResource
extends MyTestResource

## Two-level fixture (McpDerivedResource -> MyTestResource -> Resource) for the
## multi-level parent_class / deep-introspection get_info tests. Like the other
## mcp_*_fixture.gd files, the name does NOT start with `test_`, so the suite
## runner ignores it while Godot still registers the global class_name.

@export var extra: int = 0
