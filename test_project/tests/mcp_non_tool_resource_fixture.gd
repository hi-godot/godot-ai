class_name McpNonToolResource
extends Resource

## Throwaway fixture WITHOUT @tool. In the editor context (where the MCP plugin
## and the test suite run), GDScript.can_instantiate() returns false for a
## non-@tool script, so _instantiate_resource() must report it as WRONG_TYPE
## (non-instantiable) — mirroring the built-in abstract path — rather than
## INTERNAL_ERROR.
##
## Like mcp_resource_fixture.gd, the filename does NOT start with `test_`, so the
## suite runner ignores it as a suite while Godot still registers the global
## class_name so the tests can reference McpNonToolResource by type.
