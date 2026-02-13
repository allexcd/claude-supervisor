#!/usr/bin/env bash
# bin/supervisor.sh — Orchestrates parallel Claude Code agents
#
# Usage: supervisor.sh [repo_path]
#   repo_path defaults to $PWD
#
# First run:  auto-init scaffolds tasks.conf + .claude/ from templates → exits
# Normal run: reads tasks.conf, spawns one agent per task line

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/utils.sh"

# ─── Parse args ─────────────────────────────────────────────────────────────

repo_path="${1:-$PWD}"

# Resolve to absolute path
if [[ -d "$repo_path" ]]; then
  repo_path="$(cd "$repo_path" && pwd)"
else
  die "Directory not found: $repo_path"
fi

# ─── Validate repo ──────────────────────────────────────────────────────────

if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
  die "Not a git repository: $repo_path"
fi

# ─── Auto-init check ────────────────────────────────────────────────────────
# If tasks.conf doesn't exist in the repo, scaffold everything from templates.

if [[ ! -f "$repo_path/tasks.conf" ]]; then
  echo ""
  info "Project not yet set up. Initialising..."
  echo ""

  # Scaffold tasks.conf
  cp "$TEMPLATES_DIR/tasks.conf" "$repo_path/tasks.conf"
  ok "Created tasks.conf"

  # Scaffold .claude/ directory (skip if already exists)
  if [[ ! -d "$repo_path/.claude" ]]; then
    mkdir -p "$repo_path/.claude/agents"

    # Copy CLAUDE.md
    if [[ -f "$TEMPLATES_DIR/CLAUDE.md" ]]; then
      cp "$TEMPLATES_DIR/CLAUDE.md" "$repo_path/.claude/CLAUDE.md"
      ok "Created .claude/CLAUDE.md       (project memory template)"
    fi

    # Copy settings.json
    if [[ -f "$TEMPLATES_DIR/.claude/settings.json" ]]; then
      cp "$TEMPLATES_DIR/.claude/settings.json" "$repo_path/.claude/settings.json"
      ok "Created .claude/settings.json   (PermissionRequest → Opus hook)"
    fi

    # Copy agents directory contents
    if [[ -d "$TEMPLATES_DIR/.claude/agents" ]]; then
      cp -r "$TEMPLATES_DIR/.claude/agents/"* "$repo_path/.claude/agents/" 2>/dev/null || true
      ok "Created .claude/agents/         (add custom subagents here)"
    else
      ok "Created .claude/agents/         (add custom subagents here)"
    fi
  else
    warn ".claude/ directory already exists — skipping scaffold"
  fi

  echo ""
  printf "${BOLD}Next:${RESET} edit ${CYAN}tasks.conf${RESET} with your tasks, then run supervisor again.\n"
  printf "      ${CYAN}%s/tasks.conf${RESET}\n" "$repo_path"
  echo ""
  exit 0
fi

# ─── Normal run — agents fire ───────────────────────────────────────────────

echo ""
printf "${BOLD}Claude Supervisor${RESET}\n"
printf "Repo: ${CYAN}%s${RESET}\n" "$repo_path"
echo ""

# Step 1: Check dependencies
check_deps

# Step 2: Resolve API key
resolve_api_key

# Step 3: Fetch models once
fetch_models

# Step 4: Parse tasks.conf (INI-style blocks) and spawn agents
tasks_file="$repo_path/tasks.conf"
agent_index=0
agent_count=0

# ─── INI block parser ────────────────────────────────────────────────────────
# Format:
#   [task]
#   prompt = description of the task
#   branch = optional-branch-name
#   model  = optional-model-id
#   mode   = normal | plan
#
# Empty lines and # comments are ignored. A [task] header starts a new block.
# When the next [task] header (or EOF) is reached, the previous block is spawned.

_spawn_current_task() {
  local branch="$1" model="$2" mode="$3" prompt="$4"

  # Prompt must be non-empty
  if [[ -z "$prompt" ]]; then
    warn "Skipping task block (empty prompt)"
    return
  fi

  # Auto-generate branch from task if empty
  if [[ -z "$branch" ]]; then
    branch="$(slugify "$prompt")"
  fi

  # Prompt for model if empty
  if [[ -z "$model" ]]; then
    model="$(pick_model "$prompt" "$branch")"
  fi

  # Default mode to normal
  if [[ -z "$mode" ]]; then
    mode="normal"
  fi

  # Validate mode
  if [[ "$mode" != "normal" && "$mode" != "plan" ]]; then
    warn "Invalid mode '$mode' for task '$prompt' — defaulting to normal"
    mode="normal"
  fi

  # Spawn the agent
  info "Spawning agent ${agent_index}: ${branch} (${model}, ${mode})"
  "$SCRIPT_DIR/spawn-agent.sh" "$repo_path" "$branch" "$model" "$mode" "$agent_index" "$prompt"

  agent_index=$((agent_index + 1))
  agent_count=$((agent_count + 1))
}

in_block=false
t_branch="" t_model="" t_mode="" t_prompt=""

while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip leading/trailing whitespace
  line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"

  # Skip empty lines and comments
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^# ]] && continue

  # [task] header — spawn previous block, start new one
  if [[ "$line" =~ ^\[task\]$ ]]; then
    if $in_block; then
      _spawn_current_task "$t_branch" "$t_model" "$t_mode" "$t_prompt"
    fi
    in_block=true
    t_branch="" t_model="" t_mode="" t_prompt=""
    continue
  fi

  # key = value pairs inside a block
  if $in_block && [[ "$line" =~ ^([a-z]+)[[:space:]]*=[[:space:]]*(.*) ]]; then
    local_key="${BASH_REMATCH[1]}"
    local_val="${BASH_REMATCH[2]}"
    case "$local_key" in
      prompt) t_prompt="$local_val" ;;
      branch) t_branch="$local_val" ;;
      model)  t_model="$local_val" ;;
      mode)   t_mode="$local_val" ;;
      *)      warn "Unknown key '$local_key' in task block — ignoring" ;;
    esac
  fi

done < "$tasks_file"

# Spawn the last block
if $in_block; then
  _spawn_current_task "$t_branch" "$t_model" "$t_mode" "$t_prompt"
fi

# ─── Summary ────────────────────────────────────────────────────────────────

session="$(basename "$repo_path")-agents"

echo ""
printf "${BOLD}─────────────────────────────────────────${RESET}\n"
printf "  Spawned ${GREEN}${agent_count}${RESET} agents. Worktrees:\n"
printf "${BOLD}─────────────────────────────────────────${RESET}\n"
git -C "$repo_path" worktree list
printf "${BOLD}─────────────────────────────────────────${RESET}\n"
echo ""
printf "  tmux session: ${CYAN}${session}${RESET}\n"
printf "  Attach with:  ${BOLD}tmux attach -t ${session}${RESET}\n"
echo ""
