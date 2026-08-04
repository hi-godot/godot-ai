# Vision Routing

Vision Routing lets models without image support (e.g. DeepSeek) still "see"
the editor and the running game. When enabled, every single-image capture made through the
`editor_screenshot` tool is sent to a curated vision model on a worker thread,
and the resulting **text description** is returned to the AI instead of the raw
image.

The feature is implemented natively in the plugin (`vision_routing.gd`) and is
off by default. It is opt-in per editor installation; the enabled flag and the
API key live in **Editor Settings**, so they are not committed with the
project.

## Providers

The provider and its model are **curated** - the model id is fixed per provider
and shown in brackets in the Provider dropdown, so switching providers can
never silently call the wrong model:

| Provider | Model | Dialect | Free tier |
| --- | --- | --- | --- |
| Groq | `qwen/qwen3.6-27b` | OpenAI chat-completions | Yes |
| Google Gemini | `gemini-2.5-flash` | generateContent (REST) | Yes (AI Studio key) |
| xAI Grok | `grok-4.5` | OpenAI chat-completions | No (paid) |

Each provider has its own encrypted key slot and its own environment-variable
override: `GROQ_API_KEY`, `GOOGLE_API_KEY` and `XAI_API_KEY`. The environment
variable always takes priority over the stored key. Changing the provider in
the dropdown switches the key field to that provider's stored key.

## Why

Most MCP clients used with godot-ai can consume image blocks. Some cannot
(DeepSeek and other text-only models reject or ignore them). With routing on,
the screenshot tool stays useful for those models: the image is replaced by a
tiny 2x2 placeholder, and the description is delivered as text metadata
(`vision_description`, plus a `note` that the server forwards into the tool
result's text block).

## How it works

1. The AI calls `editor_screenshot` (any `source`), optionally passing a
   `user_prompt` with context that is sent to the vision model alongside the
   image.
2. The plugin captures the frame exactly as before.
3. If routing is enabled, the image is sent to the selected provider's model
   (see [Providers](#providers)) on a background thread - the editor main
   thread never blocks.
4. The response is deferred until the description is ready; the payload the
   model receives contains:
   - `vision_description`: the text description.
   - `note`: the description (plus any pre-existing note, e.g. stale-frame).
   - `routed_via`: `provider:model` (e.g. `groq:qwen/qwen3.6-27b`), so the
     client knows the capture was routed and by which model.
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
3. Pick a provider in the **Provider** dropdown (the model it will use is
   shown in brackets, e.g. `Google Gemini (gemini-2.5-flash)`).
4. Paste the key for that provider (Groq: <https://console.groq.com>, Google:
   <https://aistudio.google.com>, xAI: <https://console.x.ai>). Each provider
   keeps its own key slot. Keys are stored encrypted (AES-256-CBC, key derived
   from this machine) in Editor Settings - not plain text, but local
   obfuscation only. Alternatively set `GROQ_API_KEY`, `GOOGLE_API_KEY` or
   `XAI_API_KEY`; the environment variable takes priority over the stored key.
5. Press **Test connection** to verify the key works.

A quick **Vision Routing** toggle also sits in the dock right under
**Developer mode**, so you can flip routing on/off without opening the settings
window (e.g. when you switch from a text-only model to one that analyzes
images itself).

## Notes

- The vision call adds ~1-2s to each screenshot while routing is enabled.
- Screenshots are downscaled to at most 1024px on the longest edge before
  being sent to the provider.
- If you stop using a key that was typed into the settings window, consider
  rotating it in the provider console - an encrypted-at-rest key is still
  local obfuscation, not a secret vault.
- Routing only applies when the connected model is expected to be text-only;
  keep it off for image-capable models to avoid the extra hop.
- Metadata-only captures (`include_image=false`) are still routed and still
  pay the vision call - for a text-only model that is the point, since the
  description is what makes the capture readable. Image-capable clients that
  only want capture metadata should turn routing off.

## Developer notes

- `plugin/addons/godot_ai/vision_routing.gd` - routing core, per-provider
  workers (OpenAI chat-completions + Gemini generateContent dialects),
  encrypted key storage, UI construction. The `PROVIDERS` constant is the
  single place where provider/model pairs are curated.
- Hook points: `editor_handler.gd::take_screenshot` (editor captures) and
  `mcp_debugger_plugin.gd::_on_screenshot_response` (game captures).
- Server-side metadata forwarding: `src/godot_ai/handlers/editor.py`.
- Tests: `tests/unit/test_runtime_handlers.py` (routed metadata + image-block
  omission) and `test_project/tests/test_vision_routing.gd` (key storage,
  prompt, deferred-reply conversion).
