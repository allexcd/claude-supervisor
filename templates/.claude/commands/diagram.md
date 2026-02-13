---
description: Draw an ASCII diagram of the code structure, data flow, or architecture being discussed
allowed-tools:
  - Read
  - Glob
  - Grep
---

Create a clear ASCII diagram to visualize the requested code, architecture, or data flow.

Choose the right diagram type for the content:
- **Call graph** — which functions call which, and in what order
- **Data flow** — how data moves and transforms through the system
- **State machine** — for protocols, lifecycle events, or event-driven logic
- **Layer diagram** — module boundaries, dependencies, and what depends on what
- **Sequence diagram** — request/response or multi-step interactions between components

Rules:
- Label every arrow with what is being passed or what triggers the transition
- Add a one-line legend if you use any non-obvious symbols
- Keep the diagram narrow enough to fit in a terminal (≤ 80 chars wide if possible)
- After the diagram, write a 2–3 sentence explanation of what it shows

If the full system is too large to diagram at once, ask which layer or component to focus on.
