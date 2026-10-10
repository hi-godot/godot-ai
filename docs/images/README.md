# docs/images manifest

Some assets in this directory are referenced from OUTSIDE the repo, so a
repo-wide grep finding zero references does NOT mean an image is safe to
delete (#716 audit note). Check this manifest first.

All "External" claims below were verified against the live AssetLib listing
(`https://godotengine.org/asset-library/api/asset/5050`) on 2026-07-13 — the
listing hotlinks `raw.githubusercontent.com/hi-godot/godot-ai/main/...` URLs,
so deleting (or moving) any of them breaks the store page immediately.

| File | Used by |
| --- | --- |
| `assetlib.png` | `README.md` |
| `blockarena.gif` | `README.md` |
| `blockgame.png` | **External**: preview image on AssetLib asset 5050. Dereferenced from the README by #94, but the store listing still hotlinks it — #725 briefly deleted it, which 404'd that preview until this restore. Safe to delete only after the listing drops the preview. |
| `community-addons.png` | `docs/community-addons.md`: Addons tab captured in Godot 4.7.2 at 150% editor scale. |
| `community-addons-tools.png` | `docs/community-addons.md`: Tools tab discovery shortcut captured in Godot 4.7.2 at 100% editor scale. |
| `dock.png` | **External**: preview image on the frozen v3 AssetLib asset 5050. It intentionally remains available but is no longer embedded in the v4 README because it depicts the v1/v3-era dock. |
| `huddemo.gif` | `README.md` |
| `store-hero.png` | **External**: preview image on AssetLib asset 5050 (see commit 46ba62a). |
| `saveslots.png` | **External**: preview image on AssetLib asset 5050. |
| `../hero.png` | **External**: first preview image on AssetLib asset 5050. |
| `../icon.png` | **External**: the AssetLib asset 5050 listing icon (`icon_url`). |

When adding an image used only by an external listing, record it here.
