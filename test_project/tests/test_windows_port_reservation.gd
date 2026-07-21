@tool
extends McpTestSuite

## Tests for McpWindowsPortReservation — netsh output parsing and the
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
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8000),
		"8000 sits at the start of [8000, 8099]"
	)
	assert_true(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8050),
		"8050 is inside [8000, 8099]"
	)
	assert_true(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8099),
		"8099 sits at the end of [8000, 8099]"
	)


func test_parse_accepts_single_port_range() -> void:
	assert_true(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 80),
		"80 is a single-port range [80, 80]"
	)
	assert_true(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 5040),
		"5040 is a single-port range"
	)


func test_parse_returns_false_outside_ranges() -> void:
	assert_false(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 79),
		"79 is below the lowest range"
	)
	assert_false(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 100),
		"100 is between [80,80] and [5040,5040]"
	)
	assert_false(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 8100),
		"8100 is one past the end of [8000, 8099]"
	)


func test_parse_ignores_headers_and_footers() -> void:
	# Any line whose first token isn't an integer must be skipped. The
	# header rows ("Start Port", "----------", "* - Administered ...")
	# all fit this — the parser shouldn't blow up or falsely match.
	assert_false(
		McpWindowsPortReservation.parse_excluded(SAMPLE_NETSH_OUTPUT, 0),
		"port 0 should not match even though headers contain '0'"
	)


func test_parse_empty_input_returns_false() -> void:
	assert_false(McpWindowsPortReservation.parse_excluded("", 8000))
	assert_false(McpWindowsPortReservation.parse_excluded("\n\n", 8000))


func test_cache_miss_before_first_store() -> void:
	McpWindowsPortReservation._clear_cache_for_tests()
	var cached := McpWindowsPortReservation._get_cached_excluded_output()
	assert_false(bool(cached.get("hit", false)), "an empty cache must miss")
	assert_eq(str(cached.get("text", "")), "")


func test_cache_hit_lasts_for_the_session() -> void:
	## winnat's excluded ranges are set at boot, so the cache is
	## session-lifetime: once stored, netsh (~250ms per spawn) must never
	## re-run for this editor session. The old 2s TTL re-paid it on every
	## startup walk.
	McpWindowsPortReservation._clear_cache_for_tests()
	McpWindowsPortReservation._store_excluded_output(SAMPLE_NETSH_OUTPUT)
	var cached := McpWindowsPortReservation._get_cached_excluded_output()
	assert_true(bool(cached.get("hit", false)), "stored netsh output should be reused for the whole session")
	assert_eq(str(cached.get("text", "")), SAMPLE_NETSH_OUTPUT)
	McpWindowsPortReservation._clear_cache_for_tests()


func test_cache_clear_removes_stored_output() -> void:
	McpWindowsPortReservation._store_excluded_output(SAMPLE_NETSH_OUTPUT)
	McpWindowsPortReservation._clear_cache_for_tests()
	var cached := McpWindowsPortReservation._get_cached_excluded_output()
	assert_false(bool(cached.get("hit", false)), "clearing the cache should remove stored output")
	assert_eq(str(cached.get("text", "")), "")


func test_cached_output_serves_queries_without_netsh() -> void:
	## Windows-only: exercises the real is_port_excluded /
	## suggest_non_excluded_port entry points against a seeded cache and
	## proves neither respawns netsh (the query counter is the same seam
	## the startup trace reads).
	if OS.get_name() != "Windows":
		skip("Windows-only netsh path")
		return
	McpWindowsPortReservation._clear_cache_for_tests()
	McpWindowsPortReservation._store_excluded_output(SAMPLE_NETSH_OUTPUT)
	var before := McpWindowsPortReservation.netsh_query_count()
	assert_true(
		McpWindowsPortReservation.is_port_excluded(8050),
		"8050 sits inside the seeded [8000, 8099] range"
	)
	assert_eq(
		McpWindowsPortReservation.suggest_non_excluded_port(8000, 2048),
		8100,
		"suggestion should skip the seeded [8000, 8099] range"
	)
	assert_eq(
		McpWindowsPortReservation.netsh_query_count(),
		before,
		"session-cached output must serve both queries without a netsh spawn"
	)
	McpWindowsPortReservation._clear_cache_for_tests()


func test_parse_excluded_ranges_extracts_ranges() -> void:
	var ranges := McpWindowsPortReservation.parse_excluded_ranges(SAMPLE_NETSH_OUTPUT)
	assert_true(ranges.has(Vector2i(80, 80)), "single-port range should be preserved")
	assert_true(ranges.has(Vector2i(8000, 8099)), "multi-port range should be preserved")
	assert_true(ranges.has(Vector2i(50000, 50059)), "high range should be preserved")


# ----- suggest_non_excluded_port_from_output -----

func test_suggest_non_excluded_port_skips_reserved_ranges() -> void:
	var output := """
Protocol tcp Port Exclusion Ranges

Start Port    End Port
----------    --------
    9491          9590
    9591          9690
    9691          9790

* - Administered port exclusions.
"""
	assert_eq(
		McpWindowsPortReservation.suggest_non_excluded_port_from_output(output, 9501, 2048),
		9791,
		"fallback should skip every reserved range that follows the configured WS port",
	)


func test_suggest_non_excluded_port_returns_start_when_available() -> void:
	assert_eq(
		McpWindowsPortReservation.suggest_non_excluded_port_from_output(SAMPLE_NETSH_OUTPUT, 8100, 100),
		8100,
		"unreserved start port should be returned unchanged",
	)


func test_suggest_non_excluded_port_falls_back_when_span_exhausted() -> void:
	var output := """
Protocol tcp Port Exclusion Ranges

Start Port    End Port
----------    --------
    9501          9503
"""
	assert_eq(
		McpWindowsPortReservation.suggest_non_excluded_port_from_output(output, 9501, 3),
		9501,
		"if every candidate is reserved, preserve the existing fallback behavior",
	)
