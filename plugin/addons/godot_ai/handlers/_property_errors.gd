@tool
class_name McpPropertyErrors
extends RefCounted

## Shared helper for building "Property not found" error messages that include
## "did you mean" suggestions and a tail of available property names. All
## handlers that validate user-supplied property names against a target Object
## (Node, Resource, …) should route through build_message() so agents get
## consistent, actionable errors on typos.
##
## Ranking combines Godot's built-in String.similarity() with a substring
## bonus so both "radus" → "radius" (edit distance) and "top" → "top_radius"
## (substring) surface naturally.

const _SIMILARITY_THRESHOLD: float = 0.4
const _SUBSTRING_BONUS: float = 0.5
const _MAX_SUGGESTIONS: int = 5
const _MAX_TAIL: int = 10


static func build_message(target: Object, bad_name: String) -> String:
	if target == null:
		return "Property '%s' not found" % bad_name
	var class_label := _class_label(target)
	var available := _available_property_names(target)
	if available.is_empty():
		return "Property '%s' not found on %s" % [bad_name, class_label]

	var msg := "Property '%s' not found on %s" % [bad_name, class_label]
	var suggestions := _rank_suggestions(bad_name, available)
	if not suggestions.is_empty():
		msg += ". Did you mean: %s?" % ", ".join(suggestions)

	var tail_names := available.slice(0, min(_MAX_TAIL, available.size()))
	msg += " (available: %s" % ", ".join(tail_names)
	if available.size() > tail_names.size():
		msg += ", ..."
	msg += ")"
	return msg


## Prefer a scripted class_name if the target has one, else the engine class.
static func _class_label(target: Object) -> String:
	var scr := target.get_script()
	if scr != null and scr.has_method("get_global_name"):
		var gcn: String = scr.get_global_name()
		if not gcn.is_empty():
			return gcn
	return target.get_class()


## Editor-visible properties, alphabetised, with internal/category entries dropped.
static func _available_property_names(target: Object) -> Array:
	var names: Array = []
	for p in target.get_property_list():
		var usage: int = int(p.get("usage", 0))
		if (usage & PROPERTY_USAGE_EDITOR) == 0:
			continue
		var name: String = p.get("name", "")
		if name.is_empty() or name.begins_with("_"):
			continue
		names.append(name)
	names.sort()
	return names


static func _rank_suggestions(bad: String, available: Array) -> Array:
	if bad.is_empty():
		return []
	var bad_lower := bad.to_lower()
	var scored: Array = []
	for n in available:
		var score: float = bad.similarity(n)
		if n.to_lower().find(bad_lower) != -1 or bad_lower.find(n.to_lower()) != -1:
			score += _SUBSTRING_BONUS
		if score >= _SIMILARITY_THRESHOLD:
			scored.append([score, n])
	scored.sort_custom(func(a, b): return a[0] > b[0])
	var result: Array = []
	for i in range(min(_MAX_SUGGESTIONS, scored.size())):
		result.append(scored[i][1])
	return result
