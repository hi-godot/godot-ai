#!/usr/bin/env python3
"""Select and pin the Godot editor session used by shell CI runners.

The ci-* scripts may be run locally against a server shared by several editor
worktrees.  A lone session is not automatically trustworthy: the configured
MCP URL can point at an unrelated project.  This helper keeps the selection and
path-normalization policy in one place so every shell runner fails closed in
the same way.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


def _normalized_project_path(raw: str) -> str:
    """Return a comparison form for a Godot or shell-reported project path."""

    value = raw.strip().replace("\\", "/")
    if os.name == "nt":
        # Git Bash reports ``/c/path`` while Godot reports ``C:/path``.
        match = re.match(r"^/([A-Za-z])(?:/(.*))?$", value)
        if match:
            suffix = match.group(2) or ""
            value = f"{match.group(1)}:/{suffix}"

    resolved = Path(value).expanduser().resolve(strict=False)
    return os.path.normcase(os.path.normpath(str(resolved))).replace("\\", "/")


def _read_object() -> dict[str, Any]:
    try:
        payload = json.load(sys.stdin)
    except json.JSONDecodeError as exc:
        raise ValueError(f"session response is not valid JSON: {exc}") from exc
    if not isinstance(payload, dict):
        raise ValueError("session response must be a JSON object")
    return payload


def _sessions(payload: dict[str, Any]) -> list[dict[str, Any]]:
    sessions = payload.get("sessions")
    if not isinstance(sessions, list):
        raise ValueError("session response is missing a sessions array")
    if not all(isinstance(session, dict) for session in sessions):
        raise ValueError("session response contains a non-object session")
    return sessions


def _print_sessions(sessions: list[dict[str, Any]]) -> None:
    print("Connected sessions:", file=sys.stderr)
    if not sessions:
        print("  (none)", file=sys.stderr)
        return
    for session in sessions:
        session_id = session.get("session_id", "?")
        project_path = session.get("project_path", "?")
        print(f"  {session_id}  {project_path}", file=sys.stderr)


def _select_session(payload: dict[str, Any], *, expected_project: str, explicit_pin: str) -> str:
    sessions = _sessions(payload)

    if explicit_pin:
        matches = [session for session in sessions if session.get("session_id") == explicit_pin]
        if len(matches) != 1:
            print(
                f"ERROR: GODOT_AI_SESSION_ID={explicit_pin!r} is not connected.",
                file=sys.stderr,
            )
            _print_sessions(sessions)
            raise SystemExit(1)
        return explicit_pin

    if len(sessions) != 1:
        if not sessions:
            print("ERROR: no Godot session is connected.", file=sys.stderr)
        else:
            print(
                f"ERROR: {len(sessions)} Godot sessions are connected; "
                "refusing to guess which one to drive.",
                file=sys.stderr,
            )
        _print_sessions(sessions)
        if sessions:
            print(
                "Re-run with GODOT_AI_SESSION_ID set to the one you mean.",
                file=sys.stderr,
            )
        raise SystemExit(1)

    selected = sessions[0]
    session_id = selected.get("session_id")
    project_path = selected.get("project_path")
    if not isinstance(session_id, str) or not session_id:
        raise ValueError("connected session is missing a non-empty session_id")
    if not isinstance(project_path, str) or not project_path:
        raise ValueError("connected session is missing a non-empty project_path")

    expected_normalized = _normalized_project_path(expected_project)
    actual_normalized = _normalized_project_path(project_path)
    if actual_normalized != expected_normalized:
        print(
            "ERROR: the only connected Godot session belongs to a different project; "
            "refusing to drive it.",
            file=sys.stderr,
        )
        print(f"Expected project:  {expected_project}", file=sys.stderr)
        print(f"Connected project: {project_path}", file=sys.stderr)
        _print_sessions(sessions)
        print(
            "Check MCP_SERVER_URL, or set GODOT_AI_SESSION_ID explicitly if this "
            "cross-project target is intentional.",
            file=sys.stderr,
        )
        raise SystemExit(1)

    return session_id


def _pin_args(payload: dict[str, Any], *, session_id: str) -> dict[str, Any]:
    existing = payload.get("session_id")
    if existing not in (None, "", session_id):
        raise ValueError(
            f"tool arguments already target session_id={existing!r}, "
            f"not selected session {session_id!r}"
        )
    payload["session_id"] = session_id
    return payload


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    select = subparsers.add_parser("select")
    select.add_argument("--expected-project", required=True)
    select.add_argument("--pin", default="")

    pin_args = subparsers.add_parser("pin-args")
    pin_args.add_argument("--session-id", required=True)
    return parser


def main() -> int:
    args = _build_parser().parse_args()
    try:
        payload = _read_object()
        if args.command == "select":
            print(
                _select_session(
                    payload,
                    expected_project=args.expected_project,
                    explicit_pin=args.pin,
                )
            )
        else:
            print(json.dumps(_pin_args(payload, session_id=args.session_id), separators=(",", ":")))
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
