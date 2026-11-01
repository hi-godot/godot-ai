"""The screenshot boundary budgets the complete MCP result, including coverage."""

import base64
import json
import re
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest
from mcp.types import CallToolResult

from godot_ai.godot_client.client import GodotCommandError
from godot_ai.handlers.editor import SCREENSHOT_RESULT_MAX_BYTES, editor_screenshot


def test_plugin_and_server_share_screenshot_result_budget():
    source = (
        Path(__file__).parents[2] / "plugin/addons/godot_ai/utils/screenshot_encode.gd"
    ).read_text(encoding="utf-8")
    expression = re.search(r"const SCREENSHOT_RESULT_MAX_BYTES := (.+)", source)[1]
    assert expression == "1024 * 1024 - 4096"
    assert SCREENSHOT_RESULT_MAX_BYTES == 1024 * 1024 - 4096


def _capture(image_size, coverage):
    image = {
        "source": "viewport",
        "width": 512,
        "height": 512,
        "original_width": 1024,
        "original_height": 1024,
        "format": "png",
        "image_base64": base64.b64encode(b"x" * image_size).decode(),
    }
    if coverage:
        return {
            "source": "viewport",
            "coverage": True,
            "images": [
                dict(image, label="establishing", elevation=25, azimuth=20, fov=50),
                dict(image, label="top", elevation=90, azimuth=0, fov=50, ortho=True),
            ],
        }
    return image


@pytest.mark.parametrize("coverage", [False, True])
async def test_screenshot_complete_content_fits_transport(coverage):
    png_budget = (SCREENSHOT_RESULT_MAX_BYTES - 64 * 1024) * 3 // 4
    runtime = SimpleNamespace(
        send_command=AsyncMock(
            return_value=_capture(png_budget // (2 if coverage else 1), coverage)
        )
    )
    blocks = await editor_screenshot(runtime, coverage=coverage, view_target="/Main/模型")
    content = [b.to_image_content() if hasattr(b, "to_image_content") else b for b in blocks]
    wire = CallToolResult(content=content).model_dump_json(by_alias=True).encode()
    assert len(wire) < SCREENSHOT_RESULT_MAX_BYTES
    assert len(content) == (3 if coverage else 2)
    metadata = json.loads(content[0].text)
    images = metadata["images"] if coverage else [metadata]
    assert all(image["width"] == 512 and image["original_width"] == 1024 for image in images)


@pytest.mark.parametrize("coverage", [False, True])
@pytest.mark.parametrize("oversized_metadata", [False, True])
async def test_oversized_screenshot_returns_actionable_error(coverage, oversized_metadata):
    runtime = SimpleNamespace(
        send_command=AsyncMock(
            return_value=_capture(100 if oversized_metadata else 800_000, coverage)
        )
    )
    with pytest.raises(GodotCommandError, match="lower max_resolution") as error:
        await editor_screenshot(
            runtime,
            coverage=coverage,
            view_target="模型" * 100_000 if oversized_metadata else "/Main",
        )
    assert error.value.data["response_bytes"] > SCREENSHOT_RESULT_MAX_BYTES
    assert error.value.data["max_bytes"] == SCREENSHOT_RESULT_MAX_BYTES
