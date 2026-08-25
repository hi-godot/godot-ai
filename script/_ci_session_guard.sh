#!/usr/bin/env bash
## Shared target-selection helpers for the shell ci-* runners.

_CI_SESSION_GUARD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ci_select_godot_session() { # sessions-json expected-project [explicit-pin]
  local sessions_json="$1"
  local expected_project="$2"
  local explicit_pin="${3:-}"
  printf '%s' "$sessions_json" | python3 \
    "$_CI_SESSION_GUARD_DIR/_ci_session_guard.py" select \
    --expected-project "$expected_project" \
    --pin "$explicit_pin"
}

ci_pin_tool_args() { # arguments-json selected-session-id
  local arguments_json="$1"
  local session_id="$2"
  printf '%s' "$arguments_json" | python3 \
    "$_CI_SESSION_GUARD_DIR/_ci_session_guard.py" pin-args \
    --session-id "$session_id"
}
