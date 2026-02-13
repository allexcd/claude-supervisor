#!/usr/bin/env bash
# lib/utils.sh — Shared functions for claude-supervisor
# Sourced by both supervisor.sh and spawn-agent.sh

[[ -n "${_UTILS_LOADED:-}" ]] && return
_UTILS_LOADED=1

# ─── Colors / formatting ────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "  ${CYAN}▸${RESET} %s\n" "$*"; }
ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}⚠${RESET}  %s\n" "$*" >&2; }
die()   { printf "  ${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }
step()  { printf "\n${BOLD}${CYAN}▶  %s${RESET}\n" "$*"; }

# ─── Window color palette ───────────────────────────────────────────────────

PALETTE=("colour33" "colour70" "colour166" "colour126" "colour31" "colour208")
PLAN_COLOR="colour220"

# ─── check_deps ─────────────────────────────────────────────────────────────
# Scans for all required tools, reports all missing ones at once,
# offers one-shot auto-install in correct dependency order.

check_deps() {
  local missing=()

  for tool in git tmux npm claude; do
    if ! command -v "$tool" &>/dev/null; then
      missing+=("$tool")
    fi
  done

  if [[ ${#missing[@]} -eq 0 ]]; then
    ok "All dependencies satisfied (git, tmux, npm, claude)"
    return 0
  fi

  warn "Missing tools: ${missing[*]}"
  echo ""
  for tool in "${missing[@]}"; do
    case "$tool" in
      git)    printf "  ${BOLD}%s${RESET}: %b\n" "$tool" "Install via Xcode CLI tools: xcode-select --install" ;;
      tmux)   printf "  ${BOLD}%s${RESET}: %b\n" "$tool" "brew install tmux" ;;
      npm)    printf "  ${BOLD}%s${RESET}: %b\n" "$tool" "Install nvm first:\n    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash\n  Then: nvm install --lts" ;;
      claude) printf "  ${BOLD}%s${RESET}: %b\n" "$tool" "npm install -g @anthropic-ai/claude-code" ;;
    esac
  done
  echo ""

  read -rp "Auto-install missing tools? [y/N] " answer
  if [[ "$answer" != [yY] ]]; then
    die "Install the missing tools above, then run again."
  fi

  # Install in dependency order: nvm → npm → claude, tmux separately
  for tool in "${missing[@]}"; do
    case "$tool" in
      git)
        info "Installing git via Xcode CLI tools..."
        xcode-select --install 2>/dev/null || true
        # xcode-select is interactive — just warn if it didn't work
        if ! command -v git &>/dev/null; then
          warn "git install requires manual approval of the Xcode dialog."
          warn "Run 'xcode-select --install', approve, then run supervisor again."
          exit 1
        fi
        ;;
      tmux)
        info "Installing tmux via Homebrew..."
        if command -v brew &>/dev/null; then
          brew install tmux || die "Failed to install tmux"
        else
          die "Homebrew not found. Install tmux manually: https://github.com/tmux/tmux"
        fi
        ;;
      npm)
        info "Installing nvm..."
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/HEAD/install.sh | bash || die "Failed to install nvm"
        # Source nvm into current shell
        export NVM_DIR="${HOME}/.nvm"
        # shellcheck disable=SC1091
        [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
        info "Installing Node.js LTS via nvm..."
        nvm install --lts || die "Failed to install Node.js"
        ;;
      claude)
        info "Installing Claude Code CLI..."
        npm install -g @anthropic-ai/claude-code || die "Failed to install claude"
        ;;
    esac
  done

  # Re-check everything
  local -a still_missing=()
  for tool in git tmux npm claude; do
    if ! command -v "$tool" &>/dev/null; then
      still_missing+=("$tool")
    fi
  done

  if [[ ${#still_missing[@]} -gt 0 ]]; then
    die "Still missing after install: ${still_missing[*]}. Install manually and try again."
  fi

  ok "All dependencies installed successfully"
}

# ─── Billing mode ───────────────────────────────────────────────────────────
# CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE is "pro" (Claude Pro/Max/Team — OAuth login, no API key needed)
# or "api" (Anthropic Console — API key billing).

CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=""

# Static model list for Pro users (no API call needed)
STATIC_MODELS=(
  "claude-sonnet-4-5-20250929|Claude Sonnet 4.5"
  "claude-opus-4-6|Claude Opus 4"
  "claude-haiku-4-5-20251001|Claude Haiku 4.5"
)

ask_billing_mode() {
  local repo="${1:-}"

  # If ANTHROPIC_API_KEY is already set, assume API billing
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="api"
    ok "ANTHROPIC_API_KEY found — using API key billing"
    return 0
  fi

  # Check project .env file for API key
  if [[ -n "$repo" && -f "$repo/.env" ]]; then
    local env_val
    env_val="$(grep '^ANTHROPIC_API_KEY=' "$repo/.env" 2>/dev/null | tail -1 | cut -d'=' -f2- || true)"
    if [[ -n "$env_val" ]]; then
      ANTHROPIC_API_KEY="$env_val"
      export ANTHROPIC_API_KEY
      CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="api"
      ok "ANTHROPIC_API_KEY loaded from .env — using API key billing"
      return 0
    fi
  fi

  # Check project .env file for saved billing mode
  if [[ -z "${RESET_BILLING:-}" && -n "$repo" && -f "$repo/.env" ]]; then
    local saved_mode
    saved_mode="$(grep '^CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=' "$repo/.env" 2>/dev/null | tail -1 | cut -d'=' -f2- || true)"
    if [[ "$saved_mode" == "pro" || "$saved_mode" == "api" ]]; then
      CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="$saved_mode"
      if [[ "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" == "pro" ]]; then
        ok "Using Claude Pro subscription (saved preference)"
      else
        ok "Using API key billing (saved preference)"
      fi
      return 0
    fi
  fi

  # Ask user
  echo ""
  printf "  ${BOLD}How do you use Claude Code?${RESET}\n"
  printf "    1) Claude Pro / Max / Team subscription (OAuth login)\n"
  printf "    2) Anthropic API key (Console billing)\n"
  echo ""
  printf "  Select [1]: "
  local choice
  read -r choice </dev/tty 2>/dev/null || choice="1"
  [[ -z "$choice" ]] && choice="1"

  if [[ "$choice" == "2" ]]; then
    CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="api"
    ok "Using API key billing"
  else
    CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="pro"
    ok "Using Claude Pro subscription (no API key needed)"
  fi

  # Persist the choice to .env
  _save_billing_mode "$repo"
}

# ─── _save_billing_mode ────────────────────────────────────────────────────
# Persists CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE to the project's .env file.
# Updates existing CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE= line or appends.

_save_billing_mode() {
  local repo="${1:-}"
  [[ -z "$repo" ]] && return 0
  [[ -z "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" ]] && return 0

  local env_file="$repo/.env"

  if [[ -f "$env_file" ]] && grep -q '^CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=' "$env_file" 2>/dev/null; then
    # Update existing line
    local _tmp; _tmp="$(mktemp)"
    sed "s/^CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=.*/CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=${CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE}/" "$env_file" > "$_tmp" && mv "$_tmp" "$env_file"
  elif [[ -f "$env_file" ]]; then
    # Append to existing .env
    [[ -s "$env_file" && "$(tail -c1 "$env_file")" != "" ]] && printf '\n' >> "$env_file"
    printf 'CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=%s\n' "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" >> "$env_file"
  else
    # Create new .env
    printf 'CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=%s\n' "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" > "$env_file"
  fi

  # Ensure .env is in .gitignore
  local gitignore="$repo/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qx '.env' "$gitignore" 2>/dev/null; then
      printf '\n.env\n' >> "$gitignore"
    fi
  else
    printf '.env\n' > "$gitignore"
  fi
}

# ─── resolve_api_key ────────────────────────────────────────────────────────
# Only called for API billing users. Checks env, .env file, then prompts.
# Usage: resolve_api_key [repo_path]

resolve_api_key() {
  local repo="${1:-}"

  # Already loaded by ask_billing_mode
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ok "ANTHROPIC_API_KEY ready"
    export ANTHROPIC_API_KEY
    return 0
  fi

  # Prompt interactively
  echo ""
  printf "${BOLD}Enter your Anthropic API key:${RESET} "
  read -rs ANTHROPIC_API_KEY
  echo ""  # newline after silent read

  if [[ -z "$ANTHROPIC_API_KEY" ]]; then
    die "API key cannot be empty."
  fi

  export ANTHROPIC_API_KEY
  ok "API key set"
}

# ─── save_api_key_to_env ────────────────────────────────────────────────────
# Persists ANTHROPIC_API_KEY to the project's .env file.
# Creates .env if it doesn't exist. Appends as the last entry if the file
# already has other variables. Skips if the key is already present.
# Also ensures .env is listed in .gitignore (secrets must not be committed).
# Usage: save_api_key_to_env <repo_path>

save_api_key_to_env() {
  local repo="$1"
  [[ -z "${ANTHROPIC_API_KEY:-}" ]] && return 0

  local env_file="$repo/.env"

  # Already present — don't duplicate
  if [[ -f "$env_file" ]] && grep -q '^ANTHROPIC_API_KEY=' "$env_file" 2>/dev/null; then
    return 0
  fi

  # Append or create
  if [[ -f "$env_file" ]]; then
    # Ensure a trailing newline before appending
    [[ -s "$env_file" && "$(tail -c1 "$env_file")" != "" ]] && printf '\n' >> "$env_file"
    printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" >> "$env_file"
    ok "Saved ANTHROPIC_API_KEY to .env (appended)"
  else
    printf 'ANTHROPIC_API_KEY=%s\n' "$ANTHROPIC_API_KEY" > "$env_file"
    ok "Created .env with ANTHROPIC_API_KEY"
  fi

  # Ensure .env is in .gitignore
  local gitignore="$repo/.gitignore"
  if [[ -f "$gitignore" ]]; then
    if ! grep -qx '.env' "$gitignore" 2>/dev/null; then
      printf '\n.env\n' >> "$gitignore"
      ok "Added .env to .gitignore"
    fi
  else
    printf '.env\n' > "$gitignore"
    ok "Created .gitignore with .env"
  fi
}

# ─── fetch_models ───────────────────────────────────────────────────────────
# Hits Anthropic API once; populates AVAILABLE_MODELS array.
# Each entry is "model_id|display_name".
# Uses jq if available, grep/sed fallback otherwise.

AVAILABLE_MODELS=()

fetch_models() {
  # Pro users: use static model list (no API key available)
  if [[ "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" == "pro" ]]; then
    AVAILABLE_MODELS=("${STATIC_MODELS[@]}")
    ok "Using standard model list (${#AVAILABLE_MODELS[@]} models)"
    info "You can also type /model inside Claude to switch models anytime."
    return 0
  fi

  # API users: fetch live from Anthropic API
  info "Fetching available models from Anthropic API..."

  local response
  response=$(curl -sf \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/models?limit=100" 2>/dev/null) || true

  if [[ -z "$response" ]]; then
    warn "Could not fetch models from API — using static list."
    AVAILABLE_MODELS=("${STATIC_MODELS[@]}")
    ok "Using standard model list (${#AVAILABLE_MODELS[@]} models)"
    return 0
  fi

  AVAILABLE_MODELS=()

  if command -v jq &>/dev/null; then
    while IFS= read -r line; do
      [[ -n "$line" ]] && AVAILABLE_MODELS+=("$line")
    done < <(echo "$response" | jq -r '.data[] | "\(.id)|\(.display_name // .id)"' 2>/dev/null)
  else
    while IFS= read -r id; do
      [[ -n "$id" ]] && AVAILABLE_MODELS+=("${id}|${id}")
    done < <(echo "$response" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"id"[[:space:]]*:[[:space:]]*"//;s/"$//')
  fi

  if [[ ${#AVAILABLE_MODELS[@]} -eq 0 ]]; then
    warn "No models found in API response."
    _prompt_manual_model
    return 0
  fi

  ok "Found ${#AVAILABLE_MODELS[@]} models"
}

_prompt_manual_model() {
  warn "You can enter a model ID manually when prompted per agent."
  echo ""
  printf "Enter a model ID to use (e.g. claude-sonnet-4-5-20250929): "
  read -r manual_model
  if [[ -n "$manual_model" ]]; then
    AVAILABLE_MODELS=("${manual_model}|${manual_model}")
    ok "Using manually entered model: $manual_model"
  else
    die "No models available. Check your API key and try again."
  fi
}

# ─── pick_model ─────────────────────────────────────────────────────────────
# Shows task description + numbered model menu from AVAILABLE_MODELS.
# Echoes selected model ID to stdout (caller captures with $()).

pick_model() {
  local task_prompt="$1"
  local branch_name="$2"

  # Print model list to stderr so it doesn't pollute the captured output
  {
    echo ""
    printf "  ${BOLD}Available models:${RESET}\n"

    local i=1
    for entry in "${AVAILABLE_MODELS[@]}"; do
      local model_id="${entry%%|*}"
      local display_name="${entry#*|}"
      printf "    %d) %s  —  %s\n" "$i" "$model_id" "$display_name"
      i=$((i + 1))
    done

    echo ""
  } >&2

  local selection
  while true; do
    printf "  Select model [1]: " >&2
    read -r selection </dev/tty

    # Default to 1
    [[ -z "$selection" ]] && selection=1

    # Validate it's a number in range
    if [[ "$selection" =~ ^[0-9]+$ ]] && (( selection >= 1 && selection <= ${#AVAILABLE_MODELS[@]} )); then
      break
    fi
    printf "  ${RED}Invalid selection. Try again.${RESET}\n" >&2
  done

  local chosen="${AVAILABLE_MODELS[$((selection - 1))]}"
  local model_id="${chosen%%|*}"
  echo "$model_id"
}

# ─── show_available_models ──────────────────────────────────────────────────
# Displays available models for reference during first-run scaffolding.
# For API key users: fetches live from API. For Pro users: shows static list.
# Soft-fail — never dies.

show_available_models() {
  local repo="${1:-}"

  echo ""
  printf "  ${BOLD}Common model IDs for the 'model' field in tasks.conf:${RESET}\n"
  echo ""

  # Always show the static/common models
  for entry in "${STATIC_MODELS[@]}"; do
    local mid="${entry%%|*}"
    local mname="${entry#*|}"
    printf "    ${CYAN}%-45s${RESET} %s\n" "$mid" "$mname"
  done

  # If API key is available, also fetch live list
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    info "Fetching full model list from Anthropic API..."
    local response
    response=$(curl -sf \
      -H "x-api-key: $ANTHROPIC_API_KEY" \
      -H "anthropic-version: 2023-06-01" \
      "https://api.anthropic.com/v1/models?limit=100" 2>/dev/null) || response=""

    if [[ -n "$response" ]]; then
      local model_lines=()
      if command -v jq &>/dev/null; then
        while IFS= read -r line; do
          [[ -n "$line" ]] && model_lines+=("$line")
        done < <(echo "$response" | jq -r '.data[] | "\(.id)|\(.display_name // .id)"' 2>/dev/null)
      else
        while IFS= read -r id; do
          [[ -n "$id" ]] && model_lines+=("${id}|${id}")
        done < <(echo "$response" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"id"[[:space:]]*:[[:space:]]*"//;s/"$//')
      fi

      if [[ ${#model_lines[@]} -gt 0 ]]; then
        ok "Found ${#model_lines[@]} models from API"
        echo ""
        printf "  ${BOLD}Full list from API:${RESET}\n"
        echo ""
        for entry in "${model_lines[@]}"; do
          local mid="${entry%%|*}"
          local mname="${entry#*|}"
          printf "    ${CYAN}%-45s${RESET} %s\n" "$mid" "$mname"
        done
      fi
    fi
  fi

  echo ""
  info "You can also omit the model field — the supervisor will prompt on the next run."
  info "Or type /model inside Claude to switch models anytime."
}

# ─── slugify ────────────────────────────────────────────────────────────────
# Converts free text to a valid git branch name.
# Lowercase, spaces→hyphens, strip non-alphanumeric except hyphens,
# collapse multiple hyphens, strip leading/trailing hyphens. Max 50 chars.

slugify() {
  local text="$1"
  echo "$text" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9 -]//g' \
    | tr ' ' '-' \
    | sed 's/-\{2,\}/-/g' \
    | sed 's/^-//;s/-$//' \
    | cut -c1-50
}

# ─── setup_window ───────────────────────────────────────────────────────────
# Assigns color from palette by agent index; plan mode gets yellow.
# Sets tmux window color + title. Sets Ghostty tab title via OSC if detected.

setup_window() {
  local session="$1"
  local window_name="$2"
  local index="$3"
  local mode="$4"

  # Pick color
  local color
  if [[ "$mode" == "plan" ]]; then
    color="$PLAN_COLOR"
  else
    color="${PALETTE[$((index % ${#PALETTE[@]}))]}"
  fi

  # Set tmux window style
  tmux set-window-option -t "${session}:${window_name}" window-status-style \
    "bg=${color},fg=colour232,bold" 2>/dev/null || true
  tmux set-window-option -t "${session}:${window_name}" window-status-current-style \
    "bg=${color},fg=colour232,bold" 2>/dev/null || true
}

# ─── print_banner ───────────────────────────────────────────────────────────
# Returns the banner text as a string. Caller writes it where needed.

print_banner() {
  local task="$1"
  local branch="$2"
  local model="$3"
  local mode="$4"

  # Truncate task for display if too long
  local display_task="$task"
  if (( ${#display_task} > 50 )); then
    display_task="${display_task:0:47}..."
  fi

  cat <<BANNER
╔══════════════════════════════════════════════════════╗
║  CLAUDE AGENT                                        ║
╠══════════════════════════════════════════════════════╣
║  Task  : ${display_task}
║  Branch: ${branch}
║  Model : ${model}
║  Mode  : ${mode}
╠══════════════════════════════════════════════════════╣
║  Hints:                                              ║
║  • /model      — switch model mid-session            ║
║  • /agents     — view available subagents            ║
║  • /statusline — enable context + git branch bar     ║
║  • Update CLAUDE.md after corrections                ║
║  • Explain the WHY behind every change               ║
╚══════════════════════════════════════════════════════╝
BANNER
}
