#!/usr/bin/env bash
# bin/supervisor.sh — Orchestrates parallel Claude Code agents
#
# Usage: supervisor.sh [--reset] [repo_path]
#   repo_path defaults to $PWD
#   --reset   re-prompt for billing mode (Pro vs API)
#
# First run:  auto-init scaffolds tasks.conf + .claude/ from templates → exits
# Normal run: reads tasks.conf, spawns one agent per task line

set -euo pipefail

_SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_SCRIPT_PATH" ]]; do
  _SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
  _SCRIPT_PATH="$(readlink "$_SCRIPT_PATH")"
  [[ "$_SCRIPT_PATH" != /* ]] && _SCRIPT_PATH="$_SCRIPT_DIR/$_SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"
VERSION="$(cat "$SCRIPT_DIR/../VERSION" 2>/dev/null || echo "unknown")"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/utils.sh"

# ─── Parse args ─────────────────────────────────────────────────────────────

RESET_BILLING=""
args=()
for arg in "$@"; do
  case "$arg" in
    --reset)      RESET_BILLING=1 ;;
    --version|-V) printf "claude-supervisor %s\n" "$VERSION"; exit 0 ;;
    *)            args+=("$arg") ;;
  esac
done
export RESET_BILLING

repo_path="${args[0]:-$PWD}"

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

  # Show available models so the user knows what to put in tasks.conf
  step "Available models"
  show_available_models "$repo_path"

  echo ""
  printf "${BOLD}Next:${RESET} edit ${CYAN}tasks.conf${RESET} with your tasks, then run supervisor again.\n"
  printf "      ${CYAN}%s/tasks.conf${RESET}\n" "$repo_path"
  echo ""
  info "Leave the model field blank in tasks.conf to choose at run time."
  info "Pro subscribers authenticate via Claude — no API key needed."
  echo ""
  exit 0
fi

# ─── Normal run — agents fire ───────────────────────────────────────────────

echo ""
printf "${BOLD}Claude Supervisor v%s${RESET}\n" "$VERSION"
printf "  Repo : ${CYAN}%s${RESET}\n" "$repo_path"

step "1/4 — Checking dependencies"
check_deps

step "2/4 — Billing mode & authentication"
ask_billing_mode "$repo_path"

if [[ "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" == "api" ]]; then
  resolve_api_key "$repo_path"
  save_api_key_to_env "$repo_path"
fi

step "3/4 — Loading available models"
fetch_models

# Warn if the PermissionRequest hook model is no longer available.
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

if [[ "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" == "api" ]]; then
  _check_hook_model
fi

# Step 5: Parse tasks.conf (INI-style blocks) and spawn agents
tasks_file="$repo_path/tasks.conf"
total_tasks=$(grep -c '^\[task\]' "$tasks_file" 2>/dev/null || echo "0")

step "4/4 — Spawning agents  (${total_tasks} task block(s) found in tasks.conf)"

agent_index=0
agent_count=0

# Arrays to store resolved agent details for the summary
declare -a _spawned_branches=()
declare -a _spawned_models=()
declare -a _spawned_modes=()
declare -a _spawned_prompts=()

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

  # Store resolved details for summary
  _spawned_branches+=("$branch")
  _spawned_models+=("$model")
  _spawned_modes+=("$mode")
  _spawned_prompts+=("$prompt")

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
repo_parent="$(dirname "$repo_path")"
repo_name="$(basename "$repo_path")"

echo ""
printf "${BOLD}═══════════════════════════════════════════════════════════════${RESET}\n"
printf "  ${GREEN}✓${RESET} Spawned ${GREEN}${agent_count}${RESET} agent(s) in tmux session: ${CYAN}${session}${RESET}\n"
printf "${BOLD}═══════════════════════════════════════════════════════════════${RESET}\n"
echo ""

# Show per-agent instructions
printf "  ${BOLD}Option A — Attach to tmux (all agents in one place):${RESET}\n"
echo ""
printf "    ${CYAN}tmux attach -t ${session}${RESET}\n"
echo ""
printf "    Navigate: ${BOLD}Ctrl+b n${RESET} (next)  ${BOLD}Ctrl+b p${RESET} (prev)  ${BOLD}Ctrl+b w${RESET} (list)\n"
printf "    Detach:   ${BOLD}Ctrl+b d${RESET} (agents keep running in background)\n"
echo ""

printf "  ${BOLD}Option B — Open each agent in its own terminal tab:${RESET}\n"
echo ""
printf "    Open a new tab for each worktree below and run the command:\n"
echo ""

for i in "${!_spawned_branches[@]}"; do
  local_branch="${_spawned_branches[$i]}"
  local_model="${_spawned_models[$i]}"
  local_mode="${_spawned_modes[$i]}"
  local_prompt="${_spawned_prompts[$i]}"
  local_wt="${repo_parent}/${repo_name}-${local_branch}"
  local_prompt_short=$(echo "$local_prompt" | head -c 60 | tr '\n' ' ')
  
  local_cmd="cd ${local_wt} && claude"
  [[ -n "$local_model" ]] && local_cmd+=" --model ${local_model}"
  [[ "$local_mode" == "plan" ]] && local_cmd+=" --permission-mode plan"
  
  printf "    ${BOLD}Tab %d${RESET} — %s\n" "$((i + 1))" "$local_prompt_short"
  printf "    ${CYAN}%s${RESET}\n\n" "$local_cmd"
done

printf "    Then paste the task prompt into Claude when it loads.\n"
echo ""
printf "${BOLD}═══════════════════════════════════════════════════════════════${RESET}\n"
echo ""
