#!/usr/bin/env bash
# bin/supervisor.sh — Orchestrates parallel Claude Code agents
#
# Usage: supervisor [--reset] [repo_path]
#         supervisor run "task1" "task2" ...
#         supervisor last | list | attach <n>
#         supervisor watch | update | on-stop | migrate | uninstall | doctor
#   --reset   re-prompt for billing mode (Pro vs API)

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

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/parse-bullets.sh"

# ── Subcommand dispatch ───────────────────────────────────────────────────────

_INPUT_MODE=""   # argv | last | stdin | editor
_ARGV_TASKS=()   # populated for "run" subcommand

if [[ ${#args[@]} -gt 0 ]]; then
  case "${args[0]}" in
    watch)     exec "$SCRIPT_DIR/watch.sh" "${args[1]:-$PWD}" ;;
    update)    exec "$SCRIPT_DIR/update.sh" "${args[1]:-$PWD}" ;;
    on-stop)   exec "$SCRIPT_DIR/on-stop.sh" ;;
    migrate)   exec "$SCRIPT_DIR/migrate.sh" "${args[@]:1}" ;;
    uninstall) exec "$SCRIPT_DIR/uninstall.sh" "${args[@]:1}" ;;
    doctor)    exec "$SCRIPT_DIR/doctor.sh" "${args[1]:-$PWD}" ;;
    run)
      _INPUT_MODE="argv"
      _ARGV_TASKS=("${args[@]:1}")
      args=()
      ;;
    last|list|attach)
      _INPUT_MODE="${args[0]}"
      args=("${args[@]:1}")
      ;;
  esac
fi

# ── Repo path ────────────────────────────────────────────────────────────────

if [[ "$_INPUT_MODE" == "argv" || "$_INPUT_MODE" == "list" ]]; then
  repo_path="$PWD"
elif [[ "$_INPUT_MODE" == "last" || "$_INPUT_MODE" == "attach" ]]; then
  repo_path="${args[0]:-$PWD}"
else
  repo_path="${args[0]:-$PWD}"
fi

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
# Triggered when .claude/settings.local.json (supervisor's overlay marker) is absent.

_gitignore_add() {
  local gitignore_file="$1" entry="$2" comment="$3"
  if ! grep -qx "$entry" "$gitignore_file" 2>/dev/null; then
    printf '\n# %s\n%s\n' "$comment" "$entry" >> "$gitignore_file"
  fi
}

_upsert_supervisor_block() {
  local repo="$1"
  local claude_md="$repo/.claude/CLAUDE.md"
  local block='<!-- BEGIN claude-supervisor (do not edit by hand) -->
## Worktree-sync Notes

This project uses `claude-supervisor` to run parallel agents across isolated git worktrees.

**Race-condition guidance:**
- Each agent works in its own worktree — never write to another agent'"'"'s branch
- After adding to Known Pitfalls, commit this file:
  `git add .claude/CLAUDE.md && git commit -m "docs: update CLAUDE.md"`

**Sharing learnings across worktrees:**
The project owner runs `collect-learnings.sh [--yes] <repo_path>` to merge
new pitfall bullets from all active worktrees into the main copy.

**Shared peer notes:**
- Read peer updates: `cat .claude/agents-shared/*.md`
- Use `/share <message>` to append a timestamped note for peers
- Use `/peers` to view all peer notes
<!-- END claude-supervisor -->'

  [[ -d "$(dirname "$claude_md")" ]] || mkdir -p "$(dirname "$claude_md")"
  [[ -f "$claude_md" ]] || touch "$claude_md"
  if ! grep -q "BEGIN claude-supervisor" "$claude_md" 2>/dev/null; then
    printf '\n%s\n' "$block" >> "$claude_md"
    ok "Added worktree-sync block to .claude/CLAUDE.md"
  fi
}

# ── Pre-1.0 state detection ───────────────────────────────────────────────────
# If tasks.conf exists but settings.local.json doesn't, this is a 0.2.x layout.
if [[ -f "$repo_path/tasks.conf" && ! -f "$repo_path/.claude/settings.local.json" ]]; then
  echo ""
  warn "This project uses the 0.2.x layout (tasks.conf without settings.local.json)."
  printf "\n  Run ${CYAN}supervisor migrate${RESET} to upgrade to 1.0, then run supervisor again.\n\n"
  exit 1
fi

# ── Auto-init (first run) ────────────────────────────────────────────────────
if [[ ! -f "$repo_path/.claude/settings.local.json" ]]; then
  echo ""
  info "Project not yet set up. Initialising..."
  echo ""

  gitignore="$repo_path/.gitignore"
  [[ -f "$gitignore" ]] || touch "$gitignore"

  # ── Bootstrap workspace via workspace-kit (or bare fallback) ───────────────
  if [[ -d "$repo_path/.claude" ]]; then
    if [[ -f "$repo_path/.cwk.lock" ]]; then
      ok ".cwk.lock found — workspace-kit already initialised"
    else
      warn ".claude/ already exists — skipping workspace bootstrap"
    fi
  else
    if [[ -f "$repo_path/.cwk.lock" ]]; then
      ok ".cwk.lock found — workspace-kit already initialised"
      mkdir -p "$repo_path/.claude"
    else
      echo ""
      printf "  Set up project agents and skills via ${CYAN}claude-workspace-kit${RESET}? [Y/n] "
      read -r _cwk_ans
      echo ""
      _cwk_ans="${_cwk_ans:-Y}"

      _cwk_ok=false
      if [[ "$_cwk_ans" =~ ^[Yy] ]]; then
        if command -v npx &>/dev/null; then
          info "Running npx claude-workspace-kit init..."
          if npx --yes claude-workspace-kit init "$repo_path"; then
            ok "workspace-kit initialised"
            _cwk_ok=true
          else
            warn "workspace-kit init failed — using minimal scaffold"
          fi
        else
          warn "npx not found — using minimal scaffold"
        fi
      fi

      if ! $_cwk_ok; then
        mkdir -p "$repo_path/.claude/agents"
        cp "$TEMPLATES_DIR/CLAUDE.md" "$repo_path/.claude/CLAUDE.md"
        ok "Created .claude/CLAUDE.md       (project memory template)"
        if [[ -f "$TEMPLATES_DIR/.claude/agents/_example-agent.md" ]]; then
          cp "$TEMPLATES_DIR/.claude/agents/_example-agent.md" "$repo_path/.claude/agents/_example-agent.md"
          ok "Created .claude/agents/         (_example-agent.md template)"
        fi
      fi
    fi
  fi

  # ── Supervisor overlay: settings.local.json ────────────────────────────────
  mkdir -p "$repo_path/.claude"
  cp "$TEMPLATES_DIR/.claude/settings.local.json" "$repo_path/.claude/settings.local.json"
  ok "Created .claude/settings.local.json  (PermissionRequest → Opus + Stop hooks)"

  # ── Shared peer notes directory ────────────────────────────────────────────
  mkdir -p "$repo_path/.claude/agents-shared"
  ok "Created .claude/agents-shared/       (shared peer notes, gitignored)"

  # ── Append fenced supervisor block to CLAUDE.md ───────────────────────────
  _upsert_supervisor_block "$repo_path"

  # ── .gitignore: supervisor entries (idempotent) ────────────────────────────
  _gitignore_add "$gitignore" ".env" "Claude Supervisor — local secrets"
  _gitignore_add "$gitignore" ".claude/agents-shared/" "Claude Supervisor — shared peer notes"
  ok "Updated .gitignore"

  # ── Show available models ──────────────────────────────────────────────────
  step "Available models"
  show_available_models "$repo_path"

  echo ""
  printf "${BOLD}Next:${RESET} run ${CYAN}supervisor${RESET} again to enter your tasks.\n"
  printf "      (or pipe tasks:  echo '- implement OAuth' | ${CYAN}supervisor${RESET})\n"
  echo ""
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
# Models get deprecated — if settings.local.json still references an old model ID the
# hook will silently fail, which means risky actions go ungated.
_check_hook_model() {
  local settings_file="$repo_path/.claude/settings.local.json"
  [[ -f "$settings_file" ]] || settings_file="$repo_path/.claude/settings.json"
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
    printf "    → Update ${CYAN}%s/.claude/settings.local.json${RESET} with a current model.\n" "$repo_path"
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

# ─── list / attach subcommands (need billing + models loaded first) ──────────

if [[ "$_INPUT_MODE" == "list" ]]; then
  state_file="$repo_path/.claude/supervisor-agents.jsonl"
  if [[ ! -f "$state_file" || ! -s "$state_file" ]]; then
    info "No active agents found. Run supervisor to spawn agents."
  else
    echo ""
    printf "  ${BOLD}%-20s %-12s %-6s  %s${RESET}\n" "Branch" "Model" "Mode" "Spawned at"
    printf "  %-20s %-12s %-6s  %s\n" "────────────────────" "────────────" "──────" "───────────────────"
    while IFS= read -r entry; do
      local_b="" local_m="" local_mo="" local_ts=""
      if command -v jq &>/dev/null; then
        local_b="$(echo "$entry"  | jq -r '.branch    // "?"' 2>/dev/null)"
        local_m="$(echo "$entry"  | jq -r '.model     // "?"' 2>/dev/null)"
        local_mo="$(echo "$entry" | jq -r '.mode      // "?"' 2>/dev/null)"
        local_ts="$(echo "$entry" | jq -r '.spawned_at // "?"' 2>/dev/null)"
      else
        local_b="$(echo "$entry"  | grep -o '"branch":"[^"]*"'   | sed 's/"branch":"//;s/"//')"
        local_m="$(echo "$entry"  | grep -o '"model":"[^"]*"'    | sed 's/"model":"//;s/"//')"
        local_mo="$(echo "$entry" | grep -o '"mode":"[^"]*"'     | sed 's/"mode":"//;s/"//')"
        local_ts="$(echo "$entry" | grep -o '"spawned_at":"[^"]*"' | sed 's/"spawned_at":"//;s/"//')"
      fi
      printf "  %-20s %-12s %-6s  %s\n" \
        "${local_b:0:20}" "${local_m/claude-/}" "${local_mo:0:6}" "$local_ts"
    done < "$state_file"
    echo ""
    printf "  Attach: ${CYAN}supervisor attach <branch>${RESET} or ${CYAN}tmux attach -t %s-agents${RESET}\n" \
      "$(basename "$repo_path")"
  fi
  echo ""
  exit 0
fi

if [[ "$_INPUT_MODE" == "attach" ]]; then
  local_target="${args[0]:-}"
  local_session="$(basename "$repo_path")-agents"
  if [[ -z "$local_target" ]]; then
    # Attach to session (window 0 = watch dashboard)
    exec tmux attach -t "$local_session"
  else
    exec tmux attach -t "${local_session}:${local_target}"
  fi
fi

# ─── Step 4/4 — Read task input and spawn agents ─────────────────────────────

step "4/4 — Reading tasks"

# ── Determine input source ────────────────────────────────────────────────────

_TASK_INPUT=""

if [[ "$_INPUT_MODE" == "argv" ]]; then
  # supervisor run "task1" "task2" — each arg is a task bullet
  for _t in "${_ARGV_TASKS[@]}"; do
    [[ "$_t" =~ ^[[:space:]]*[-*+] ]] || _t="- $_t"
    _TASK_INPUT+="$_t"$'\n'
  done

elif [[ "$_INPUT_MODE" == "last" ]]; then
  _last_file="$repo_path/.claude/supervisor-last.md"
  if [[ ! -f "$_last_file" ]]; then
    die "No previous session found at $_last_file. Run supervisor with tasks first."
  fi
  _TASK_INPUT="$(cat "$_last_file")"
  info "Reusing last session tasks from supervisor-last.md"

elif [[ ! -t 0 ]]; then
  # Stdin is a pipe/redirect
  _TASK_INPUT="$(cat)"

else
  # Interactive prompt loop — one question per task
  echo ""
  printf "  Optional tags: [model: sonnet|haiku|opus]  [plan]  [branch: name]  [depends: branch]\n"
  echo ""
  _task_num=1
  while true; do
    if [[ $_task_num -eq 1 ]]; then
      printf "  ${BOLD}What would you like to work on?${RESET}\n  > "
    else
      printf "  ${BOLD}Task $_task_num:${RESET}\n  > "
    fi
    read -r _task_line </dev/tty || break
    _task_line="${_task_line## }"; _task_line="${_task_line%% }"
    if [[ -z "$_task_line" ]]; then
      printf "  ${YELLOW}(empty — skipped)${RESET}\n"
    else
      [[ "$_task_line" =~ ^[-*+][[:space:]] ]] || _task_line="- $_task_line"
      _TASK_INPUT+="$_task_line"$'\n'
      _task_num=$(( _task_num + 1 ))
    fi
    echo ""
    printf "  Add another task? [y/N] "
    read -r _more </dev/tty || _more="n"
    [[ -z "$_more" ]] && _more="n"
    echo ""
    [[ "$_more" =~ ^[Yy] ]] || break
  done
fi

# ── Parse bullets ─────────────────────────────────────────────────────────────

declare -a _task_prompts=()
declare -a _task_branches=()
declare -a _task_models=()
declare -a _task_modes=()
declare -a _task_depends=()

while IFS='|' read -r _rec _prompt _branch _model _mode _depends; do
  [[ "$_rec" != "TASK" ]] && continue
  _task_prompts+=("$_prompt")
  _task_branches+=("$_branch")
  _task_models+=("$_model")
  _task_modes+=("$_mode")
  _task_depends+=("$_depends")
done < <(parse_bullets "$_TASK_INPUT")

total_tasks="${#_task_prompts[@]}"

if [[ "$total_tasks" -eq 0 ]]; then
  info "No tasks found — nothing to spawn."
  echo ""
  exit 0
fi

# ── Phase 1: resolve branches + pick missing models interactively ─────────────

echo ""
printf "${BOLD}Tasks to spawn:${RESET}\n"

for _i in "${!_task_prompts[@]}"; do
  _p="${_task_prompts[$_i]}"
  _b="${_task_branches[$_i]}"
  _m="${_task_models[$_i]}"
  _mo="${_task_modes[$_i]:-normal}"
  _dep="${_task_depends[$_i]}"

  [[ -z "$_b" ]] && { _b="$(slugify "$_p")"; _task_branches[$_i]="$_b"; }
  [[ -z "$_mo" ]] && { _mo="normal"; _task_modes[$_i]="normal"; }

  echo ""
  printf "  ${BOLD}%d.${RESET} %s\n" "$((_i+1))" "$_p"
  printf "     branch: ${CYAN}%s${RESET}  mode: %s" "$_b" "$_mo"
  [[ -n "$_dep" ]] && printf "  depends: ${YELLOW}%s${RESET}" "$_dep"
  printf "\n"

  if [[ -z "$_m" ]]; then
    printf "     model: (choose below)\n"
    _m="$(pick_model "$_p" "$_b")"
    _task_models[$_i]="$_m"
  fi
  printf "     model: %s\n" "$_m"
done

echo ""
printf "Spawn %d agent(s)? [Y/n] " "$total_tasks"
read -r _confirm </dev/tty || _confirm="y"
[[ -z "$_confirm" ]] && _confirm="y"
if [[ ! "$_confirm" =~ ^[Yy] ]]; then
  echo "Cancelled."
  exit 0
fi

# ── Save for 'supervisor last' ────────────────────────────────────────────────

printf '%s\n' "$_TASK_INPUT" > "$repo_path/.claude/supervisor-last.md"

# ── Session setup ─────────────────────────────────────────────────────────────

step "4/4 — Spawning agents  (${total_tasks} task(s))"

session="$(basename "$repo_path")-agents"
repo_parent="$(dirname "$repo_path")"
repo_name="$(basename "$repo_path")"

state_file="$repo_path/.claude/supervisor-agents.jsonl"
mkdir -p "$(dirname "$state_file")"
: > "$state_file"

if ! tmux has-session -t "$session" 2>/dev/null; then
  tmux new-session -d -s "$session" -n "watch" -c "$repo_path" \
    "bash \"$SCRIPT_DIR/watch.sh\" \"$repo_path\"" 2>/dev/null || true
fi

agent_index=0
agent_count=0

declare -a _spawned_branches=()
declare -a _spawned_models=()
declare -a _spawned_modes=()
declare -a _spawned_prompts=()

_spawn_current_task() {
  local branch="$1" model="$2" mode="$3" prompt="$4"
  local task_num=$((agent_count + 1))

  [[ -z "$prompt" ]] && { warn "Skipping task (empty prompt)"; return; }
  [[ -z "$mode" || ( "$mode" != "normal" && "$mode" != "plan" ) ]] && mode="normal"

  echo ""
  printf "  ${BOLD}── Task %d of %d ──────────────────────────────────────────${RESET}\n" \
    "$task_num" "$total_tasks"
  printf "  ${BOLD}Prompt${RESET} : %s\n" "$prompt"
  printf "  ${BOLD}Branch${RESET} : %s\n" "$branch"
  printf "  ${BOLD}Mode${RESET}   : %s\n" "$mode"
  printf "  ${BOLD}Model${RESET}  : %s\n" "$model"
  echo ""

  _spawned_branches+=("$branch")
  _spawned_models+=("$model")
  _spawned_modes+=("$mode")
  _spawned_prompts+=("$prompt")

  local worktree_path="${repo_parent}/${repo_name}-${branch}"
  "$SCRIPT_DIR/spawn-agent.sh" "$repo_path" "$branch" "$model" "$mode" "$agent_index" "$prompt"

  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf '{"branch":"%s","model":"%s","mode":"%s","worktree":"%s","spawned_at":"%s"}\n' \
    "$branch" "$model" "$mode" "$worktree_path" "$ts" >> "$state_file"

  agent_index=$((agent_index + 1))
  agent_count=$((agent_count + 1))
}

# ── Phase 2+3: Spawn agents (immediate or dependency-gated) ──────────────────

for _i in "${!_task_prompts[@]}"; do
  _p="${_task_prompts[$_i]}"
  _b="${_task_branches[$_i]}"
  _m="${_task_models[$_i]}"
  _mo="${_task_modes[$_i]:-normal}"
  _dep="${_task_depends[$_i]}"

  if [[ -n "$_dep" ]]; then
    # Dependency staging: spawn in background once dep's Stop hook fires
    (
      _sum_file="$repo_path/.claude/supervisor-session-summary.jsonl"
      printf "  ${YELLOW}⏳${RESET} Waiting for '%s' to complete before starting '%s'...\n" "$_dep" "$_b"
      while ! grep -q '"branch":"'"$_dep"'"' "$_sum_file" 2>/dev/null; do
        sleep 15
      done

      # Augment prompt with dep diff summary
      _dep_diff="$(git -C "$repo_path" diff HEAD..."$_dep" --stat 2>/dev/null | head -10 || true)"
      _augmented="$_p"
      if [[ -n "$_dep_diff" ]]; then
        _augmented="$_p

Dependency '$_dep' has completed. Summary of changes:
$_dep_diff"
      fi

      _spawn_current_task "$_b" "$_m" "$_mo" "$_augmented"
    ) &
    disown
    info "Task '$_b' staged — will start after '$_dep' completes"
    agent_count=$((agent_count + 1))
  else
    _spawn_current_task "$_b" "$_m" "$_mo" "$_p"
  fi
done

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}═══════════════════════════════════════════════════════════════${RESET}\n"
printf "  ${GREEN}✓${RESET} Spawned ${GREEN}%d${RESET} agent(s) in tmux session: ${CYAN}%s${RESET}\n" \
  "$agent_count" "$session"
printf "${BOLD}═══════════════════════════════════════════════════════════════${RESET}\n"
echo ""

printf "  ${BOLD}Attach to tmux (live watch dashboard + all agents):${RESET}\n"
echo ""
printf "    ${CYAN}tmux attach -t %s${RESET}\n" "$session"
echo ""
printf "    Window 0 — watch dashboard  |  Windows 1+ — agents\n"
printf "    Navigate: Ctrl+b n/p  |  Detach: Ctrl+b d\n"
echo ""

printf "  ${BOLD}Or open each agent directly:${RESET}\n"
echo ""

for _i in "${!_spawned_branches[@]}"; do
  _lb="${_spawned_branches[$_i]}"
  _lm="${_spawned_models[$_i]}"
  _lmo="${_spawned_modes[$_i]}"
  _lp="${_spawned_prompts[$_i]}"
  _lwt="${repo_parent}/${repo_name}-${_lb}"

  _lcmd="cd ${_lwt} && claude"
  [[ -n "$_lm" ]] && _lcmd+=" --model ${_lm}"
  [[ "$_lmo" == "plan" ]] && _lcmd+=" --permission-mode plan"

  printf "    ${BOLD}%d.${RESET} %s\n" "$((_i + 1))" "${_lp:0:60}"
  printf "    ${CYAN}%s${RESET}\n\n" "$_lcmd"
done

printf "  ${BOLD}Live dashboard:${RESET}  ${CYAN}supervisor watch %s${RESET}\n" "$repo_path"
echo ""
printf "${BOLD}═══════════════════════════════════════════════════════════════${RESET}\n"
echo ""
