#!/usr/bin/env bash
# bin/collect-learnings.sh — Merge CLAUDE.md updates from worktrees back to main repo
#
# Usage: collect-learnings.sh [--yes] [repo_path]
#   --yes       Auto-approve all merges (non-interactive / CI / test use)
#   repo_path   defaults to $PWD
#
# For each active git worktree that has a .claude/CLAUDE.md differing from the
# main repo's copy, it shows the new lines and asks whether to apply them.
# New lines are appended to the Known Pitfalls section of the main CLAUDE.md.

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

# ─── Parse args ─────────────────────────────────────────────────────────────

auto_yes=false
repo_path="$PWD"

for arg in "$@"; do
  case "$arg" in
    --yes|-y) auto_yes=true ;;
    *)        repo_path="$arg" ;;
  esac
done

if [[ -d "$repo_path" ]]; then
  repo_path="$(cd "$repo_path" && pwd)"
else
  die "Directory not found: $repo_path"
fi

# ─── Validate repo ──────────────────────────────────────────────────────────

if ! git -C "$repo_path" rev-parse --git-dir &>/dev/null; then
  die "Not a git repository: $repo_path"
fi

main_claude="$repo_path/.claude/CLAUDE.md"

if [[ ! -f "$main_claude" ]]; then
  die "No .claude/CLAUDE.md found in $repo_path"
fi

# ─── Collect worktrees ──────────────────────────────────────────────────────

echo ""
printf "${BOLD}Claude Supervisor — Collect Learnings${RESET}\n"
printf "  Repo : ${CYAN}%s${RESET}\n" "$repo_path"
echo ""

# git worktree list --porcelain outputs blocks like:
#   worktree /path/to/worktree
#   HEAD <sha>
#   branch refs/heads/<name>
#
# We collect all paths except the main worktree.

worktree_paths=()
in_main=true
current_path=""

while IFS= read -r line; do
  if [[ "$line" =~ ^worktree[[:space:]]+(.*) ]]; then
    current_path="${BASH_REMATCH[1]}"
    if $in_main; then
      # First worktree is always the main checkout
      in_main=false
    else
      worktree_paths+=("$current_path")
    fi
  fi
done < <(git -C "$repo_path" worktree list --porcelain)

if [[ ${#worktree_paths[@]} -eq 0 ]]; then
  ok "No active worktrees found (nothing to collect)."
  echo ""
  printf "  Worktrees are created by the supervisor when agents run.\n"
  printf "  Once agents are done, run this script before removing them.\n"
  echo ""
  exit 0
fi

printf "  Found ${BOLD}%d${RESET} worktree(s) to check.\n" "${#worktree_paths[@]}"
echo ""

# ─── Per-worktree diff ──────────────────────────────────────────────────────

total_new=0

for wt in "${worktree_paths[@]}"; do
  wt_claude="$wt/.claude/CLAUDE.md"

  if [[ ! -f "$wt_claude" ]]; then
    info "Skipping ${CYAN}$(basename "$wt")${RESET} — no .claude/CLAUDE.md"
    continue
  fi

  # Lines added in the worktree copy vs main (added = exist in wt, not in main)
  new_lines="$(diff "$main_claude" "$wt_claude" | grep '^>' | sed 's/^> //' || true)"

  if [[ -z "$new_lines" ]]; then
    ok "${CYAN}$(basename "$wt")${RESET} — CLAUDE.md unchanged"
    continue
  fi

  echo ""
  printf "  ${BOLD}${CYAN}── Worktree: %s ──${RESET}\n" "$(basename "$wt")"
  printf "  New lines in this worktree's CLAUDE.md:\n\n"
  while IFS= read -r nline; do
    printf "    ${GREEN}+${RESET} %s\n" "$nline"
  done <<< "$new_lines"
  echo ""

  if $auto_yes; then
    answer="y"
  else
    printf "  Apply these changes to the main CLAUDE.md? [y/N] "
    read -r answer </dev/tty
  fi
  if [[ "$answer" == [yY] ]]; then
    # Extract only new Known Pitfalls bullets (lines starting with "- ")
    pitfall_lines="$(echo "$new_lines" | grep '^- ' || true)"
    other_lines="$(echo "$new_lines" | grep -v '^- ' | grep -v '^$' || true)"

    if [[ -n "$pitfall_lines" ]]; then
      # Insert new pitfall bullets into the Known Pitfalls section of main CLAUDE.md
      # Find the line number of "## Known Pitfalls" and the following blank line or next section
      # We'll append bullets right before the next "---" or "## " after the Known Pitfalls header
      tmp="$(mktemp)"
      in_pitfalls=false
      inserted=false
      while IFS= read -r ln || [[ -n "$ln" ]]; do
        if [[ "$ln" == "## Known Pitfalls" ]]; then
          in_pitfalls=true
        fi
        # When we hit the closing --- after Known Pitfalls, insert before it
        if $in_pitfalls && ! $inserted && [[ "$ln" == "---" || "$ln" =~ ^##\  ]]; then
          echo "" >> "$tmp"
          while IFS= read -r bullet; do
            echo "$bullet" >> "$tmp"
          done <<< "$pitfall_lines"
          inserted=true
          in_pitfalls=false
        fi
        echo "$ln" >> "$tmp"
      done < "$main_claude"
      mv "$tmp" "$main_claude"
      ok "Added ${GREEN}$(echo "$pitfall_lines" | wc -l | tr -d ' ')${RESET} pitfall bullet(s) to main CLAUDE.md"
    fi

    if [[ -n "$other_lines" ]]; then
      # Append non-bullet new content at the end of the file with a comment
      {
        echo ""
        echo "<!-- Merged from worktree: $(basename "$wt") -->"
        echo "$other_lines"
      } >> "$main_claude"
      ok "Appended ${GREEN}$(echo "$other_lines" | wc -l | tr -d ' ')${RESET} other line(s) to main CLAUDE.md"
    fi

    total_new=$((total_new + 1))
  else
    info "Skipped $(basename "$wt")"
  fi
done

# ─── Summary ────────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}─────────────────────────────────────${RESET}\n"
if [[ $total_new -gt 0 ]]; then
  ok "Merged learnings from ${GREEN}${total_new}${RESET} worktree(s) into:"
  printf "    ${CYAN}%s${RESET}\n" "$main_claude"
  echo ""
  printf "  Commit the updated CLAUDE.md to preserve it:\n"
  printf "    ${BOLD}git -C %s add .claude/CLAUDE.md && git commit -m 'docs: merge agent learnings'${RESET}\n" \
    "$repo_path"
else
  ok "Nothing new to merge."
fi
printf "${BOLD}─────────────────────────────────────${RESET}\n"
echo ""
