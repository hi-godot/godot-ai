@tool
class_name MyTestResource
extends Resource

## Throwaway fixture for the custom class_name Resource tests.
## Lives under test_project/tests/ but does NOT start with `test_`, so the
## suite runner ignores it as a suite; Godot still registers the global
## class_name so the tests can reference MyTestResource by type.

@export var label: String = ""

## Sub-resource slot used by the nested-`__class__` shortcut tests: a generic
## Resource slot so a custom class_name Resource can be nested under it.
@export var sub: Resource = null
