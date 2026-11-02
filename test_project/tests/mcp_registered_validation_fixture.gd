@tool
class_name McpRegisteredValidationFixture
extends RefCounted

var retained_value := 7


func value() -> String:
	return "old"


static func make() -> McpRegisteredValidationFixture:
	return McpRegisteredValidationFixture.new()
