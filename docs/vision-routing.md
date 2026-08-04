# Vision Routing

Vision Routing lets models without image support (e.g. DeepSeek) still "see"
the editor and the running game. When enabled, every capture made through the
`editor_screenshot` tool is sent to Groq's free vision API on a worker thread,
and the resulting **text description** is returned to the AI instead of the raw
image.

The feature is implemented natively in the plugin (`vision_routing.gd`) and is
off by default. It is opt-in per editor installation; the enabled flag and the
API key live in **Editor Settings**, so they are not committed with the
project.

## Why

Most MCP clients used with godot-ai can consume image blocks. Some cannot
(DeepSeek and other text-only models reject or ignore them). With routing on,
the screenshot tool stays useful for those models: the image is replaced by a
tiny 2x2 placeholder, and the description is delivered as text metadata
(`vision_description`, plus a `note` that the server forwards into the tool
result's text block).

## How it works

1. The AI calls `editor_screenshot` (any `source`).
2. The plugin captures the frame exactly as before.
3. If routing is enabled, the image is sent to
   `qwen/qwen3.6-27b` on Groq (free tier) on a background thread - the editor
   main thread never blocks.
4. The response is deferred until the description is ready; the payload the
   model receives contains:
   - `vision_description`: the Groq description.
   - `note`: the description (plus any pre-existing note, e.g. stale-frame).
   - `routed_via`: the model id, so the client knows the capture was routed.
   - `image_base64`: a 2x2 transparent placeholder PNG (kept so the payload
     stays well-formed; the server omits the image block for routed captures).
5. Any failure (missing key, network error, API error) passes the **original
   image through unchanged** - the screenshot tool never breaks.

The same flow applies to editor viewport / cinematic / 2D captures and to
running-game captures (`source="game"`, which are intercepted in the debugger
plugin).

Coverage sweeps (`coverage=true`, multiple images) are passed through
untouched - routing applies to single-image captures.

## Setup

1. Open the Godot AI dock -> **Clients & Tools** -> **Vision Routing** tab.
2. Toggle **Enable routing** on.
3. Paste a Groq API key (free tier: <https://console.groq.com>). The key is
   stored encrypted (AES-256-CBC, key derived from this machine) in Editor
   Settings - not plain text, but local obfuscation only. Alternatively set
   the `GROQ_API_KEY` environment variable; it takes priority over the stored
   key.
4. Press **Test connection** to verify the key works.

A quick **Vision Routing** toggle also sits in the dock right under
**Developer mode**, so you can flip routing on/off without opening the settings
window (e.g. when you switch from a text-only model to one that analyzes
images itself).

## Notes

- The Groq call adds ~1-2s to each screenshot while routing is enabled.
- Screenshots are downscaled to at most 1024px on the longest edge before
  being sent to Groq.
- If you stop using a key that was typed into the settings window, consider
  rotating it in the Groq console - an encrypted-at-rest key is still local
  obfuscation, not a secret vault.
- Routing only applies when the connected model is expected to be text-only;
  keep it off for image-capable models to avoid the extra hop.

## Developer notes

- `plugin/addons/godot_ai/vision_routing.gd` - routing core, Groq worker,
  encrypted key storage, UI construction.
- Hook points: `editor_handler.gd::take_screenshot` (editor captures) and
  `mcp_debugger_plugin.gd::_on_screenshot_response` (game captures).
- Server-side metadata forwarding: `src/godot_ai/handlers/editor.py`.
- Tests: `tests/unit/test_runtime_handlers.py` (routed metadata + image-block
  omission) and `test_project/tests/test_vision_routing.gd` (key storage,
  prompt, deferred-reply conversion).