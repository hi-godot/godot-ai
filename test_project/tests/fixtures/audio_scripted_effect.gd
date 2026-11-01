@tool
extends AudioEffectCompressor

static var setter_calls := 0

@export var custom_gain := 1.0:
	set(value):
		custom_gain = value
		setter_calls += 1
