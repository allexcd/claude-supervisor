#!/usr/bin/env bash
# bin/update.sh — Update workspace-kit files and refresh supervisor overlay
#
# Usage: supervisor update [repo_path]
#   repo_path defaults to $PWD

set -euo pipefail

_SCRIPT_PATH="${BASH_SOURCE[0]}"
while [[ -L "$_SCRIPT_PATH" ]]; do
  _SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
  _SCRIPT_PATH="$(readlink "$_SCRIPT_PATH")"
  [[ "$_SCRIPT_PATH" != /* ]] && _SCRIPT_PATH="$_SCRIPT_DIR/$_SCRIPT_PATH"
done
SCRIPT_DIR="$(cd -P "$(dirname "$_SCRIPT_PATH")" && pwd)"
TEMPLATES_DIR="$SCRIPT_DIR/../templates"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/utils.sh"

repo_path="${1:-$PWD}"
if [[ -d "$repo_path" ]]; then
  repo_path="$(cd "$repo_path" && pwd)"
else
  die "Directory not found: $repo_path"
fi

if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
  die "Not a git repository: $repo_path"
fi

echo ""
printf "${BOLD}Claude Supervisor — update${RESET}\n"
echo ""

# ── Update workspace-kit if installed ─────────────────────────────────────
if [[ -f "$repo_path/.cwk.lock" ]]; then
  step "Updating claude-workspace-kit"
  if command -v npx &>/dev/null; then
    npx --yes claude-workspace-kit@latest update "$repo_path" \
      && ok "workspace-kit updated" \
      || warn "workspace-kit update failed — skipping"
  else
    warn "npx not found — skipping workspace-kit update"
  fi
else
  info "workspace-kit not installed — skipping (run supervisor in project to install)"
fi

# ── Refresh supervisor overlay ─────────────────────────────────────────────
step "Refreshing supervisor overlay"

if [[ ! -d "$repo_path/.claude" ]]; then
  warn "No .claude/ directory found — run supervisor to initialise first"
  exit 1
fi

# Refresh settings.local.json (preserves user edits only if model changed)
settings_local="$repo_path/.claude/settings.local.json"
template_local="$TEMPLATES_DIR/.claude/settings.local.json"

if [[ -f "$template_local" ]]; then
  if [[ ! -f "$settings_local" ]]; then
    cp "$template_local" "$settings_local"
    ok "Created .claude/settings.local.json"
  else
    # Check if hook model in settings.local.json is deprecated
    if command -v jq &>/dev/null; then
      current_model="$(jq -r '.hooks.PermissionRequest[0].hooks[0].model // empty' "$settings_local" 2>/dev/null)"
      template_model="$(jq -r '.hooks.PermissionRequest[0].hooks[0].model // empty' "$template_local" 2>/dev/null)"
      if [[ -n "$current_model" && -n "$template_model" && "$current_model" != "$template_model" ]]; then
        warn "PermissionRequest hook uses '$current_model' — template recommends '$template_model'"
        printf "  → Update ${CYAN}%s${RESET} to use '%s'\n" "$settings_local" "$template_model"
        printf "  → Or run: supervisor update --apply-hook-model\n"
      else
        ok ".claude/settings.local.json is up to date"
      fi
    else
      ok ".claude/settings.local.json present (install jq to check hook model)"
    fi
  fi
fi

# Ensure agents-shared/ exists
if [[ ! -d "$repo_path/.claude/agents-shared" ]]; then
  mkdir -p "$repo_path/.claude/agents-shared"
  ok "Created .claude/agents-shared/"
fi

# Ensure fenced supervisor block exists in CLAUDE.md
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

  [[ -f "$claude_md" ]] || touch "$claude_md"
  if ! grep -q "BEGIN claude-supervisor" "$claude_md" 2>/dev/null; then
    printf '\n%s\n' "$block" >> "$claude_md"
    ok "Added worktree-sync block to .claude/CLAUDE.md"
  else
    ok ".claude/CLAUDE.md supervisor block present"
  fi
}
_upsert_supervisor_block "$repo_path"

echo ""
ok "Update complete"
echo ""
