# Context Circuit Breaker System

*Built: 2026-04-28*

A self-contained system that replaces Claude Code's built-in auto-compaction with a smarter, agent-agnostic context handoff. When context fills up, work is preserved with full intent captured, and a fresh agent session picks up exactly where the old one left off — in a new tmux window, with zero manual steps beyond the initial `/clear`.

---

## The Problem

Claude Code's built-in compaction fires automatically and silently when context fills. It summarizes the conversation, but the summary lacks the precise intent behind in-flight work — the *why* behind the tool call that was about to run, the hypothesis being tested, the exact IDs being chased. You lose the thread.

The workaround (scroll up, re-read) is expensive and error-prone under pressure. And the compacted session still carries 60-70% of context overhead into what should be a clean run.

---

## The Architecture

```
Context hits threshold (60%)
         ↓
PreToolUse hook fires — reads % from HUD cache
         ↓
Blocks the tool call — writes partial checkpoint
         ↓
Claude completes the checkpoint
  - Intent: WHY that tool was about to run
  - Goal, Facts, Remaining Work (this task only)
  - Other Pending Work (separate section — not resumed automatically)
         ↓
Claude runs context-handoff.sh
  - Reads configured agent from ~/.local/state/checkpoints/.handoff-agent
  - tmux new-window "claude" (or pi / hermes / opencode)
  - disown'd background: sleep 3 && send-keys "/checkpoint restore"
  - tmux kill-pane  ← old session dies here
         ↓
New window: fresh agent at 0% context
  3 seconds later receives "/checkpoint restore"
  Reads checkpoint → continues from Remaining Work item 1
```

---

## Files

| File | Purpose |
|------|---------|
| `~/.claude-cadmium/hooks/context-circuit-breaker.sh` | PreToolUse hook — monitors context, fires at threshold |
| `~/.claude-cadmium/hooks/context-handoff.sh` | Launches new agent session, seeds restore, self-terminates |
| `~/.claude-cadmium/skills/checkpoint/SKILL.md` | Checkpoint skill — updated with auto flow + handoff step |
| `~/.claude-cadmium/commands/handoff.md` | `/handoff` slash command |
| `~/.local/state/checkpoints/.handoff-agent` | Configured target agent (plain text file) |
| `~/.local/state/checkpoints/{SLUG}/.pending-restore` | Pending-restore marker (fallback for non-tmux /clear flow) |

---

## Component Details

### context-circuit-breaker.sh

**Type:** PreToolUse hook (registered in `settings.json`)

**How it reads context:** Claude Code's `PreToolUse` stdin does not include `context_window` data. The HUD plugin writes context % to a cache file every ~3 seconds. The hook reads from:
```
$CLAUDE_CONFIG_DIR/plugins/claude-hud/context-cache/{sha256(transcript_path)}.json
```
This was a key discovery — the hook can't read context from its own stdin, but can piggyback on the HUD's cache.

**Pending-restore check (runs first):** Before the threshold check, the hook looks for a `.pending-restore` marker file. If found, it deletes it and blocks with an auto-restore message. This is the fallback path for when the user does a manual `/clear` instead of the tmux handoff.

**Debounce:** A session-scoped file in `/tmp/` prevents re-triggering for 10 minutes. Key: first 16 chars of sha256(transcript_path).

**Block output:**
```json
{"decision": "block", "reason": "...step 1 and step 2 instructions..."}
```
`exit 2` required alongside the JSON for the block to take effect.

---

### context-handoff.sh

**Key design decisions:**

**Agent resolution order:** `--agent` flag → `~/.local/state/checkpoints/.handoff-agent` → `claude` (default)

**The `disown` trick:** After `tmux new-window`, we schedule the `send-keys` restore command as a background subshell and immediately `disown` it. Then `tmux kill-pane` destroys the current pane. Normally, killing a pane sends SIGHUP to all processes in it, including background jobs. `disown` removes the job from the shell's job table, so it becomes an orphan adopted by init — it survives the pane death and fires the `send-keys` 3 seconds later.

```bash
(sleep 3 && tmux send-keys -t "$WINDOW_NAME" "/checkpoint restore" Enter) &
disown $!
tmux kill-pane
```

**Pending-restore cleanup:** The script deletes `.pending-restore` before launching the new session. Since `send-keys` handles the restore, we don't want the hook's auto-restore to double-trigger in the new session.

**Not-in-tmux handling:** If `$TMUX` is not set, the script exits with an error and Claude falls back to the manual `/clear` + pending-restore flow.

---

### Checkpoint Skill Updates

Two structural changes to `~/.claude-cadmium/skills/checkpoint/SKILL.md`:

**1. Split Remaining Work into two sections**

The original auto-checkpoint template had a single `### Remaining Work` section. When context from one task contained references to other projects, the restore would accidentally pivot to those other projects.

New template:
- `### Remaining Work` — current active task only; item 1 is always the blocked tool call
- `### Other Pending Work` — separate projects, recorded for reference, explicitly off-limits for "A) Continue"

**2. Handoff instead of /clear in Step 5**

Old Step 5: "Tell the user to run `/clear`, then `/checkpoint restore`."  
New Step 5: "Run `context-handoff.sh {filepath}` (tmux primary) or tell user to `/clear` (fallback)."

The resume flow now includes a guard: when restoring an auto-checkpoint (`type: auto`), "A) Continue" means Remaining Work item 1 — never Other Pending Work.

---

### /handoff Slash Command

**Location:** `~/.claude-cadmium/commands/handoff.md`

**Modes:**

| Invocation | Action |
|-----------|--------|
| `/handoff agent pi` | Sets `.handoff-agent` to `pi`. Confirms. No handoff triggered. |
| `/handoff agent claude` | Resets to default. |
| `/handoff` | Reads configured agent, saves checkpoint, runs handoff script. |
| `/handoff now` | Same as `/handoff`. |
| `/handoff status` | Shows current configured agent. |

The agent preference persists across sessions in `~/.local/state/checkpoints/.handoff-agent`. Set once, applies to all future auto-handoffs until changed.

---

## Two Flows

### Primary: tmux handoff (automatic, zero manual steps)

```
Hook fires → Claude completes checkpoint → Claude runs handoff.sh
New tmux window opens → agent starts → /checkpoint restore fires in 3s
Old pane dies → new agent continues from Remaining Work item 1
```

**Manual steps required:** none (circuit breaker handles everything)

### Fallback: manual /clear (non-tmux)

```
Hook fires → Claude completes checkpoint → pending-restore marker written
User types /clear → on next tool call, hook detects marker → auto-restore message
Claude restores → continues
```

**Manual steps required:** type `/clear`

---

## Agent Agnosticism

The system hands off to whatever agent is configured. The receiving agent only needs to understand the checkpoint format and the `/checkpoint restore` command. The checkpoint file is plain markdown — human-readable, tool-neutral.

Tested: Claude Code  
Designed to work: Hermes, Pi, Opencode (any agent that runs in a terminal and has the checkpoint skill or equivalent)

---

## Novel Techniques

- **Reading context % via HUD cache** — PreToolUse hook has no native context visibility; sidesteps this by reading the HUD plugin's cache file
- **`disown` for post-pane-death execution** — background subshell survives `tmux kill-pane` by being orphaned before the kill
- **Pending-restore fallback** — marker file bridges the gap between circuit breaker fire and new session, even when tmux isn't available
- **Checkpoint section split** — separating active task from other pending work prevents restore from pivoting to unrelated projects
- **Self-terminating session** — Claude kills its own tmux pane as the final step, handing focus to the new window

---

## Threshold Tuning

Current threshold: **60%**  
Observed: a long design conversation (like the one that built this system) hits 70% before doing much "real" tool work. Operational sessions with many tool calls hit 60% faster.

To adjust: edit `THRESHOLD=60` in `context-circuit-breaker.sh`.

Debounce window: **10 minutes** (`DEBOUNCE_MINUTES=10`). Prevents re-triggering immediately after a handoff if context is still high.

---

## Known Limitations

- `send-keys` timing (3s sleep) assumes Claude Code starts within 3 seconds. Adjust `sleep 3` in `context-handoff.sh` if the new session isn't receiving the restore command.
- `shasum -a 256` (macOS) — Linux needs `sha256sum`. Not portable out of the box.
- `jq` is a hard dependency of the circuit breaker hook.
- If Claude Code is running outside tmux (e.g., in a plain terminal), only the fallback `/clear` flow is available.
