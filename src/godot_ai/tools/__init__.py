"""MCP tool modules.

`DEFER_META` marks a tool as deferred-loading for clients using Anthropic
tool search. Core tools (always loaded: editor_state, scene_get_hierarchy,
node_get_properties, session_list, session_activate) omit it.
"""

DEFER_META: dict[str, object] = {"defer_loading": True}
