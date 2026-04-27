---
name: peers
description: Show recent notes from all peer agents working in parallel worktrees
---

## Usage

/peers

## What it does

Reads all `.md` files in `.claude/agents-shared/` and displays their contents,
grouped by agent (filename = branch name). Each file is written exclusively by
its owning agent, so reads are always consistent.

## Instructions

1. List all `.md` files in `.claude/agents-shared/` sorted by modification time (newest first).
2. If no files exist, output: `No peer notes yet.`
3. For each file display:
   - A header: `## <branch-name>` (derived from the filename without `.md`)
   - The full file contents
4. After displaying, summarise how many peer agents have posted notes.
