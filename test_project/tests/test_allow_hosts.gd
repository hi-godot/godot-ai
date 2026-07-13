@tool
extends McpTestSuite

const PluginScript := preload("res://addons/godot_ai/plugin.gd")

## Deterministic tests for the `--allow-host` LAN opt-in plumbing (#507):
## the pure McpAllowHosts helpers (value normalization, token validation,
## LAN-address pick, manual-command LAN URL note) and the
## EditorSetting → `_build_server_flags` launch-args path. The Settings-tab
## UI itself is live-verified in the editor.

## Snapshot the user's live allow-hosts setting at suite entry so the
## set/clear dance below can't leave the editor exposing a range the user
## never opted into if a test fails mid-flight.
var _saved_allow_hosts: Variant = null
var _had_allow_hosts_setting := false


func suite_name() -> String:
	return "allow_hosts"


func suite_setup(_ctx: Dictionary) -> void:
	var es := EditorInterface.get_editor_settings()
	if es != null and es.has_setting(McpSettings.SETTING_ALLOW_HOSTS):
		_had_allow_hosts_setting = true
		_saved_allow_hosts = es.get_setting(McpSettings.SETTING_ALLOW_HOSTS)


func suite_teardown() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		return
	if _had_allow_hosts_setting:
		es.set_setting(McpSettings.SETTING_ALLOW_HOSTS, _saved_allow_hosts)
	elif es.has_setting(McpSettings.SETTING_ALLOW_HOSTS):
		es.erase(McpSettings.SETTING_ALLOW_HOSTS)


# ----- normalize -----

func test_normalize_strips_dedupes_and_sorts() -> void:
	var normalized := McpAllowHosts.normalize(" 192.168.1.0/24 ,10.0.0.5, 192.168.1.0/24 ,, ")
	assert_eq(normalized, "10.0.0.5,192.168.1.0/24")


func test_normalize_empty_and_whitespace_only() -> void:
	assert_eq(McpAllowHosts.normalize(""), "")
	assert_eq(McpAllowHosts.normalize(" , ,  "), "")


# ----- token validation (mirrors server parse_allow_hosts) -----

func test_valid_tokens() -> void:
	for token in ["192.168.1.50", "192.168.1.0/24", "10.0.0.0/8", "::1", "fd00::/8", "fe80::1/64", "192.168.1.5/24"]:
		assert_true(McpAllowHosts.token_is_valid(token), "expected valid: %s" % token)


func test_invalid_tokens() -> void:
	for token in ["", "example.com", "192.168.1", "192.168.1.0/33", "::1/129", "10.0.0.0/abc", "not-an-ip/24", "10.0.0.0/-1", "::1/-8"]:
		assert_false(McpAllowHosts.token_is_valid(token), "expected invalid: %s" % token)


func test_invalid_tokens_reports_offenders_only() -> void:
	var bad := McpAllowHosts.invalid_tokens("192.168.1.0/24, example.com, 10.0.0.5, 1.2.3.4/40")
	assert_eq(bad.size(), 2)
	assert_true(bad.has("example.com"))
	assert_true(bad.has("1.2.3.4/40"))


# ----- LAN allowlist detection -----

func test_loopback_only_allowlist_is_not_lan_active() -> void:
	assert_false(McpAllowHosts.is_lan_allowlist_active(""))
	assert_false(McpAllowHosts.is_lan_allowlist_active("127.0.0.1"))
	assert_false(McpAllowHosts.is_lan_allowlist_active("127.0.0.0/8,::1"))


func test_non_loopback_allowlist_is_lan_active() -> void:
	assert_true(McpAllowHosts.is_lan_allowlist_active("192.168.1.0/24"))
	assert_true(McpAllowHosts.is_lan_allowlist_active("127.0.0.1,10.0.0.5"))


# ----- LAN address pick -----

func test_pick_prefers_private_ipv4_and_skips_loopback_link_local() -> void:
	var pick := McpAllowHosts.pick_lan_address(PackedStringArray(
		["127.0.0.1", "::1", "169.254.10.10", "fe80::1", "fea0::1", "192.168.1.50"]
	))
	assert_eq(String(pick["address"]), "192.168.1.50")
	assert_false(bool(pick["ambiguous"]))


func test_pick_flags_ambiguity_with_multiple_candidates() -> void:
	var pick := McpAllowHosts.pick_lan_address(PackedStringArray(["10.0.0.7", "192.168.1.50"]))
	assert_eq(String(pick["address"]), "10.0.0.7")
	assert_true(bool(pick["ambiguous"]))


func test_pick_returns_empty_when_only_loopback() -> void:
	var pick := McpAllowHosts.pick_lan_address(PackedStringArray(["127.0.0.1", "::1"]))
	assert_eq(String(pick["address"]), "")


func test_pick_falls_back_to_public_ipv4_then_ipv6() -> void:
	var ipv4 := McpAllowHosts.pick_lan_address(PackedStringArray(["203.0.113.9"]))
	assert_eq(String(ipv4["address"]), "203.0.113.9")
	var ipv6 := McpAllowHosts.pick_lan_address(PackedStringArray(["fd12:3456::1"]))
	assert_eq(String(ipv6["address"]), "fd12:3456::1")


# ----- manual-command LAN URL note -----

func test_lan_url_note_names_lan_url() -> void:
	var note := McpAllowHosts.lan_url_note(
		"192.168.1.0/24",
		PackedStringArray(["127.0.0.1", "192.168.1.50"]),
		8000
	)
	assert_contains(note, "http://192.168.1.50:8000/mcp")
	assert_contains(note, "--allow-host 192.168.1.0/24")


func test_lan_url_note_brackets_ipv6() -> void:
	var note := McpAllowHosts.lan_url_note(
		"fd00::/8", PackedStringArray(["fd12:3456::1"]), 8000
	)
	assert_contains(note, "http://[fd12:3456::1]:8000/mcp")


func test_lan_url_note_empty_when_allowlist_empty_or_loopback_only() -> void:
	assert_eq(McpAllowHosts.lan_url_note("", PackedStringArray(["192.168.1.50"]), 8000), "")
	assert_eq(McpAllowHosts.lan_url_note("127.0.0.1", PackedStringArray(["192.168.1.50"]), 8000), "")


func test_lan_url_note_mentions_ambiguity() -> void:
	var note := McpAllowHosts.lan_url_note(
		"10.0.0.0/8", PackedStringArray(["10.0.0.7", "192.168.1.50"]), 8000
	)
	assert_contains(note, "multiple network interfaces")


# ----- setting → launch-args plumbing -----

func test_allow_host_flag_appended_when_setting_non_empty() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("no EditorSettings in this context")
		return
	es.set_setting(McpSettings.SETTING_ALLOW_HOSTS, "192.168.1.0/24, 10.0.0.5")
	var flags := PluginScript._build_server_flags(8000, 9500)
	var idx := flags.find("--allow-host")
	assert_gt(idx, -1, "expected --allow-host in server flags: %s" % str(flags))
	assert_eq(flags[idx + 1], "10.0.0.5,192.168.1.0/24")


func test_allow_host_flag_absent_when_setting_empty() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("no EditorSettings in this context")
		return
	es.set_setting(McpSettings.SETTING_ALLOW_HOSTS, "")
	var flags := PluginScript._build_server_flags(8000, 9500)
	assert_eq(flags.find("--allow-host"), -1, "empty setting must not emit --allow-host: %s" % str(flags))


func test_configurator_allow_hosts_normalizes_setting() -> void:
	var es := EditorInterface.get_editor_settings()
	if es == null:
		skip("no EditorSettings in this context")
		return
	es.set_setting(McpSettings.SETTING_ALLOW_HOSTS, " 192.168.1.5 , 192.168.1.5 ")
	assert_eq(McpClientConfigurator.allow_hosts(), "192.168.1.5")


func test_signed_and_empty_prefixes_rejected() -> void:
	## Parity with the server's parse_allow_hosts: ipaddress refuses
	## explicit signs ("10.0.0.0/+8") and empty prefixes, but GDScript's
	## is_valid_int accepts "+8" — the mirror must reject them too.
	assert_false(McpAllowHosts.token_is_valid("10.0.0.0/+8"))
	assert_false(McpAllowHosts.token_is_valid("10.0.0.0/-1"))
	assert_false(McpAllowHosts.token_is_valid("10.0.0.0/"))
	assert_true(McpAllowHosts.token_is_valid("10.0.0.0/8"))
