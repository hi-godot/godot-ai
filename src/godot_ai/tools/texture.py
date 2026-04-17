"""MCP tools for procedural texture authoring (gradient + noise)."""

from __future__ import annotations

from fastmcp import Context, FastMCP

from godot_ai.handlers import texture as texture_handlers
from godot_ai.runtime.direct import DirectRuntime
from godot_ai.tools import DEFER_META


def register_texture_tools(mcp: FastMCP) -> None:
    @mcp.tool(meta=DEFER_META)
    async def gradient_texture_create(
        ctx: Context,
        stops: list,
        width: int = 256,
        height: int = 1,
        fill: str = "linear",
        path: str = "",
        property: str = "",
        resource_path: str = "",
        overwrite: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create a GradientTexture2D wrapping a Gradient from color stops.

        Builds the Gradient resource with the provided (offset, color) stops,
        wraps it in a GradientTexture2D, and either assigns it to a node
        property (undoable, bundles both resources in one action) or saves it
        to a .tres file.

        Common target properties: Line2D.texture, Sprite2D.texture, TextureRect.texture.

        Args:
            stops: List of {"offset": float, "color": {"r","g","b","a"} or "#rrggbb"}
                ordered by offset. Minimum 2 stops.
            width: Texture width in pixels. Default 256.
            height: Texture height in pixels. Default 1 (strip).
            fill: Fill mode — "linear", "radial", or "square". Default "linear".
            path: Scene path of the target node.
            property: Property name on that node.
            resource_path: res:// destination (.tres). Mutually exclusive with path.
            overwrite: Allow replacing an existing file at resource_path.
            session_id: Optional Godot session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await texture_handlers.gradient_texture_create(
            runtime,
            stops=stops,
            width=width,
            height=height,
            fill=fill,
            path=path,
            property=property,
            resource_path=resource_path,
            overwrite=overwrite,
        )

    @mcp.tool(meta=DEFER_META)
    async def noise_texture_create(
        ctx: Context,
        noise_type: str = "simplex_smooth",
        width: int = 512,
        height: int = 512,
        frequency: float = 0.01,
        seed: int = 0,
        fractal_octaves: int = 0,
        path: str = "",
        property: str = "",
        resource_path: str = "",
        overwrite: bool = False,
        session_id: str = "",
    ) -> dict:
        """Create a NoiseTexture2D wrapping a FastNoiseLite for procedural textures.

        Useful for terrain heightmaps, cloud/smoke masks, detail maps,
        organic-looking variation. Assigns to a node (undoable) or saves to
        .tres. NoiseTexture2D generates asynchronously in Godot; the texture
        resource is returned immediately and Godot fills the image data on its
        worker thread.

        Args:
            noise_type: "simplex", "simplex_smooth" (default), "perlin",
                "cellular", "value", or "value_cubic".
            width: Texture width in pixels. Default 512.
            height: Texture height in pixels. Default 512.
            frequency: FastNoiseLite frequency (larger = finer detail). Default 0.01.
            seed: Noise seed. Default 0.
            fractal_octaves: Optional fractal octaves (0 = leave default).
            path: Scene path of the target node.
            property: Property name on that node.
            resource_path: res:// destination (.tres).
            overwrite: Allow replacing an existing file.
            session_id: Optional Godot session.
        """
        runtime = DirectRuntime.from_context(ctx, session_id=session_id or None)
        return await texture_handlers.noise_texture_create(
            runtime,
            noise_type=noise_type,
            width=width,
            height=height,
            frequency=frequency,
            seed=seed,
            fractal_octaves=fractal_octaves,
            path=path,
            property=property,
            resource_path=resource_path,
            overwrite=overwrite,
        )
