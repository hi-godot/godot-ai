@tool
extends AnimationNodeBlendTree

static var setter_calls := 0

@export var custom_value := 1.0:
	set(value):
		custom_value = value
		setter_calls += 1
