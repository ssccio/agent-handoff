#!/usr/bin/env bash
# context-handoff.sh
# Launches a fresh agent in a new tmux window pre-seeded with /checkpoint restore,
# then self-terminates the current pane. Agent-agnostic: supports claude, hermes, pi, opencode.
#
# Usage: context-handoff.sh <checkpoint-path> [--agent claude|hermes|pi|opencode]
#
# Called by Claude after completing /checkpoint auto. The old session hands off and dies;
# the new session restores from the checkpoint and continues from Remaining Work item 1.

set -euo pipefail

CHECKPOINT_PATH=""
AGENT=""

# Parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent) AGENT="$2"; shift 2 ;;
    *) CHECKPOINT_PATH="$1"; shift ;;
  esac
done

# Read agent from preference file if not specified via flag
if [ -z "$AGENT" ]; then
  AGENT=$(cat "${XDG_STATE_HOME:-$HOME/.local/state}/checkpoints/.handoff-agent" 2>/dev/null || true)
  [ -z "$AGENT" ] && AGENT="claude"
fi

# Validate
if [ -z "${TMUX:-}" ]; then
  echo "ERROR: Not in a tmux session. Cannot hand off automatically." >&2
  echo "Instead: type /clear, then /checkpoint restore in the new session." >&2
  exit 1
fi

if [ -z "$CHECKPOINT_PATH" ]; then
  echo "Usage: context-handoff.sh <checkpoint-path> [--agent claude|hermes|pi|opencode]" >&2
  exit 1
fi

if [ ! -f "$CHECKPOINT_PATH" ]; then
  echo "ERROR: Checkpoint not found: $CHECKPOINT_PATH" >&2
  exit 1
fi

# Delete pending-restore marker — send-keys is handling the restore, avoid double-trigger
SLUG=$(git rev-parse --show-toplevel 2>/dev/null | xargs basename 2>/dev/null || basename "$PWD")
SLUG=$(printf '%s' "$SLUG" | tr -cd 'a-zA-Z0-9._-')
PENDING="${XDG_STATE_HOME:-$HOME/.local/state}/checkpoints/${SLUG}/.pending-restore"
rm -f "$PENDING"

# Derive window name from checkpoint title (first ## heading)
RAW_TITLE=$(grep '^## ' "$CHECKPOINT_PATH" 2>/dev/null | head -1 | sed 's/^## //')
SHORT_TITLE=$(printf '%s' "$RAW_TITLE" | tr ' /' '--' | tr -cd 'a-zA-Z0-9._-' | cut -c1-25)
WINDOW_NAME="resume-${SHORT_TITLE:-checkpoint}"

# Determine agent launch command
case "$AGENT" in
  claude)   LAUNCH_CMD="claude" ;;
  hermes)   LAUNCH_CMD="hermes" ;;
  pi)       LAUNCH_CMD="pi" ;;
  opencode) LAUNCH_CMD="opencode" ;;
  *)        LAUNCH_CMD="$AGENT" ;;
esac

# Launch new tmux window in the same directory
tmux new-window -n "$WINDOW_NAME" -c "$(pwd)" "$LAUNCH_CMD"

# Seed the new session with the restore command after it starts up.
# disown detaches the background job from this shell's SIGHUP propagation,
# so it survives after tmux kill-pane destroys this pane.
(sleep 3 && tmux send-keys -t "$WINDOW_NAME" "/checkpoint restore" Enter) &
disown $!

printf '\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '  HANDOFF COMPLETE\n'
printf '  Agent:      %s\n' "$AGENT"
printf '  Window:     %s\n' "$WINDOW_NAME"
printf '  Checkpoint: %s\n' "$CHECKPOINT_PATH"
printf '  New session will restore in ~3s and continue.\n'
printf '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '\n'

# Self-terminate: kill the current pane, handing focus to the new window
tmux kill-pane
