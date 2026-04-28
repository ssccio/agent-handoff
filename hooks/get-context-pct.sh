#!/usr/bin/env bash
# get-context-pct.sh
# Reads context % directly from the Claude Code transcript JSONL.
# No external dependencies beyond jq and the transcript file itself.
#
# Usage: get-context-pct.sh <transcript_path>
# Output: integer 0-100 on stdout, 0 on any error
#
# How it works:
#   Claude Code writes a JSONL transcript file where each line is a message.
#   Assistant messages include a message.usage field with token counts from the API:
#     { input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens }
#   Context window usage = input_tokens + cache_creation + cache_read (the tokens Claude
#   receives, not what it generates). Divide by context_window_size to get %.
#
#   We read the last 100 lines of the transcript (enough to find the most recent assistant
#   message) rather than the whole file, which may be several MB for long sessions.
#
# Fallback hierarchy:
#   1. Transcript JSONL (primary — no dependencies)
#   2. claude-hud context cache (if transcript unreadable and HUD is installed)
#   3. 0 (safe default — hook does not fire if context is unknown)

set -euo pipefail

TRANSCRIPT_PATH="${1:-}"
CONTEXT_WINDOW=200000  # All current Claude 4.x models: 200k tokens

# Validate transcript path
if [ -z "$TRANSCRIPT_PATH" ] || [ ! -f "$TRANSCRIPT_PATH" ]; then
  echo "0"
  exit 0
fi

# --- Primary: read from transcript JSONL ---
# Read last 100 lines — enough to find the most recent assistant message even in
# dense agentic runs with many sequential tool calls between assistant responses.
LAST_ASSISTANT=$(tail -n 100 "$TRANSCRIPT_PATH" 2>/dev/null | grep '"type":"assistant"' | tail -1 2>/dev/null || true)

if [ -n "$LAST_ASSISTANT" ]; then
  INPUT=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.usage.input_tokens // 0' 2>/dev/null || echo "0")
  CACHE_CREATE=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.usage.cache_creation_input_tokens // 0' 2>/dev/null || echo "0")
  CACHE_READ=$(printf '%s' "$LAST_ASSISTANT" | jq -r '.message.usage.cache_read_input_tokens // 0' 2>/dev/null || echo "0")

  if [[ "$INPUT" =~ ^[0-9]+$ ]] && [[ "$CACHE_CREATE" =~ ^[0-9]+$ ]] && [[ "$CACHE_READ" =~ ^[0-9]+$ ]]; then
    TOTAL=$(( INPUT + CACHE_CREATE + CACHE_READ ))
    PCT=$(( TOTAL * 100 / CONTEXT_WINDOW ))
    [ "$PCT" -gt 100 ] && PCT=100
    [ "$PCT" -lt 0 ] && PCT=0
    echo "$PCT"
    exit 0
  fi
fi

# --- Fallback: claude-hud context cache ---
# If transcript parse failed (no assistant messages yet, malformed line),
# try the HUD cache as a secondary source.
CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if command -v shasum >/dev/null 2>&1; then
  CACHE_HASH=$(printf '%s' "$TRANSCRIPT_PATH" | shasum -a 256 | cut -c1-64)
elif command -v sha256sum >/dev/null 2>&1; then
  CACHE_HASH=$(printf '%s' "$TRANSCRIPT_PATH" | sha256sum | cut -c1-64)
else
  echo "0"
  exit 0
fi

CACHE_FILE="$CLAUDE_CFG/plugins/claude-hud/context-cache/${CACHE_HASH}.json"
if [ -f "$CACHE_FILE" ]; then
  PCT=$(jq -r '(.used_percentage // 0) | floor' "$CACHE_FILE" 2>/dev/null || echo "0")
  echo "$PCT"
  exit 0
fi

# Unknown — return 0 (safe: hook does not fire)
echo "0"
