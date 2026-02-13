#!/usr/bin/env bash
# bin/spawn-agent.sh — Spawns a single Claude Code agent in a git worktree + tmux window
#
# Usage: spawn-agent.sh <repo_path> <branch_name> <model_id> <mode> <agent_index> "<task_prompt>"
#
# Independently runnable — all validation duplicated from supervisor.

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

# Per-agent labeled output helpers
AGENT_LABEL="[${branch_name}]"
agent_info() { printf "    ${CYAN}%s${RESET} ▸ %s\n" "$AGENT_LABEL" "$*"; }
agent_ok()   { printf "    ${GREEN}%s${RESET} ✓ %s\n" "$AGENT_LABEL" "$*"; }

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
  agent_info "Worktree already exists — reusing $worktree_path"
else
  # Check if branch already exists
  if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    agent_info "Creating worktree for existing branch: $branch_name"
    git -C "$repo_path" worktree add "$worktree_path" "$branch_name"
  else
    agent_info "Creating worktree with new branch: $branch_name"
    git -C "$repo_path" worktree add -b "$branch_name" "$worktree_path"
  fi
  agent_ok "Worktree ready at $worktree_path"
fi

# ─── Copy .claude/ directory ────────────────────────────────────────────────

if [[ -d "$repo_path/.claude" ]]; then
  agent_info "Copying .claude/ into worktree  (CLAUDE.md, agents/, commands/, settings.json)"
  rm -rf "$worktree_path/.claude"
  cp -r "$repo_path/.claude" "$worktree_path/.claude"
  agent_ok "Config ready"
else
  agent_info "No .claude/ directory in repo — skipping copy"
fi

# ─── Tmux session setup ─────────────────────────────────────────────────────

agent_info "Using tmux windows for agent isolation"
session="${repo_name}-agents"

# ─── Write startup script ───────────────────────────────────────────────────
# The script runs inside the tmux window: prints banner, launches claude, cleans up.
# Written BEFORE creating the tmux window so the window can launch it directly.

startup_script="$worktree_path/.claude-agent-start.sh"

banner_text="$(print_banner "$task_prompt" "$branch_name" "$model_id" "$mode")"

# Capture key value before heredoc (safe under set -u)
_api_key_val="${ANTHROPIC_API_KEY:-}"

cat > "$startup_script" <<STARTUP
#!/usr/bin/env bash

# Export API key only if using API billing
if [[ -n "${_api_key_val}" ]]; then
  export ANTHROPIC_API_KEY="${_api_key_val}"
fi

# Set Ghostty tab title if applicable
if [[ "\${TERM_PROGRAM:-}" == "ghostty" ]]; then
  printf '\033]0;${branch_name}\007'
fi

cat <<'BANNER'
${banner_text}
BANNER

echo ""
printf "\033[0;36m▸\033[0m Connecting to Claude API...\n"
printf "\033[0;36m▸\033[0m Will auto-start task in 5 seconds...\n"
echo ""

# Clean up this startup script
rm -f "${startup_script}"

# Launch claude (interactive mode)
STARTUP

# Build the claude command based on what's set
{
  printf 'exec claude'
  [[ -n "${model_id}" ]] && printf ' --model "%s"' "${model_id}"
  [[ "${mode}" == "plan" ]] && printf ' --permission-mode plan'
  printf '\n'
} >> "$startup_script"

chmod +x "$startup_script"

# ─── Create tmux window and launch startup script directly ──────────────────
# Using the shell command argument instead of send-keys avoids echoing
# the command text visibly in the terminal.

agent_info "Opening tmux window in session: $session"
if [[ -n "${TMUX:-}" ]]; then
  # Already inside tmux — add a new window
  tmux new-window -t "$session" -n "$branch_name" -c "$worktree_path" \
    "bash \"${startup_script}\"" 2>/dev/null \
    || tmux new-window -n "$branch_name" -c "$worktree_path" \
    "bash \"${startup_script}\""
else
  # Not inside tmux — create or join session
  if tmux has-session -t "$session" 2>/dev/null; then
    tmux new-window -t "$session" -n "$branch_name" -c "$worktree_path" \
      "bash \"${startup_script}\""
  else
    tmux new-session -d -s "$session" -n "$branch_name" -c "$worktree_path" \
      "bash \"${startup_script}\""
  fi
fi

# ─── Setup window color ─────────────────────────────────────────────────────

setup_window "$session" "$branch_name" "$agent_index" "$mode"

# ─── Auto-paste task prompt after Claude loads ─────────────────────────────

(
  # Wait for Claude to load, then send the task prompt automatically
  sleep 5
  
  # Send the task prompt to this specific window
  # Silence errors — the window may have closed if Claude exited early
  task_prompt_escaped=$(printf '%s' "$task_prompt" | sed 's/"/\\"/g')
  tmux send-keys -t "$session:$branch_name" "$task_prompt_escaped" Enter 2>/dev/null || true
) &
disown

agent_ok "Agent ready — model: ${model_id}  mode: ${mode}"
