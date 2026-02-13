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

# ─── resolve_api_key ────────────────────────────────────────────────────────
# Checks ANTHROPIC_API_KEY env var; prompts via read -s if absent.
# Key is exported so it can be passed explicitly to tmux windows.

resolve_api_key() {
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    ok "ANTHROPIC_API_KEY found in environment"
    export ANTHROPIC_API_KEY
    return 0
  fi

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

# ─── fetch_models ───────────────────────────────────────────────────────────
# Hits Anthropic API once; populates AVAILABLE_MODELS array.
# Each entry is "model_id|display_name".
# Uses jq if available, grep/sed fallback otherwise.

AVAILABLE_MODELS=()

fetch_models() {
  info "Fetching available models from Anthropic API..."

  local response
  response=$(curl -sf \
    -H "x-api-key: $ANTHROPIC_API_KEY" \
    -H "anthropic-version: 2023-06-01" \
    "https://api.anthropic.com/v1/models?limit=100" 2>/dev/null) || true

  if [[ -z "$response" ]]; then
    warn "Could not fetch models from API."
    _prompt_manual_model
    return 0
  fi

  AVAILABLE_MODELS=()

  if command -v jq &>/dev/null; then
    # jq path — clean extraction
    while IFS= read -r line; do
      [[ -n "$line" ]] && AVAILABLE_MODELS+=("$line")
    done < <(echo "$response" | jq -r '.data[] | "\(.id)|\(.display_name // .id)"' 2>/dev/null)
  else
    # grep/sed fallback — extract id and display_name pairs
    # The API returns JSON objects with "id" and "display_name" fields
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

  # Set Ghostty tab title via OSC 0 if detected
  if [[ "${TERM_PROGRAM:-}" == "ghostty" ]]; then
    tmux send-keys -t "${session}:${window_name}" \
      "printf '\\033]0;${window_name}\\007'" Enter 2>/dev/null || true
  fi
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
