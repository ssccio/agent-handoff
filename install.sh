#!/usr/bin/env bash
# Install agent-handoff into Claude Code config directory.
# Copies hooks, skill, and command. Does not modify settings.json automatically.

set -euo pipefail

CLAUDE_CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"

echo "Installing agent-handoff to $CLAUDE_CFG"
echo ""

# Hooks
mkdir -p "$CLAUDE_CFG/hooks"
cp hooks/context-circuit-breaker.sh "$CLAUDE_CFG/hooks/"
cp hooks/context-handoff.sh "$CLAUDE_CFG/hooks/"
chmod +x "$CLAUDE_CFG/hooks/context-circuit-breaker.sh"
chmod +x "$CLAUDE_CFG/hooks/context-handoff.sh"
echo "✓ Hooks installed"

# Skill
mkdir -p "$CLAUDE_CFG/skills/checkpoint"
if [ -f "$CLAUDE_CFG/skills/checkpoint/SKILL.md" ]; then
  echo "  ! checkpoint skill already exists — backing up to SKILL.md.bak"
  cp "$CLAUDE_CFG/skills/checkpoint/SKILL.md" "$CLAUDE_CFG/skills/checkpoint/SKILL.md.bak"
fi
cp skills/checkpoint/SKILL.md "$CLAUDE_CFG/skills/checkpoint/"
echo "✓ Checkpoint skill installed"

# Command
mkdir -p "$CLAUDE_CFG/commands"
cp commands/handoff.md "$CLAUDE_CFG/commands/"
echo "✓ /handoff command installed"

# State directory
mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/checkpoints"
echo "✓ Checkpoint state directory ready"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  One manual step: register the PreToolUse hook"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Add to $CLAUDE_CFG/settings.json:"
echo ""
cat << 'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "REPLACE_WITH_YOUR_CLAUDE_CFG/hooks/context-circuit-breaker.sh"
          }
        ]
      }
    ]
  }
}
EOF
echo ""
echo "Replace REPLACE_WITH_YOUR_CLAUDE_CFG with: $CLAUDE_CFG"
echo ""
echo "Then set your handoff agent (default is claude):"
echo "  /handoff agent pi"
echo "  /handoff agent hermes"
echo ""
echo "Done."
