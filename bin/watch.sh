#!/usr/bin/env bash
# bin/watch.sh — Live status dashboard for claude-supervisor agents
#
# Usage: supervisor watch [repo_path]
#        Can also be run directly: bash bin/watch.sh [repo_path]
#
# Reads .claude/supervisor-agents.jsonl from repo_path (written by supervisor on each run).
# Tails each agent's Claude Code session JSONL and renders a live status table.
# Refreshes every CS_WATCH_INTERVAL seconds (default: 3).
# Flags agents idle longer than CS_STUCK_MINUTES minutes (default: 5) as potentially stuck.

set -euo pipefail

_SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_SCRIPT_PATH" ]]; do
  _SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
  _SCRIPT_PATH="$(readlink "$_SCRIPT_PATH")"
  [[ "$_SCRIPT_PATH" != /* ]] && _SCRIPT_PATH="$_SCRIPT_DIR/$_SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"
# shellcheck disable=SC1091
source "$LIB_DIR/utils.sh"

# ─── Config ─────────────────────────────────────────────────────────────────

WATCH_INTERVAL="${CS_WATCH_INTERVAL:-3}"
STUCK_MINUTES="${CS_STUCK_MINUTES:-5}"
STUCK_SECONDS=$(( STUCK_MINUTES * 60 ))

# ─── Args (only when run directly, not sourced) ──────────────────────────────
# When sourced for testing, callers should set repo_path and state_file directly.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  repo_path="${1:-$PWD}"
  if [[ -d "$repo_path" ]]; then
    repo_path="$(cd "$repo_path" && pwd)"
  else
    die "Directory not found: $repo_path"
  fi
  state_file="$repo_path/.claude/supervisor-agents.jsonl"
fi

# ─── Node helper ────────────────────────────────────────────────────────────

JSONL_TAIL="$LIB_DIR/jsonl-tail.mjs"
NODE_BIN=""

_find_node() {
  if command -v node &>/dev/null; then
    NODE_BIN="node"
    return
  fi
  # Try nvm-managed node
  local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
  for candidate in "$nvm_dir"/versions/node/*/bin/node; do
    if [[ -x "$candidate" ]]; then
      NODE_BIN="$candidate"
      return
    fi
  done
}
_find_node

# ─── Helpers ────────────────────────────────────────────────────────────────

# Convert an absolute worktree path to a Claude Code project dir name.
# Claude Code maps path → dir by replacing / and _ with -.
_worktree_to_project_dir() {
  local wt="$1"
  local d="${wt//\//-}"
  echo "${d//_/-}"
}

# Find the most recently modified .jsonl file for a given project dir.
_latest_session_jsonl() {
  local project_dir="$1"
  local sessions_dir="$HOME/.claude/projects/$project_dir"
  [[ -d "$sessions_dir" ]] || return 0

  local newest=""
  for f in "$sessions_dir"/*.jsonl; do
    [[ -f "$f" ]] || continue
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then
      newest="$f"
    fi
  done
  echo "$newest"
}

# Get agent status by parsing the latest session JSONL.
# Output: space-separated "status tool timestamp"
_get_agent_status() {
  local jsonl="$1"
  if [[ -z "$jsonl" || ! -f "$jsonl" ]]; then
    echo "unknown - -"
    return
  fi

  if [[ -n "$NODE_BIN" && -f "$JSONL_TAIL" ]]; then
    local result
    result="$("$NODE_BIN" "$JSONL_TAIL" "$jsonl" 2>/dev/null)" || result='{"status":"unknown"}'
    local status tool ts
    if command -v jq &>/dev/null; then
      status="$(echo "$result" | jq -r '.status // "unknown"' 2>/dev/null)"
      tool="$(echo "$result" | jq -r '.tool // "-"' 2>/dev/null)"
      ts="$(echo "$result" | jq -r '.timestamp // "-"' 2>/dev/null)"
    else
      # Fallback: extract with grep/sed (no jq)
      status="$(echo "$result" | grep -o '"status":"[^"]*"' | sed 's/"status":"//;s/"//' | head -1)"
      tool="$(echo "$result" | grep -o '"tool":"[^"]*"' | sed 's/"tool":"//;s/"//' | head -1)"
      ts="$(echo "$result" | grep -o '"timestamp":"[^"]*"' | sed 's/"timestamp":"//;s/"//' | head -1)"
      [[ -z "$status" ]] && status="unknown"
      [[ -z "$tool" ]] && tool="-"
      [[ -z "$ts" ]] && ts="-"
    fi
    echo "$status $tool $ts"
  else
    # Pure bash fallback: grep last tool_use or last event type
    local status="idle"
    local tool="-"
    local ts="-"
    local lastline
    lastline="$(grep '"type":"assistant"' "$jsonl" 2>/dev/null | grep -o '.*' | tail -1)" || true
    if [[ "$lastline" == *'"tool_use"'* ]]; then
      status="tool"
      tool="$(echo "$lastline" | grep -o '"name":"[^"]*"' | head -1 | sed 's/"name":"//;s/"//')"
      [[ -z "$tool" ]] && tool="?"
    elif [[ "$lastline" == *'"thinking"'* ]]; then
      status="thinking"
    fi
    ts="$(echo "$lastline" | grep -o '"timestamp":"[^"]*"' | head -1 | sed 's/"timestamp":"//;s/"//')"
    [[ -z "$ts" ]] && ts="-"
    echo "$status $tool $ts"
  fi
}

# Convert ISO 8601 timestamp to epoch seconds (macOS + Linux).
_iso_to_epoch() {
  local ts="$1"
  [[ -z "$ts" || "$ts" == "-" || "$ts" == "null" ]] && echo "" && return
  local clean="${ts%.*}"    # strip sub-second
  clean="${clean%Z}"        # strip trailing Z
  clean="${clean/T/ }"      # T → space
  # macOS
  date -jf '%Y-%m-%d %H:%M:%S' "$clean" '+%s' 2>/dev/null && return
  # GNU/Linux
  date -d "$clean" '+%s' 2>/dev/null && return
  echo ""
}

# Convert epoch seconds to human-readable relative time.
_relative_time() {
  local epoch="$1"
  [[ -z "$epoch" ]] && echo "?" && return
  local now
  now="$(date '+%s')"
  local diff=$(( now - epoch ))
  if (( diff < 0 )); then echo "now"
  elif (( diff < 60 )); then echo "${diff}s ago"
  elif (( diff < 3600 )); then echo "$(( diff / 60 ))m ago"
  else echo "$(( diff / 3600 ))h ago"
  fi
}

# Format the status cell with color and symbol.
_format_status() {
  local status="$1" tool="$2"
  case "$status" in
    tool)      printf "${GREEN}⏵${RESET} tool: %s" "${tool:--}" ;;
    thinking)  printf "${CYAN}⏵${RESET} thinking" ;;
    writing)   printf "${CYAN}⏵${RESET} writing" ;;
    waiting)   printf "${CYAN}⏵${RESET} processing" ;;
    idle)      printf "${YELLOW}⏸${RESET} idle" ;;
    *)         printf "  unknown" ;;
  esac
}

# ─── Render loop ─────────────────────────────────────────────────────────────

_render() {
  if [[ ! -f "$state_file" ]]; then
    echo ""
    printf "  ${YELLOW}⚠${RESET}  No agent state found.\n"
    printf "  Run ${CYAN}supervisor${RESET} to spawn agents, then re-run ${CYAN}supervisor watch${RESET}.\n"
    printf "  State file: ${CYAN}%s${RESET}\n" "$state_file"
    return
  fi

  local now
  now="$(date '+%s')"

  printf "\n  ${BOLD}%-20s %-8s %-6s  %-22s %s${RESET}\n" \
    "Agent" "Model" "Mode" "Status" "Last activity"
  printf "  %-20s %-8s %-6s  %-22s %s\n" \
    "────────────────────" "────────" "──────" "──────────────────────" "─────────────"

  local shown=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue

    # Parse agent fields (bash-only, no jq dependency)
    local branch model mode worktree spawned_at
    if command -v jq &>/dev/null; then
      branch="$(echo "$line" | jq -r '.branch // "?"' 2>/dev/null)"
      model="$(echo "$line" | jq -r '.model // "?"' 2>/dev/null)"
      mode="$(echo "$line" | jq -r '.mode // "normal"' 2>/dev/null)"
      worktree="$(echo "$line" | jq -r '.worktree // ""' 2>/dev/null)"
      spawned_at="$(echo "$line" | jq -r '.spawned_at // ""' 2>/dev/null)"
    else
      branch="$(echo "$line" | grep -o '"branch":"[^"]*"' | sed 's/"branch":"//;s/"//')"
      model="$(echo "$line" | grep -o '"model":"[^"]*"' | sed 's/"model":"//;s/"//')"
      mode="$(echo "$line" | grep -o '"mode":"[^"]*"' | sed 's/"mode":"//;s/"//')"
      worktree="$(echo "$line" | grep -o '"worktree":"[^"]*"' | sed 's/"worktree":"//;s/"//')"
      spawned_at="$(echo "$line" | grep -o '"spawned_at":"[^"]*"' | sed 's/"spawned_at":"//;s/"//')"
      [[ -z "$branch" ]] && branch="?"
      [[ -z "$model" ]] && model="?"
      [[ -z "$mode" ]] && mode="normal"
    fi

    # Shorten model name for display
    local model_short="${model}"
    model_short="${model_short/claude-/}"
    model_short="${model_short/-*/}"  # keep only first segment
    if [[ "${#model_short}" -gt 8 ]]; then model_short="${model_short:0:7}…"; fi

    # Find latest JSONL for this worktree
    local project_dir
    project_dir="$(_worktree_to_project_dir "$worktree")"
    local jsonl
    jsonl="$(_latest_session_jsonl "$project_dir")"

    # Get status
    local status_line
    status_line="$(_get_agent_status "$jsonl")"
    local status tool ts
    read -r status tool ts <<< "$status_line"

    # Compute last activity time
    local epoch=""
    if [[ "$ts" != "-" && "$ts" != "null" && -n "$ts" ]]; then
      epoch="$(_iso_to_epoch "$ts")"
    fi
    local rel_time
    rel_time="$(_relative_time "$epoch")"

    # Detect stuck: active status but no activity for a long time
    local stuck_flag=""
    if [[ -n "$epoch" && "$status" != "idle" && "$status" != "unknown" ]]; then
      local age=$(( now - epoch ))
      if (( age >= STUCK_SECONDS )); then
        stuck_flag=" ${YELLOW}← stuck?${RESET}"
      fi
    fi

    # Format status cell
    local status_cell
    status_cell="$(_format_status "$status" "$tool")"

    printf "  %-20s %-8s %-6s  %-22b %s%b\n" \
      "${branch:0:20}" "${model_short:0:8}" "${mode:0:6}" \
      "$status_cell" "$rel_time" "$stuck_flag"

    shown=$((shown + 1))
  done < "$state_file"

  if (( shown == 0 )); then
    echo ""
    printf "  ${YELLOW}⚠${RESET}  State file exists but contains no agent records.\n"
  fi

  echo ""
}

# ─── Main ────────────────────────────────────────────────────────────────────

_watch_main() {
  # Warn if Node is not available
  if [[ -z "$NODE_BIN" ]]; then
    warn "node not found — using simplified bash JSONL parser (less accurate)"
  fi

  printf "${BOLD}Claude Supervisor — Live Agent Dashboard${RESET}\n"
  printf "  Repo  : ${CYAN}%s${RESET}\n" "$repo_path"
  printf "  State : ${CYAN}%s${RESET}\n" "$state_file"
  printf "  Stuck threshold: ${YELLOW}%d min${RESET}  |  Refresh: ${YELLOW}%ds${RESET}\n" \
    "$STUCK_MINUTES" "$WATCH_INTERVAL"
  printf "  Press ${BOLD}Ctrl+C${RESET} to exit  |  ${BOLD}Ctrl+b n${RESET} to cycle tmux windows\n"

  while true; do
    printf "\033[2J\033[H"  # clear screen
    printf "${BOLD}Claude Supervisor — Live Agent Dashboard${RESET}"
    printf "  ${CYAN}%s${RESET}" "$(date '+%H:%M:%S')"
    printf "\n  Repo: ${CYAN}%s${RESET}\n" "$repo_path"
    _render
    printf "  Refresh: every %ds  |  Ctrl+C to exit  |  Ctrl+b n/p to navigate\n" "$WATCH_INTERVAL"
    sleep "$WATCH_INTERVAL"
  done
}

# Only run main loop when executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _watch_main
fi
