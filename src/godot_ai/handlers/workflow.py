"""Shared handlers for agent workflow helpers (modeling, assets, visual QA).

These ops are intentionally composition-first: they use existing editor
commands (filesystem search, screenshots, editor state) rather than new
plugin WebSocket commands. Pure-guidance ops ignore the runtime connection
when no Godot session is required.

Exposed via the ``workflow_manage`` MCP rollup (domain id: ``workflow``).
"""

from __future__ import annotations

import asyncio
from typing import Any

from godot_ai.handlers import editor as editor_handlers
from godot_ai.handlers import filesystem as filesystem_handlers
from godot_ai.handlers import project as project_handlers
from godot_ai.runtime.direct import DirectRuntime

## Default visual-QA checklist — project-agnostic; callers may override.
_DEFAULT_CHECKLIST: tuple[str, ...] = (
    "Composition readable at play-camera distance",
    "Materials/textures intentional (not pure white or single flat color)",
    "Props sit on surfaces (no major floating or sinking)",
    "Lighting not over-blown; emission intentional",
    "UI readable; no debug clutter covering important art",
    "No obvious z-fighting or double geometry on surfaces",
)

_STYLE_GUIDANCE: dict[str, dict[str, Any]] = {
    "general_pbr": {
        "summary": "General-purpose PBR props and environments for Godot 4.",
        "silhouette": [
            "Readable massing at game camera distance before fine detail",
            "Avoid hairline spikes; thicken thin silhouettes for 3D readability",
        ],
        "naming": [
            "Mesh names describe role (Body, Trim, Glass, Collision if separate)",
            "Keep glTF node names stable — Godot material overrides key off names",
        ],
        "materials": [
            "Albedo + Normal + Roughness (AO optional); pack height in alpha when required",
            "Prefer StandardMaterial3D or ORM; avoid unique shaders until needed",
            "sRGB albedo, linear normal maps (OpenGL convention for Godot)",
        ],
        "poly_budget": [
            "Hero props: roughly 1k–8k tris depending on screen size",
            "Background clutter: under ~500 tris; use LODs for dense forests",
        ],
        "export": [
            "glTF 2.0 binary (.glb) preferred for single-file props",
            "Apply scale in Blender (unit = meter); Y-up; forward -Z",
            "Apply modifiers; freeze transforms before export",
        ],
    },
    "low_poly": {
        "summary": "Stylized low-poly assets with clear faceting.",
        "silhouette": [
            "Bold primary shapes; secondary bevels sparingly",
            "Canopy / foliage as clusters of simple solids, not leaf cards (unless intentional)",
        ],
        "naming": [
            "Prefix role: Trunk*, Canopy*, Rock*, Building*",
            "One mesh per material role when possible for runtime recolor",
        ],
        "materials": [
            "Flat or soft gradients; limited palette (3–5 colors per prop)",
            "Roughness high for rock/bark; mid for painted wood; low for crystals",
            "Emission only for hero glow states (power, magic, interactables)",
        ],
        "poly_budget": [
            "Trees: ~200–800 tris; buildings: modular pieces under ~1k each",
            "Prefer instances over unique high-density meshes",
        ],
        "export": [
            "glTF .glb; no subdivision surface modifiers left active",
            "Hard edges via auto-smooth or marked edges for faceted look",
        ],
    },
    "stylized_ethereal": {
        "summary": "Dreamy / ethereal stylized look (soft glow, cool rock, mint flora).",
        "silhouette": [
            "Soft organic forms and lobed foliage; avoid photoreal tree noise",
            "Floating or elevated forms need clear underside mass so they read as solid",
        ],
        "naming": [
            "Trees: Trunk* / Canopy* (classifiers often key off these substrings)",
            "Split walkable top vs cliff/side materials when both are visible",
        ],
        "materials": [
            "Bark: muted purple-brown, high roughness (~0.85–0.92)",
            "Leaves: mint/teal, mid roughness; soft emission for magical states",
            "Rock: cool grey-blue, not sandy warm beige",
            "Dead/desaturated vs restored theme-color emission when games use restore loops",
        ],
        "poly_budget": [
            "Stylized trees ~300–900 tris with 4–6 canopy lobes + short branches",
            "Keep cliff skirts separate from walkable tops when dual materials help",
        ],
        "export": [
            "glTF .glb; headless Blender pipelines work well for agent iteration",
            "Keep origin at base (characters/props) or logical center (islands/platforms)",
        ],
    },
}


def _normalize_style(style: str) -> str:
    key = (style or "general_pbr").strip().lower().replace("-", "_")
    if key in _STYLE_GUIDANCE:
        return key
    return "general_pbr"


async def workflow_modeling_guidance(
    runtime: DirectRuntime,
    style: str = "general_pbr",
    topic: str = "props",
) -> dict:
    """Return structured 3D modeling guidance for agent asset work.

    Does not require a live Godot write lock. ``runtime`` is accepted for
    manage-tool API consistency and may be unused.
    """
    del runtime  # pure guidance
    style_key = _normalize_style(style)
    guide = dict(_STYLE_GUIDANCE[style_key])
    guide["style"] = style_key
    guide["topic"] = topic or "props"
    guide["godot_notes"] = [
        "Godot 4.x Forward+; import .glb via EditorFileSystem",
        "Prefer runtime material overrides for state changes over many mesh variants",
        "Name meshes for classification (trunk vs canopy, cliff vs top)",
        "Keep collision simpler than render mesh (convex or trimmed trimesh)",
    ]
    guide["checklist"] = [
        "Silhouette readable at play camera distance",
        "Mesh names match material override conventions",
        "Scale is meters; player height ~1.7 m reference",
        "Exported .glb opens cleanly in Godot without missing buffers",
        "Materials not pure white/black; roughness set intentionally",
    ]
    return guide


async def workflow_asset_pipeline(
    runtime: DirectRuntime,
    path: str = "res://",
    limit: int = 80,
) -> dict:
    """Scan the project for common asset-pipeline signals."""
    root = path or "res://"
    if not root.startswith("res://"):
        root = "res://" + root.lstrip("/")

    glb = await filesystem_handlers.filesystem_search(runtime, name=".glb", path=root, limit=limit)
    gltf = await filesystem_handlers.filesystem_search(
        runtime, name=".gltf", path=root, limit=max(20, limit // 4)
    )
    blender = await filesystem_handlers.filesystem_search(
        runtime, name="blender", path=root, limit=40
    )
    pbr = await filesystem_handlers.filesystem_search(
        runtime, name=".jpg", path="res://assets", limit=limit
    )
    terrain = await filesystem_handlers.filesystem_search(
        runtime, name="terrain_3d", path="res://addons", limit=20
    )

    glb_files = list(glb.get("files") or [])
    gltf_files = list(gltf.get("files") or [])
    blender_hits = list(blender.get("files") or [])
    pbr_hits = list(pbr.get("files") or [])
    terrain_hits = list(terrain.get("files") or [])

    found = {
        "glb_count": len(glb_files),
        "gltf_count": len(gltf_files),
        "blender_path_hits": len(blender_hits),
        "pbr_jpg_hits": len(pbr_hits),
        "terrain3d_hits": len(terrain_hits),
        "sample_glb": glb_files[:12],
        "sample_blender": blender_hits[:8],
    }

    missing: list[str] = []
    recommendations: list[str] = []
    if found["glb_count"] + found["gltf_count"] == 0:
        missing.append("No .glb/.gltf under scan root")
        recommendations.append(
            "Add props via Blender glTF export or kitbash packs under res://assets/"
        )
    if found["blender_path_hits"] == 0:
        recommendations.append(
            "Optional: tools/blender (or similar) scripts help agents regenerate assets headlessly"
        )
    if found["pbr_jpg_hits"] == 0:
        recommendations.append(
            "Consider CC0 PBR maps (albedo/normal/roughness) under "
            "res://assets/pbr/ when using textured materials"
        )
    if found["terrain3d_hits"] == 0:
        recommendations.append(
            "Terrain3D not detected — use mesh heightfields or install "
            "Terrain3D for painted terrain"
        )
    else:
        recommendations.append(
            "Terrain3D present — prefer discrete regions/holes when the "
            "world should not be a continuous floor"
        )

    recommendations.append(
        "After asset changes: EditorFileSystem scan / reimport; smoke with project_run + screenshot"
    )

    return {
        "root": root,
        "found": found,
        "missing": missing,
        "recommendations": recommendations,
    }


async def workflow_screenshot_verify(
    runtime: DirectRuntime,
    source: str = "viewport",
    max_resolution: int = 800,
    include_image: bool = False,
    checklist: list[str] | None = None,
    view_target: str = "",
    elevation: float | None = None,
    azimuth: float | None = None,
    fov: float | None = None,
) -> dict:
    """Capture a screenshot and attach a structured visual checklist.

    Defaults to ``include_image=False`` so tool-capped clients get compact
    JSON metadata; set ``include_image=True`` when the agent must see pixels.
    Checklist items are returned as *pending agent review* (not auto-scored).
    """
    items = list(checklist) if checklist else list(_DEFAULT_CHECKLIST)
    capture = await editor_handlers.editor_screenshot(
        runtime,
        source=source,
        max_resolution=max_resolution,
        include_image=include_image,
        view_target=view_target,
        elevation=elevation,
        azimuth=azimuth,
        fov=fov,
    )

    # When include_image=True the editor handler may return a content-block list.
    if isinstance(capture, list):
        meta: dict[str, Any] = {"content_blocks": True, "block_count": len(capture)}
        for block in capture:
            if hasattr(block, "text"):
                try:
                    import json

                    meta.update(json.loads(block.text))
                except Exception:
                    meta["text_preview"] = str(getattr(block, "text", ""))[:200]
                break
        capture_out: Any = meta
    else:
        capture_out = capture

    checklist_results = [
        {
            "item": item,
            "status": "pending_agent_review",
            "hint": "Compare against the capture; mark pass/fail in your notes",
        }
        for item in items
    ]

    return {
        "capture": capture_out,
        "source": source,
        "checklist_results": checklist_results,
        "agent_instructions": (
            "Visually inspect the capture (or re-call with include_image=true). "
            "Update each checklist item to pass/fail with a one-line reason. "
            "For game-view QA, prefer source=game after project_run when helper_live."
        ),
    }


async def workflow_visual_qa(
    runtime: DirectRuntime,
    sources: list[str] | None = None,
    run_if_needed: bool = False,
    max_resolution: int = 640,
    include_image: bool = False,
) -> dict:
    """Multi-shot visual QA: optional play, then screenshots per source."""
    sources = sources or ["viewport"]
    state = await editor_handlers.editor_state(runtime)
    game_status = state.get("game_status") or {}
    helper_live = bool(state.get("helper_live") or game_status.get("helper_live"))
    is_playing = bool(state.get("is_playing"))

    ran = False
    if run_if_needed and not is_playing:
        await project_handlers.project_run(runtime, mode="main", autosave=True)
        ran = True
        # Wait briefly for helper liveness (best-effort; do not hang forever).
        for _ in range(20):
            await asyncio.sleep(0.5)
            state = await editor_handlers.editor_state(runtime)
            game_status = state.get("game_status") or {}
            helper_live = bool(state.get("helper_live") or game_status.get("helper_live"))
            is_playing = bool(state.get("is_playing"))
            if helper_live or not is_playing:
                break

    shots: list[dict[str, Any]] = []
    for src in sources:
        src_norm = (src or "viewport").strip().lower()
        if src_norm == "game" and not helper_live:
            shots.append(
                {
                    "source": src_norm,
                    "skipped": True,
                    "reason": "Game helper not live; project_run first or set run_if_needed=true",
                }
            )
            continue
        try:
            result = await workflow_screenshot_verify(
                runtime,
                source=src_norm,
                max_resolution=max_resolution,
                include_image=include_image,
            )
            shots.append({"source": src_norm, "skipped": False, "result": result})
        except Exception as exc:  # noqa: BLE001 — surface per-shot failures
            shots.append({"source": src_norm, "skipped": True, "reason": str(exc)})

    return {
        "ran_project": ran,
        "is_playing": is_playing,
        "helper_live": helper_live,
        "shots": shots,
        "summary": (
            f"{sum(1 for s in shots if not s.get('skipped'))} shot(s) captured; "
            f"{sum(1 for s in shots if s.get('skipped'))} skipped"
        ),
    }


async def workflow_install_hints(runtime: DirectRuntime) -> dict:
    """Return instructions to wire Godot AI into Grok Build and common installs."""
    del runtime
    return {
        "title": "Connect Godot AI to Grok Build (and related clients)",
        "mcp_url": "http://127.0.0.1:8000/mcp",
        "grok_config_toml": (
            '[mcp_servers.godot-ai]\nurl = "http://127.0.0.1:8000/mcp"\nenabled = true\n'
        ),
        "options": [
            {
                "name": "dock_configure",
                "steps": [
                    "Install the Godot AI plugin under res://addons/godot_ai and enable it",
                    "Open the Godot AI dock → Clients → Grok Build → Configure",
                    "Confirm ~/.grok/config.toml has [mcp_servers.godot-ai] with the MCP URL",
                    "Restart or reload Grok Build so it picks up the MCP server",
                ],
            },
            {
                "name": "manual_toml",
                "steps": [
                    "Create or edit ~/.grok/config.toml "
                    "(Windows: %USERPROFILE%\\.grok\\config.toml)",
                    'Add: [mcp_servers.godot-ai] url = "http://127.0.0.1:8000/mcp" enabled = true',
                    "Ensure the Godot editor is running with the plugin so the server is up",
                ],
            },
            {
                "name": "external_python_server",
                "steps": [
                    "From a godot-ai checkout: "
                    "python -m godot_ai --transport streamable-http --port 8000",
                    "Plugin adopts an existing server on :8000 when already listening",
                    "Point Grok at http://127.0.0.1:8000/mcp",
                ],
            },
            {
                "name": "dev_checkout_junction",
                "steps": [
                    "For local development, junction/symlink project addons/godot_ai → "
                    "checkout/plugin/addons/godot_ai so the plugin finds the fork .venv",
                    "Optional: set GODOT_AI_VENV_PYTHON to the checkout .venv python",
                    "Plugin versions with PEP 440 local tags (e.g. 3.0.2+local.1) pin uvx "
                    "to the base PyPI version; prefer the dev venv for extras not on PyPI",
                ],
            },
        ],
        "docs": [
            "README.md (install + clients)",
            "docs/TOOLS.md (workflow_manage ops)",
            "docs/port-conflicts.md (MCP URL / ports)",
        ],
    }
