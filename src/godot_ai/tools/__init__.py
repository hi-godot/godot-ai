"""MCP tool modules.

`DEFER_META` marks a tool as deferred-loading for clients using Anthropic
tool search. Core tools (always loaded: editor_state, scene_get_hierarchy,
node_get_properties, session_list, session_activate) omit it.

`JsonCoerced` is a pydantic `BeforeValidator` that JSON-decodes string
inputs before list/dict validation runs. Some MCP clients (Claude Code
as of 2026-04) stringify complex-typed tool arguments before sending
them over the wire, so a `list[dict]` parameter arrives as its JSON
representation. Annotating such params with this validator lets the
tool accept both the real structure and the stringified form. See #11.
"""

from __future__ import annotations

import json
from typing import Any

from pydantic import BeforeValidator

DEFER_META: dict[str, object] = {"defer_loading": True}


def _coerce_json(value: Any) -> Any:
    if isinstance(value, str):
        try:
            return json.loads(value)
        except json.JSONDecodeError:
            return value
    return value


JsonCoerced = BeforeValidator(_coerce_json)
