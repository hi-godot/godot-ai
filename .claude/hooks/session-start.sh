#!/usr/bin/env bash
# Claude Code on the web: install dev deps + headless Godot so MCP tools work.
# Idempotent — safe to re-run; cached artifacts are reused after the first session.
#
# Runs in async mode: the session starts immediately while this bootstraps in
# the background. Cold-start race window is ~60s (pip + Godot download), warm
# is ~15s (editor launch). Quick readiness checks before firing dependent
# commands:
#   - venv:    test -x .venv/bin/pytest
#   - godot:   command -v godot
#   - editor:  pgrep -f 'godot.*--editor' >/dev/null
#   - server:  curl -sf -o /dev/null http://127.0.0.1:8000/mcp -X POST \
#                -H 'Content-Type: application/json' \
#                -H 'Accept: application/json, text/event-stream' \
#                -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"check","version":"1"}}}'
echo '{"async": true, "asyncTimeout": 300000}'

set -euo pipefail

# Only run inside Claude Code on the web. Local sessions already have setup-dev.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "$CLAUDE_PROJECT_DIR"

GODOT_VERSION="4.6.2"
GODOT_CACHE="$HOME/.cache/godot-ai"
GODOT_BIN="$GODOT_CACHE/godot"
GODOT_ZIP="Godot_v${GODOT_VERSION}-stable_linux.x86_64.zip"
GODOT_EXE="Godot_v${GODOT_VERSION}-stable_linux.x86_64"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/${GODOT_ZIP}"

echo "[godot-ai session-start] running script/setup-dev..."
script/setup-dev

if [ ! -x "$GODOT_BIN" ]; then
  echo "[godot-ai session-start] downloading Godot ${GODOT_VERSION}..."
  mkdir -p "$GODOT_CACHE"
  curl -fsSL -o "$GODOT_CACHE/godot.zip" "$GODOT_URL"
  unzip -q -o "$GODOT_CACHE/godot.zip" -d "$GODOT_CACHE"
  mv "$GODOT_CACHE/${GODOT_EXE}" "$GODOT_BIN"
  chmod +x "$GODOT_BIN"
  rm -f "$GODOT_CACHE/godot.zip"
else
  echo "[godot-ai session-start] reusing cached Godot at $GODOT_BIN"
fi

mkdir -p "$HOME/.local/bin"
ln -sf "$GODOT_BIN" "$HOME/.local/bin/godot"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$CLAUDE_ENV_FILE"

echo "[godot-ai session-start] importing test_project assets..."
"$GODOT_BIN" --headless --path test_project --import \
  > /tmp/godot-import.log 2>&1 || \
  echo "[godot-ai session-start] WARN: godot --import returned non-zero (see /tmp/godot-import.log)"

# Skip starting the editor if a session is already running on :8000.
if curl -sf -o /dev/null -X POST \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"hook","version":"1.0"}}}' \
    http://127.0.0.1:8000/mcp; then
  echo "[godot-ai session-start] MCP server already running on :8000"
else
  echo "[godot-ai session-start] launching headless Godot editor (plugin auto-spawns MCP server on :8000)..."
  nohup "$GODOT_BIN" --headless --path test_project --editor \
    > /tmp/godot-editor.log 2>&1 &
  disown
fi

echo "[godot-ai session-start] done"
