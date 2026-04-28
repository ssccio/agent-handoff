Configure the agent that the context circuit breaker hands off to, or trigger an immediate handoff.

Usage:
  /handoff agent pi       → set next auto-handoff target to Pi (no immediate action)
  /handoff agent claude   → set next auto-handoff target to Claude Code (the default)
  /handoff agent hermes   → set next auto-handoff target to Hermes
  /handoff agent opencode → set next auto-handoff target to Opencode
  /handoff                → trigger an immediate handoff to the configured agent
  /handoff now            → same as /handoff

Arguments: $ARGUMENTS

Agent preference file: ~/.local/state/checkpoints/.handoff-agent

## Steps

Parse $ARGUMENTS to determine the mode:

### Mode: set agent ("agent {name}" in $ARGUMENTS)

1. Extract the agent name — the word after "agent". Valid values: claude, hermes, pi, opencode.
   If the name is not recognized, list valid options and stop.

2. Write the agent name to the preference file via Bash:
   ```
   printf '%s' '{agent}' > ~/.local/state/checkpoints/.handoff-agent
   ```

3. Confirm to the user:
   ```
   Handoff agent set to: {agent}
   The context circuit breaker will hand off to {agent} when context hits threshold.
   Run /handoff to trigger an immediate handoff.
   ```

Do NOT trigger a handoff. This is configuration only.

### Mode: immediate handoff (no args, or "now")

1. Read the configured agent:
   ```
   cat ~/.local/state/checkpoints/.handoff-agent 2>/dev/null || echo claude
   ```

2. Save a checkpoint using the checkpoint skill:
   Run /checkpoint save (the skill handles the save flow)
   Note the checkpoint file path from the save confirmation.

3. Run the handoff script:
   ```
   ~/.claude-cadmium/hooks/context-handoff.sh {checkpoint_path} --agent {agent}
   ```

4. The script launches the new session and kills this pane. This session ends here.

### Mode: show current setting (args = "status" or "?")

Read and display the current agent preference:
```
cat ~/.local/state/checkpoints/.handoff-agent 2>/dev/null || echo "claude (default)"
```
