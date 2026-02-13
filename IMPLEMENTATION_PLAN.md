# Claude Supervisor — Implementation Plan

## Goal
A pure-bash tool that spins up N parallel Claude Code agents, each in an isolated git worktree,
each with a chosen model, mode (normal/plan), and task — with terminal color-coding, CLAUDE.md memory,
subagent support, and a PermissionRequest hook that routes risky decisions to Opus.

---

## File Tree to Produce

```
bin/
  supervisor.sh                    # Orchestrator entry point (handles auto-init + run)
  spawn-agent.sh                   # Single agent launcher
lib/
  utils.sh                         # All shared functions
templates/                         # Internal — never touched by user directly
  tasks.conf                       # Scaffolded into target project by auto-init
  CLAUDE.md                        # Scaffolded into target project .claude/
  .claude/
    settings.json                  # PermissionRequest → Opus hook
    agents/                        # Empty dir placeholder (user populates)
.gitignore                         # Already done
ARCHITECTURE.md                    # Already done
IMPLEMENTATION_PLAN.md             # This file
```

## How It All Fits Together

```
USER RUNS:
  supervisor.sh [repo_path]

WHAT HAPPENS AUTOMATICALLY:

  1. First run (project not set up):
     supervisor detects no tasks.conf in repo
     → scaffolds from templates/ into repo:
          repo/.claude/CLAUDE.md
          repo/.claude/settings.json
          repo/.claude/agents/
          repo/tasks.conf
     → prints "Edit tasks.conf with your tasks, then run again"
     → exits

  2. Normal run (tasks.conf exists):
     for each task line in tasks.conf:
       → git branch created automatically (-b flag)
       → git worktree created automatically at ../repo-branch/
       → .claude/ copied from repo into worktree
       → tmux window opened, color-coded
       → claude launched with task, model, mode
     → summary printed

USER NEVER:
  - Creates branches manually
  - Creates worktrees manually
  - Copies files into worktrees manually
  - Runs a separate init command
```

---

## Step 1 — Directory Structure

Create all directories:
```
bin/  lib/  templates/  templates/.claude/  templates/.claude/agents/
```

---

## Step 2 — `lib/utils.sh`

Source guard at top: `[[ -n "$_UTILS_LOADED" ]] && return; _UTILS_LOADED=1`

### 2.1 `check_deps`
- Required tools: `git`, `tmux`, `npm`, `claude`
- Loop over each tool, collect missing ones into an array
- If none missing → return 0
- Print a clear list of what's missing with install instructions for each:
  - `git`: "Install via Xcode CLI: xcode-select --install"
  - `tmux`: "brew install tmux"
  - `npm`: "Install nvm first: curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash  then: nvm install --lts"
  - `claude`: "npm install -g @anthropic-ai/claude-code"
- Ask: "Auto-install missing tools? [y/N]"
- If no → print instructions and `exit 1`
- If yes → install in correct order:
  1. If `npm` missing: install nvm via curl, source it, run `nvm install --lts`
  2. If `tmux` missing: `brew install tmux` (macOS) else print manual instructions
  3. If `claude` missing: `npm install -g @anthropic-ai/claude-code`
- Re-check after install; if still failing → print instructions and `exit 1`

### 2.2 `resolve_api_key`
- If `$ANTHROPIC_API_KEY` is set and non-empty → export it and return
- Else prompt: "Enter your Anthropic API key: " using `read -s ANTHROPIC_API_KEY`
- Print newline after silent read
- Validate non-empty; if empty → error and `exit 1`
- `export ANTHROPIC_API_KEY`
- Note: key will be passed explicitly to tmux windows via `tmux send-keys` or `env` in the window command — not inherited

### 2.3 `fetch_models`
- Populates global array `AVAILABLE_MODELS` with entries formatted as `"id|display_name"`
- `curl -sf -H "x-api-key: $ANTHROPIC_API_KEY" -H "anthropic-version: 2023-06-01" https://api.anthropic.com/v1/models`
- Parse JSON:
  - If `jq` available: `jq -r '.data[] | "\(.id)|\(.display_name)"'`
  - Else: `grep`/`sed` fallback — extract `"id":"..."` and `"display_name":"..."` pairs
- If curl fails or array is empty → warn user, ask to enter model ID manually
- Manual entry is stored as `"manual-entry|$user_input"` and AVAILABLE_MODELS set to that single entry

### 2.4 `pick_model <task_prompt> <branch_name>`
- Receives task + branch as args so it can display context before the menu
- Print:
  ```
  ─────────────────────────────────────────
  Task  : <task_prompt>
  Branch: <branch_name>

  Available models:
    1) id     — display_name
    2) ...

  Select model [1]:
  ```
- Use a `select`-style numbered loop (plain `read` — no `select` builtin, avoids PS3 issues)
- Accept number input; validate range
- On invalid input → re-prompt
- Return selected model ID via `echo` (caller captures with `$()`)

### 2.5 `slugify <text>`
- Input: arbitrary string
- Output: lowercase, spaces→hyphens, strip non-alphanumeric except hyphens, collapse multiple hyphens, strip leading/trailing hyphens
- Max 50 chars to keep branch names sane
- Example: "implement OAuth2 login flow" → "implement-oauth2-login-flow"

### 2.6 `setup_window <session> <window_name> <index> <mode>`
- Color palette array (indexes cycle):
  ```bash
  PALETTE=("colour33" "colour70" "colour166" "colour126" "colour31" "colour208")
  # plan mode always: colour220 (yellow)
  ```
- Determine color:
  - If mode == "plan" → `colour220`
  - Else → `PALETTE[$((index % ${#PALETTE[@]}))]`
- Set tmux window style: `tmux set-window-option -t "$session:$window_name" window-status-style "bg=$color,fg=colour232,bold"`
- Set tmux window title: `tmux rename-window -t "$session:$window_name" "$window_name"`
- If Ghostty detected (`$TERM_PROGRAM == "ghostty"`): set tab title via OSC 0
  - Done by sending `printf '\033]0;%s\007' "$window_name"` inside the tmux window

### 2.7 `print_banner <task> <branch> <model> <mode>`
- Print to stdout (will be run inside the tmux window via send-keys or shell init):
  ```
  ╔══════════════════════════════════════════════════════╗
  ║  CLAUDE AGENT                                        ║
  ╠══════════════════════════════════════════════════════╣
  ║  Task  : <task>                                      ║
  ║  Branch: <branch>                                    ║
  ║  Model : <model>                                     ║
  ║  Mode  : <mode>                                      ║
  ╠══════════════════════════════════════════════════════╣
  ║  Hints:                                              ║
  ║  • /model      — switch model mid-session            ║
  ║  • /agents     — view available subagents            ║
  ║  • /statusline — enable context + git branch bar     ║
  ║  • Update CLAUDE.md after corrections                ║
  ║  • Explain the WHY behind every change               ║
  ╚══════════════════════════════════════════════════════╝
  ```
- Note: this banner is written to a temp script that gets executed inside the tmux window before claude starts

---

## Step 3 — `bin/spawn-agent.sh`

Usage: `spawn-agent.sh <repo_path> <branch_name> <model_id> <mode> <agent_index> "<task_prompt>"`

All args required (supervisor always passes all of them).

```
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
```

Steps:
1. **Validate args** — exactly 6 args; error with usage if not
2. **Validate repo** — `git -C "$repo_path" rev-parse --git-dir` must succeed; error if not a git repo
3. **Derive worktree path** — `<repo_parent>/<repo_name>-<branch_name>`
   - `repo_parent=$(dirname "$repo_path")`
   - `repo_name=$(basename "$repo_path")`
   - `worktree_path="$repo_parent/$repo_name-$branch_name"`
4. **Create worktree**
   - If `$worktree_path` already exists: print "Worktree already exists at $worktree_path, skipping creation"
   - Else: `git -C "$repo_path" worktree add "$worktree_path" -b "$branch_name"` (if branch doesn't exist)
   - Or: `git -C "$repo_path" worktree add "$worktree_path" "$branch_name"` (if branch already exists)
   - Use `git -C "$repo_path" branch --list "$branch_name"` to detect
5. **Copy `.claude/` directory**
   - Source: `$repo_path/.claude/`
   - Dest: `$worktree_path/.claude/`
   - If source exists: `cp -r "$repo_path/.claude/" "$worktree_path/.claude/"`
   - If not: silently skip (agent still works, just without project hooks/agents)
6. **Tmux setup**
   - Derive session name: `$(basename "$repo_path")-agents`
   - If inside tmux (`$TMUX` set):
     - `tmux new-window -t "$session" -n "$branch_name" -c "$worktree_path"` (attach to existing session)
   - Else:
     - Check if session exists: `tmux has-session -t "$session" 2>/dev/null`
     - If not: `tmux new-session -d -s "$session" -n "$branch_name" -c "$worktree_path"`
     - If yes: `tmux new-window -t "$session" -n "$branch_name" -c "$worktree_path"`
7. **Setup window color + title**
   - Call `setup_window "$session" "$branch_name" "$agent_index" "$mode"`
8. **Write startup script to temp file**
   - Create `$worktree_path/.claude-agent-start.sh` (removed after claude exits)
   - Contents:
     ```bash
     #!/usr/bin/env bash
     export ANTHROPIC_API_KEY="<key>"
     # print banner
     <banner content>
     # remove this script
     rm -f "$worktree_path/.claude-agent-start.sh"
     # launch claude
     if [[ "$mode" == "plan" ]]; then
       exec claude --model "$model_id" --permission-mode plan
     else
       exec claude --model "$model_id"
     fi
     ```
   - `chmod +x` the script
9. **Send startup script to tmux window**
   - `tmux send-keys -t "$session:$branch_name" "bash $worktree_path/.claude-agent-start.sh" Enter`

---

## Step 4 — `bin/supervisor.sh`

Usage: `supervisor.sh [repo_path]`
- `repo_path` defaults to `$PWD`
- `tasks.conf` always read from `$repo_path/tasks.conf`

```
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/utils.sh"
```

Steps:
1. **Parse args** — `repo_path="${1:-$PWD}"`
2. **Validate repo** — `git -C "$repo_path" rev-parse --git-dir` must succeed; error if not a git repo
3. **Auto-init check** — if `$repo_path/tasks.conf` does NOT exist:
   - Print: "Project not yet set up. Initialising..."
   - Copy `templates/tasks.conf` → `$repo_path/tasks.conf`
   - Copy `templates/.claude/` → `$repo_path/.claude/` (skip if already exists)
   - Print:
     ```
     ✓ Created tasks.conf
     ✓ Created .claude/settings.json  (PermissionRequest → Opus hook)
     ✓ Created .claude/CLAUDE.md      (project memory template)
     ✓ Created .claude/agents/        (add custom subagents here)

     Next: edit tasks.conf with your tasks, then run supervisor again.
     ```
   - `exit 0`
4. **`check_deps`**
5. **`resolve_api_key`**
6. **`fetch_models`** — populates `AVAILABLE_MODELS`
7. **Parse tasks.conf (INI-style blocks)**
   - Iterate lines; skip blanks and `#` comments
   - `[task]` header → spawn previous block (if any), reset fields
   - `key = value` lines → populate `t_branch`, `t_model`, `t_mode`, `t_prompt`
   - On next `[task]` or EOF, spawn the accumulated block:
     - `prompt` must be non-empty; skip with warning if blank
     - If `branch` empty → `branch=$(slugify "$prompt")`
     - If `model` empty → `model=$(pick_model "$prompt" "$branch")`
     - If `mode` empty → `mode="normal"`
     - Validate `mode` is "normal" or "plan"; default to "normal" if invalid
     - Call: `"$SCRIPT_DIR/spawn-agent.sh" "$repo_path" "$branch" "$model" "$mode" "$agent_index" "$prompt"`
     - Increment `agent_index`
8. **Print summary**
   ```
   ─────────────────────────────────────────
   Spawned <N> agents. Worktrees:
   ─────────────────────────────────────────
   <git -C "$repo_path" worktree list output>
   ─────────────────────────────────────────
   tmux session: <session_name>
   Attach with: tmux attach -t <session_name>
   ─────────────────────────────────────────
   ```

---

## Step 5 — `templates/tasks.conf`

**Purpose:** Scaffolded into `<project>/tasks.conf` on first run. The user edits this file to define what each agent should work on. The supervisor reads it at runtime — agents never see it directly.

**Format:** INI-style blocks. Each `[task]` header starts a new agent. Only `prompt` is required:
- `branch` omitted → auto-generated from prompt text via `slugify`
- `model` omitted → user is prompted interactively with a live model menu
- `mode` omitted → defaults to `normal` | options: `normal` · `plan`

```ini
# Claude Supervisor — Tasks Config
#
# Each [task] block defines one agent. Only `prompt` is required.
# Omit any other field to use defaults or be prompted interactively.

# --- Plan phase ---

[task]
mode   = plan
prompt = review the codebase and write a detailed implementation plan for OAuth2 login

[task]
mode   = plan
prompt = review the above plan as a staff engineer and flag risks or missing steps

# --- Execution phase ---

[task]
branch = feature-auth
model  = claude-sonnet-4-5-20250929
prompt = implement the OAuth2 login flow per the approved plan

[task]
branch = fix-login-bug
model  = claude-haiku-4-5-20251001
prompt = fix the login session timeout bug

[task]
prompt = refactor the database layer to use connection pooling
```

---

## Step 6 — `templates/CLAUDE.md`

**Purpose:** Scaffolded into `<project>/.claude/CLAUDE.md` on first run. Copied into every worktree at agent spawn time. Every agent reads it as project memory. The user fills in their project specifics and updates "Known Pitfalls" after every correction — so agents learn over time.

**Default content (shipped as-is, user fills in the blanks):**

```markdown
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
```

---

## Step 7 — `templates/.claude/settings.json`

**Purpose:** Scaffolded into `<project>/.claude/settings.json` on first run. Copied into every worktree. Configures the `PermissionRequest` hook so risky tool calls are routed to Opus for approval rather than prompting the user — cheap agents do the work, Opus makes trust decisions.

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "prompt",
            "model": "claude-opus-4-6",
            "prompt": "A Claude agent running on a cheaper model is requesting permission to use a tool. Your job is to decide whether this action is safe and appropriate given the agent's assigned task. Deny if the action looks destructive, irreversible without clear justification, out of scope for the task, or potentially harmful. Approve if it is clearly safe and aligned with the stated task. Return only valid JSON: {\"ok\": true} to approve or {\"ok\": false, \"reason\": \"<why>\"} to deny. Context: $ARGUMENTS",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

---

## Step 7b — `templates/.claude/agents/`

**What it is:** A directory where each `.md` file defines a custom Claude Code subagent — a specialized assistant with its own system prompt, tool access, and description. Claude Code reads these files automatically. When an agent needs to delegate a narrow task, it can spawn one of these subagents via the `Task` tool.

**Why it matters for this project:** Every worktree gets a copy of this directory. So any custom subagent the user defines in their project will be available to every spawned agent automatically.

**File format:** YAML frontmatter + markdown system prompt.

```
.claude/agents/
  techdebt.md           # Finds and removes duplicated/messy code
  code-reviewer.md      # Reviews changes for quality and security
  test-writer.md        # Writes tests for a given function or module
```

**Example — `templates/.claude/agents/techdebt.md`** (ship this as a starter):

```markdown
---
name: techdebt
description: Use this agent when asked to find technical debt, remove duplicated code, simplify over-engineered logic, or clean up dead code. Do not use for feature work.
tools:
  - Read
  - Glob
  - Grep
  - Edit
  - Write
  - Bash
---

You are a senior engineer specializing in code quality and technical debt reduction.

Your job:
1. Find duplicated logic, copy-pasted code, or near-identical functions
2. Find dead code — unused exports, unreachable branches, commented-out blocks
3. Simplify over-engineered abstractions that could be replaced with simpler code
4. Consolidate without changing external behaviour

Rules:
- Never change public API signatures without flagging it explicitly
- Always explain WHY a change reduces debt, not just what you changed
- Run tests after each change to verify nothing broke
- Make one focused change at a time — do not refactor everything at once
```

---

## Step 8 — Make scripts executable

```bash
chmod +x bin/supervisor.sh bin/spawn-agent.sh
```

---

## Step 9 — Smoke tests (manual, step by step)

### Test A — `slugify`
```bash
source lib/utils.sh
slugify "implement OAuth2 login flow"
# expected: implement-oauth2-login-flow
slugify "Fix  the BUG!! in prod@env"
# expected: fix-the-bug-in-prodenv
```

### Test B — `check_deps`
```bash
source lib/utils.sh
check_deps
# expected: prints missing tools or "all dependencies satisfied"
```

### Test C — `fetch_models`
```bash
export ANTHROPIC_API_KEY=sk-ant-...
source lib/utils.sh
fetch_models
echo "${AVAILABLE_MODELS[@]}"
# expected: array of "id|display_name" entries
```

### Test D — `spawn-agent.sh` standalone
```bash
# Use any local git repo as test target
bash bin/spawn-agent.sh /path/to/test-repo test-branch-1 claude-haiku-4-5-20251001 normal 0 "fix the login bug"
# expected:
# - worktree created at ../test-repo-test-branch-1
# - tmux session or window created
# - banner printed in window
# - claude launched in window
```

### Test E — `supervisor.sh` full run
```bash
# Copy examples/tasks.conf to a test repo, edit 1-2 lines
bash bin/supervisor.sh /path/to/test-repo /path/to/test-repo/tasks.conf
# expected:
# - model prompts shown per agent with empty model field
# - all worktrees created
# - tmux windows color-coded
# - summary printed with git worktree list
```

### Test F — edge cases
- Empty branch field → slugify fires
- Empty model field → pick_model prompts
- Empty mode field → defaults to "normal"
- Duplicate branch → worktree creation skipped, agent still launches
- No `.claude/` in repo → copy step silently skipped

---

## Critical Implementation Notes

1. **API key in tmux windows** — do NOT rely on env inheritance. Write the key explicitly into the startup script that runs inside the tmux window.

2. **`read -s` for API key** — always use silent read. Print a newline after it (`echo`) so the terminal doesn't look broken.

3. **`set -euo pipefail`** in all scripts — fail fast, no silent errors.

4. **INI-style config parsing** — `tasks.conf` uses `[task]` blocks with `key = value` pairs. Parse by iterating lines: `[task]` starts a new block, `key = value` lines populate fields, next `[task]` or EOF triggers spawn of the current block. Use `BASH_REMATCH` from `[[ "$line" =~ ^([a-z]+)[[:space:]]*=[[:space:]]*(.*) ]]` to extract key/value pairs.

5. **tmux session already exists** — always check with `tmux has-session` before creating; attach/add-window to existing session rather than erroring.

6. **Worktree branch collision** — check if branch already exists in repo before passing `-b` flag to `git worktree add`.

7. **`jq` is optional** — `fetch_models` must work without it. Test both paths.

8. **Startup script cleanup** — the `.claude-agent-start.sh` temp file must `rm -f` itself before launching claude, so it doesn't pollute the worktree.

9. **`spawn-agent.sh` must be independently runnable** — never assume it was called by supervisor. All validation duplicated.

10. **plan mode cursor** — `--permission-mode plan` is the correct flag for claude CLI plan mode.
