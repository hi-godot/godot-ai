@tool
class_name McpAllowHosts
extends RefCounted

## Client-side helpers for the `--allow-host` LAN opt-in (#507, server core
## in #421). Pure static functions only — no EditorSettings, no sockets —
## so the settings-value → launch-args plumbing and the manual-command LAN
## URL builder are deterministically testable without a live editor.
##
## Accepted syntax mirrors the server's `parse_allow_hosts`
## (src/godot_ai/transport/origin_guard.py): each token is a bare IP
## (IPv4 or IPv6) or a CIDR, comma-separated. Host bits set on a CIDR are
## tolerated server-side (`strict=False`), so we only validate the IP part
## and the prefix length here — anything else fails loudly at server
## startup, which the dock-side validation exists to pre-empt.


## Canonicalize a comma-separated allow-host value: whitespace-stripped,
## deduplicated, sorted. Returns "" for a value with no usable tokens so
## callers can skip appending `--allow-host` entirely (keeps spawns
## compatible with pre-#421 servers — same contract as
## `ClientConfigurator.excluded_domains()`).
static func normalize(raw: String) -> String:
	var parts := PackedStringArray()
	for p in raw.split(","):
		var t := p.strip_edges()
		if not t.is_empty() and parts.find(t) == -1:
			parts.append(t)
	parts.sort()
	return ",".join(parts)


## Whether a single token is a bare IP or a CIDR the server will accept.
static func token_is_valid(token: String) -> bool:
	var t := token.strip_edges()
	if t.is_empty():
		return false
	var ip := t
	var prefix := 0
	## Track slash presence separately from the prefix value: reusing -1 as
	## the "no slash" sentinel let an explicit negative prefix like
	## "10.0.0.0/-1" validate (is_valid_int accepts "-1"). CodeRabbit review.
	var has_prefix := false
	var slash := t.find("/")
	if slash != -1:
		ip = t.substr(0, slash)
		var prefix_text := t.substr(slash + 1)
		if not prefix_text.is_valid_int():
			return false
		prefix = int(prefix_text)
		has_prefix = true
	if not ip.is_valid_ip_address():
		return false
	var max_prefix := 128 if ip.contains(":") else 32
	return not has_prefix or (prefix >= 0 and prefix <= max_prefix)


## Every token in `raw` that fails `token_is_valid` — the dock surfaces
## these inline so a typo is caught before it aborts the server spawn.
static func invalid_tokens(raw: String) -> PackedStringArray:
	var bad := PackedStringArray()
	for p in raw.split(","):
		var t := p.strip_edges()
		if t.is_empty():
			continue
		if not token_is_valid(t) and bad.find(t) == -1:
			bad.append(t)
	return bad


## True when the allowlist names at least one non-loopback range — i.e.
## the server is actually reachable off this machine and the manual
## command should surface a LAN URL.
static func is_lan_allowlist_active(value: String) -> bool:
	for p in value.split(","):
		var t := p.strip_edges()
		if t.is_empty():
			continue
		var ip := t.substr(0, t.find("/")) if t.contains("/") else t
		if not _is_loopback(ip):
			return true
	return false


## Choose the LAN address to show in the manual command from the
## machine's local addresses (caller passes `IP.get_local_addresses()`
## so this stays pure). Loopback and link-local addresses are dropped;
## the first private-range IPv4 wins, then any remaining IPv4, then
## anything left (IPv6). Returns `{"address": String, "ambiguous": bool}`
## — `ambiguous` flags multiple viable candidates so the note can tell
## the user to pick the interface on their trusted network.
static func pick_lan_address(addresses: PackedStringArray) -> Dictionary:
	var candidates := PackedStringArray()
	for a in addresses:
		var addr := String(a).strip_edges()
		if addr.is_empty() or _is_loopback(addr) or _is_link_local(addr):
			continue
		candidates.append(addr)
	if candidates.is_empty():
		return {"address": "", "ambiguous": false}
	var chosen := ""
	for addr in candidates:
		if _is_private_ipv4(addr):
			chosen = addr
			break
	if chosen.is_empty():
		for addr in candidates:
			if addr.contains("."):
				chosen = addr
				break
	if chosen.is_empty():
		chosen = candidates[0]
	return {"address": chosen, "ambiguous": candidates.size() > 1}


## Informational LAN-URL note appended to the manual command when the
## allowlist is active (#507). Never changes what gets WRITTEN to client
## configs — loopback stays the write target; this is copy-paste help for
## pointing a remote agent at the right address.
static func lan_url_note(allow_hosts_value: String, addresses: PackedStringArray, http_port: int) -> String:
	if not is_lan_allowlist_active(allow_hosts_value):
		return ""
	var pick := pick_lan_address(addresses)
	var addr := String(pick.get("address", ""))
	if addr.is_empty():
		return (
			"LAN access is enabled (--allow-host %s), but no LAN address was detected on this machine."
			% allow_hosts_value
		)
	var host := "[%s]" % addr if addr.contains(":") else addr
	var note := (
		"LAN access is enabled (--allow-host %s). Remote agents on the allowed network can use: http://%s:%d/mcp"
		% [allow_hosts_value, host, http_port]
	)
	if bool(pick.get("ambiguous", false)):
		note += "\n(multiple network interfaces detected — pick the address on the network you allowed)"
	return note


static func _is_loopback(addr: String) -> bool:
	var a := addr.to_lower()
	return a.begins_with("127.") or a == "::1" or a == "localhost"


static func _is_link_local(addr: String) -> bool:
	var a := addr.to_lower()
	if a.begins_with("169.254."):
		return true
	## IPv6 link-local is fe80::/10 — the whole fe80-febf first hextet, not
	## just literal "fe80" (Copilot review on #507's PR: fea0::... etc. must
	## also be excluded from LAN-URL candidates).
	if a.length() >= 4 and a.begins_with("fe") and a[2] in "89ab":
		return true
	return false


static func _is_private_ipv4(addr: String) -> bool:
	if not addr.contains("."):
		return false
	if addr.begins_with("10.") or addr.begins_with("192.168."):
		return true
	if addr.begins_with("172."):
		var second := int(addr.get_slice(".", 1))
		return second >= 16 and second <= 31
	return false
