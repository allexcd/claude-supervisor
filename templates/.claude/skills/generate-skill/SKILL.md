---
name: generate-skill
description: >
  Generates a new Claude Code skill from a user description. Use when the user
  asks to create a skill, add a slash command, make a new /command, or scaffold
  a custom skill.
argument-hint: "[skill-name] [description]"
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Write
  - Bash
---

Generate a new Claude Code skill based on the user's request.

## Inputs

- **Skill name**: `$ARGUMENTS[0]` (if provided). Must be lowercase with hyphens only.
- **Description**: remaining arguments or ask the user.

If no arguments are provided, ask the user for:
1. A short name for the skill (lowercase, hyphens, e.g. `review-pr`)
2. What the skill should do
3. Whether Claude should auto-load it or only run on manual `/name` invocation

## Steps

1. **Determine scope** — ask the user where to place the skill:
   - `.claude/skills/<name>/SKILL.md` — project-only (default)
   - `~/.claude/skills/<name>/SKILL.md` — available in all projects

2. **Create the directory** — `mkdir -p <scope-path>/skills/<name>/`

3. **Generate SKILL.md** — write the file with proper YAML frontmatter and markdown body:

   ```yaml
   ---
   name: <skill-name>
   description: >
     <Clear description of what the skill does and when to use it.
     Claude reads this to decide auto-loading — be specific.>
   argument-hint: "<hint if the skill takes arguments>"
   # Set disable-model-invocation: true if the skill has side effects
   # (deploys, sends messages, modifies external systems)
   allowed-tools:
     - <list only the tools the skill actually needs>
   ---
   ```

   The markdown body should include:
   - A brief explanation of what the skill does
   - Numbered steps Claude should follow
   - Rules / constraints / quality requirements
   - Example output (when helpful)

4. **Verify** — read the generated file back and confirm it is valid YAML frontmatter + markdown.

5. **Report** — tell the user the skill is ready and how to invoke it (`/skill-name` or automatically).

## Rules

- Skill names must be lowercase letters, numbers, and hyphens only (max 64 characters)
- The file MUST be named `SKILL.md` (all caps, exact)
- Keep the description field specific — vague descriptions cause false auto-loads
- Set `disable-model-invocation: true` for skills with side effects (deploy, send, publish, delete)
- Set `user-invocable: false` only for background knowledge skills the user never invokes directly
- Only list tools the skill actually needs in `allowed-tools`
- Keep `SKILL.md` under 500 lines — move detailed reference material to supporting files
- If the skill needs reference data, create supporting `.md` files in the same directory

## Available tools reference

For the `allowed-tools` field, these are the tools Claude Code can use:

| Tool     | Purpose                                      |
|----------|----------------------------------------------|
| `Read`   | Read file contents                           |
| `Write`  | Create or overwrite files                    |
| `Edit`   | Make targeted edits to existing files        |
| `Glob`   | Find files by pattern (e.g. `**/*.ts`)       |
| `Grep`   | Search file contents with regex              |
| `Bash`   | Run shell commands                           |
| `Task`   | Launch subagents for complex subtasks        |

## Example

For `/generate-skill review-pr "Reviews a pull request for issues"`:

```markdown
---
name: review-pr
description: >
  Reviews the current pull request for bugs, style issues, and missing tests.
  Use when the user asks to review a PR, check a pull request, or review changes.
argument-hint: "[pr-number]"
disable-model-invocation: true
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
---

Review the current pull request for quality issues.

## Steps

1. Get the PR diff with `git diff main...HEAD` (or the specified PR number)
2. Read each changed file to understand context
3. Check for:
   - Bugs and logic errors
   - Missing error handling at system boundaries
   - Security issues (injection, XSS, secrets)
   - Missing or broken tests
   - Style inconsistencies with the rest of the codebase

4. Categorize findings as:
   - **Critical** — must fix before merge
   - **Suggestion** — would improve quality
   - **Nit** — minor style preference

## Rules

- Do not suggest changes to unchanged code
- Focus on the diff, not the entire file
- If no issues found, say so — do not invent problems
```
