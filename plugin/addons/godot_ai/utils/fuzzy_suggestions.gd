@tool
extends RefCounted

## Shared fuzzy ranking for typo suggestions.


static func rank(
	needle: String,
	candidates: Array,
	limit: int = 5,
	threshold: float = 0.4,
	substring_bonus: float = 0.5,
	prefix_bonus: float = 1.0
) -> Array[String]:
	if needle.is_empty() or candidates.is_empty():
		return []
	var needle_lower := needle.to_lower()
	var scored: Array = []
	for raw_candidate in candidates:
		var candidate := str(raw_candidate)
		var candidate_lower := candidate.to_lower()
		var score := needle.similarity(candidate)
		if prefix_bonus != 0.0 and candidate_lower.begins_with(needle_lower):
			score += prefix_bonus
		elif substring_bonus != 0.0 and (
			candidate_lower.contains(needle_lower) or needle_lower.contains(candidate_lower)
		):
			score += substring_bonus
		if score >= threshold:
			scored.append([score, candidate])
	scored.sort_custom(func(a, b):
		if a[0] == b[0]:
			return a[1] < b[1]
		return a[0] > b[0]
	)
	var result: Array[String] = []
	for index in range(min(limit, scored.size())):
		result.append(scored[index][1])
	return result
