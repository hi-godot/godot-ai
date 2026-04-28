class_name Repro
extends RefCounted

var injected_dict: Dictionary = {}

func say() -> String:
	return "v2: injected_dict.keys() = %s" % str(injected_dict.keys())
