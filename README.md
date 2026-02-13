# Claude Supervisor

Spin up parallel [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents in isolated git worktrees — each with its own task, model, and mode — from a single config file.

```bash
bash /path/to/claude-supervisor/bin/supervisor.sh /path/to/your-project
```

On first run it scaffolds a config file. On every run after that it reads the config and spawns one agent per `[task]` block: branch created, worktree created, tmux window opened, Claude launched. You never touch git branches or worktrees manually.

---

## Prerequisites

| Tool | Install |
|---|---|
| **git** | `xcode-select --install` (macOS) · or `brew install git` for a newer version |
| **tmux** | `brew install tmux` |
| **Node.js / npm** | [nvm](https://github.com/nvm-sh/nvm): `curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh \| bash` then `nvm install --lts` |
| **Claude Code CLI** | `npm install -g @anthropic-ai/claude-code` |

> The supervisor checks for all of these on every run. If anything is missing it will list what's needed and offer to auto-install.

To check for and apply updates via Homebrew:

```bash
brew outdated git        # check if git has an update
brew update && brew upgrade git  # update git
brew upgrade             # update all outdated formulae at once
```

You also need an [Anthropic API key](https://console.anthropic.com/). Either export it:

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

Or the supervisor will prompt you (silent input, key never echoed).

---

## Quick Start

### 1. Clone this repo

```bash
git clone <this-repo-url> claude-supervisor
cd claude-supervisor
```

### 2. First run — scaffold config into your project

```bash
bash bin/supervisor.sh /path/to/your-project
```

This creates:

```
your-project/
  tasks.conf                 # Define your tasks here (gitignored — personal)
  .gitignore                 # Updated to exclude tasks.conf
  .claude/
    CLAUDE.md                # Project memory — shared by all agents
    settings.json            # PermissionRequest → Opus hook
    agents/
      reviewer.md            # Code review subagent
      debugger.md            # Debugging and root cause analysis subagent
      test-writer.md         # Test writing subagent
      _example-agent.md      # Blank template — copy to create your own
    commands/
      techdebt.md            # /techdebt — find and fix technical debt
      explain.md             # /explain — explain code with the why
      diagram.md             # /diagram — draw ASCII architecture diagrams
      learn.md               # /learn — Socratic learning session
```

`tasks.conf` is automatically added to `.gitignore`. 

What to commit and what to ignore:

| File | Git | Why |
|---|---|---|
| `.claude/CLAUDE.md` | **Commit** | Shared project memory — conventions, pitfalls, context for all agents |
| `.claude/settings.json` | **Commit** | PermissionRequest hook config — same safety gating for everyone |
| `.claude/agents/` | **Commit** | Subagents are project tools — reviewer, debugger, test-writer |
| `.claude/commands/` | **Commit** | Slash commands belong to the project — `/techdebt`, `/explain`, etc. |
| `tasks.conf` | **Ignore** | Personal and ephemeral — your current batch of work. Two people running different tasks would conflict. |

The supervisor then exits with instructions.

### 3. Edit tasks.conf

Open `your-project/tasks.conf` and define your tasks. Each `[task]` block defines one agent:

```ini
[task]
prompt = description of the task
branch = optional-branch-name
model  = optional-model-id
mode   = normal | plan
```

Only `prompt` is required. Omit any other field to use its default:

| Field | Omitted means |
|---|---|
| `branch` | Auto-generated from prompt text (e.g. `fix login bug` → `fix-login-bug`) |
| `model` | You'll be prompted with a live model menu for that task |
| `mode` | Defaults to `normal` |

**Examples:**

```ini
# Fully specified
[task]
branch = feature-auth
model  = claude-sonnet-4-5-20250929
mode   = normal
prompt = implement the OAuth2 login flow

# Only a prompt — branch auto-generated, model prompted, mode defaults to normal
[task]
prompt = refactor the database layer to use connection pooling

# Plan mode — only prompt and mode needed
[task]
mode   = plan
prompt = review the codebase and write an implementation plan

# Explicit branch and model, mode defaults to normal
[task]
branch = fix-login-bug
model  = claude-haiku-4-5-20251001
prompt = fix the login session timeout bug
```

Blank lines and `#` comments are ignored. A `[task]` header starts a new block.

### 4. Run again — agents spawn

```bash
bash bin/supervisor.sh /path/to/your-project
```

The supervisor will:
1. Check dependencies
2. Ask for your API key (if not in env)
3. Fetch available models from the Anthropic API
4. For each task block, prompt you to pick a model (if not specified in config)
5. Create a git branch + worktree per task
6. Open a color-coded tmux window per agent
7. Launch Claude Code with the task, model, and mode
8. Print a summary with tmux attach instructions

```
─────────────────────────────────────────
  Spawned 5 agents. Worktrees:
─────────────────────────────────────────
  /path/to/your-project          abc1234 [main]
  /path/to/your-project-feature-auth  def5678 [feature-auth]
  /path/to/your-project-fix-login-bug ghi9012 [fix-login-bug]
  ...
─────────────────────────────────────────

  tmux session: your-project-agents
  Attach with:  tmux attach -t your-project-agents
─────────────────────────────────────────
```

> **Tip:** The commands above work because you `cd`'d into the claude-supervisor directory. For daily use from anywhere, either use the full path — `bash /path/to/claude-supervisor/bin/supervisor.sh /path/to/project` — or set up shell shortcuts (next section).

---

## Shell Shortcuts (Optional)

If you use the supervisor frequently, you can set up shell shortcuts to avoid typing the full path every time.

### Quick setup

Run from the claude-supervisor directory:

```bash
bash bin/setup-shortcuts.sh
```

It will:
- Auto-detect the installation path
- Back up your `~/.zshrc` to `~/.zshrc.backup-YYYYMMDD-HHMMSS`
- Let you choose between adding to **PATH** or creating **aliases** (both modify `~/.zshrc`)
- Check if already installed (won't duplicate)
- Reload your shell configuration automatically (if running in zsh)

### PATH setup (recommended)

Adds `claude-supervisor/bin` to your PATH. Then run:

```bash
supervisor.sh              # run in current directory
supervisor.sh ~/my-project
collect-learnings.sh --yes
spawn-agent.sh ~/my-project fix-bug claude-sonnet-4-5-20250929 normal 0 "fix the login bug"
```

### Alias setup

Creates short aliases. Then run:

```bash
supervisor              # run in current directory  
supervisor ~/my-project
collect-learnings --yes
spawn-agent ~/my-project fix-bug claude-sonnet-4-5-20250929 normal 0 "fix the login bug"
```

### Manual setup

If you prefer to edit `~/.zshrc` yourself:

**PATH:**
```bash
export PATH="/path/to/claude-supervisor/bin:$PATH"
```

**Aliases:**
```bash
alias supervisor='bash /path/to/claude-supervisor/bin/supervisor.sh'
alias collect-learnings='bash /path/to/claude-supervisor/bin/collect-learnings.sh'
alias spawn-agent='bash /path/to/claude-supervisor/bin/spawn-agent.sh'
```

Then reload: `source ~/.zshrc`

---

## Example Walkthrough

Assuming you have a project and want to work on two things in parallel, here's exactly what to do.

> Commands below use full paths so they work from any directory. If you set up shell shortcuts, replace `bash /path/to/claude-supervisor/bin/supervisor.sh` with `supervisor`.

**Your tasks:**
1. Add an "Ungroup All" feature — removes all tab groups at once
2. Rename tab titles using AI — infer a meaningful name from tab content

**Step 1:** Run the supervisor on your project for the first time to scaffold the config:

```bash
bash /path/to/claude-supervisor/bin/supervisor.sh /path/to/your-project
```

**Step 2:** Open `your-project/tasks.conf`, delete the example blocks, and add your two tasks:

```ini
[task]
prompt = Add "Ungroup All" functionality — a button/command that removes all tab groups at once

[task]
prompt = Rename tab titles using AI — infer a meaningful name from tab content and update the title
```

Branch names will be auto-generated from the prompts, and you'll pick a model interactively for each.

**Step 3:** Run the supervisor again:

```bash
bash /path/to/claude-supervisor/bin/supervisor.sh /path/to/your-project
```

You'll be prompted to pick a model for each task. Pick Haiku for straightforward tasks, Sonnet or Opus for complex ones. Two worktrees and two tmux windows open automatically.

**Step 4:** Attach to the tmux session and watch both agents work:

```bash
tmux attach -t your-project-agents
```

Switch between windows with `Ctrl+b n` / `Ctrl+b p`. Each window shows a banner and the live Claude session.

**Step 5:** After agents finish, collect learnings, open PRs, and clean up:

```bash
# Collect any CLAUDE.md updates agents made, before removing worktrees
bash /path/to/claude-supervisor/bin/collect-learnings.sh your-project

# Review what each agent did
git -C your-project diff main..add-ungroup-all-functionality
git -C your-project diff main..rename-tab-titles-using-ai

# Open PRs (requires gh CLI)
gh pr create --head add-ungroup-all-functionality --base main \
  --title "Add Ungroup All" --body "Implemented by Claude agent"
gh pr create --head rename-tab-titles-using-ai --base main \
  --title "Rename tab titles with AI" --body "Implemented by Claude agent"

# Once PRs are approved and merged, clean up worktrees locally
git worktree remove ../your-project-add-ungroup-all-functionality
git worktree remove ../your-project-rename-tab-titles-using-ai
```

---

## Modes

The `mode` field in `tasks.conf` controls how the agent behaves:

| Mode | Flag | What it does |
|---|---|---|
| `normal` | _(default)_ | Agent reads and writes freely. Full access to tools. Use for implementation tasks. |
| `plan` | `--permission-mode plan` | Agent can read and analyze but won't modify any files until you explicitly approve each action. Use for planning, code review, and risk assessment. Plan-mode windows are always **yellow** in tmux. |

**When to use `plan`:**
- You want to understand the scope before anything is written
- You want a second agent to review a plan before workers execute it
- The task is large or risky and you want a read-only audit first

**When to use `normal`:**
- The task is well-defined and scoped
- You trust the agent to proceed without a planning step
- You're running a small fix or an isolated feature

**Typical pattern for complex work:**

```ini
# tasks.conf

# Phase 1 — read-only planning
[task]
mode   = plan
prompt = review the codebase and write a detailed implementation plan for OAuth2 login

[task]
mode   = plan
prompt = review the above plan as a staff engineer and flag risks or missing steps

# Phase 2 — execution (add these after approving the plan)
[task]
branch = feature-auth
model  = claude-sonnet-4-5-20250929
prompt = implement the OAuth2 login flow per the approved plan

[task]
branch = write-tests
model  = claude-haiku-4-5-20251001
prompt = write tests for the new auth module
```

---

## Workflow

### Recommended pattern for complex features

**Phase 1 — Plan (read-only agents)**

```ini
[task]
mode   = plan
prompt = review the codebase and write a detailed implementation plan for the feature

[task]
mode   = plan
prompt = review the above plan as a staff engineer and flag risks or missing steps
```

Plan-mode agents use `--permission-mode plan` — they can read and analyze but won't modify files until you approve. Their tmux windows are always **yellow** so you can spot them at a glance.

**Phase 2 — Execute (worker agents)**

Once you've reviewed and approved the plan, update `tasks.conf` with workers:

```ini
[task]
branch = feature-auth
model  = claude-sonnet-4-5-20250929
prompt = implement the OAuth2 login flow per the approved plan

[task]
branch = write-tests
model  = claude-haiku-4-5-20251001
prompt = write tests for the new auth module
```

Run the supervisor again to spawn the workers.

**Phase 3 — Re-plan if needed**

If a worker goes sideways, spawn a new plan-mode agent to reassess before continuing.

### Inside each agent session

Each agent tmux window shows a banner with:

```
╔══════════════════════════════════════════════════════╗
║  CLAUDE AGENT                                        ║
╠══════════════════════════════════════════════════════╣
║  Task  : fix the login session timeout bug
║  Branch: fix-login-bug
║  Model : claude-haiku-4-5-20251001
║  Mode  : normal
╠══════════════════════════════════════════════════════╣
║  Hints:                                              ║
║  • /model      — switch model mid-session            ║
║  • /agents     — view available subagents            ║
║  • /statusline — enable context + git branch bar     ║
║  • Update CLAUDE.md after corrections                ║
║  • Explain the WHY behind every change               ║
╚══════════════════════════════════════════════════════╝
```

Useful commands inside an agent:
- **`/model`** — switch to a cheaper model once complex planning is done
- **`/agents`** — list available subagents (from `.claude/agents/`)
- **`/statusline`** — enable the context usage + git branch bar (one-time global config)

### After agents finish

Each agent works on its own branch. Open a PR per branch, review it, merge it. Worktrees are created at `../your-project-<branch>/` alongside your project directory.

```bash
# 1. Collect agent learnings back into the main CLAUDE.md (before removing worktrees!)
bash /path/to/claude-supervisor/bin/collect-learnings.sh /path/to/your-project

# 2. Commit the updated CLAUDE.md
git -C /path/to/your-project add .claude/CLAUDE.md
git -C /path/to/your-project commit -m "docs: merge agent learnings"

# 3. List all active worktrees and branches
git worktree list

# 4. Open a PR for a branch (requires gh CLI)
gh pr create --head feature-auth --base main \
  --title "Feature: OAuth2 login" --body "Implemented by Claude agent"

# 5. After the PR is merged, remove the worktree
git worktree remove ../your-project-feature-auth
```

> **Important:** Run `collect-learnings.sh` _before_ `git worktree remove`. Once a worktree is gone, its CLAUDE.md updates are gone with it.

---

## Model Selection

There are two separate model choices:

**1. Agent model** — you pick this per task. It does the actual work. The supervisor fetches available models live from the Anthropic API and presents a menu for any task with an empty model field. You can also hardcode a model ID in `tasks.conf`.

**2. PermissionRequest hook model** — hardcoded to `claude-opus-4-6` in `.claude/settings.json`. This only fires when an agent tries a risky action (e.g., deleting a file). Opus evaluates for a few seconds and returns allow/deny. It does not run continuously.

```
User picks Haiku for agent  →  agent does 95% of the work cheaply
         ↓
Agent tries to delete a file  →  PermissionRequest hook fires
         ↓
Opus evaluates for ~2s: "is this safe given the task?"  →  allow / deny
         ↓
Agent continues on Haiku
```

Opus is the gatekeeper, not the worker. The bulk of compute stays on cheap models.

**When models are deprecated:**

Anthropic periodically retires old model IDs. If `.claude/settings.json` still references a deprecated model, the `PermissionRequest` hook fails silently — risky actions go through ungated, with no error visible to you.

The supervisor detects this automatically. On every normal run it checks whether the hook model is still in the live model list:

```
⚠  PermissionRequest hook uses 'claude-opus-4-6' — this model is no longer available.
   → Update .claude/settings.json with a current model.
   → Recommended replacements (from live model list):
       claude-opus-5-0
```

When you see this warning, open `.claude/settings.json` in your project and update the `"model"` field to the model shown. The supervisor fetches the list live so the suggestion is always current.

---

## Project Memory (CLAUDE.md)

`.claude/CLAUDE.md` is copied into every worktree. Every agent reads it automatically at session start. Fill in:

- **Project Overview** — what it does, stack, entry point
- **Conventions** — style, naming, tests, branching
- **Known Pitfalls** — grows over time as agents document corrections

When an agent makes a mistake and gets corrected, it should add a note to Known Pitfalls. The next agent spawned will inherit that knowledge automatically.

### Syncing learnings back to the main repo

Each worktree gets its own **copy** of CLAUDE.md. Updates an agent makes are local to that worktree — the main repo's copy is not automatically updated. When you remove a worktree, any unsynced knowledge is lost.

**Why agents don't update the main CLAUDE.md directly:**

- **Race conditions** — Multiple agents run in parallel. If they all wrote to the same file simultaneously, you'd get conflicts and corruption.
- **Isolation** — Worktrees are separate git checkouts on separate branches. An agent reaching into the main repo's working directory to modify files would break the isolation model that makes parallel work safe.
- **Review gate** — Not every agent-discovered "pitfall" is correct or relevant. The owner should review before merging into the shared memory that all future agents inherit.

**The fix — two steps:**

1. Tell agents to commit their CLAUDE.md changes with the rest of their work. The template already includes this instruction in the Agent Instructions section.

2. Before removing worktrees, run `collect-learnings.sh` to diff each worktree's CLAUDE.md against the main and apply the new lines:

```bash
# Interactive — prompts for each worktree
bash /path/to/claude-supervisor/bin/collect-learnings.sh /path/to/your-project

# Non-interactive — auto-approve all merges (CI, scripts, testing)
bash /path/to/claude-supervisor/bin/collect-learnings.sh --yes /path/to/your-project
```

The script walks all active worktrees, shows any new lines, and asks whether to apply each one (unless `--yes` is passed). New Known Pitfalls bullets are inserted into the correct section; other additions are appended at the end. Then commit the result:

```bash
git -C /path/to/your-project add .claude/CLAUDE.md
git -C /path/to/your-project commit -m "docs: merge agent learnings"
```

This is the step that turns individual agent corrections into shared project memory.

---

## Custom Subagents

Subagents are defined in `.claude/agents/` — each file has YAML frontmatter and a system prompt. Claude Code reads them automatically at session start.

**How delegation works:** Claude automatically delegates tasks based on the task description in your request, the `description` field in subagent configurations, and current context. That's why the `description:` needs to be specific and concrete — it's essentially a routing rule. You can also add `"Use proactively"` in the description to make the agent trigger more aggressively. You can also force it explicitly: *"Use the debugger subagent to look at this error."*

Three subagents are included out of the box:

| Agent | Purpose |
|---|---|
| `reviewer.md` | Reviews code before a PR — flags critical issues, minor problems, and nits. Ends with APPROVE / REQUEST CHANGES. |
| `debugger.md` | Diagnoses errors and failures, traces root causes, applies minimal fixes. |
| `test-writer.md` | Writes unit and integration tests matching the project's existing style. |

`_example-agent.md` is a blank template you can copy to create your own. Add as many as you need — each focused on one job.

Any agent can delegate to a subagent via the `/agents` command or the `Task` tool.

---

## Spawning a Single Agent

`spawn-agent.sh` is independently runnable — you don't have to use the supervisor:

```bash
bash /path/to/claude-supervisor/bin/spawn-agent.sh /path/to/repo my-branch claude-sonnet-4-5-20250929 normal 0 "fix the login bug"
```

Arguments: `<repo_path> <branch_name> <model_id> <mode> <agent_index> "<task_prompt>"`

- `agent_index` — assigns a color to the tmux window (0-7 for different colors). Use `0` if spawning just one agent.

This creates the worktree, copies `.claude/`, opens a tmux window, and launches Claude — same as what the supervisor does, but for a single agent.

---

## Terminal Setup

- **tmux** — each agent gets its own tmux window, color-coded by index from a fixed palette. Plan-mode windows are always yellow.
- **Ghostty** — if detected, tab titles are set via OSC escape sequences.
- **Statusline** — run `/statusline` once in any Claude session to enable the context usage + git branch bar globally.

---

## File Structure

```
claude-supervisor/
  bin/
    supervisor.sh              # Entry point — run this
    spawn-agent.sh             # Single agent launcher (also standalone)
    collect-learnings.sh       # Merge CLAUDE.md updates from worktrees back to main
    setup-shortcuts.sh         # Shell shortcuts installer (adds to ~/.zshrc)
  lib/
    utils.sh                   # Shared functions (both scripts source this)
  templates/                   # Internal — never edit directly
    tasks.conf                 # Scaffolded into project on first run
    CLAUDE.md                  # Scaffolded into project .claude/
    .claude/
      settings.json            # PermissionRequest → Opus hook
      agents/
        reviewer.md            # Code review subagent
        debugger.md            # Debugging subagent
        test-writer.md         # Test writing subagent
        _example-agent.md      # Blank template
      commands/
        techdebt.md            # /techdebt skill
        explain.md             # /explain skill
        diagram.md             # /diagram skill
        learn.md               # /learn skill
```

---

## Effective Prompts & Patterns

Patterns that work well when working with agents day-to-day.

---

### CLAUDE.md as a correction loop

After every mistake an agent makes and you correct it, tell it:

> *"Update CLAUDE.md so you don't make that mistake again."*

Over time this creates a project-specific rulebook. The next agent you spawn will inherit it and skip the same mistake entirely. The key habit is being ruthless about it — every correction, every time.

The template CLAUDE.md has a **Known Pitfalls** section for exactly this. Keep it updated.

---

### Autonomous bug fixing

Point an agent at the problem and say "fix":

```ini
[task]
prompt = go fix the failing CI tests — run them, read the errors, iterate until they pass

[task]
prompt = the login flow throws a null pointer on logout — read the stack trace in logs/app.log and fix it

[task]
prompt = read docker logs for the auth service and fix whatever is causing the 500s
```

You can also paste a raw error message or Slack thread directly into the task prompt. The agent will figure out where to start.

---

### Claude as a harsh reviewer

Use a plan-mode agent to review before merging:

```ini
[task]
mode   = plan
prompt = review the diff between main and feature-auth — act as a staff engineer, be harsh, flag anything that looks wrong, fragile, or incomplete. Do not approve until you are satisfied.

[task]
mode   = plan
prompt = prove that the new auth flow actually works — trace the happy path and every failure case through the code

[task]
mode   = plan
prompt = the last solution was too complex — scrap the approach and think through a simpler implementation
```

The "prove this works" pattern is especially useful. A reviewer agent that has to justify the logic tends to catch things a writing agent glosses over.

---

### Turning repeat work into skills

There are two places to put reusable work:

- **`.claude/commands/`** — slash commands you invoke yourself (`/techdebt`, `/explain`, `/diagram`, `/learn`). Use for workflows you trigger intentionally.
- **`.claude/agents/`** — subagents Claude delegates to automatically based on the task. Use for specialized roles (reviewer, debugger, test writer).

If you do something more than once a week, it belongs in one of these. The rule of thumb: if *you* decide when to run it, it's a command. If *Claude* should decide when to delegate it, it's a subagent.

More ideas for commands:

| Command | What it does |
|---|---|
| `pr-description.md` | Reads the diff and writes a detailed PR body |
| `changelog.md` | Summarizes commits since the last tag into a CHANGELOG entry |
| `onboarding.md` | Generates an HTML walkthrough of a module for a new engineer |
| `db-query.md` | Writes and runs queries against your database CLI |

The database pattern deserves special mention: give the agent access to any DB with a CLI (`psql`, `sqlite3`, `bq`, etc.) and describe your intent in plain English. You stop writing queries and start describing outcomes.

---

### Learning mode

Enable explanatory output for any agent session via `/config` → output style → Explanatory. The agent will explain the *why* behind every change it makes, not just the *what*.

Four built-in skills accelerate understanding:

| Command | What it does |
|---|---|
| `/explain` | Explains what a file or function does, why it exists, and how it fits in |
| `/diagram` | Draws an ASCII diagram of the architecture, data flow, or call chain |
| `/learn` | Starts a Socratic learning session — you explain, Claude asks follow-ups, saves a summary |

Ad-hoc prompts that also work well:

> *"Generate an HTML presentation of this codebase I can step through like slides — one concept per slide."*

> *"I'll explain my understanding of this code. Ask follow-up questions to fill any gaps."*

These are especially useful when onboarding to an unfamiliar codebase before spawning worker agents.

---

### Shell aliases for session navigation

Add these to your `~/.zshrc` or `~/.bashrc` to hop between agent windows in one keystroke:

```bash
# Jump to agent window by letter — adjust session name as needed
alias za='tmux select-window -t agents:0'
alias zb='tmux select-window -t agents:1'
alias zc='tmux select-window -t agents:2'
alias zd='tmux select-window -t agents:3'

# Or jump by branch name (fuzzy)
agent() { tmux select-window -t "$(tmux list-windows -F '#{window_name}' | fzf --query="$1" --select-1)"; }
```

The `agent` function with `fzf` lets you type `agent login` and jump straight to the `feature-login` window without counting indices.

---

## Running Tests

Smoke tests verify that all functions and scripts work correctly:

```bash
bash tests/smoke.sh
```

The test suite checks: `slugify`, `print_banner`, `check_deps`, auto-init scaffolding, `tasks.conf` parsing, and `spawn-agent.sh` argument validation — all without needing an API key or tmux.

---

## License

See [LICENSE](LICENSE).
