# agent-handoff

A context circuit breaker and session handoff system for terminal-based AI agents.

When context fills up, work is saved with full intent captured and a fresh agent session picks up exactly where the old one left off — in a new tmux window, automatically.

**Agent-agnostic:** works with Claude Code, Hermes, Pi, Opencode, or any agent that runs in a terminal and understands the checkpoint format.

---

## The Problem

AI coding agents hit context limits mid-task. Built-in compaction summarizes the conversation but loses the critical thing: *why* a specific tool call was about to run — the hypothesis being tested, the exact IDs being chased, the constraint that shaped the next move. You lose the thread.

This system captures intent at the moment of interruption and transfers it to a fresh agent session with zero context overhead.

---

## How It Works

```
Context hits 60%
       ↓
PreToolUse hook fires
Reads % from HUD cache (Claude Code's native context data isn't in hook stdin)
       ↓
Blocks the in-flight tool call
Writes a partial checkpoint with mechanical facts
       ↓
Claude completes the checkpoint:
  - Intent: WHY that specific tool was about to run
  - Goal, Discovered Facts, Remaining Work (this task)
  - Other Pending Work (separate section — not auto-resumed)
       ↓
Claude runs context-handoff.sh
  - Reads configured agent from ~/.local/state/checkpoints/.handoff-agent
  - tmux new-window "{agent}"
  - disown'd background: sleep 3 && send-keys "/checkpoint restore"
  - tmux kill-pane  ← old session dies here
       ↓
New window: fresh agent at 0% context
Receives "/checkpoint restore" 3 seconds after launch
Reads checkpoint → continues from Remaining Work item 1
```

---

## Requirements

- **tmux** — session handoff uses tmux windows
- **jq** — hook output and cache parsing
- **claude-hud** — provides the context % cache the hook reads from (Claude Code only)
- **Claude Code** — hooks are registered in Claude Code's `settings.json`
- A checkpoint skill — the agent needs to understand `/checkpoint auto` and `/checkpoint restore`

---

## Installation

```bash
git clone https://github.com/yourusername/agent-handoff
cd agent-handoff
./install.sh
```

Then register the PreToolUse hook in `$CLAUDE_CONFIG_DIR/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude-cadmium/hooks/context-circuit-breaker.sh"
          }
        ]
      }
    ]
  }
}
```

---

## Configuration

### Set the target agent

```
/handoff agent pi       → next auto-handoff goes to Pi
/handoff agent claude   → reset to default (Claude Code)
/handoff agent hermes   → Hermes
/handoff agent opencode → Opencode
```

The preference is stored in `~/.local/state/checkpoints/.handoff-agent` and persists across sessions.

### Trigger an immediate handoff

```
/handoff        → save checkpoint + hand off to configured agent
/handoff now    → same
/handoff status → show current agent setting
```

### Tune the threshold

Edit `THRESHOLD=60` in `hooks/context-circuit-breaker.sh`. Default is 60%.

The debounce window (prevents re-triggering) is `DEBOUNCE_MINUTES=10`.

---

## Files

```
hooks/
  context-circuit-breaker.sh   PreToolUse hook — monitors context, fires at threshold
  context-handoff.sh           Launches new agent session, seeds restore, kills current pane

skills/
  checkpoint/
    SKILL.md                   Checkpoint skill with auto-handoff flow

commands/
  handoff.md                   /handoff slash command definition

docs/
  context-circuit-breaker-system.md   Full design documentation
```

---

## The Checkpoint Format

Checkpoints are plain markdown files stored in `~/.local/state/checkpoints/{project-slug}/`. Any agent can read them.

```markdown
---
tool: claude-code
type: auto
status: in-progress
branch: main
working_dir: /path/to/project
timestamp: 2026-04-28T05:35:47Z
context_pct: 70
---

## Task title

### Intent
Why the interrupted tool call was running

### Goal
One sentence: the high-level objective

### Handoff Brief
2-3 sentences a cold-start agent can read to orient instantly

### Discovered Facts
- Specific IDs, values, states found this run

### Ruled Out This Run
- Approaches tried and abandoned

### Remaining Work
1. The blocked tool call (run this first)
2. Next step
...

### Other Pending Work
- Separate projects (not resumed automatically)

### Notes
- Blockers, gotchas, open questions
```

The `### Other Pending Work` section is a key design decision: it keeps unrelated project context visible without causing the restoring agent to pivot away from the active task.

---

## Novel Techniques

**Reading context % via HUD cache**
Claude Code's `PreToolUse` hook stdin doesn't include context window data. The claude-hud plugin writes context % to a sidecar cache file every ~3 seconds. The hook reads from:
```
$CLAUDE_CONFIG_DIR/plugins/claude-hud/context-cache/{sha256(transcript_path)}.json
```

**`disown` for post-pane-death execution**
After `tmux new-window`, the send-keys command is scheduled in a background subshell and immediately `disown`'d. Then `tmux kill-pane` destroys the current pane. Normally this sends SIGHUP to all processes including background jobs. `disown` removes the job from the shell's SIGHUP propagation, orphaning it to init — it survives pane death and fires 3 seconds later.

```bash
(sleep 3 && tmux send-keys -t "$WINDOW_NAME" "/checkpoint restore" Enter) &
disown $!
tmux kill-pane
```

**Pending-restore marker (non-tmux fallback)**
When tmux isn't available, the hook writes `.pending-restore` to the checkpoint dir. After manual `/clear`, the first tool call in the new session triggers the hook, which detects the marker, deletes it, and blocks with an auto-restore prompt.

---

## Flows

### Primary: tmux handoff (fully automatic)

No manual steps. The circuit breaker, checkpoint completion, and handoff all happen without user input.

### Fallback: manual `/clear`

If not in tmux: hook fires → Claude completes checkpoint → pending-restore marker written → user types `/clear` → next tool call auto-triggers restore.

---

## Known Limitations

- `send-keys` timing assumes the agent starts within 3 seconds. Adjust `sleep 3` in `context-handoff.sh` if needed.
- `shasum -a 256` is macOS. Linux needs `sha256sum`.
- `jq` is required.
- claude-hud is required for context % reading (Claude Code only). Other agents need an alternative context source.
- If the agent isn't Claude Code, `/checkpoint restore` needs to be understood by the receiving agent.
