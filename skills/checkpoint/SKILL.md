---
name: checkpoint
description: |
  Use when saving working state to resume later, switching between AI agent tools,
  or handing off in-progress work to another session. Triggers: "checkpoint",
  "save progress", "resume", "restore", "where did I leave off", "hand off to Hermes",
  "pick up where we left off", "switching to Pi", "checkpoint auto" (hook-triggered
  mid-run capture — completes a partial checkpoint written by the circuit breaker hook).
---

# /checkpoint — Cross-Agent State Persistence

Staff-engineer-quality session notes any AI agent can write and any other can read.

**HARD GATE:** Never modify code. This skill only reads state and writes checkpoint files.

---

## Storage

XDG-compliant, tool-agnostic — every agent writes to and reads from the same place:

```
${XDG_STATE_HOME:-$HOME/.local/state}/checkpoints/{SLUG}/
```

**Slug derivation** — run each as a separate single command, in order. Works in all three cases: normal git repo, initialized-but-empty repo, and non-git directory.

1. `git remote get-url origin 2>/dev/null`
   - If output: transform `owner/repo` → `owner-repo`, strip `.git` → use as SLUG
2. If empty: `git rev-parse --show-toplevel 2>/dev/null` → take `basename` → use as SLUG
   - This succeeds for initialized repos even with zero commits
3. If still empty (not a git directory at all): `basename "$PWD"` → use as SLUG
4. Sanitize SLUG to `[a-zA-Z0-9._-]` only
5. `mkdir -p "${XDG_STATE_HOME:-$HOME/.local/state}/checkpoints/{SLUG}"`

---

## Commands

| Input | Action |
|---|---|
| `/checkpoint` or `/checkpoint save [title]` | Save — manual, strategic, full synthesis |
| `/checkpoint auto {filepath}` | Auto — complete a hook-triggered partial checkpoint |
| `/checkpoint resume [N\|title]` or `/checkpoint restore [N\|title]` | Resume |
| `/checkpoint list [--all]` | List |
| `/checkpoint handoff [target-tool]` | Generate handoff prompt for another tool |

---

## Tool Identity

Self-identify which tool is running this skill. Use this as the `tool` field in every checkpoint:

| Tool | How to detect |
|---|---|
| `claude-code` | `$CLAUDE_CONFIG_DIR` is set |
| `hermes` | Running in Hermes agent environment |
| `pi` | Running in Pi agent environment |
| `unknown` | Cannot determine |

---

## Save Flow

### Step 1 — Gather context (one command each)

- `pwd` → working directory (always works; use as fallback for everything)
- `git symbolic-ref --short HEAD 2>/dev/null` → branch name
  - Returns branch name for normal repos AND initialized-but-empty repos (unborn HEAD)
  - Empty output = not a git directory → use `"none"` for branch
- `git status --short 2>/dev/null` → modified files (empty if no commits or not a repo — fine)
- `git log --oneline -5 2>/dev/null` → recent commits (empty if no commits — fine)

### Step 1b — Git hygiene check

After gathering context, assess the git state and prompt the user if appropriate:

| Situation | Action |
|---|---|
| Not a git repo at all | Ask: "This directory isn't a git repo. Should I run `git init`? It enables branch tracking and file history across checkpoints." |
| Initialized repo, zero commits | Ask: "This repo has no commits yet. Should I create an initial commit so file history is tracked?" |
| Normal repo | Continue — no prompt needed |

Only ask once per save. If the user declines, proceed with the checkpoint anyway — git is helpful, not required.

### Step 2 — Get timestamps (two separate commands)

- `date -u +%Y-%m-%dT%H:%M:%SZ` → ISO timestamp for frontmatter
- `date +%Y%m%d-%H%M%S` → for filename

### Step 3 — Synthesize from conversation history + git state

Produce all five sections:
1. **Goal** — one sentence: what are we trying to accomplish and why
2. **Handoff Brief** — 2-3 sentences a tool with zero prior context can read to orient instantly. Must include: working directory, active task, single most important constraint or blocker.
3. **Decisions Made** — choices, trade-offs, and reasoning
4. **Remaining Work** — ordered next steps
5. **Notes** — blockers, gotchas, failed approaches, open questions

### Step 4 — Write file

Filename: `{TIMESTAMP}-{title-kebab-case}.md`

```markdown
---
tool: {tool}
status: in-progress
branch: {branch or "none"}
working_dir: {absolute path from pwd}
timestamp: {ISO-8601 UTC}
---

## {title}

### Goal

{one sentence}

### Handoff Brief

{2-3 sentences, fully self-contained, no assumed context}

### Decisions Made

- {bullet}

### Remaining Work

1. {ordered item}

### Notes

- {blocker / gotcha / open question}
```

Confirm:

```
CHECKPOINT SAVED
════════════════════════════════════════
Tool:     {tool}
Title:    {title}
Branch:   {branch}
Dir:      {working_dir}
File:     {full path}
════════════════════════════════════════
```

---

## Auto Flow (hook-triggered)

The context circuit breaker hook fires at 60% context, blocks the next tool call, writes a partial checkpoint containing the mechanical facts (tool name, input, timestamp, branch, cwd), and hands back to Claude with a message like:

> "⚠️ Context at 67%. Blocked: Bash({args}). Partial checkpoint at {path}. Complete it — why were you running this?"

When you receive that message, invoke `/checkpoint auto {filepath}`.

### Step 1 — Read the partial checkpoint

Read the file at `{filepath}`. It already contains:
- Tool name and full input (verbatim from hook)
- Branch, working directory, timestamp, context %

### Step 2 — Complete the Intent section first

This is the most critical section. Answer in 2-4 sentences:
- **Why** were you about to run this specific tool with these specific arguments?
- **What** were you expecting to find, confirm, or do?
- **What hypothesis** were you testing or action were you taking?

This is the thing that would otherwise be lost. Be precise — "I was checking if the FSx SG had a 0.0.0.0/0 all-traffic rule so I could determine whether it was safe to remove" is vastly more useful than "investigating security groups."

### Step 3 — Complete all remaining sections

Fill in from conversation history:
- **Goal** — one sentence: the high-level objective of the CURRENT active task
- **Handoff Brief** — 2-3 sentences for a cold-start agent (include working_dir, active task, most important constraint)
- **Discovered Facts** — specific IDs, values, states, names found this run (not prose — structured list)
- **Ruled Out This Run** — what was tried and abandoned, explicitly, with why
- **Remaining Work** — THIS TASK ONLY. Ordered next steps; item 1 should be "run `{tool_name}({tool_input})`" — exactly what was blocked. Do NOT include unrelated projects here.
- **Other Pending Work** — Separate projects or tasks that exist but are NOT part of the current task. Kept in its own section so restore does not accidentally pivot to them.
- **Notes** — blockers, gotchas, open questions

### Step 4 — Write the completed file

Overwrite the partial file with all sections filled. Update frontmatter `status` to `in-progress` (leave `type: auto`).

Confirm:

```
AUTO-CHECKPOINT COMPLETE
════════════════════════════════════════
Context was: {context_pct}%
Blocked:     {tool_name}
Intent:      {first sentence of Intent}
File:        {filepath}
════════════════════════════════════════
Now run /clear — the hook will auto-restore on your next message.
```

### Step 5 — Hand off to a fresh session

**If in a tmux session (primary flow):** Run the handoff script via Bash:

```
~/.claude-cadmium/hooks/context-handoff.sh {filepath}
```

This script:
1. Launches a new tmux window running a fresh agent (`claude` by default)
2. Seeds it with `/checkpoint restore` via tmux send-keys (fires ~3s after launch)
3. Deletes the pending-restore marker (avoids double-trigger)
4. Kills the current pane — this session ends here

To hand off to a different agent: `context-handoff.sh {filepath} --agent hermes`

**If NOT in tmux (fallback):** Tell the user: "Run `/clear` now — the hook will detect the pending-restore marker and auto-restore on your next message."

The hook wrote a `.pending-restore` marker file. After `/clear`, the first tool call is intercepted and Claude auto-restores from the saved checkpoint.

---

## Resume / Restore Flow

### Step 1 — Find checkpoints

`ls -1t {CHECKPOINT_DIR}/*.md 2>/dev/null`

If no files: "No checkpoints for this project yet. Run `/checkpoint` to save."

### Step 2 — Select

Match by number or title fragment if specified; otherwise use most recent. Read the file.

### Step 2b — Detect partial checkpoint

After reading, check if the checkpoint is partial (hook wrote it but Claude never completed it). A partial checkpoint has placeholder text in the Intent section — look for the literal string `*(Why were you running`.

If partial: **do not present it as a completed restore.** Instead, run the auto-complete flow first:
- Tell the user: "This checkpoint is partial — the circuit breaker fired before intent was captured. Completing it now from conversation context."
- Fill in all sections (Intent, Goal, Handoff Brief, Discovered Facts, Remaining Work, Other Pending Work, Notes) using whatever context is available
- If context is sparse (fresh session with no history), fill what you can and mark unknowns explicitly
- Overwrite the file, then continue to Step 3 with the completed checkpoint

### Step 3 — Present

```
RESUMING CHECKPOINT
════════════════════════════════════════
Saved by: {tool}
Title:    {title}
Branch:   {branch}
Saved:    {timestamp, human-readable}
Status:   {status}
════════════════════════════════════════

### Goal
{goal}

### Remaining Work
{numbered list}

### Notes
{notes}
```

If current branch differs from checkpoint branch: "Checkpoint was saved on `{saved-branch}`, you are on `{current}`. Switch branches before continuing?"

### Step 4 — Offer next steps

```
A) Continue — start on Remaining Work item 1
B) Show full checkpoint file
C) Just needed the context, thanks
```

**Important for auto-checkpoints (`type: auto`):** "A) Continue" means starting on `### Remaining Work` item 1 — the blocked tool call that triggered the circuit breaker. Do NOT pivot to anything listed under `### Other Pending Work`; those are separate projects recorded for reference only. Proceed on the active task unless the user explicitly redirects.

---

## List Flow

`ls -1t {CHECKPOINT_DIR}/*.md 2>/dev/null`

Read frontmatter from each file. Display:

```
CHECKPOINTS — {slug}
════════════════════════════════════════
#   Saved              Tool          Title                     Status
──  ─────────────────  ────────────  ────────────────────────  ───────────
1   Apr 27 23:33 EDT   claude-code   soc2-sg-remediation       in-progress
2   Apr 27 21:30 EDT   claude-code   soc2-root-mfa             in-progress
════════════════════════════════════════
```

With `--all`: scan all subdirectories under the checkpoints base. Add a Project column.

---

## Handoff Flow

Generates a paste-ready prompt for picking up work in a different tool.

Load the most recent checkpoint (or one the user specifies), then emit:

```
──────────────────────────────────────────────────
HANDOFF PROMPT  →  paste into {target tool}
──────────────────────────────────────────────────
You are continuing an in-progress task. Here is the full context:

Working directory: {working_dir}
Branch: {branch}

{Handoff Brief — verbatim from checkpoint}

Remaining work (in order):
{numbered list verbatim from checkpoint}

Key notes:
{notes verbatim from checkpoint}

Start by confirming you have the context, then proceed with item 1.
──────────────────────────────────────────────────
```

After displaying, offer: "Copy to clipboard? (macOS: `pbcopy`, Linux: `xclip -sel clip`)"

---

## Rules

- **Never modify code.** Read state and write checkpoint files only.
- **One command per Bash call.** No `&&`, `|`, `$()`, `;`, or loops.
- **Each save is a new file.** Never overwrite existing checkpoints.
- **Handoff Brief is mandatory on every save.** It must stand alone — readable by a tool with zero conversation history.
- **Infer, don't interrogate.** Fill everything from git state and conversation context. Ask only if the title truly cannot be inferred.
