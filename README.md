# Claude Supervisor

[![npm version](https://img.shields.io/npm/v/claude-supervisor.svg)](https://www.npmjs.com/package/claude-supervisor)
[![CI](https://github.com/allexcd/claude-supervisor/actions/workflows/ci.yml/badge.svg)](https://github.com/allexcd/claude-supervisor/actions/workflows/ci.yml)
[![npm downloads](https://img.shields.io/npm/dm/claude-supervisor)](https://www.npmjs.com/package/claude-supervisor)
[![License](https://img.shields.io/github/license/allexcd/claude-supervisor)](LICENSE)

Spin up parallel [Claude Code](https://docs.anthropic.com/en/docs/claude-code) agents in isolated git worktrees — each with its own task, model, and mode — from a single config file.

```bash
bash /path/to/claude-supervisor/bin/supervisor.sh /path/to/your-project
```

On first run it scaffolds a config file. On every run after that it reads the config and spawns one agent per `[task]` block: branch created, worktree created, Claude launched in a tmux window. At the end it prints ready-to-copy commands so you can also open each agent in its own terminal tab.

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

**Billing:** The supervisor supports two billing modes:

| Mode | Who | API key needed? |
|---|---|---|
| **Pro / Max / Team** | Claude subscription users | No — authenticate via Claude's OAuth login |
| **API key** | Anthropic Console users | Yes — `ANTHROPIC_API_KEY` required |

The supervisor remembers your billing mode choice and saves it to your project's `.env` file. On subsequent runs, it uses the saved preference without re-prompting. If it finds `ANTHROPIC_API_KEY` in the environment or in your project's `.env`, it auto-selects API mode.

To change your billing mode later, use the `--reset` flag:

```bash
bash bin/supervisor.sh --reset /path/to/your-project
```

API-key users can export the key beforehand (`export ANTHROPIC_API_KEY=sk-ant-...`) or enter it at the prompt — it's saved to `.env` so you only enter it once.

---

## Install via npm

The supervisor is published to npm. If you already have Node.js/npm installed (required for Claude Code CLI), this is the fastest way to get started.

### Option A — Global install (personal use, run from any directory)

```bash
npm install -g claude-supervisor
supervisor.sh ~/my-project
```

### Option B — Local devDependency (teams, CI, version-locked)

```json
// your-project/package.json
{
  "scripts": {
    "agents":         "supervisor.sh",
    "agents:reset":   "supervisor.sh --reset",
    "agents:collect": "collect-learnings.sh --yes"
  },
  "devDependencies": {
    "claude-supervisor": "^0.1.0"
  }
}
```

```bash
npm install          # pulls in claude-supervisor
npm run agents       # first run → scaffolds tasks.conf + .claude/ → exits
# edit tasks.conf
npm run agents       # spawns agents
```

npm symlinks the bin entries into `node_modules/.bin/` and adds that directory to PATH during `npm run`. The shell scripts resolve their own location via `BASH_SOURCE[0]` which follows symlinks correctly, so `../lib/utils.sh` and `../templates/` resolve to the right place inside `node_modules/claude-supervisor/`.

### Option C — Clone and run directly (no install required)

```bash
git clone <this-repo-url> claude-supervisor
bash claude-supervisor/bin/supervisor.sh ~/my-project
```

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

The supervisor then displays common model IDs so you know what to put in `tasks.conf`. If an API key is available (environment variable or `.env` file), it also fetches the full list from the Anthropic API.

What to commit and what to ignore:

| File | Git | Why |
|---|---|---|
| `.claude/CLAUDE.md` | **Commit** | Shared project memory — conventions, pitfalls, context for all agents |
| `.claude/settings.json` | **Commit** | PermissionRequest hook config — same safety gating for everyone |
| `.claude/agents/` | **Commit** | Subagents are project tools — reviewer, debugger, test-writer |
| `.claude/commands/` | **Commit** | Slash commands belong to the project — `/techdebt`, `/explain`, etc. |
| `tasks.conf` | **Ignore** | Personal and ephemeral — your current batch of work. Two people running different tasks would conflict. |
| `.env` | **Ignore** | Contains your API key (API-key billing only) — automatically gitignored when created. |

The supervisor then exits with instructions.

> **Tip:** If you skip the model list during first run, that's fine — you can omit the `model` field in tasks.conf and the supervisor will show an interactive menu on the next run.

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
2. Use saved billing mode preference, or prompt if first run (Pro subscription or API key)
3. Resolve API key (API-key users only — prompts if not found, saves to `.env`)
4. Fetch available models (live from API for API-key users, static list for Pro users)
5. For each task block, prompt you to pick a model (if not specified in config)
6. Create a git branch + worktree per task
7. Open a tmux window per agent, launch Claude Code
8. Auto-paste the task prompt into Claude after it loads
9. Print instructions for accessing each agent

### 5. Access your agents

After spawning, the supervisor prints two options:

**Option A — tmux (all agents in one place):**

```bash
tmux attach -t your-project-agents
```

| Key | Action |
|---|---|
| `Ctrl+b n` | Next agent |
| `Ctrl+b p` | Previous agent |
| `Ctrl+b w` | List all agents — pick one |
| `Ctrl+b 0` / `1` / `2` | Jump to agent by number |
| `Ctrl+b d` | Detach (agents keep running in background) |

> **Note:** Press `Ctrl+b`, release **both** keys, then press the second key. It's two separate keystrokes, not a three-key combo.

**Option B — separate terminal tabs (simpler navigation):**

The supervisor prints a ready-to-copy `cd ... && claude ...` command for each agent. Open a new tab in your terminal (`Cmd+T`), paste the command, and you're in. Use normal tab switching (`Cmd+1`, `Cmd+2`, etc.).

Example output:

```
═══════════════════════════════════════════════════════════════
  ✓ Spawned 2 agent(s) in tmux session: your-project-agents
═══════════════════════════════════════════════════════════════

  Option A — Attach to tmux (all agents in one place):

    tmux attach -t your-project-agents

  Option B — Open each agent in its own terminal tab:

    Tab 1 — implement the OAuth2 login flow
    cd /path/to/your-project-feature-auth && claude --model claude-sonnet-4-5-20250929

    Tab 2 — fix the login session timeout bug
    cd /path/to/your-project-fix-login-bug && claude --model claude-haiku-4-5-20251001

    Then paste the task prompt into Claude when it loads.

═══════════════════════════════════════════════════════════════
```

> **IMPORTANT — First time using Claude Code CLI?** You'll see Claude's setup wizard asking "Select login method". **Press `1`** if you have a Claude Pro/Max/Team subscription, or **press `2`** if you're using an Anthropic API key. This setup is one-time per machine.

**Detach and reattach tmux anytime:**

```bash
# Detach (go back to your shell, agents keep running)
Ctrl+b d

# Reattach later
tmux attach -t your-project-agents

# List all sessions
tmux ls
```

> **Tip:** The commands above work because you `cd`'d into the claude-supervisor directory. For daily use from anywhere, either use the full path — `bash /path/to/claude-supervisor/bin/supervisor.sh /path/to/project` — or set up shell shortcuts (next section).

**Usage:**

```bash
supervisor.sh [--reset] [repo_path]
```

- `--reset`: Re-prompt for billing mode (clears saved preference)
- `repo_path`: Project directory (defaults to current directory)

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

**Step 4:** Access your agents. The supervisor prints two options:

**Option A — tmux:** Attach to the tmux session and navigate between agents:

```bash
tmux attach -t your-project-agents
```

**Option B — separate tabs:** Copy the `cd ... && claude ...` command for each agent into a new terminal tab (`Cmd+T`).

You'll see each agent in its own color-coded tmux window with a banner showing the task.

> **First time using Claude Code CLI?** You'll see a setup wizard asking "Select login method:". **Press `1` and Enter** if you have a Claude Pro/Max/Team subscription, or **Press `2` and Enter** if you're using an Anthropic API key (Console billing). This is one-time setup per machine. After setup, Claude will show its prompt.

When Claude loads:
- **Copy the task** from the banner at the top and paste it to Claude to begin
- Switch between agents with `Ctrl+b` then `n`/`p` (tmux) or `Cmd+1`/`Cmd+2` (tabs)
- Type **`/model`** to switch models mid-session (e.g. start with Opus for planning, switch to Haiku for implementation)

Each agent works independently on its worktree.

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

# Kill the tmux session (stops all agents)
tmux kill-session -t your-project-agents
```

> **Tip:** If you need to stop agents early or start over, see the "Stopping agents and cleaning up worktrees" section below.

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

Each agent tmux window shows a banner with the task details:

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

▸ Starting Claude...

💡 Task will be shown above - you can copy/paste it to Claude when ready
```

**First time using Claude Code CLI on this machine?**

Before the banner appears, you'll see Claude's setup wizard:

```
Select login method:
 › 1. Claude account with subscription · Pro, Max, Team, or Enterprise
   2. Anthropic Console account · API usage billing
   3. 3rd-party platform · Amazon Bedrock, Microsoft Foundry, or Vertex AI
```

**Press `1` and Enter** if you have a Claude Pro, Max, Team, or Enterprise subscription. **Press `2` and Enter** if you're using an Anthropic API key (Console billing). This is one-time setup per machine. After completing setup, the banner will appear and Claude will be ready.

**Start the agent:** Copy the task text from the banner and paste it to Claude when ready. The agent will begin working on it immediately.

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
gh pr create --head feature-auth --base main 
  --title "Feature: OAuth2 login" --body "Implemented by Claude agent"

# 5. After the PR is merged, remove the worktree
git worktree remove ../your-project-feature-auth
```

> **Important:** Run `collect-learnings.sh` _before_ `git worktree remove`. Once a worktree is gone, its CLAUDE.md updates are gone with it.

### Stopping agents and cleaning up worktrees

**To stop all agents and kill the tmux session:**

```bash
# Kill the entire tmux session (stops all agents immediately)
tmux kill-session -t your-project-agents
```

**To list and remove worktrees:**

```bash
# 1. List all active worktrees
git worktree list

# 2. Remove a specific worktree
git worktree remove ../your-project-feature-auth

# 3. Force remove (if there are uncommitted changes)
git worktree remove --force ../your-project-feature-auth

# 4. Remove all agent worktrees for a project
git worktree list | grep "your-project-" | awk '{print $1}' | xargs -I {} git worktree remove --force {}
```

**Common scenarios:**

| Scenario | Commands |
|---|---|
| **Agents stuck/hung** | `tmux kill-session -t project-agents` |
| **Start fresh** | Kill session → remove worktrees → edit `tasks.conf` → run supervisor again |
| **Agent finished, want to keep work** | Don't remove worktree yet — open PR from that branch first |
| **Agent failed, want to retry** | Remove worktree → remove branch → run supervisor again (it will recreate) |
| **Force closed terminal** | Agents still running — use `tmux attach` to reconnect, or `tmux kill-session` to stop |
| **Killed session, want to resume** | Just run the supervisor again with the same `tasks.conf` — it detects existing worktrees and reuses them, no work is lost |

**To remove branches after removing worktrees:**

```bash
# List all branches
git branch -a

# Delete a local branch (after merging)
git branch -d feature-auth

# Force delete a local branch (without merging)
git branch -D feature-auth
```

---

## Model Selection

There are two separate model choices:

**1. Agent model** — you pick this per task. It does the actual work.

- **Pro users:** the supervisor shows a static list of common models. You can also type `/model` inside any agent session to switch models on the fly.
- **API-key users:** models are fetched live from the Anthropic API.
- For any task with an empty `model` field, the supervisor presents an interactive menu. You can also hardcode a model ID in `tasks.conf`.

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

## How Agents Run

The supervisor uses **tmux** to run agents in the background. Each agent gets its own tmux window with a descriptive name. This works in any terminal (iTerm, Terminal.app, Ghostty, VS Code, etc.).

After spawning, you have two ways to access agents:

| Method | Best for | How |
|---|---|---|
| **tmux attach** | Monitoring all agents at once | `tmux attach -t session` + navigate with `Ctrl+b` |
| **Separate tabs** | Easier navigation, familiar workflow | Copy the `cd ... && claude ...` commands into new tabs |

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

## Release Workflow

```bash
# Bump version, update VERSION file, commit, and tag — all in one:
npm version patch    # or minor / major
npm publish          # runs smoke tests, then publishes to npm registry

# Git tag is created automatically by npm version
git push && git push --tags
```

`npm version` updates `package.json`, writes the new version to `VERSION`, stages it, and creates a git commit + tag. `npm publish` runs the smoke tests first — if they fail, the publish is aborted.

---

## License

See [LICENSE](LICENSE).
