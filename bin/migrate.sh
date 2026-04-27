#!/usr/bin/env bash
# bin/migrate.sh — Migrate a claude-supervisor 0.2.x project to 1.0 layout
#
# Usage: supervisor migrate [--yes] [repo_path]
#   --yes   Non-interactive: confirm all prompts automatically, skip workspace-kit,
#           archive tasks.conf. Useful for CI and testing.
#
# What it does:
#   1. Backs up .claude/ to .claude.backup-YYYYMMDD-HHMMSS/
#   2. Moves PermissionRequest hook from settings.json → settings.local.json
#   3. Renames settings.json → settings.json.v0-backup
#   4. Optionally runs npx claude-workspace-kit init
#   5. Creates agents-shared/, appends fenced supervisor block to CLAUDE.md
#   6. Handles tasks.conf: offer to archive or spawn from it

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

YES=false
repo_path=""
for _arg in "$@"; do
  case "$_arg" in
    --yes|-y) YES=true ;;
    *)        [[ -z "$repo_path" ]] && repo_path="$_arg" ;;
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
printf "${BOLD}Claude Supervisor — Migrate 0.2.x → 1.0${RESET}\n"
printf "  Repo: ${CYAN}%s${RESET}\n" "$repo_path"
echo ""

# ─── Detect whether migration is needed ──────────────────────────────────────

has_old_settings=false
has_tasks_conf=false
has_settings_local=false

[[ -f "$repo_path/.claude/settings.json" ]] && has_old_settings=true
[[ -f "$repo_path/tasks.conf" ]] && has_tasks_conf=true
[[ -f "$repo_path/.claude/settings.local.json" ]] && has_settings_local=true

if ! $has_old_settings && ! $has_tasks_conf && $has_settings_local; then
  ok "This project is already on the 1.0 layout — nothing to migrate."
  echo ""
  exit 0
fi

# ─── Print migration plan ─────────────────────────────────────────────────────

printf "${BOLD}Migration plan:${RESET}\n"
echo ""
printf "  1. Back up ${CYAN}.claude/${RESET} → ${CYAN}.claude.backup-YYYYMMDD-HHMMSS/${RESET}\n"
if $has_old_settings; then
  printf "  2. Move PermissionRequest hook from settings.json → settings.local.json\n"
  printf "  3. Rename settings.json → settings.json.v0-backup\n"
fi
printf "  4. Create ${CYAN}.claude/agents-shared/${RESET} and append supervisor block to CLAUDE.md\n"
if $has_tasks_conf; then
  printf "  5. Archive ${CYAN}tasks.conf${RESET} → ${CYAN}tasks.conf.v0-archive${RESET}\n"
fi
echo ""
printf "  ${YELLOW}Recovery:${RESET} rm -rf .claude && mv .claude.backup-* .claude\n"
echo ""
if $YES; then
  _confirm="y"
else
  printf "Proceed? [y/N] "
  read -r _confirm </dev/tty || _confirm="n"
fi
[[ "$_confirm" =~ ^[Yy] ]] || { echo "Cancelled."; exit 0; }
echo ""

# ─── Step 1: Backup ──────────────────────────────────────────────────────────

backup_ts="$(date '+%Y%m%d-%H%M%S')"
backup_dir="$repo_path/.claude.backup-${backup_ts}"
if [[ -d "$repo_path/.claude" ]]; then
  cp -r "$repo_path/.claude" "$backup_dir"
  ok "Backed up .claude/ → $(basename "$backup_dir")/"
else
  ok "No .claude/ to back up — skipping"
fi

# ─── Step 2+3: Move hook from settings.json → settings.local.json ────────────

if $has_old_settings && [[ ! -f "$repo_path/.claude/settings.local.json" ]]; then
  # Copy supervisor's template as the new overlay
  mkdir -p "$repo_path/.claude"
  cp "$TEMPLATES_DIR/.claude/settings.local.json" "$repo_path/.claude/settings.local.json"
  ok "Created .claude/settings.local.json (PermissionRequest + Stop hooks)"

  # Archive the old settings.json
  mv "$repo_path/.claude/settings.json" "$repo_path/.claude/settings.json.v0-backup"
  ok "Archived settings.json → settings.json.v0-backup"
  warn "Your customised agents/commands/skills in .claude/ are preserved."
  printf "    Review ${CYAN}.claude/${RESET} and consolidate any duplicates after workspace-kit init.\n"
  echo ""
elif $has_old_settings && [[ -f "$repo_path/.claude/settings.local.json" ]]; then
  ok "settings.local.json already exists — skipping hook migration"
fi

# ─── Step 4: Workspace-kit + agents-shared + CLAUDE.md block ─────────────────

# Optionally bootstrap workspace-kit
if [[ ! -f "$repo_path/.cwk.lock" ]]; then
  if $YES; then
    _cwk_ans="n"
  else
    echo ""
    printf "  Set up project agents and skills via ${CYAN}claude-workspace-kit${RESET}? [Y/n] "
    read -r _cwk_ans </dev/tty || _cwk_ans="n"
    _cwk_ans="${_cwk_ans:-Y}"
  fi
  if [[ "$_cwk_ans" =~ ^[Yy] ]] && command -v npx &>/dev/null; then
    info "Running npx claude-workspace-kit init..."
    npx --yes claude-workspace-kit init "$repo_path" || warn "workspace-kit init failed — skipping"
  fi
fi

# Ensure supervisor overlay exists
[[ -f "$repo_path/.claude/settings.local.json" ]] || \
  cp "$TEMPLATES_DIR/.claude/settings.local.json" "$repo_path/.claude/settings.local.json"

# agents-shared
mkdir -p "$repo_path/.claude/agents-shared"
ok "Created .claude/agents-shared/"

# Fenced CLAUDE.md block (reuse supervisor.sh helper logic)
claude_md="$repo_path/.claude/CLAUDE.md"
if [[ -f "$claude_md" ]] && ! grep -q "BEGIN claude-supervisor" "$claude_md" 2>/dev/null; then
  cat >> "$claude_md" <<'BLOCK'

<!-- BEGIN claude-supervisor (do not edit by hand) -->
## Worktree-sync Notes

This project uses `claude-supervisor` to run parallel agents across isolated git worktrees.

**Race-condition guidance:**
- Each agent works in its own worktree — never write to another agent's branch
- After adding to Known Pitfalls, commit this file:
  `git add .claude/CLAUDE.md && git commit -m "docs: update CLAUDE.md"`

**Sharing learnings across worktrees:**
The project owner runs `collect-learnings.sh [--yes] <repo_path>` to merge
new pitfall bullets from all active worktrees into the main copy.

**Shared peer notes:**
- Read peer updates: `cat .claude/agents-shared/*.md`
- Use `/share <message>` to append a timestamped note for peers
- Use `/peers` to view all peer notes
<!-- END claude-supervisor -->
BLOCK
  ok "Appended supervisor block to .claude/CLAUDE.md"
fi

# .gitignore entries
gitignore="$repo_path/.gitignore"
[[ -f "$gitignore" ]] || touch "$gitignore"
grep -qx ".env" "$gitignore" 2>/dev/null || printf '\n# Claude Supervisor — local secrets\n.env\n' >> "$gitignore"
grep -qx ".claude/agents-shared/" "$gitignore" 2>/dev/null || \
  printf '\n# Claude Supervisor — shared peer notes\n.claude/agents-shared/\n' >> "$gitignore"
ok "Updated .gitignore"

# ─── Step 5: Archive tasks.conf ──────────────────────────────────────────────

if $has_tasks_conf; then
  echo ""
  printf "${BOLD}tasks.conf found:${RESET}\n"
  echo ""
  head -20 "$repo_path/tasks.conf" | sed 's/^/    /'
  echo ""
  if $YES; then
    _tc_choice="a"
  else
    printf "  What would you like to do?\n"
    printf "    a) Archive it (rename to tasks.conf.v0-archive)\n"
    printf "    s) Spawn from it now with the new supervisor\n"
    printf "    k) Keep it as-is\n"
    printf "  Choice [a]: "
    read -r _tc_choice </dev/tty || _tc_choice="a"
    _tc_choice="${_tc_choice:-a}"
  fi

  case "$_tc_choice" in
    a|A)
      mv "$repo_path/tasks.conf" "$repo_path/tasks.conf.v0-archive"
      ok "Archived tasks.conf → tasks.conf.v0-archive"
      ;;
    s|S)
      ok "Keeping tasks.conf for one-time spawn — run: supervisor"
      ;;
    *)
      ok "Keeping tasks.conf as-is"
      ;;
  esac
fi

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}═══════════════════════════════════════════════════════════${RESET}\n"
printf "  ${GREEN}✓${RESET} Migration complete\n"
printf "${BOLD}═══════════════════════════════════════════════════════════${RESET}\n"
echo ""
printf "  Backup:  ${CYAN}%s${RESET}\n" "$(basename "$backup_dir" 2>/dev/null || echo "(none)")"
printf "  Recovery: rm -rf .claude && mv %s .claude\n" "$(basename "$backup_dir" 2>/dev/null || echo ".claude.backup-*")"
echo ""
printf "  Run ${CYAN}supervisor${RESET} to enter tasks and spawn agents.\n"
echo ""
