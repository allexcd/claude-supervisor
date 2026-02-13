# Project Memory

> This file is read by every Claude agent working on this project.
> Keep it up to date — especially the Known Pitfalls section.
> After every correction, add a note here so the next agent doesn't repeat the mistake.

---

## Project Overview
- **What it does:** <describe the project briefly>
- **Stack:** <language · framework · key libraries>
- **Entry point:** <e.g. src/main.ts, app.py, cmd/server/main.go>

---

## Conventions
- **Style:** <e.g. ESLint + Prettier, Black, gofmt>
- **Naming:** <e.g. camelCase for vars, PascalCase for types>
- **Tests:** <e.g. Jest, pytest, go test — where they live, how to run>
- **Branching:** <e.g. feature/*, fix/*, refactor/*>

---

## Known Pitfalls
<!-- Add a bullet here every time you make a correction -->
- <example: never use process.env directly — always use the config module in src/config.ts>

---

## Agent Instructions
- Always explain the WHY behind every change — not just what, but reasoning and tradeoffs
- Use subagents for narrow, isolated tasks — delegate to keep your main context clean
- Run tests before marking any task as done
- After a correction, add it to Known Pitfalls above
- Use `/model` to switch to a cheaper model once complex planning is complete
- Use `/agents` to see available subagents for this project

## Syncing Learnings Back

This file lives in your worktree — a copy of the main project's `.claude/CLAUDE.md`.
Updates you make here are **not** automatically reflected in the main repo.

**Why not?** Multiple agents run in parallel across isolated worktrees. If they all
wrote to the same main CLAUDE.md simultaneously, you'd get race conditions and
corruption. The owner also needs a review gate — not every agent-discovered pitfall
is correct or worth propagating to all future agents.

**To preserve learnings across worktrees:**
1. After adding to Known Pitfalls, commit this file with your other changes:
   ```
   git add .claude/CLAUDE.md && git commit -m "docs: update CLAUDE.md with new pitfall"
   ```
2. The project owner runs `bin/collect-learnings.sh [--yes] <repo_path>` to diff all
   active worktrees' CLAUDE.md files against main and patch the main copy with new lines.
   Use `--yes` to auto-approve all merges (useful in CI or scripts).
