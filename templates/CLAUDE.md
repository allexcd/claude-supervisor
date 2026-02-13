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
