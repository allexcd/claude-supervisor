#!/usr/bin/env bash
# bin/spawn-agent.sh — Spawns a single Claude Code agent in a git worktree + tmux window
#
# Usage: spawn-agent.sh <repo_path> <branch_name> <model_id> <mode> <agent_index> "<task_prompt>"
#
# Independently runnable — all validation duplicated from supervisor.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/utils.sh"

# ─── Validate args ──────────────────────────────────────────────────────────

if [[ $# -ne 6 ]]; then
  die "Usage: spawn-agent.sh <repo_path> <branch_name> <model_id> <mode> <agent_index> \"<task_prompt>\""
fi

repo_path="$1"
branch_name="$2"
model_id="$3"
mode="$4"
agent_index="$5"
task_prompt="$6"

# ─── Validate repo ──────────────────────────────────────────────────────────

if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
  die "Not a git repository: $repo_path"
fi

# Resolve to absolute path
repo_path="$(cd "$repo_path" && pwd)"

# ─── Derive worktree path ───────────────────────────────────────────────────

repo_parent="$(dirname "$repo_path")"
repo_name="$(basename "$repo_path")"
worktree_path="${repo_parent}/${repo_name}-${branch_name}"

# ─── Create worktree ────────────────────────────────────────────────────────

if [[ -d "$worktree_path" ]]; then
  info "Worktree already exists at $worktree_path, skipping creation"
else
  # Check if branch already exists
  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    info "Creating worktree for existing branch: $branch_name"
    git -C "$repo_path" worktree add "$worktree_path" "$branch_name"
  else
    info "Creating worktree with new branch: $branch_name"
    git -C "$repo_path" worktree add -b "$branch_name" "$worktree_path"
  fi
  ok "Worktree created at $worktree_path"
fi

# ─── Copy .claude/ directory ────────────────────────────────────────────────

if [[ -d "$repo_path/.claude" ]]; then
  # Remove old copy to ensure fresh state
  rm -rf "$worktree_path/.claude"
  cp -r "$repo_path/.claude" "$worktree_path/.claude"
  ok "Copied .claude/ into worktree"
else
  info "No .claude/ directory in repo — skipping copy"
fi

# ─── Tmux setup ─────────────────────────────────────────────────────────────

session="${repo_name}-agents"

if [[ -n "${TMUX:-}" ]]; then
  # Already inside tmux — add a new window
  tmux new-window -t "$session" -n "$branch_name" -c "$worktree_path" 2>/dev/null \
    || tmux new-window -n "$branch_name" -c "$worktree_path"
else
  # Not inside tmux — create or join session
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux new-window -t "$session" -n "$branch_name" -c "$worktree_path"
  else
    tmux new-session -d -s "$session" -n "$branch_name" -c "$worktree_path"
  fi
fi

# ─── Setup window color + title ─────────────────────────────────────────────

setup_window "$session" "$branch_name" "$agent_index" "$mode"

# ─── Write startup script ───────────────────────────────────────────────────
# The script runs inside the tmux window: prints banner, launches claude, cleans up.

startup_script="$worktree_path/.claude-agent-start.sh"

banner_text="$(print_banner "$task_prompt" "$branch_name" "$model_id" "$mode")"

cat > "$startup_script" <<STARTUP
#!/usr/bin/env bash
export ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY}"

cat <<'BANNER'
${banner_text}
BANNER

echo ""

# Clean up this startup script
rm -f "${startup_script}"

# Launch claude
if [[ "${mode}" == "plan" ]]; then
  exec claude --model "${model_id}" --permission-mode plan -p "${task_prompt}"
else
  exec claude --model "${model_id}" -p "${task_prompt}"
fi
STARTUP

chmod +x "$startup_script"

# ─── Send startup command to tmux window ─────────────────────────────────────

tmux send-keys -t "${session}:${branch_name}" "bash \"${startup_script}\"" Enter

ok "Agent spawned: ${branch_name} (${model_id}, ${mode} mode)"
