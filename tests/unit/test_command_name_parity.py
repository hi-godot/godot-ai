"""Contract test: every command Python sends is registered by the plugin.

The WebSocket command namespace (~135 names) is duplicated between the
Python handlers' ``send_command("<name>", ...)`` literals and plugin.gd's
``_dispatcher.register("<name>", ...)`` literals with no compiler on either
side of the wire. A typo'd or renamed command on one side only surfaces at
runtime as UNKNOWN_COMMAND — and the Python unit suite's StubClient answers
ANY command, so unit tests can't catch it.

The contract is one-way: Python-sent ⊆ plugin-registered. The plugin may
register commands Python doesn't call by literal (e.g. rollup-internal
names dispatched via batch_execute payloads); that asymmetry is fine.

Audit backlog item (S3 · tests). Style per test_error_code_parity.py.
"""

from __future__ import annotations

import functools
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PLUGIN_GD = REPO_ROOT / "plugin" / "addons" / "godot_ai" / "plugin.gd"
PYTHON_SRC = REPO_ROOT / "src" / "godot_ai"

## Multiline-aware: `register(\n\t"name"` and `send_command(\n    "name"`
## both match — \s* spans the newline.
_REGISTER_RE = re.compile(r'\.register\(\s*"([a-z0-9_]+)"')
_SEND_RE = re.compile(r'send_command\(\s*"([a-z0-9_]+)"')


@functools.cache
def _registered_plugin_commands() -> frozenset[str]:
    return frozenset(_REGISTER_RE.findall(PLUGIN_GD.read_text(encoding="utf-8")))


@functools.cache
def _python_sent_commands() -> frozenset[str]:
    names: set[str] = set()
    for path in sorted(PYTHON_SRC.rglob("*.py")):
        names.update(_SEND_RE.findall(path.read_text(encoding="utf-8")))
    return frozenset(names)


def test_extraction_is_non_vacuous() -> None:
    # Guard the test itself: a regex regression returning near-nothing
    # would let the subset assertion below pass vacuously.
    registered = _registered_plugin_commands()
    sent = _python_sent_commands()
    assert len(registered) > 100, (
        f"only {len(registered)} register() literals parsed from plugin.gd; "
        f"check _REGISTER_RE against the current registration style"
    )
    assert len(sent) > 50, (
        f"only {len(sent)} send_command() literals parsed from src/godot_ai; "
        f"check _SEND_RE against the current call style"
    )


def test_every_python_sent_command_is_registered_by_plugin() -> None:
    unknown = sorted(_python_sent_commands() - _registered_plugin_commands())
    assert not unknown, (
        f"Python sends commands plugin.gd never registers — these fail at "
        f"runtime as UNKNOWN_COMMAND and the StubClient-based unit tests "
        f"can't catch them: {unknown}"
    )
