#!/usr/bin/env bash
# bin/uninstall.sh — Remove claude-supervisor from a project
#
# Usage: supervisor uninstall [--dry-run] [--with-workspace] [--everything] [repo_path]
#
# Flags:
#   --dry-run         Print plan and exit without changing anything
#   --with-workspace  Also prompt to run `npx claude-workspace-kit uninstall`
#   --everything      Also kill tmux session, remove worktrees, delete branches
#
# Light uninstall (default):
#   - .claude/settings.local.json
#   - .claude/agents-shared/
#   - Supervisor fenced block in .claude/CLAUDE.md
#   - Supervisor-added .gitignore entries (.env, .claude/agents-shared/)

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

DRY_RUN=false
WITH_WORKSPACE=false
EVERYTHING=false
repo_path=""

for arg in "$@"; do
  case "$arg" in
    --dry-run)         DRY_RUN=true ;;
    --with-workspace)  WITH_WORKSPACE=true ;;
    --everything)      EVERYTHING=true ;;
    *)
      if [[ -z "$repo_path" ]]; then
        repo_path="$arg"
      fi
      ;;
  esac
done

repo_path="${repo_path:-$PWD}"
if [[ -d "$repo_path" ]]; then
  repo_path="$(cd "$repo_path" && pwd)"
else
  die "Directory not found: $repo_path"
fi

if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
  die "Not a git repository: $repo_path"
fi

echo ""
printf "${BOLD}Claude Supervisor — Uninstall${RESET}\n"
printf "  Repo: ${CYAN}%s${RESET}\n" "$repo_path"
$DRY_RUN && printf "  ${YELLOW}DRY RUN — no changes will be made${RESET}\n"
echo ""

# ─── Build action list ────────────────────────────────────────────────────────

declare -a _actions=()

[[ -f "$repo_path/.claude/settings.local.json" ]] && \
  _actions+=("Remove .claude/settings.local.json")

[[ -d "$repo_path/.claude/agents-shared" ]] && \
  _actions+=("Remove .claude/agents-shared/")

if [[ -f "$repo_path/.claude/CLAUDE.md" ]] && \
   grep -q "BEGIN claude-supervisor" "$repo_path/.claude/CLAUDE.md" 2>/dev/null; then
  _actions+=("Remove supervisor fenced block from .claude/CLAUDE.md")
fi

if [[ -f "$repo_path/.gitignore" ]]; then
  grep -q ".claude/agents-shared/" "$repo_path/.gitignore" 2>/dev/null && \
    _actions+=("Remove .claude/agents-shared/ from .gitignore")
fi

if [[ -f "$repo_path/.claude/supervisor-agents.jsonl" ]]; then
  _actions+=("Remove .claude/supervisor-agents.jsonl")
fi

if [[ -f "$repo_path/.claude/supervisor-last.md" ]]; then
  _actions+=("Remove .claude/supervisor-last.md")
fi

if [[ -f "$repo_path/.claude/supervisor-session-summary.jsonl" ]]; then
  _actions+=("Remove .claude/supervisor-session-summary.jsonl")
fi

if $WITH_WORKSPACE && [[ -f "$repo_path/.cwk.lock" ]]; then
  _actions+=("Run: npx claude-workspace-kit uninstall $repo_path")
fi

if $EVERYTHING; then
  session="$(basename "$repo_path")-agents"
  if tmux has-session -t "$session" 2>/dev/null; then
    _actions+=("Kill tmux session: $session")
  fi
  while IFS= read -r wt; do
    [[ -d "$wt" ]] && _actions+=("Remove worktree: $wt")
  done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null | grep '^worktree ' | awk '{print $2}' | grep -v "^$repo_path$" || true)
fi

if [[ ${#_actions[@]} -eq 0 ]]; then
  ok "Nothing to remove — supervisor files not found in this project."
  echo ""
  exit 0
fi

# ─── Print plan ───────────────────────────────────────────────────────────────

printf "${BOLD}Will remove:${RESET}\n"
echo ""
for action in "${_actions[@]}"; do
  printf "  ${YELLOW}•${RESET} %s\n" "$action"
done
echo ""
printf "  ${CYAN}Undo:${RESET} git checkout .claude/ (for tracked files)\n"
echo ""

if $DRY_RUN; then
  printf "${YELLOW}Dry run — no changes made.${RESET}\n"
  echo ""
  exit 0
fi

printf "Proceed? [y/N] "
read -r _confirm </dev/tty || _confirm="n"
[[ "$_confirm" =~ ^[Yy] ]] || { echo "Cancelled."; exit 0; }
echo ""

# ─── Execute ─────────────────────────────────────────────────────────────────

if [[ -f "$repo_path/.claude/settings.local.json" ]]; then
  rm -f "$repo_path/.claude/settings.local.json"
  ok "Removed .claude/settings.local.json"
fi

if [[ -d "$repo_path/.claude/agents-shared" ]]; then
  rm -rf "$repo_path/.claude/agents-shared"
  # Remove symlinks in worktrees pointing at it
  while IFS= read -r wt; do
    local_link="$wt/.claude/agents-shared"
    [[ -L "$local_link" ]] && rm -f "$local_link" && ok "Removed symlink in $wt"
  done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null | grep '^worktree ' | awk '{print $2}' | grep -v "^$repo_path$" || true)
  ok "Removed .claude/agents-shared/"
fi

if [[ -f "$repo_path/.claude/CLAUDE.md" ]]; then
  # Remove the fenced supervisor block
  local_tmp="$(mktemp)"
  sed '/<!-- BEGIN claude-supervisor/,/<!-- END claude-supervisor -->/d' \
    "$repo_path/.claude/CLAUDE.md" > "$local_tmp" && \
    mv "$local_tmp" "$repo_path/.claude/CLAUDE.md"
  ok "Removed supervisor block from .claude/CLAUDE.md"
fi

if [[ -f "$repo_path/.gitignore" ]]; then
  local_tmp="$(mktemp)"
  grep -v '^\.claude/agents-shared/$' "$repo_path/.gitignore" > "$local_tmp" && \
    mv "$local_tmp" "$repo_path/.gitignore"
  ok "Cleaned .gitignore"
fi

rm -f "$repo_path/.claude/supervisor-agents.jsonl" \
      "$repo_path/.claude/supervisor-last.md" \
      "$repo_path/.claude/supervisor-session-summary.jsonl" 2>/dev/null || true

if $WITH_WORKSPACE && [[ -f "$repo_path/.cwk.lock" ]] && command -v npx &>/dev/null; then
  info "Running npx claude-workspace-kit uninstall..."
  npx --yes claude-workspace-kit uninstall "$repo_path" || warn "workspace-kit uninstall failed"
fi

if $EVERYTHING; then
  session="$(basename "$repo_path")-agents"
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux kill-session -t "$session" 2>/dev/null || true
    ok "Killed tmux session: $session"
  fi
  while IFS= read -r wt; do
    if [[ -d "$wt" && "$wt" != "$repo_path" ]]; then
      local_branch="$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
      git -C "$repo_path" worktree remove --force "$wt" 2>/dev/null || true
      [[ -n "$local_branch" ]] && git -C "$repo_path" branch -D "$local_branch" 2>/dev/null || true
      ok "Removed worktree and branch: $wt"
    fi
  done < <(git -C "$repo_path" worktree list --porcelain 2>/dev/null | grep '^worktree ' | awk '{print $2}' | grep -v "^$repo_path$" || true)
fi

echo ""
ok "Uninstall complete."
echo ""
