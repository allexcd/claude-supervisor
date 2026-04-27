---
name: share
description: Append a timestamped note to your peer-notes file for other agents to read
---

## Usage

/share <message>

## What it does

Appends a timestamped note to `.claude/agents-shared/<current-branch>.md` so peer agents
running in other worktrees can read it with `/peers`.

## Instructions

1. Run `git rev-parse --abbrev-ref HEAD` to get the current branch name.
2. Run `date -u '+%Y-%m-%dT%H:%M:%SZ'` to get the current timestamp.
3. Ensure `.claude/agents-shared/` exists (create with `mkdir -p` if not).
4. Append the following line to `.claude/agents-shared/<branch>.md`:
   ```
   [<timestamp>] <message>
   ```
5. Confirm to the user: `Shared: <message>`
