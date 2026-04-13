"""Unit tests for MCP resource definitions."""

from __future__ import annotations

import pytest

from godot_ai.resources.project import COMMON_SETTINGS
from godot_ai.server import create_server


@pytest.fixture
def mcp():
    return create_server(ws_port=0)


class TestResourceRegistration:
    """Verify all expected resources are registered on the server."""

    async def _resource_uris(self, mcp) -> set[str]:
        if hasattr(mcp, "list_resources"):
            resources = await mcp.list_resources()
        else:
            resources = await mcp.get_resources()

        return {str(getattr(resource, "uri", resource)) for resource in resources}

    async def test_sessions_resource_registered(self, mcp):
        assert "godot://sessions" in await self._resource_uris(mcp)

    async def test_scene_current_resource_registered(self, mcp):
        assert "godot://scene/current" in await self._resource_uris(mcp)

    async def test_scene_hierarchy_resource_registered(self, mcp):
        assert "godot://scene/hierarchy" in await self._resource_uris(mcp)

    async def test_selection_current_resource_registered(self, mcp):
        assert "godot://selection/current" in await self._resource_uris(mcp)

    async def test_project_info_resource_registered(self, mcp):
        assert "godot://project/info" in await self._resource_uris(mcp)

    async def test_project_settings_resource_registered(self, mcp):
        assert "godot://project/settings" in await self._resource_uris(mcp)

    async def test_logs_recent_resource_registered(self, mcp):
        assert "godot://logs/recent" in await self._resource_uris(mcp)

    async def test_total_resource_count(self, mcp):
        assert len(await self._resource_uris(mcp)) == 7


class TestCommonSettingsList:
    """Verify the common settings list is sensible."""

    def test_includes_project_name(self):
        assert "application/config/name" in COMMON_SETTINGS

    def test_includes_viewport_size(self):
        assert "display/window/size/viewport_width" in COMMON_SETTINGS
        assert "display/window/size/viewport_height" in COMMON_SETTINGS

    def test_includes_rendering_method(self):
        assert "rendering/renderer/rendering_method" in COMMON_SETTINGS

    def test_at_least_five_settings(self):
        assert len(COMMON_SETTINGS) >= 5
