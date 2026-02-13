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

  # Add tasks.conf to .gitignore (personal/ephemeral — not committed)
  gitignore="$repo_path/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qx "tasks.conf" "$gitignore" 2>/dev/null; then
      printf '\n\n# Claude Supervisor — personal task config (not shared)\ntasks.conf\n' >> "$gitignore"
      ok "Added tasks.conf to .gitignore"
    fi
  else
    printf '# Claude Supervisor — personal task config (not shared)\ntasks.conf\n' > "$gitignore"
    ok "Created .gitignore with tasks.conf"
  fi

  # Scaffold .claude/ directory (skip if already exists)
  if [[ ! -d "$repo_path/.claude" ]]; then
    mkdir -p "$repo_path/.claude/agents"
    mkdir -p "$repo_path/.claude/commands"

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
      ok "Created .claude/agents/         (reviewer, debugger, test-writer subagents)"
    else
      ok "Created .claude/agents/         (add custom subagents here)"
    fi

    # Copy commands directory contents
    if [[ -d "$TEMPLATES_DIR/.claude/commands" ]]; then
      cp -r "$TEMPLATES_DIR/.claude/commands/"* "$repo_path/.claude/commands/" 2>/dev/null || true
      ok "Created .claude/commands/       (/techdebt, /explain, /diagram, /learn skills)"
    else
      ok "Created .claude/commands/       (add custom slash commands here)"
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
printf "  Repo : ${CYAN}%s${RESET}\n" "$repo_path"

step "1/5 — Checking dependencies"
check_deps

step "2/5 — Resolving API key"
resolve_api_key

step "3/5 — Fetching available models from Anthropic API"
fetch_models

# Step 3.5: Warn if the PermissionRequest hook model is no longer available
# Models get deprecated — if settings.json still references an old model ID the
# hook will silently fail, which means risky actions go ungated.
_check_hook_model() {
  local settings_file="$repo_path/.claude/settings.json"
  [[ -f "$settings_file" ]] || return
  [[ ${#AVAILABLE_MODELS[@]} -eq 0 ]] && return  # couldn't fetch models — skip check

  local hook_model=""
  if command -v jq &>/dev/null; then
    hook_model="$(jq -r '.hooks.PermissionRequest[0].hooks[0].model // empty' "$settings_file" 2>/dev/null)"
  else
    hook_model="$(grep -o '"model"[[:space:]]*:[[:space:]]*"[^"]*"' "$settings_file" | head -1 | sed 's/"model"[[:space:]]*:[[:space:]]*"//;s/"$//')"
  fi

  [[ -z "$hook_model" ]] && return

  local found=false
  local entry
  for entry in "${AVAILABLE_MODELS[@]}"; do
    if [[ "${entry%%|*}" == "$hook_model" ]]; then
      found=true
      break
    fi
  done

  if [[ "$found" == false ]]; then
    warn "PermissionRequest hook uses '$hook_model' — this model is no longer available."
    printf "    → Update ${CYAN}%s/.claude/settings.json${RESET} with a current model.\n" "$repo_path"
    printf "    → Recommended replacements (from live model list):\n"
    for entry in "${AVAILABLE_MODELS[@]}"; do
      local mid="${entry%%|*}"
      if [[ "$mid" == *opus* ]]; then
        printf "        %s\n" "$mid"
      fi
    done
    echo ""
  else
    ok "Hook model '$hook_model' is available"
  fi
}

step "4/5 — Verifying PermissionRequest hook model"
_check_hook_model

# Step 5: Parse tasks.conf (INI-style blocks) and spawn agents
tasks_file="$repo_path/tasks.conf"
total_tasks=$(grep -c '^\[task\]' "$tasks_file" 2>/dev/null || echo "0")

step "5/5 — Spawning agents  (${total_tasks} task block(s) found in tasks.conf)"

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
  local task_num=$((agent_count + 1))

  # Prompt must be non-empty
  if [[ -z "$prompt" ]]; then
    warn "Skipping task block (empty prompt)"
    return
  fi

  # Auto-generate branch from task if empty
  local branch_note=""
  if [[ -z "$branch" ]]; then
    branch="$(slugify "$prompt")"
    branch_note="  (auto-generated)"
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

  # Print task summary box
  echo ""
  printf "  ${BOLD}── Task %d of %s ───────────────────────────────────────────${RESET}\n" \
    "$task_num" "$total_tasks"
  printf "  ${BOLD}Prompt${RESET} : %s\n" "$prompt"
  printf "  ${BOLD}Branch${RESET} : %s%s\n" "$branch" "$branch_note"
  printf "  ${BOLD}Mode${RESET}   : %s\n" "$mode"

  # Pick model if not specified
  if [[ -z "$model" ]]; then
    printf "  ${BOLD}Model${RESET}  : (choose below)\n"
    model="$(pick_model "$prompt" "$branch")"
  fi
  printf "  ${BOLD}Model${RESET}  : %s\n" "$model"
  echo ""

  # Spawn the agent
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
