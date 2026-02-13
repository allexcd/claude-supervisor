---
name: example-agent
description: >
  [Describe exactly when the main agent should delegate here. Be specific —
  the main agent reads this field to decide whether to use this agent.
  Example: "Use this agent when asked to write or update unit tests. Do not use for feature work."]
tools:
  - Read
  - Glob
  - Grep
  - Edit
  - Write
  - Bash
---

[Write the system prompt for this specialized agent here.]

You are a [role] specializing in [domain].

Your job:
1. [Primary responsibility]
2. [Secondary responsibility]
3. [...]

Rules:
- [Constraint or guideline]
- [Constraint or guideline]
- [...]
