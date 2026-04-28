# Design Document: Agent Handoff System

*Session date: 2026-04-28 (late night)*  
*Authors: Ken Trenkelbach + Claude (Sonnet 4.6)*

This document captures the full design of the agent-handoff system — not just what was built, but why, what we discovered along the way, what didn't work, and what still needs doing. Written immediately after the session so nothing is lost.

---

## Origin: What We Were Trying to Fix

Claude Code has a built-in auto-compaction feature that fires when context fills up. It summarizes the conversation into a condensed form and continues. The problem: **the summary loses intent**.

When you're deep in an investigation — you just found something, you have a hypothesis, you were about to run a specific command for a specific reason — the compaction flattens all of that into a generic summary. The precise *why* behind the next tool call disappears. You lose the thread.

We wanted something better: a system that **captures intent at the moment of interruption** and transfers it to a fresh session that can continue without any context overhead.

---

## The Session: A Narrative

### Starting point

The circuit breaker hook (`context-circuit-breaker.sh`) already existed at the start of this session. It had fired successfully the night before at 70% context — the hook worked mechanically. But the recovery flow was broken in two ways:

**Problem 1: Claude resumed the wrong task after restore.**

The checkpoint had this structure:
```
### Remaining Work
1. ~~chmod on hook~~ — skip
2. Tune threshold
3. Consider PreCompact hook
4. Clean up old files
5. Resume SOC2 remediation ← separate project, listed here by mistake
```

When the user ran `/checkpoint restore` and said "A) Continue", Claude jumped to item 5 (SOC2 remediation) instead of item 2 (tune threshold). The checkpoint mixed active task steps with unrelated project notes in a single list, so Claude couldn't tell which was the current task.

**Problem 2: Too many manual steps.**

After the circuit breaker fired, the user had to:
1. Read the block message
2. Type `/checkpoint auto {long path}` 
3. Wait for Claude to complete the checkpoint
4. Type `/clear`
5. Type `/checkpoint restore`
6. Choose "A) Continue"

That's five deliberate manual steps during what should be an interruption handled automatically.

### First fixes: checkpoint structure and pending-restore marker

We fixed Problem 1 by splitting the checkpoint into two sections:
- `### Remaining Work` — active task only, item 1 is always the blocked tool call
- `### Other Pending Work` — separate projects, visible but explicitly off-limits for "A) Continue"

We fixed part of Problem 2 by adding a pending-restore marker: when the circuit breaker fires, it writes `.pending-restore` to the checkpoint directory. After manual `/clear`, the first tool call in the new (cleared) session triggers the hook, which detects the marker, deletes it, and blocks with an auto-restore message. This eliminates the need to type `/checkpoint restore`.

This reduced manual steps to: `/clear` only.

### The insight: don't /clear at all — use tmux

Ken raised the key architectural question: **if we're in tmux, why not just launch a new session?**

Instead of `/clear` (which resets the current session), Claude could:
1. Complete the checkpoint
2. Open a new tmux window running a fresh agent
3. Seed the new window with `/checkpoint restore`
4. Kill the current pane

The new session starts at 0% context. The old session is gone. No manual steps at all.

This is **fundamentally different** from `/clear`:
- `/clear` resets context but stays in the same session. The model, CLAUDE.md, session hooks all reload. But you're still in the same process lineage.
- The tmux handoff starts a genuinely fresh process. True zero context.
- It's also **agent-agnostic**: the new window can run Claude Code, Hermes, Pi, Opencode — whatever makes sense for the task.

### The disown trick

The key implementation challenge: how do you seed the new session with `/checkpoint restore` when you're about to kill the current pane?

Naive approach:
```bash
tmux new-window "claude"
sleep 3
tmux send-keys -t new-window "/checkpoint restore" Enter
tmux kill-pane
```

Problem: `sleep 3` blocks. By the time `tmux kill-pane` runs, the sleep has consumed time in the current pane. And if we kill the pane, the sleep process (and the send-keys that follows) gets killed with it via SIGHUP.

The fix: **`disown`**.

```bash
(sleep 3 && tmux send-keys -t "$WINDOW_NAME" "/checkpoint restore" Enter) &
disown $!
tmux kill-pane
```

`disown` removes the background job from the shell's job table. When `tmux kill-pane` destroys the pane and the shell receives SIGHUP, it normally forwards SIGHUP to all background jobs. A `disown`'d job is no longer in the job table, so it's orphaned to init instead. Init doesn't forward SIGHUP. The background subshell survives, completes its sleep, and fires the `send-keys` to the new window 3 seconds after the old pane is dead.

This was the critical non-obvious technique that makes the whole handoff work.

### The /handoff command

We added a `/handoff` slash command. Initial intent was "trigger an immediate handoff." Ken clarified: **`/handoff agent pi` should be configuration, not an action**.

The distinction matters: you might want to set your handoff target at the start of a work session ("today I'm working with Pi"), then let the circuit breaker fire automatically when it needs to. The `/handoff agent {name}` command writes to a preference file; the circuit breaker and handoff script read from it.

Final command semantics:
- `/handoff agent pi` → set preference to Pi, confirm, no handoff triggered
- `/handoff` → trigger immediate handoff to configured agent
- `/handoff status` → show current setting

Agent preference stored in: `~/.local/state/checkpoints/.handoff-agent`

---

## Technical Discoveries

### Discovery 1: PreToolUse hook stdin has no context data

**What we assumed:** Claude Code would pass context window information in the hook's stdin JSON, so the hook could read `context_window.used_percentage` directly.

**What we found:** The PreToolUse hook stdin contains:
```json
{
  "session_id": "...",
  "transcript_path": "/path/to/transcript.jsonl",
  "cwd": "/current/dir",
  "tool_name": "Bash",
  "tool_input": {...},
  "tool_use_id": "..."
}
```

No `context_window` field. No token counts. The hook is completely blind to how full the context is.

**How we worked around it:** The claude-hud plugin (a statusline component already installed) writes context % to a sidecar cache file every ~3 seconds:

```
$CLAUDE_CONFIG_DIR/plugins/claude-hud/context-cache/{sha256(transcript_path)}.json
```

The cache file contains:
```json
{
  "used_percentage": 69.4,
  "remaining_percentage": 30.6,
  "current_usage": 143200,
  "context_window_size": 200000,
  "saved_at": "2026-04-28T05:12:34Z"
}
```

The hook reads `used_percentage` from this file. The key is derived by sha256-hashing the transcript path (which IS available in stdin), giving a stable per-session cache key.

This is a dependency: **the circuit breaker only works if claude-hud is installed and running**. If hud isn't active, `CONTEXT_PCT` stays 0 and the hook never fires. We should add a warning for this case.

The sha256 derivation (macOS):
```bash
CACHE_HASH=$(printf '%s' "$TRANSCRIPT_PATH" | shasum -a 256 | cut -c1-64)
```

Linux needs `sha256sum` instead of `shasum -a 256`. Not currently handled.

### Discovery 2: /clear cannot be triggered programmatically

We explored every angle: hooks, Bash tool calls, special output, Claude API calls. `/clear` is a Claude Code CLI built-in that operates on the client side — it never reaches the model. There is no way for Claude or a hook to trigger it programmatically.

This is why the tmux handoff architecture matters: it eliminates the need for `/clear` entirely by creating a genuinely new session.

### Discovery 3: The checkpoint section split solves task pivoting

The restore flow presented `### Remaining Work` as a numbered list and offered "A) Continue — start on Remaining Work item 1." When unrelated projects were in that list (because the checkpoint was written during a session that had been doing multiple things), Claude would pick whichever item seemed most actionable — not necessarily the one that was interrupted.

The fix is structural: `### Remaining Work` is contractually "this task only, item 1 is the blocked call." `### Other Pending Work` is a separate section with its own clear label and an explicit instruction in the skill: "Do NOT pivot to Other Pending Work on 'A) Continue'."

This is a soft constraint (Claude reads it, not a hard rule), but it's been reliable because the sections have distinct names and the restore flow instruction is unambiguous.

### Discovery 4: The debounce is session-scoped, not time-scoped

The debounce mechanism prevents the circuit breaker from firing repeatedly in the same session (e.g., if the threshold is still above 60% after a checkpoint is written).

Key: the debounce file is keyed by `sha256(transcript_path)[0:16]` stored in `/tmp/`. This means:
- Same session: same transcript path → same debounce key → won't re-trigger for `DEBOUNCE_MINUTES`
- New session (after tmux handoff): new transcript path → new key → no debounce

This is the right behavior: we don't want the debounce to carry over to the new fresh session.

---

## Architecture Decisions

### Why PreToolUse, not PostToolUse or Stop?

- **PostToolUse:** fires after the tool runs. By then we've consumed more context executing the tool. We want to stop *before* context gets worse.
- **Stop:** fires when Claude finishes generating a response — not between tool calls in an agentic run. Long tool sequences can go many turns without hitting Stop.
- **PreToolUse:** fires before every tool execution. Maximum opportunity to intercept. Correct choice.

### Why write a partial checkpoint in the hook, not a complete one?

The hook is a bash script. It has mechanical facts: which tool was blocked, what the input was, timestamp, branch, cwd. It does not have the *why* — that's in Claude's conversation context.

Writing a partial checkpoint in the hook and having Claude complete it (via `/checkpoint auto`) captures the intent that would otherwise be lost. This is the whole point of the system.

An alternative: have Claude write the checkpoint without the hook writing anything. But then the hook's block message can't include the file path, and Claude has to choose a checkpoint path itself, which is less reliable.

### Why pending-restore marker rather than sending /checkpoint restore directly?

When the circuit breaker fires and the user does a manual `/clear` (non-tmux fallback), the new session is a blank slate. Claude has no context about what it was doing. We need a mechanism to tell the fresh Claude "there's a pending restore."

Options considered:
1. **Have the user type `/checkpoint restore`** — requires them to remember
2. **Pre-seed the session with a message** — `/clear` doesn't accept initial messages
3. **Write a marker file the hook detects** — reliable, file-system based, works across sessions

The marker file approach is the only one that survives a `/clear`. The hook runs on every tool call including the very first one in the new session. It checks for the marker, deletes it (so it only triggers once), and blocks with an auto-restore message.

### Why `disown` instead of a wrapper script or named pipe?

We considered several approaches to pre-seed the new session:

- **Named pipe/fifo feeding initial input to claude:** puts claude in non-interactive mode when stdin is a pipe. Doesn't work.
- **Wrapper script that calls claude then send-keys:** timing is unreliable, same SIGHUP problem.
- **tmux `send-keys` with a long sleep:** works, but the sleep runs in the current pane and gets killed when the pane dies.
- **Write a `.pending-restore` marker and rely on hook:** works, but requires one tool call in the new session to trigger. If the user's first action doesn't involve a tool call, restore doesn't happen automatically.
- **`disown` + background subshell:** background job survives pane death via orphaning to init. Fires reliably after the sleep. Clean.

`disown` won because it's the only approach that doesn't depend on timing, doesn't interfere with Claude's interactive mode, and reliably survives the pane kill.

### Why project-scoped checkpoint directories?

`~/.local/state/checkpoints/{project-slug}/` rather than a flat directory.

- Slug derived from `git rev-parse --show-toplevel | xargs basename` (or `basename $PWD` fallback)
- Keeps checkpoints organized by project
- Pending-restore markers are project-scoped, so a restore in one project doesn't accidentally interfere with another
- `--all` flag on `/checkpoint list` can scan across all project dirs

### Why not write the handoff directly in the hook?

The hook runs before Claude has completed the checkpoint. If the hook launched the handoff immediately (writing partial checkpoint + launching new window + killing pane), Claude would never get to fill in the intent section. The most important part of the checkpoint — *why* the tool was about to run — would be lost.

The hook blocks and waits. Claude fills in the checkpoint. Then Claude runs the handoff. This two-step is intentional.

---

## File Inventory

### `hooks/context-circuit-breaker.sh`

**Type:** Bash script, registered as Claude Code PreToolUse hook

**Flow:**
1. Read stdin (JSON)
2. Derive project slug and checkpoint dir (needed early for pending-restore check)
3. **Check for pending-restore marker** — if found, delete it, block with "restore now" message, exit 2
4. Read transcript path from stdin, derive HUD cache hash, read context %
5. If below threshold: `exit 0`
6. Check debounce file; if within window: `exit 0`
7. Update debounce file with current timestamp
8. Extract tool name and input from stdin
9. Write partial checkpoint file (mechanical facts + empty Claude-fill sections)
10. Write pending-restore marker (fallback for manual /clear flow)
11. Derive handoff script path (same directory as this script)
12. Block with two-step instructions: complete checkpoint, then run handoff

**Environment dependencies:**
- `jq` — JSON parsing and output
- `shasum` (macOS) / `sha256sum` (Linux) — cache key derivation
- `git` — slug derivation (graceful fallback to `basename $PWD`)
- `$CLAUDE_CONFIG_DIR` — finds HUD cache

**Key variables:**
- `THRESHOLD=60` — context % at which to fire
- `DEBOUNCE_MINUTES=10` — minimum time between triggers per session

### `hooks/context-handoff.sh`

**Type:** Bash script, called by Claude after completing checkpoint

**Arguments:**
- `$1` — checkpoint file path (required)
- `--agent claude|hermes|pi|opencode` — target agent (optional, reads from preference file if not given)

**Flow:**
1. Parse arguments
2. If not in tmux (`$TMUX` unset): print error, exit 1
3. Validate checkpoint file exists
4. Read agent from preference file if not specified via flag
5. Delete pending-restore marker (avoids double-trigger in new session)
6. Derive tmux window name from checkpoint's `## Title` heading
7. `tmux new-window -n "$WINDOW_NAME" -c "$(pwd)" "$LAUNCH_CMD"`
8. `(sleep 3 && tmux send-keys -t "$WINDOW_NAME" "/checkpoint restore" Enter) & disown $!`
9. Print handoff summary
10. `tmux kill-pane` — self-terminate

**Environment dependencies:**
- `tmux` — required (exits with error if not in tmux)
- `git` — slug derivation for pending-restore path
- Preference file: `~/.local/state/checkpoints/.handoff-agent`

### `skills/checkpoint/SKILL.md`

The checkpoint skill is the interface contract between the circuit breaker and the restoring agent. Key sections added/modified in this session:

**Auto Flow:** Added `### Other Pending Work` as a distinct section separate from `### Remaining Work`. Updated Step 5 from "run /clear" to "run context-handoff.sh (tmux) or /clear (fallback)."

**Resume Flow:** Added explicit instruction: when restoring an auto-checkpoint (`type: auto`), "A) Continue" means Remaining Work item 1. Do NOT pivot to Other Pending Work.

### `commands/handoff.md`

Custom Claude Code slash command at `{CLAUDE_CONFIG_DIR}/commands/handoff.md`.

**Modes:**
- `agent {name}` in arguments → configuration mode, no handoff
- No args or `now` → immediate handoff
- `status` → show current setting

---

## State Files

| Path | Contents | Created by | Consumed by |
|------|---------|-----------|-------------|
| `~/.local/state/checkpoints/{slug}/{ts}-auto-checkpoint.md` | Completed checkpoint | Claude (via skill) | Claude (restore) |
| `~/.local/state/checkpoints/{slug}/.pending-restore` | Checkpoint file path | circuit-breaker.sh | circuit-breaker.sh (on next session's first tool call) |
| `~/.local/state/checkpoints/.handoff-agent` | Agent name (e.g. "pi") | /handoff command | context-handoff.sh |
| `/tmp/claude-ctx-cb-{first16_sha256}.json` | Unix timestamp of last trigger | circuit-breaker.sh | circuit-breaker.sh (debounce check) |
| `{CLAUDE_CONFIG_DIR}/plugins/claude-hud/context-cache/{sha256}.json` | Context % + token counts | claude-hud plugin | circuit-breaker.sh |

---

## What Still Needs Work

### High priority

**1. HUD dependency warning**
If claude-hud isn't installed or isn't generating cache files, `CONTEXT_PCT` stays 0 and the hook never fires silently. The hook should detect this case and warn:
```bash
if [ ! -f "$CACHE_FILE" ]; then
  # Warn once, don't spam every tool call
  # Maybe write a warning flag file so we only warn once per session
fi
```

**2. Linux portability**
`shasum -a 256` is macOS only. Linux uses `sha256sum`. Should detect at runtime:
```bash
if command -v sha256sum >/dev/null 2>&1; then
  HASH=$(printf '%s' "$INPUT" | sha256sum | cut -c1-64)
else
  HASH=$(printf '%s' "$INPUT" | shasum -a 256 | cut -c1-64)
fi
```

**3. send-keys timing**
`sleep 3` assumes the agent starts within 3 seconds. Claude Code typically starts in 1-2s, but on slow machines or first runs it might take longer. Consider increasing to `sleep 5` or making it configurable via an env var.

### Medium priority

**4. Make context source pluggable**
Currently hard-wired to read from the claude-hud cache. Other agents (Hermes, Pi) won't have this cache. Need an abstraction:
- A `get-context-pct.sh` script that can be swapped out per agent
- Or an env var `CONTEXT_SOURCE=hud|file|estimate`

**5. PreCompact hook as belt-and-suspenders**
The circuit breaker fires at 60% (PreToolUse). If something bypasses it (a very long tool response pushes context past 80% in one shot), Claude's built-in compaction fires instead. A PreCompact hook could write a checkpoint before compaction runs, giving a fallback save even if the circuit breaker didn't catch it first.

**6. Test with non-Claude agents**
Designed to work with Hermes, Pi, Opencode. Not yet tested. Key questions:
- Does each agent understand `/checkpoint restore`?
- Does each agent have a skill system or equivalent?
- Is the `send-keys` timing sufficient for slower-starting agents?

**7. Threshold auto-tuning**
60% was chosen empirically. A long design conversation hits 70% before doing much tool work. A fast operational session (many small tool calls) hits 60% before the user expects it. Consider making threshold configurable per-project via a `.handoff-config` file, or adaptive based on session type.

**8. Window naming**
The tmux window name is derived from the checkpoint's `## Title` heading. This can be long or contain special characters. Should sanitize more aggressively and maybe truncate to 20 chars.

### Low priority

**9. Multi-session state**
If the user runs multiple Claude Code sessions in parallel (different tmux windows), each session has its own transcript path and thus its own debounce key. The pending-restore marker is project-scoped, so if two sessions are working on the same project, one could accidentally consume the other's pending-restore. Unlikely in practice but worth noting.

**10. Checkpoint format versioning**
The checkpoint markdown format is a de facto standard right now. If we improve it (new sections, different frontmatter), old checkpoints won't have the new sections. Add a `version: 1` frontmatter field so restore logic can handle old formats gracefully.

**11. Clean up old pending-restore files**
If Claude is killed mid-handoff (after writing the marker but before the new session restores), the marker file persists indefinitely. Add a max-age check: if the marker is more than N hours old, ignore it rather than triggering a restore.

---

## The Bigger Picture

This system is one instance of a more general pattern: **stateful agent continuity via checkpoint protocol**.

The checkpoint format is the interface. Any agent that can:
1. Write a checkpoint to `~/.local/state/checkpoints/{slug}/`
2. Read a checkpoint and continue from `### Remaining Work` item 1
3. Respond to `/checkpoint restore` (or equivalent)

...can participate in this handoff protocol. The circuit breaker and handoff script are the Claude Code implementation of the trigger side. Different agents could implement their own trigger side while sharing the same checkpoint store.

Future work worth exploring:
- **Standardizing the checkpoint format** as a spec other tool authors can implement
- **A checkpoint registry** that lets you see what state is pending across all projects
- **Cross-agent handoff testing**: explicitly test Claude → Pi → Hermes → back to Claude chains
- **Handoff with context injection**: instead of just sending `/checkpoint restore`, seed the new session with the full checkpoint content in the initial message, so even agents without a restore command can pick it up

---

## Session Notes

- The HUD cache discovery was the hardest part — we knew the hook needed context %, we didn't know hooks couldn't see it. Finding the HUD sidecar file was the key unlock.
- The `disown` technique came from thinking about what happens to background processes when a pane dies. Not something either of us knew off the top of our heads; reasoned through from first principles.
- The "Other Pending Work" section split was triggered by a real failure: Claude pivoted to SOC2 audit work instead of the circuit breaker work it had just been doing. The fix was structural, not instructional.
- We were working in `/Users/ken/dev/DLC/Incident` (an OpenShift incident response repo) — unrelated to this project, just the working directory we happened to be in.
- Total session time: several hours, late into the night. Everything documented here should be enough to pick it up cold.
