#!/usr/bin/env bash
# bin/setup-shortcuts.sh — Set up shell shortcuts for claude-supervisor
#
# Usage: bash bin/setup-shortcuts.sh
#
# Adds either PATH or aliases to ~/.zshrc for easy access to supervisor commands.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUPERVISOR_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()  { printf "  ${CYAN}▸${RESET} %s\n" "$*"; }
ok()    { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
warn()  { printf "  ${YELLOW}⚠${RESET}  %s\n" "$*"; }
die()   { printf "  ${RED}✗${RESET} %s\n" "$*" >&2; exit 1; }

# ─── Check if already installed ─────────────────────────────────────────────

ZSHRC="$HOME/.zshrc"

if ! [[ -f "$ZSHRC" ]]; then
  die "~/.zshrc not found. Are you using zsh?"
fi

if grep -q "# Claude Supervisor" "$ZSHRC" 2>/dev/null; then
  echo ""
  warn "Claude Supervisor already installed in ~/.zshrc"
  echo ""
  printf "  To reinstall, remove the ${CYAN}# Claude Supervisor${RESET} section from ~/.zshrc and run this again.\n"
  echo ""
  exit 0
fi

# ─── Show menu ──────────────────────────────────────────────────────────────

echo ""
printf "${BOLD}Claude Supervisor — Shell Integration${RESET}\n"
echo ""
printf "  Install location: ${CYAN}%s${RESET}\n" "$SUPERVISOR_ROOT"
echo ""
printf "  Choose installation method:\n"
echo ""
printf "  ${BOLD}1)${RESET} Add to PATH ${CYAN}(recommended)${RESET}\n"
printf "     Then run: ${BOLD}supervisor.sh${RESET} or ${BOLD}collect-learnings.sh${RESET}\n"
echo ""
printf "  ${BOLD}2)${RESET} Create aliases\n"
printf "     Then run: ${BOLD}supervisor${RESET} or ${BOLD}collect-learnings${RESET}\n"
echo ""
printf "  ${BOLD}3)${RESET} Cancel\n"
echo ""

while true; do
  printf "Select [1-3]: "
  read -r choice
  case "$choice" in
    1|2|3) break ;;
    *) printf "  ${RED}Invalid selection. Try again.${RESET}\n" ;;
  esac
done

if [[ "$choice" == "3" ]]; then
  echo ""
  info "Installation cancelled."
  echo ""
  exit 0
fi

# ─── Backup ~/.zshrc ────────────────────────────────────────────────────────

backup_file="${ZSHRC}.backup-$(date +%Y%m%d-%H%M%S)"
cp "$ZSHRC" "$backup_file"
ok "Backed up ~/.zshrc to $(basename "$backup_file")"

# ─── Append configuration ───────────────────────────────────────────────────

echo ""
info "Writing configuration to ~/.zshrc..."

if [[ "$choice" == "1" ]]; then
  # PATH setup
  cat >> "$ZSHRC" <<EOF

# Claude Supervisor
export PATH="${SUPERVISOR_ROOT}/bin:\$PATH"
EOF
  ok "Added ${SUPERVISOR_ROOT}/bin to PATH"
else
  # Alias setup
  cat >> "$ZSHRC" <<EOF

# Claude Supervisor
alias supervisor='bash ${SUPERVISOR_ROOT}/bin/supervisor.sh'
alias collect-learnings='bash ${SUPERVISOR_ROOT}/bin/collect-learnings.sh'
alias spawn-agent='bash ${SUPERVISOR_ROOT}/bin/spawn-agent.sh'
EOF
  ok "Created aliases: supervisor, collect-learnings, spawn-agent"
fi

# ─── Source the updated file ────────────────────────────────────────────────

echo ""
info "Reloading ~/.zshrc..."

# Source in the current shell if we're in zsh
if [[ -n "${ZSH_VERSION:-}" ]]; then
  # shellcheck disable=SC1090
  source "$ZSHRC"
  ok "Configuration loaded"
else
  warn "Not running in zsh — restart your terminal or run: source ~/.zshrc"
fi

# ─── Show usage instructions ────────────────────────────────────────────────

echo ""
printf "${BOLD}────────────────────────────────────────${RESET}\n"
ok "Installation complete!"
printf "${BOLD}────────────────────────────────────────${RESET}\n"
echo ""

if [[ "$choice" == "1" ]]; then
  printf "  You can now run from anywhere:\n"
  printf "    ${BOLD}supervisor.sh${RESET} [project-path]\n"
  printf "    ${BOLD}collect-learnings.sh${RESET} [--yes] [project-path]\n"
  printf "    ${BOLD}spawn-agent.sh${RESET} <args...>\n"
else
  printf "  You can now run from anywhere:\n"
  printf "    ${BOLD}supervisor${RESET} [project-path]\n"
  printf "    ${BOLD}collect-learnings${RESET} [--yes] [project-path]\n"
  printf "    ${BOLD}spawn-agent${RESET} <args...>\n"
fi

echo ""
printf "  If you're not in a zsh shell right now, restart your terminal or run:\n"
printf "    ${CYAN}source ~/.zshrc${RESET}\n"
echo ""
printf "  Backup saved at: ${CYAN}%s${RESET}\n" "$backup_file"
echo ""
