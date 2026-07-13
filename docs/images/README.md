# docs/images manifest

Some assets in this directory are referenced from OUTSIDE the repo, so a
repo-wide grep finding zero references does NOT mean an image is safe to
delete (#716 audit note). Check this manifest first.

| File | Used by |
| --- | --- |
| `assetlib.png` | `README.md` |
| `blockarena.gif` | `README.md` |
| `dock.png` | `README.md` |
| `huddemo.gif` | `README.md` |
| `store-hero.png` | **External**: hotlinked by the Godot AssetLib listing (asset 5050) — see commit 46ba62a. Deleting it breaks the store page. |
| `saveslots.png` | No in-repo reference. Believed to be used by the AssetLib listing; verify against the live listing before deleting. |
| `../icon.png` | No in-repo reference. Believed to be the AssetLib listing icon; verify against the live listing before deleting. |

Removed: `blockgame.png` (230 KB) — dereferenced from the README by #94,
no external listing claim.

When adding an image used only by an external listing, record it here.
