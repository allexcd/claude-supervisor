# Claude Supervisor

[![npm version](https://img.shields.io/npm/v/claude-supervisor.svg)](https://www.npmjs.com/package/claude-supervisor)
[![npm downloads](https://img.shields.io/npm/dm/claude-supervisor)](https://www.npmjs.com/package/claude-supervisor)
[![CI](https://github.com/allexcd/claude-supervisor/actions/workflows/ci.yml/badge.svg)](https://github.com/allexcd/claude-supervisor/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/allexcd/claude-supervisor)](LICENSE)
[![node](https://img.shields.io/node/v/claude-supervisor)](https://nodejs.org)

Spin up **parallel Claude Code agents** in isolated git worktrees — each with its own task, model, and mode — by describing your work in plain bullet points.

```bash
supervisor                                          # opens $EDITOR with a task stub
supervisor run "implement OAuth" "write tests [depends: implement-oauth]"
echo "- fix the login bug [model: haiku]" | supervisor
```

On first run it scaffolds `.claude/` with a safety hook and peer-notes directory. On every run after that it reads your bullet list, prompts for any missing models, confirms, and spawns one agent per bullet: branch created, worktree created, Claude launched in a tmux window. A live watch dashboard opens in window 0. When an agent finishes, `collect-learnings` runs automatically.

---

## How this compares to native Claude Code

claude-supervisor is the **batch-orchestration layer on top of native Claude Code primitives** — using session JSONL and worktrees underneath, not competing with them.

**Similarities — Claude Code does these natively:**
- Worktree + tmux + Claude in one command — `claude -w <branch> --tmux`
- Headless invocation with structured streaming — `claude -p --output-format stream-json`
- Subagents, skills, hooks, session resume/fork — all first-class in Claude Code

**What supervisor adds:**
- **Batch task input** — describe N tasks in one bullet list, get N parallel agents. Native `claude -w` is one-at-a-time; experimental Agent Teams uses a single-session split-pane model. Neither has the "paste a list, walk away" workflow.
- **Per-task model differentiation** — task A on Haiku, task B on Opus, task C in plan mode, all in one invocation.
- **Workflow lifecycle** — dependency staging (`[depends: …]`), automatic `collect-learnings` on agent finish, shared peer notes between parallel agents, migrate / uninstall tooling.
- **Opinionated patterns** — plan-then-execute, `PermissionRequest → Opus` safety routing, workspace-kit integration.

**When to use supervisor vs. raw `claude -w`:** if you have a single task or are already inside Claude Code, use `claude -w` directly. Use supervisor when you have a batch of parallel work and want the list-and-walk-away workflow.

---

## Pairs with claude-workspace-kit

[claude-workspace-kit](https://github.com/allexcd/claude-workspace-kit) scaffolds `.claude/` with a curated set of agents, skills, commands, rules, and output styles. claude-supervisor and workspace-kit are designed to work together without colliding:

| Concern | Owner | Files |
|---|---|---|
| Agents, skills, commands, rules, hooks | workspace-kit | tracked in `.cwk.lock` |
| PermissionRequest → Opus safety hook | supervisor | `.claude/settings.local.json` |
| Stop hook → auto-collect-learnings | supervisor | `.claude/settings.local.json` |
| Shared peer notes directory | supervisor | `.claude/agents-shared/` (gitignored) |
| Worktree-sync notes in CLAUDE.md | supervisor | fenced `<!-- BEGIN claude-supervisor -->` block |

On first run supervisor asks if you want to bootstrap workspace-kit. If you accept, workspace-kit runs `init` first, then supervisor writes its own overlay (`settings.local.json`) on top. If you decline, supervisor writes a minimal fallback. Either way the two tools never touch each other's files.

---

## Prerequisites

| Tool | Install |
|---|---|
| **git** | `xcode-select --install` (macOS) · or `brew install git` |
| **tmux** | `brew install tmux` |
| **Node.js / npm** | [nvm](https://github.com/nvm-sh/nvm): `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh \| bash` then `nvm install --lts` |
| **Claude Code CLI** | `npm install -g @anthropic-ai/claude-code` |

The supervisor checks for all of these on every run and offers to auto-install missing tools.

**Billing:**

| Mode | Who | API key needed? |
|---|---|---|
| **Pro / Max / Team** | Claude subscription users | No — OAuth login |
| **API key** | Anthropic Console users | Yes — `ANTHROPIC_API_KEY` |

Your billing mode is saved to `.env` on first run. Use `--reset` to re-prompt.

---

## Install

### Global (personal use, run from any directory)

```bash
npm install -g claude-supervisor
supervisor              # run in current project directory
supervisor ~/my-project
```

### Local devDependency (teams, version-locked)

```bash
npm install --save-dev claude-supervisor
```

Add to `package.json`:

```json
{
  "scripts": {
    "agents": "supervisor",
    "agents:watch": "supervisor watch",
    "agents:collect": "collect-learnings.sh --yes"
  }
}
```

### Clone and run directly

```bash
git clone https://github.com/allexcd/claude-supervisor
bash claude-supervisor/bin/supervisor.sh ~/my-project
```

---

## Quick Start

### 1. First run — scaffold the project

```bash
cd ~/my-project
supervisor
```

supervisor detects `.claude/settings.local.json` is absent, scaffolds:

```
.claude/
  settings.local.json     # PermissionRequest → Opus + Stop → collect-learnings hooks
  agents-shared/          # Shared peer notes (gitignored)
  CLAUDE.md               # Project memory (created if workspace-kit declined)
  agents/
    _example-agent.md     # Blank template — copy to create your own
.gitignore                # .env and .claude/agents-shared/ added
```

If you accept the workspace-kit prompt, `.claude/agents/`, `.claude/skills/`, etc. are also created.

### 2. Enter your tasks

After scaffolding, supervisor opens `$EDITOR` with a task stub in the same run. Save and close to spawn agents:

```markdown
- review the codebase and write an implementation plan [plan, model: opus]
- implement the OAuth login flow [model: sonnet, branch: feat-oauth]
- write tests for OAuth [depends: feat-oauth]
```

Or skip the editor:

```bash
# Pipe tasks directly
echo "- fix the login bug [model: haiku]" | supervisor

# Pass tasks as arguments
supervisor run "implement OAuth" "write tests [depends: implement-oauth]"

# Respawn last session
supervisor last
```

### 3. Confirm and watch

supervisor shows a summary, asks for confirmation, then spawns agents. A live watch dashboard opens in tmux window 0:

```
Claude Supervisor — Live Agent Dashboard   12:34:01
  Repo: ~/my-project

  Agent                Model    Mode    Status                 Last activity
  ──────────────────── ──────── ──────  ────────────────────── ─────────────
  feat-oauth           sonnet   normal  ⏵ tool: Edit            2s ago
  review-plan          opus     plan    ⏵ thinking              8s ago
  write-tests          haiku    normal  ⏸ idle (waiting for feat-oauth)
```

### 4. Attach and navigate

```bash
tmux attach -t my-project-agents
```

| Key | Action |
|---|---|
| `Ctrl+b n` / `p` | Next / previous agent |
| `Ctrl+b w` | List all windows — pick one |
| `Ctrl+b 0` | Jump to watch dashboard |
| `Ctrl+b d` | Detach (agents keep running) |

Or open each agent in its own terminal tab — supervisor prints the `cd … && claude …` command for each.

### 5. After agents finish

When an agent's session ends, the Stop hook fires automatically:
- Runs `collect-learnings.sh --yes` for that worktree
- Appends a completion record to `.claude/supervisor-session-summary.jsonl`

Then review diffs and open PRs:

```bash
git -C ~/my-project diff main..feat-oauth
gh pr create --head feat-oauth --base main --title "OAuth login"

# Or clean up everything at once
supervisor uninstall --everything
```

---

## Task input

### Bullet grammar

```
- <task description> [tag, tag, ...]
```

Tags go inside `[…]` at the end of the bullet, comma-separated:

| Tag | Effect |
|---|---|
| `model: sonnet` | Use this model for the agent (`sonnet`, `haiku`, `opus`, or a full model ID) |
| `branch: my-branch` | Use this branch name (default: auto-generated from prompt) |
| `plan` or `mode: plan` | Launch in plan mode (read-only until you approve) |
| `depends: branch-name` | Wait for that branch's agent to finish before spawning |

**Examples:**

```markdown
# Plain — branch auto-generated, model prompted
- refactor the database layer

# Fully specified
- implement OAuth login [model: claude-sonnet-4-5, branch: feat-oauth, mode: normal]

# Plan mode + Opus for complex review
- review the architecture as a staff engineer [plan, model: opus]

# Dependency — spawns only after feat-oauth agent finishes
- write tests for OAuth [depends: feat-oauth, model: haiku]

# Multiple tags
- fix the session timeout bug [model: haiku, branch: fix-session]
```

**Rules:**
- Lines starting with `#` are ignored
- Indented sub-bullets (2+ spaces) are ignored — paste from meeting notes freely
- Non-bullet lines (prose, headers) are ignored
- The last `[…]` group on a line is parsed as tags; everything before it is the prompt

### Input modes

| Invocation | Mode |
|---|---|
| `supervisor` (TTY, no args) | Opens `$EDITOR` with a stub |
| `supervisor < tasks.md` | Reads from stdin |
| `echo "- task" \| supervisor` | Reads from stdin |
| `supervisor run "task1" "task2"` | Reads from argv |
| `supervisor last` | Reuses the previous session's task list |

---

## Live watch dashboard

`supervisor watch` tails each agent's Claude Code session log and renders a live status table, refreshing every 3 seconds:

```bash
supervisor watch              # current directory
supervisor watch ~/my-project
```

The watch window is pre-created as tmux window 0 every time supervisor spawns agents. Agents idle for more than 5 minutes are flagged with `← stuck?`.

Configure with environment variables:

| Variable | Default | Effect |
|---|---|---|
| `CS_WATCH_INTERVAL` | `3` | Refresh interval in seconds |
| `CS_STUCK_MINUTES` | `5` | Minutes of idle before "stuck?" flag |

---

## Shared peer notes

Parallel agents working in separate worktrees can communicate via an append-only shared directory:

```bash
# Inside an agent session (Claude skill)
/share I've settled on email+profile scope, refresh tokens enabled
/peers       # read recent updates from all other agents
```

The `/share` skill appends a timestamped line to `.claude/agents-shared/<branch>.md`. The `/peers` skill reads all files in that directory. Each agent writes only its own file — no race conditions.

The `agents-shared/` directory lives in the main repo (gitignored) and is symlinked into each worktree automatically by `spawn-agent.sh`.

---

## Dependency staging

Add `[depends: branch-name]` to a bullet to stage that agent behind another:

```markdown
- implement the OAuth login flow [model: sonnet, branch: feat-oauth]
- write tests for OAuth [depends: feat-oauth, model: haiku]
```

supervisor spawns the `feat-oauth` agent immediately. The `write-tests` agent is held in a background polling loop. When the `feat-oauth` agent's Stop hook fires, the test-writer spawns automatically — with the dependency's diff summary prepended to its prompt as context.

---

## Subcommands

```bash
supervisor                        # enter tasks (editor / stdin / argv)
supervisor run "t1" "t2" ...      # argv mode
supervisor last                   # respawn previous session
supervisor list                   # show active agents from state file
supervisor attach [branch]        # tmux attach shortcut
supervisor watch [repo]           # live status dashboard
supervisor update [repo]          # refresh workspace-kit + supervisor overlay
supervisor doctor [repo]          # diagnose project state
supervisor migrate [repo]         # upgrade 0.2.x → 1.0 layout
supervisor uninstall [--dry-run] [--with-workspace] [--everything] [repo]
supervisor on-stop                # Stop hook target (called by Claude Code internally)
```

**`supervisor doctor`** — prints current state: git repo, settings.local.json, hooks, agents-shared, workspace-kit, active worktrees, tmux session, and dependencies.

**`supervisor migrate`** — guided upgrade from 0.2.x: backs up `.claude/`, moves hook config to `settings.local.json`, archives `tasks.conf`, optionally runs workspace-kit init.

**`supervisor uninstall`** — removes only supervisor's files by default. `--with-workspace` also runs workspace-kit uninstall. `--everything` also kills the tmux session and removes worktrees.

**`supervisor update`** — re-runs `npx claude-workspace-kit@latest update` (if workspace-kit is present) and refreshes the supervisor overlay.

---

## Modes

| Mode | Flag | What it does |
|---|---|---|
| `normal` | _(default)_ | Agent reads and writes freely. Use for implementation tasks. |
| `plan` | `--permission-mode plan` | Agent can read but won't modify files until you approve each action. Plan-mode tmux windows are always **yellow**. |

**Pattern — plan then execute:**

```markdown
# Step 1: spawn planner
- review the codebase and write a detailed implementation plan [plan, model: opus]

# After approving the plan, spawn workers
- implement the feature per the plan [model: sonnet, branch: feat-impl]
- write tests for the feature [depends: feat-impl, model: haiku]
```

---

## Project memory (CLAUDE.md)

`.claude/CLAUDE.md` is copied into every worktree. Every agent reads it at session start. Fill in:

- **Project Overview** — what it does, stack, entry point
- **Conventions** — style, naming, tests, branching
- **Known Pitfalls** — grows over time as agents document corrections

After every correction, tell the agent: *"Update CLAUDE.md so you don't make that mistake again."*

### Syncing learnings

Each worktree gets its own **copy** of CLAUDE.md. The Stop hook runs `collect-learnings.sh --yes` automatically when each agent finishes. To run it manually:

```bash
# Interactive — prompts for each worktree
collect-learnings.sh ~/my-project

# Non-interactive (CI, scripts)
collect-learnings.sh --yes ~/my-project
```

Then commit the result:

```bash
git -C ~/my-project add .claude/CLAUDE.md
git -C ~/my-project commit -m "docs: merge agent learnings"
```

> **Important:** If you manually remove a worktree before `collect-learnings` runs, any CLAUDE.md updates in that worktree are lost. The Stop hook handles this automatically; the manual command is for cases where you remove worktrees early.

---

## Custom agents

Agents live in `.claude/agents/` — YAML frontmatter plus a system prompt. Claude Code reads them at session start and delegates automatically based on task and description.

`_example-agent.md` is a blank template. Copy it to create your own:

```markdown
---
name: my-agent
description: What this agent does and when to use it. Be specific — this is the routing rule.
tools: Bash, Read, Edit
---

You are a specialist in ...
```

If you accepted the workspace-kit prompt on init, a curated set of agents (reviewer, debugger, test-writer, and more) is already installed.

---

## Stopping agents and cleanup

```bash
# Kill all agents
tmux kill-session -t my-project-agents

# Remove a specific worktree
git worktree remove ../my-project-feat-oauth

# Full cleanup (worktrees + branches + tmux session)
supervisor uninstall --everything

# Start fresh (re-run after cleanup)
supervisor
```

| Scenario | Action |
|---|---|
| Agents stuck/hung | `tmux kill-session -t project-agents` |
| Start fresh | Kill session → `supervisor` (reuses existing worktrees if they exist) |
| Agent finished, want to keep work | Open PR before removing worktree |
| Agent failed, want to retry | `git worktree remove` → `git branch -D branch` → `supervisor` |
| Terminal closed | Agents still running — `tmux attach` to reconnect |

---

## What gets committed

| Path | Git | Why |
|---|---|---|
| `.claude/CLAUDE.md` | Commit | Shared project memory — all agents read this |
| `.claude/settings.local.json` | Your call | Contains supervisor's hook config; usually committed so team members get the same safety gating |
| `.claude/agents/` | Commit | Subagents are project tools |
| `.claude/skills/` | Commit | Skills are project tools |
| `.claude/agents-shared/` | **Ignore** | Gitignored automatically — ephemeral peer notes |
| `.env` | **Ignore** | API key — gitignored automatically |
| `.claude/supervisor-agents.jsonl` | Ignore | Runtime state |
| `.claude/supervisor-last.md` | Ignore | Last task list (personal) |

---

## Upgrading from 0.x to 1.0

Version 1.0 removes `tasks.conf` and replaces it with bullet-list input. The `supervisor migrate` command handles the upgrade safely.

### What changed

| 0.2.x | 1.0 |
|---|---|
| Edit `tasks.conf` (INI blocks) | Bullet-list input (editor / stdin / argv) |
| `[task]` blocks with `key = value` | `- prompt text [tags]` |
| supervisor scaffolds `settings.json` | supervisor scaffolds `settings.local.json` (overlay) |
| agents/commands/skills in templates | Delegated to workspace-kit (or minimal fallback) |
| No live dashboard | `supervisor watch` — live status table |
| No auto collect-learnings | Stop hook fires automatically |
| No peer notes | `.claude/agents-shared/`, `/share`, `/peers` |
| No dependency staging | `[depends: branch]` inline tag |

### Migration steps

```bash
# 1. Run the guided migration
supervisor migrate ~/my-project

# What it does:
#   - Backs up .claude/ → .claude.backup-YYYYMMDD-HHMMSS/
#   - Moves PermissionRequest hook from settings.json → settings.local.json
#   - Renames settings.json → settings.json.v0-backup (your agents/skills/commands untouched)
#   - Optionally runs npx claude-workspace-kit init
#   - Adds fenced supervisor block to CLAUDE.md
#   - Offers to archive tasks.conf

# 2. Run supervisor normally after migration
supervisor ~/my-project
```

### Rollback

```bash
rm -rf .claude && mv .claude.backup-* .claude
# Reinstall 0.2.x if needed:
npm install -g claude-supervisor@0.2
```

### Diagnosis

```bash
supervisor doctor ~/my-project    # check current state before or after migration
```

---

## Running tests

```bash
npm test
# or
bash tests/smoke.sh
```

224 tests covering: bullet parser (all tag combinations), auto-init flows, watch dashboard, jsonl-tail, stop hook, shared-notes symlink, dependency staging, migrate/uninstall/doctor routing, spawn-agent, collect-learnings, and more. No API key or tmux required.

---

## File structure

```
claude-supervisor/
  bin/
    supervisor.sh           # Entry point — run this
    spawn-agent.sh          # Single agent launcher (also standalone)
    collect-learnings.sh    # Merge CLAUDE.md updates from worktrees → main
    watch.sh                # Live agent status dashboard
    update.sh               # Refresh workspace-kit + supervisor overlay
    on-stop.sh              # Claude Code Stop hook target
    migrate.sh              # 0.2.x → 1.0 migration
    uninstall.sh            # Remove supervisor from a project
    doctor.sh               # Diagnose project state
  lib/
    utils.sh                # Shared functions
    parse-bullets.sh        # Bullet-list task parser
    jsonl-tail.mjs          # Node.js session JSONL reader (for watch dashboard)
  templates/
    CLAUDE.md               # Project memory template
    .claude/
      settings.local.json   # PermissionRequest + Stop hooks
      agents/
        _example-agent.md   # Blank agent template
      skills/
        share/SKILL.md      # /share — post a peer note
        peers/SKILL.md      # /peers — read peer notes
  tests/
    smoke.sh                # Test suite
```

---

## Release workflow

```bash
npm run release:patch   # 0.1.2 → 0.1.3
npm run release:minor   # 0.1.2 → 0.2.0
npm run release:major   # 0.1.2 → 1.0.0
```

Each command bumps `package.json` + `VERSION`, commits, tags, and pushes. GitHub Actions runs the smoke tests then publishes to npm automatically.

---

## License

See [LICENSE](LICENSE).
