#!/usr/bin/env bash
# bin/doctor.sh — Diagnose claude-supervisor project state
#
# Usage: supervisor doctor [repo_path]

set -euo pipefail

_SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_SCRIPT_PATH" ]]; do
  _SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
  _SCRIPT_PATH="$(readlink "$_SCRIPT_PATH")"
  [[ "$_SCRIPT_PATH" != /* ]] && _SCRIPT_PATH="$_SCRIPT_DIR/$_SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/utils.sh"

repo_path="${1:-$PWD}"
if [[ -d "$repo_path" ]]; then
  repo_path="$(cd "$repo_path" && pwd)"
else
  die "Directory not found: $repo_path"
fi

_check() {
  local label="$1" result="$2" detail="${3:-}"
  if [[ "$result" == "ok" ]]; then
    printf "  ${GREEN}✓${RESET}  %s\n" "$label"
  elif [[ "$result" == "warn" ]]; then
    printf "  ${YELLOW}⚠${RESET}  %s" "$label"
    [[ -n "$detail" ]] && printf "  (%s)" "$detail"
    printf "\n"
  else
    printf "  ${RED}✗${RESET}  %s" "$label"
    [[ -n "$detail" ]] && printf "  → %s" "$detail"
    printf "\n"
  fi
}

echo ""
printf "${BOLD}Claude Supervisor — Doctor${RESET}\n"
printf "  Repo: ${CYAN}%s${RESET}\n" "$repo_path"
echo ""

# ─── Git repository ───────────────────────────────────────────────────────────

if git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
  _check "Git repository" "ok"
else
  _check "Git repository" "fail" "not a git repo — supervisor requires git"
  echo ""
  exit 1
fi

# ─── Supervisor overlay ───────────────────────────────────────────────────────

settings_local="$repo_path/.claude/settings.local.json"
if [[ -f "$settings_local" ]]; then
  _check ".claude/settings.local.json (supervisor overlay)" "ok"
  # Check PermissionRequest hook
  if grep -q "PermissionRequest" "$settings_local" 2>/dev/null; then
    _check "  PermissionRequest hook present" "ok"
  else
    _check "  PermissionRequest hook" "warn" "missing — risky tool calls won't be gated"
  fi
  # Check Stop hook
  if grep -q '"Stop"' "$settings_local" 2>/dev/null; then
    _check "  Stop hook present" "ok"
  else
    _check "  Stop hook" "warn" "missing — collect-learnings won't auto-run on agent finish"
  fi
else
  _check ".claude/settings.local.json (supervisor overlay)" "fail" "run: supervisor (to init)"
fi

# ─── Pre-1.0 state detection ──────────────────────────────────────────────────

if [[ -f "$repo_path/tasks.conf" && ! -f "$settings_local" ]]; then
  _check "Pre-1.0 layout detected (tasks.conf without settings.local.json)" "warn" \
    "run: supervisor migrate"
elif [[ -f "$repo_path/tasks.conf" ]]; then
  _check "tasks.conf present (legacy file)" "warn" "safe to remove or archive"
fi

# ─── Workspace-kit ────────────────────────────────────────────────────────────

if [[ -f "$repo_path/.cwk.lock" ]]; then
  _check "claude-workspace-kit (.cwk.lock)" "ok"
else
  _check "claude-workspace-kit (.cwk.lock)" "warn" "not detected — run: supervisor update"
fi

# ─── agents-shared ───────────────────────────────────────────────────────────

if [[ -d "$repo_path/.claude/agents-shared" ]]; then
  _check ".claude/agents-shared/ (peer notes directory)" "ok"
else
  _check ".claude/agents-shared/ (peer notes directory)" "warn" "missing — run: supervisor (to init)"
fi

# ─── CLAUDE.md supervisor block ───────────────────────────────────────────────

if [[ -f "$repo_path/.claude/CLAUDE.md" ]]; then
  if grep -q "BEGIN claude-supervisor" "$repo_path/.claude/CLAUDE.md" 2>/dev/null; then
    _check ".claude/CLAUDE.md (supervisor block)" "ok"
  else
    _check ".claude/CLAUDE.md (supervisor block)" "warn" "fenced block missing — run: supervisor update"
  fi
else
  _check ".claude/CLAUDE.md" "warn" "missing — agents won't have project memory"
fi

# ─── Active agents ────────────────────────────────────────────────────────────

state_file="$repo_path/.claude/supervisor-agents.jsonl"
if [[ -f "$state_file" ]]; then
  agent_count="$(wc -l < "$state_file" | xargs)"
  if [[ "$agent_count" -gt 0 ]]; then
    _check "Agent state file ($agent_count agent(s) recorded)" "ok"
    # Check worktree health
    while IFS= read -r entry; do
      local_branch="" local_wt=""
      if command -v jq &>/dev/null; then
        local_branch="$(echo "$entry" | jq -r '.branch // "?"' 2>/dev/null)"
        local_wt="$(echo "$entry" | jq -r '.worktree // ""' 2>/dev/null)"
      else
        local_branch="$(echo "$entry" | grep -o '"branch":"[^"]*"' | sed 's/"branch":"//;s/"//')"
        local_wt="$(echo "$entry" | grep -o '"worktree":"[^"]*"' | sed 's/"worktree":"//;s/"//')"
      fi
      if [[ -d "$local_wt" ]]; then
        # Check agents-shared symlink
        shared_link="$local_wt/.claude/agents-shared"
        if [[ -L "$shared_link" ]]; then
          _check "  Worktree $local_branch: agents-shared symlinked" "ok"
        elif [[ -d "$shared_link" ]]; then
          _check "  Worktree $local_branch: agents-shared (copy, not symlink)" "warn" \
            "re-run supervisor to fix"
        else
          _check "  Worktree $local_branch: agents-shared missing" "warn"
        fi
      else
        _check "  Worktree $local_branch" "warn" "directory gone: $local_wt"
      fi
    done < "$state_file"
  else
    _check "Agent state file (empty)" "warn"
  fi
else
  _check "Agent state file" "warn" "no agents spawned yet"
fi

# ─── tmux session ─────────────────────────────────────────────────────────────

session="$(basename "$repo_path")-agents"
if tmux has-session -t "$session" 2>/dev/null; then
  _check "tmux session '$session'" "ok"
else
  _check "tmux session '$session'" "warn" "not running"
fi

# ─── Dependencies ─────────────────────────────────────────────────────────────

echo ""
printf "  ${BOLD}Dependencies:${RESET}\n"
for tool in git tmux claude node; do
  if command -v "$tool" &>/dev/null; then
    _check "  $tool" "ok"
  else
    _check "  $tool" "fail" "not in PATH"
  fi
done

echo ""
