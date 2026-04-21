@tool
extends McpTestSuite

## Tests for the Windows netstat parser in plugin.gd. These exercise
## the pure-string parsers (no OS interaction) to prove the fix for
## the bug where the parser iterated `output` as if each array element
## were a line — but Godot's `OS.execute` pushes the whole stdout into
## `output[0]` as a single string, so a substring match picked up
## `:PORT` on one row and `LISTENING` on an unrelated row, and the
## PID extractor returned the last whitespace-separated token in the
## entire dump (garbage).

const GodotAiPlugin := preload("res://addons/godot_ai/plugin.gd")


func suite_name() -> String:
	return "netstat_parser"


# ----- realistic Windows netstat -ano output -----

const NETSTAT_SAMPLE := """
Active Connections

  Proto  Local Address          Foreign Address        State           PID
  TCP    0.0.0.0:135            0.0.0.0:0              LISTENING       1240
  TCP    0.0.0.0:8000           0.0.0.0:0              LISTENING       57865
  TCP    0.0.0.0:3389           0.0.0.0:0              LISTENING       4
  TCP    127.0.0.1:49701        127.0.0.1:8000         ESTABLISHED     12345
  TCP    [::]:80                [::]:0                 LISTENING       980
  UDP    0.0.0.0:500            *:*                                    892
"""


func test_find_pid_returns_listening_row_for_port() -> void:
	var pid := GodotAiPlugin._parse_windows_netstat_pid(NETSTAT_SAMPLE, 8000)
	assert_eq(pid, 57865, "should return PID from the LISTENING row for :8000")


func test_find_pid_ignores_established_rows_matching_port() -> void:
	## Row 4 has :8000 in the Foreign Address column and state ESTABLISHED.
	## Old parser matched `:8000` anywhere, new one requires the LISTENING
	## column on the same row and the local address to end with :8000.
	var pid := GodotAiPlugin._parse_windows_netstat_pid(NETSTAT_SAMPLE, 8000)
	assert_true(pid != 12345, "must not return the ESTABLISHED row's PID")


func test_find_pid_returns_zero_when_port_absent() -> void:
	var pid := GodotAiPlugin._parse_windows_netstat_pid(NETSTAT_SAMPLE, 9999)
	assert_eq(pid, 0, "no LISTENING row for this port -> 0")


func test_find_pid_on_empty_output() -> void:
	assert_eq(GodotAiPlugin._parse_windows_netstat_pid("", 8000), 0)


func test_find_pid_on_garbage_output() -> void:
	var junk := "oops something went wrong\nno header\n"
	assert_eq(GodotAiPlugin._parse_windows_netstat_pid(junk, 8000), 0)


func test_find_pid_handles_leading_whitespace_per_line() -> void:
	## `netstat -ano` prints a two-space indent on every data row; the
	## parser must strip it before splitting columns.
	var sample := "  TCP    0.0.0.0:7070    0.0.0.0:0    LISTENING    42\n"
	assert_eq(GodotAiPlugin._parse_windows_netstat_pid(sample, 7070), 42)


func test_find_pid_rejects_non_integer_pid_column() -> void:
	## Guard against accidentally returning a truncated column header.
	var sample := "  TCP    0.0.0.0:8000    0.0.0.0:0    LISTENING    PID\n"
	assert_eq(GodotAiPlugin._parse_windows_netstat_pid(sample, 8000), 0)


func test_find_pid_ignores_port_substring_match() -> void:
	## :80 must not match :8000, and :80001 must not match :8000.
	var sample := (
		"  TCP    0.0.0.0:80      0.0.0.0:0    LISTENING    111\n"
		+ "  TCP    0.0.0.0:80001   0.0.0.0:0    LISTENING    222\n"
		+ "  TCP    0.0.0.0:8000    0.0.0.0:0    LISTENING    333\n"
	)
	assert_eq(GodotAiPlugin._parse_windows_netstat_pid(sample, 8000), 333)


func test_find_pid_matches_ipv6_listening() -> void:
	var sample := "  TCP    [::]:8000    [::]:0    LISTENING    777\n"
	assert_eq(GodotAiPlugin._parse_windows_netstat_pid(sample, 8000), 777)


func test_find_pid_matches_loopback_bind() -> void:
	var sample := "  TCP    127.0.0.1:8000    0.0.0.0:0    LISTENING    888\n"
	assert_eq(GodotAiPlugin._parse_windows_netstat_pid(sample, 8000), 888)


# ----- listening check -----

func test_is_listening_true_when_port_has_listener() -> void:
	assert_true(GodotAiPlugin._parse_windows_netstat_listening(NETSTAT_SAMPLE, 8000))


func test_is_listening_false_when_port_absent() -> void:
	assert_true(not GodotAiPlugin._parse_windows_netstat_listening(NETSTAT_SAMPLE, 9999))


func test_is_listening_false_on_empty_output() -> void:
	assert_true(not GodotAiPlugin._parse_windows_netstat_listening("", 8000))


func test_is_listening_ignores_established_remote_port_match() -> void:
	## The sample has an ESTABLISHED row with :8000 in the foreign column
	## and no LISTENING row for :7070 — make sure we don't say :7070 is
	## listening just because 7070 appears in ESTABLISHED somewhere.
	var sample := "  TCP    127.0.0.1:49701    127.0.0.1:7070    ESTABLISHED    321\n"
	assert_true(
		not GodotAiPlugin._parse_windows_netstat_listening(sample, 7070),
		"ESTABLISHED rows must not count as listeners for their foreign port",
	)


# ----- whitespace splitter -----

func test_split_collapses_runs_of_spaces() -> void:
	var fields := GodotAiPlugin._split_on_whitespace(
		"TCP    0.0.0.0:8000    0.0.0.0:0    LISTENING    57865"
	)
	assert_eq(fields.size(), 5)
	assert_eq(fields[0], "TCP")
	assert_eq(fields[1], "0.0.0.0:8000")
	assert_eq(fields[3], "LISTENING")
	assert_eq(fields[4], "57865")


func test_split_handles_tabs() -> void:
	var fields := GodotAiPlugin._split_on_whitespace("a\tb  c")
	assert_eq(fields.size(), 3)


func test_split_empty_string() -> void:
	var fields := GodotAiPlugin._split_on_whitespace("")
	assert_eq(fields.size(), 0)


# ----- pid-file round trip -----

func test_read_pid_file_missing_returns_zero() -> void:
	if FileAccess.file_exists(GodotAiPlugin.SERVER_PID_FILE):
		## Start from a known-empty state; some earlier test may have
		## left it behind.
		GodotAiPlugin._clear_pid_file()
	assert_eq(GodotAiPlugin._read_pid_file(), 0)


func test_read_pid_file_round_trip() -> void:
	var f := FileAccess.open(GodotAiPlugin.SERVER_PID_FILE, FileAccess.WRITE)
	assert_true(f != null, "should be able to write to user://")
	f.store_string("12345\n")
	f.close()
	assert_eq(GodotAiPlugin._read_pid_file(), 12345)
	GodotAiPlugin._clear_pid_file()
	assert_eq(GodotAiPlugin._read_pid_file(), 0, "clear should remove the file")


func test_read_pid_file_rejects_non_integer() -> void:
	var f := FileAccess.open(GodotAiPlugin.SERVER_PID_FILE, FileAccess.WRITE)
	f.store_string("not-a-pid")
	f.close()
	assert_eq(GodotAiPlugin._read_pid_file(), 0)
	GodotAiPlugin._clear_pid_file()


func test_read_pid_file_rejects_negative() -> void:
	var f := FileAccess.open(GodotAiPlugin.SERVER_PID_FILE, FileAccess.WRITE)
	f.store_string("-5")
	f.close()
	assert_eq(GodotAiPlugin._read_pid_file(), 0)
	GodotAiPlugin._clear_pid_file()


func test_read_pid_file_tolerates_whitespace() -> void:
	var f := FileAccess.open(GodotAiPlugin.SERVER_PID_FILE, FileAccess.WRITE)
	f.store_string("  98765  \n")
	f.close()
	assert_eq(GodotAiPlugin._read_pid_file(), 98765)
	GodotAiPlugin._clear_pid_file()
