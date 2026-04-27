#!/usr/bin/env bash
# bin/on-stop.sh — Claude Code Stop hook target for claude-supervisor
#
# Called by Claude Code when a supervised agent session ends.
# Finds the main repo via git common-dir, runs collect-learnings,
# and appends a completion record to the session summary log.

set -euo pipefail

_SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_SCRIPT_PATH" ]]; do
  _SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
  _SCRIPT_PATH="$(readlink "$_SCRIPT_PATH")"
  [[ "$_SCRIPT_PATH" != /* ]] && _SCRIPT_PATH="$_SCRIPT_DIR/$_SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"

# ─── Find main repo ──────────────────────────────────────────────────────────
# Works from both the main worktree and secondary worktrees.
# git --git-common-dir always points at the main repo's .git.

if ! common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"; then
  echo "[on-stop] Not inside a git repository — nothing to do." >&2
  exit 0
fi

main_repo="$(dirname "$common_dir")"

# ─── Run collect-learnings ───────────────────────────────────────────────────

collect_script="$SCRIPT_DIR/collect-learnings.sh"
if [[ -x "$collect_script" ]] && [[ -f "$main_repo/.claude/CLAUDE.md" ]]; then
  echo "[on-stop] Running collect-learnings for $main_repo"
  bash "$collect_script" --yes "$main_repo" 2>&1 | sed 's/^/  [collect-learnings] /' || true
fi

# ─── Append to session summary ───────────────────────────────────────────────

branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
worktree="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

summary_file="$main_repo/.claude/supervisor-session-summary.jsonl"
mkdir -p "$(dirname "$summary_file")"
printf '{"branch":"%s","worktree":"%s","finished_at":"%s"}\n' \
  "$branch" "$worktree" "$finished_at" >> "$summary_file"

echo "[on-stop] Agent '$branch' finished at $finished_at"
