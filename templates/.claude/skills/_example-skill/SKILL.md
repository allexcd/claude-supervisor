---
name: example-skill
description: >
  [Describe what this skill does and when Claude should use it. Be specific —
  Claude reads this field to decide whether to auto-load the skill.
  Example: "Generates a changelog from recent git commits. Use when the user
  asks for a changelog, release notes, or summary of recent changes."]
argument-hint: "[optional-arg]"
# disable-model-invocation: true   # Uncomment to prevent Claude from auto-loading this skill
# user-invocable: false            # Uncomment to hide from the /slash menu (background knowledge only)
allowed-tools:
  - Read
  - Glob
  - Grep
---

[Write the instructions for this skill here. This is the prompt Claude
receives when the skill is loaded — either manually via /example-skill
or automatically when your description matches the user's request.]

## What this skill does

[Explain the purpose in one sentence.]

## Steps

1. [First step Claude should take]
2. [Second step]
3. [Third step]

## Rules

- [Constraint or quality requirement]
- [Output format requirement]
- [Any guardrails]

## Example output

[Show what a good result looks like — Claude uses this as a reference.]

---

### Skill file reference

This file follows the Agent Skills open standard (https://agentskills.io).

**Required:**
- File must be named `SKILL.md` (all caps)
- Place in `.claude/skills/<skill-name>/SKILL.md`

**Frontmatter fields:**
| Field                      | Description                                              |
|----------------------------|----------------------------------------------------------|
| `name`                     | Slash command name (lowercase, hyphens). Defaults to dir name |
| `description`              | When to use this skill (Claude reads this for auto-load) |
| `argument-hint`            | Autocomplete hint, e.g. `[filename]`                     |
| `disable-model-invocation` | `true` = only manual `/name` invocation                  |
| `user-invocable`           | `false` = hidden from menu, background knowledge only    |
| `allowed-tools`            | Tools usable without permission prompts                  |
| `model`                    | Override model for this skill                            |
| `context`                  | `fork` = run in isolated subagent                        |
| `agent`                    | Subagent type when `context: fork`                       |

**Scope (where to place):**
| Location                              | Scope               |
|---------------------------------------|----------------------|
| `~/.claude/skills/<name>/SKILL.md`    | All your projects    |
| `.claude/skills/<name>/SKILL.md`      | This project only    |

**String substitutions:**
| Variable              | Description                          |
|-----------------------|--------------------------------------|
| `$ARGUMENTS`          | All arguments passed to the skill    |
| `$ARGUMENTS[N]`      | Specific argument by index (0-based) |
| `${CLAUDE_SKILL_DIR}` | Directory containing this SKILL.md  |
