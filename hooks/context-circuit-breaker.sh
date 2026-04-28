#!/usr/bin/env bash
# context-circuit-breaker.sh
# PreToolUse hook: monitors context usage and blocks tool execution at threshold.
# Delegates context % reading to get-context-pct.sh (transcript JSONL, no HUD dependency).
# After /clear, auto-detects the pending restore via a marker file and triggers restore automatically.

set -euo pipefail

THRESHOLD=60
DEBOUNCE_MINUTES=10

STDIN=$(cat)

# Derive project slug + checkpoint dir early — needed for both pending-restore check and new checkpoints
SLUG=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || basename "$PWD")
SLUG=$(printf '%s' "$SLUG" | tr -cd 'a-zA-Z0-9._-')
[ -z "$SLUG" ] && SLUG="workspace"
CHECKPOINT_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/checkpoints/$SLUG"
mkdir -p "$CHECKPOINT_DIR"
PENDING_RESTORE_FILE="$CHECKPOINT_DIR/.pending-restore"

# FIRST: Check for pending-restore marker (written by a prior circuit-breaker fire before /clear).
# After /clear the user's next tool call lands here; we intercept it and trigger restore instead.
if [ -f "$PENDING_RESTORE_FILE" ]; then
  CHECKPOINT_PATH=$(cat "$PENDING_RESTORE_FILE")
  rm -f "$PENDING_RESTORE_FILE"
  jq -n --arg path "$CHECKPOINT_PATH" '{
    decision: "block",
    reason: ("⚠️  AUTO-RESTORE: Context was reset via /clear after a circuit breaker checkpoint.\n\nInvoke the checkpoint skill and run restore now. The checkpoint is at:\n\($path)\n\nRestore from that file, then continue from Remaining Work item 1 (skip Other Pending Work — those are separate projects).")
  }'
  exit 2
fi

# Read context % by delegating to get-context-pct.sh
# That script reads directly from the transcript JSONL — no HUD dependency.
TRANSCRIPT_PATH=$(printf '%s' "$STDIN" | jq -r '.transcript_path // ""' 2>/dev/null || echo "")
GET_PCT_SCRIPT="$(dirname "$0")/get-context-pct.sh"
CONTEXT_PCT=0

if [ -x "$GET_PCT_SCRIPT" ]; then
  CONTEXT_PCT=$("$GET_PCT_SCRIPT" "$TRANSCRIPT_PATH" 2>/dev/null || echo "0")
fi

# Below threshold — allow tool to run
if [ "$CONTEXT_PCT" -lt "$THRESHOLD" ]; then
  exit 0
fi

# Session-scoped debounce — prevents re-triggering for DEBOUNCE_MINUTES after a checkpoint
SESSION_HASH=$(printf '%s' "$TRANSCRIPT_PATH" | shasum -a 256 | cut -c1-16)
DEBOUNCE_FILE="/tmp/claude-ctx-cb-${SESSION_HASH}"

if [ -f "$DEBOUNCE_FILE" ]; then
  LAST_TRIGGER=$(cat "$DEBOUNCE_FILE")
  NOW=$(date +%s)
  ELAPSED=$(( NOW - LAST_TRIGGER ))
  if [ "$ELAPSED" -lt $(( DEBOUNCE_MINUTES * 60 )) ]; then
    exit 0
  fi
fi

date +%s > "$DEBOUNCE_FILE"

# Extract tool details
TOOL_NAME=$(printf '%s' "$STDIN" | jq -r '.tool_name // "unknown"' 2>/dev/null || echo "unknown")
TOOL_INPUT=$(printf '%s' "$STDIN" | jq -c '.tool_input // {}' 2>/dev/null || echo "{}")

# Checkpoint file
ISO_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
FILE_TS=$(date +%Y%m%d-%H%M%S)
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "none")
CWD=$(pwd)
CHECKPOINT_FILE="${CHECKPOINT_DIR}/${FILE_TS}-auto-checkpoint.md"

# Write partial checkpoint — mechanical facts only; Claude fills in the rest via /checkpoint auto
cat > "$CHECKPOINT_FILE" << CHECKPOINT_EOF
---
tool: claude-code
type: auto
status: in-progress
branch: ${BRANCH}
working_dir: ${CWD}
timestamp: ${ISO_TS}
context_pct: ${CONTEXT_PCT}
---

## Auto-checkpoint (${CONTEXT_PCT}% context — hook triggered)

### Interrupted At

**Tool:** \`${TOOL_NAME}\`
**Input:**
\`\`\`json
${TOOL_INPUT}
\`\`\`

---

### Intent

*(Why were you running this tool? What were you expecting to find or do? — Claude completes)*

### Goal

*(High-level objective of the CURRENT active task only — Claude completes)*

### Handoff Brief

*(2-3 sentences for a cold-start agent — Claude completes)*

### Discovered Facts

*(Specific IDs, values, states, names found during this run — Claude completes)*

### Ruled Out This Run

*(Approaches tried and abandoned, explicitly — Claude completes)*

### Remaining Work

*(Next steps for THIS task only. Item 1 = the blocked tool call. — Claude completes)*

### Other Pending Work

*(Separate projects / tasks NOT part of the current task. Kept separate so restore does not pivot here. — Claude completes)*

### Notes

*(Blockers, gotchas, open questions — Claude completes)*
CHECKPOINT_EOF

# NOTE: pending-restore marker is NOT written here.
# It is written by the checkpoint skill after /checkpoint auto completes,
# ensuring the marker only exists when intent has been captured.
# Writing it here caused the marker to fire on the very next tool call
# (the /checkpoint auto Skill invocation), skipping intent capture entirely.

# Build the handoff script path — same directory as this hook
HANDOFF_SCRIPT="$(dirname "$0")/context-handoff.sh"

# Block the tool and prompt Claude to complete the checkpoint then hand off
jq -n \
  --argjson pct "$CONTEXT_PCT" \
  --arg tool "$TOOL_NAME" \
  --arg input "$TOOL_INPUT" \
  --arg file "$CHECKPOINT_FILE" \
  --arg handoff "$HANDOFF_SCRIPT" \
  '{
    decision: "block",
    reason: ("⚠️  CONTEXT CIRCUIT BREAKER: \($pct)% context used.\n\nBlocked: \($tool)\nInput: \($input)\n\nPartial checkpoint written to:\n\($file)\n\nStep 1 — complete the checkpoint:\n  /checkpoint auto \($file)\n  Fill in WHY you were running that tool and separate CURRENT task from OTHER projects.\n\nStep 2 — hand off to a fresh session:\n  \($handoff) \($file)\n  Launches a new tmux window with the configured agent (set via /handoff agent <name>),\n  seeds it with /checkpoint restore, and kills this session.")
  }'

exit 2
