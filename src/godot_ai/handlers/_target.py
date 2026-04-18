"""Shared helper for the common path/property/resource_path/overwrite params
every resource-authoring tool takes.

Matches the plugin-side `ResourceIO.validate_home` convention: tools that
instantiate or edit a Godot Resource expose the same four optional
target-location parameters, and omit the empty/default ones from the
outgoing command dict so the plugin sees a clean `{path, property}` *or*
`{resource_path, overwrite}` shape.
"""

from __future__ import annotations


def target_params(
    path: str,
    property: str,
    resource_path: str,
    overwrite: bool,
) -> dict:
    """Return a dict of only the non-default target-location params."""
    params: dict = {}
    if path:
        params["path"] = path
    if property:
        params["property"] = property
    if resource_path:
        params["resource_path"] = resource_path
    if overwrite:
        params["overwrite"] = overwrite
    return params
