@tool
extends McpTestSuite

## Tests for WindowsPortReservation — netsh output parsing and the
## output-signature → user-hint mapping. These don't touch the real OS
## (pure string parsing), so they run identically on every platform. See
## issue #146.


func suite_name() -> String:
	return "windows_port_reservation"


const SAMPLE_NETSH_OUTPUT := """
Protocol tcp Port Exclusion Ranges

Start Port    End Port
----------    --------
      80            80
    5040          5040
    8000          8099
   50000         50059

* - Administered port exclusions.
"""


# ----- parse_excluded -----

func test_parse_detects_port_inside_range() -> void:
	assert_true(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8000),
		"8000 sits at the start of [8000, 8099]"
	)
	assert_true(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8050),
		"8050 is inside [8000, 8099]"
	)
	assert_true(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8099),
		"8099 sits at the end of [8000, 8099]"
	)


func test_parse_accepts_single_port_range() -> void:
	assert_true(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 80),
		"80 is a single-port range [80, 80]"
	)
	assert_true(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 5040),
		"5040 is a single-port range"
	)


func test_parse_returns_false_outside_ranges() -> void:
	assert_false(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 79),
		"79 is below the lowest range"
	)
	assert_false(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 100),
		"100 is between [80,80] and [5040,5040]"
	)
	assert_false(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8100),
		"8100 is one past the end of [8000, 8099]"
	)


func test_parse_ignores_headers_and_footers() -> void:
	# Any line whose first token isn't an integer must be skipped. The
	# header rows ("Start Port", "----------", "* - Administered ...")
	# all fit this — the parser shouldn't blow up or falsely match.
	assert_false(
		WindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 0),
		"port 0 should not match even though headers contain '0'"
	)


func test_parse_empty_input_returns_false() -> void:
	assert_false(WindowsPortReservation.parse_excluded("", 8000))
	assert_false(WindowsPortReservation.parse_excluded("\n\n", 8000))


# ----- hint_from_output -----

func test_hint_matches_winerror_10013() -> void:
	var lines := PackedStringArray([
		"INFO:     Started server process [29096]",
		"ERROR:    [Errno 13] error while attempting to bind on address ('127.0.0.1', 8000):",
		"          [winerror 10013] an attempt was made to access a socket in a way forbidden by its access permissions",
		"INFO:     Application shutdown complete.",
	])
	var hint := WindowsPortReservation.hint_from_output(lines, 8000)
	assert_contains(hint, "winnat", "hint should recommend the winnat fix")
	assert_contains(hint, "Reconnect", "hint should tell the user what to do next")


func test_hint_matches_access_permissions_variant() -> void:
	# Lowercase variant — ensure the matcher isn't case-fragile.
	var lines := PackedStringArray([
		"error: FORBIDDEN BY ITS ACCESS PERMISSIONS",
	])
	var hint := WindowsPortReservation.hint_from_output(lines, 8000)
	assert_contains(hint, "winnat")


func test_hint_matches_port_in_use() -> void:
	var lines := PackedStringArray([
		"OSError: [Errno 98] Address already in use",
	])
	var hint := WindowsPortReservation.hint_from_output(lines, 8000)
	assert_contains(hint, "in use", "hint should call out port-in-use")


func test_hint_matches_modulenotfound() -> void:
	var lines := PackedStringArray([
		"ModuleNotFoundError: No module named 'godot_ai'",
	])
	var hint := WindowsPortReservation.hint_from_output(lines, 8000)
	assert_contains(hint, "uv cache clean", "hint should recommend cache clean")


func test_hint_empty_when_no_match() -> void:
	var lines := PackedStringArray([
		"Starting MCP server…",
		"INFO:     Application startup complete.",
	])
	assert_eq(WindowsPortReservation.hint_from_output(lines, 8000), "")


func test_hint_empty_for_empty_input() -> void:
	assert_eq(WindowsPortReservation.hint_from_output(PackedStringArray(), 8000), "")


func test_port_excluded_hint_interpolates_port() -> void:
	# Proactive-detection hint must use the caller's port (the plugin can
	# run on any port a user configured), not a hardcoded literal.
	assert_contains(WindowsPortReservation.port_excluded_hint(8001), "8001")
	assert_contains(WindowsPortReservation.port_excluded_hint(9500), "9500")
	assert_contains(WindowsPortReservation.port_excluded_hint(8001), "winnat")


func test_hint_from_output_agrees_with_proactive_hint() -> void:
	# The WinError-10013 branch of hint_from_output and the proactive
	# port_excluded_hint entry point must yield identical copy so the
	# user sees consistent guidance regardless of which path triggered.
	var lines := PackedStringArray(["[WinError 10013] forbidden..."])
	assert_eq(
		WindowsPortReservation.hint_from_output(lines, 8123),
		WindowsPortReservation.port_excluded_hint(8123)
	)
