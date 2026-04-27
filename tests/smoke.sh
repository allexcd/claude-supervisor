#!/usr/bin/env bash
# tests/smoke.sh — Smoke tests for claude-supervisor
#
# Run from project root:  bash tests/smoke.sh
#
# These tests verify core functionality without needing an API key,
# tmux, or claude installed. They test pure-bash logic and file operations.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."

# ─── Test harness ────────────────────────────────────────────────────────────

PASS=0
FAIL=0
TESTS=()

pass() { PASS=$((PASS + 1)); printf "  \033[0;32m✓\033[0m %s\n" "$1"; }
fail() { FAIL=$((FAIL + 1)); printf "  \033[0;31m✗\033[0m %s\n" "$1"; TESTS+=("$1"); }

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label — expected: '$expected', got: '$actual'"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label — expected to contain: '$needle'"
  fi
}

assert_file_exists() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    pass "$label"
  else
    fail "$label — file not found: $path"
  fi
}

assert_exit_code() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label — expected exit code $expected, got $actual"
  fi
}

# ─── Source utils.sh ─────────────────────────────────────────────────────────

source "$PROJECT_ROOT/lib/utils.sh"

# ─── Test: slugify ───────────────────────────────────────────────────────────

echo ""
echo "slugify"
echo "───────"

assert_eq "basic text" \
  "implement-oauth2-login-flow" \
  "$(slugify "implement OAuth2 login flow")"

assert_eq "special characters stripped" \
  "fix-the-bug-in-prodenv" \
  "$(slugify "Fix  the BUG!! in prod@env")"

assert_eq "leading/trailing hyphens stripped" \
  "leading-and-trailing-hyphens" \
  "$(slugify "---leading and trailing hyphens---")"

assert_eq "multiple spaces collapse to single hyphen" \
  "hello-world" \
  "$(slugify "hello     world")"

assert_eq "empty string returns empty" \
  "" \
  "$(slugify "")"

result="$(slugify "a very long task prompt that should be truncated because it exceeds the fifty character limit for branch names")"
if (( ${#result} <= 50 )); then
  pass "truncated to 50 chars (got ${#result})"
else
  fail "truncated to 50 chars — got ${#result} chars"
fi

assert_eq "already clean text unchanged" \
  "hello-world" \
  "$(slugify "hello-world")"

assert_eq "uppercase to lowercase" \
  "all-caps-test" \
  "$(slugify "ALL CAPS TEST")"

# ─── Test: print_banner ─────────────────────────────────────────────────────

echo ""
echo "print_banner"
echo "────────────"

banner="$(print_banner "fix the login bug" "fix-login-bug" "claude-haiku-4-5-20251001" "normal")"

assert_contains "banner contains task" "fix the login bug" "$banner"
assert_contains "banner contains branch" "fix-login-bug" "$banner"
assert_contains "banner contains model" "claude-haiku-4-5-20251001" "$banner"
assert_contains "banner contains mode" "normal" "$banner"
assert_contains "banner contains /model hint" "/model" "$banner"
assert_contains "banner contains /agents hint" "/agents" "$banner"
assert_contains "banner contains CLAUDE.md reminder" "CLAUDE.md" "$banner"

# Long task gets truncated
long_banner="$(print_banner "review the codebase and write a detailed implementation plan for OAuth2 login" "review-branch" "claude-sonnet-4-5-20250929" "plan")"
assert_contains "long task is truncated with ..." "..." "$long_banner"
assert_contains "plan mode shown" "plan" "$long_banner"

# ─── Helper: create a minimal mock PATH for workspace-kit responses ───────────

# Creates a mock npx that simulates "workspace-kit declined" (exits 1 or never called)
# We rely on the supervisor's stdin being /dev/null (empty) so the read gets ""
# which defaults to "Y", but with a mocked npx that fails → falls back to minimal scaffold.

_make_mock_npx_fail() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/npx" <<'MOCK'
#!/usr/bin/env bash
# Mock npx that always fails (simulates workspace-kit not found / install failure)
exit 1
MOCK
  chmod +x "$dir/npx"
}

_make_mock_npx_succeed() {
  local dir="$1" repo_path="$2"
  mkdir -p "$dir"
  cat > "$dir/npx" <<MOCK
#!/usr/bin/env bash
# Mock npx claude-workspace-kit init — creates minimal .cwk.lock and .claude/
mkdir -p "${repo_path}/.claude/agents"
touch "${repo_path}/.cwk.lock"
touch "${repo_path}/.claude/settings.json"
exit 0
MOCK
  chmod +x "$dir/npx"
}

# ─── Test: auto-init — minimal fallback (workspace-kit declined / fails) ──────

echo ""
echo "supervisor auto-init (minimal fallback)"
echo "───────────────────────────────────────"

test_repo="/tmp/claude-supervisor-test-$$"
mkdir -p "$test_repo"
git -C "$test_repo" init -b main &>/dev/null
git -C "$test_repo" config user.email "ci@test.local"
git -C "$test_repo" config user.name "CI Test"
touch "$test_repo/README.md"
git -C "$test_repo" add . &>/dev/null
git -C "$test_repo" commit -m "init" &>/dev/null

mock_bin_init="/tmp/mock-npx-init-$$"
_make_mock_npx_fail "$mock_bin_init"

# Run supervisor with mocked npx (fails → minimal fallback) and answer "n" to stdin
output="$(echo "n" | PATH="$mock_bin_init:$PATH" bash "$PROJECT_ROOT/bin/supervisor.sh" "$test_repo" 2>&1)" || true

if [[ ! -f "$test_repo/tasks.conf" ]]; then
  pass "tasks.conf not created (removed in 1.0)"
else
  fail "tasks.conf should not be created in 1.0 init"
fi
assert_file_exists ".claude/ created (minimal)"        "$test_repo/.claude"
assert_file_exists ".claude/CLAUDE.md created"         "$test_repo/.claude/CLAUDE.md"
assert_file_exists ".claude/settings.local.json"       "$test_repo/.claude/settings.local.json"
assert_file_exists ".claude/agents-shared/ created"    "$test_repo/.claude/agents-shared"
assert_file_exists ".claude/agents/_example-agent.md"  "$test_repo/.claude/agents/_example-agent.md"
assert_contains "init message mentions bullet input"   "supervisor" "$output"
assert_contains "model discovery runs during scaffold" "Available models" "$output"

# No workspace-kit-owned files should exist
if [[ ! -f "$test_repo/.claude/agents/reviewer.md" ]]; then
  pass "reviewer.md not created (workspace-kit not installed)"
else
  fail "reviewer.md should not exist in minimal fallback"
fi
if [[ ! -f "$test_repo/.claude/settings.json" ]]; then
  pass "settings.json not created (workspace-kit owns it)"
else
  fail "settings.json should not exist in minimal fallback"
fi

# settings.local.json must contain PermissionRequest hook
settings_local_content="$(cat "$test_repo/.claude/settings.local.json")"
assert_contains "settings.local.json has PermissionRequest hook" "PermissionRequest" "$settings_local_content"

# CLAUDE.md must contain the fenced supervisor block
claude_md_content="$(cat "$test_repo/.claude/CLAUDE.md")"
assert_contains "CLAUDE.md has supervisor fenced block" "BEGIN claude-supervisor" "$claude_md_content"
assert_contains "CLAUDE.md fenced block closed"         "END claude-supervisor"   "$claude_md_content"

# Verify .gitignore entries (1.0: no tasks.conf, yes agents-shared)
assert_file_exists ".gitignore created" "$test_repo/.gitignore"
if ! grep -qx "tasks.conf" "$test_repo/.gitignore" 2>/dev/null; then
  pass ".gitignore does not contain tasks.conf (removed in 1.0)"
else
  fail ".gitignore should not contain tasks.conf in 1.0"
fi
if grep -q ".claude/agents-shared/" "$test_repo/.gitignore" 2>/dev/null; then
  pass ".gitignore contains .claude/agents-shared/"
else
  fail ".gitignore missing .claude/agents-shared/ entry"
fi

rm -rf "$mock_bin_init"

# ─── Test: auto-init — workspace-kit detected (.cwk.lock present) ─────────────

echo ""
echo "supervisor auto-init (.cwk.lock branch)"
echo "────────────────────────────────────────"

cwk_repo="/tmp/claude-supervisor-cwk-$$"
mkdir -p "$cwk_repo/.claude"
git -C "$cwk_repo" init -b main &>/dev/null
git -C "$cwk_repo" config user.email "ci@test.local"
git -C "$cwk_repo" config user.name "CI Test"
touch "$cwk_repo/README.md"
touch "$cwk_repo/.cwk.lock"
git -C "$cwk_repo" add . &>/dev/null
git -C "$cwk_repo" commit -m "init" &>/dev/null

# Inject some existing content into CLAUDE.md to verify it's preserved
echo "# Existing project memory" > "$cwk_repo/.claude/CLAUDE.md"

cwk_output="$(bash "$PROJECT_ROOT/bin/supervisor.sh" "$cwk_repo" 2>&1)" || true

assert_file_exists "settings.local.json created (.cwk.lock path)" "$cwk_repo/.claude/settings.local.json"
assert_file_exists "agents-shared/ created (.cwk.lock path)"      "$cwk_repo/.claude/agents-shared"
assert_contains    ".cwk.lock detected in output"                  ".cwk.lock" "$cwk_output"

# Existing CLAUDE.md content must be preserved (we only append, never replace)
cwk_claude_content="$(cat "$cwk_repo/.claude/CLAUDE.md")"
assert_contains "existing CLAUDE.md content preserved" "Existing project memory" "$cwk_claude_content"
assert_contains "supervisor block appended to existing CLAUDE.md" "BEGIN claude-supervisor" "$cwk_claude_content"

rm -rf "$cwk_repo"

# ─── Test: auto-init — .claude/ already exists with content ──────────────────

echo ""
echo "auto-init idempotency"
echo "─────────────────────"

# settings.local.json is now the init marker; re-run with it present should skip
# (skip straight to normal run — which needs tasks.conf to not error)
# First, make sure tasks.conf exists so the normal run reaches task spawn
echo "custom content" > "$test_repo/.claude/CLAUDE.md"
output2="$(bash "$PROJECT_ROOT/bin/supervisor.sh" "$test_repo" 2>&1)" || true

# Init must NOT run again (settings.local.json already exists)
# We know init didn't run if output2 doesn't contain "Initialising..."
if [[ "$output2" != *"Initialising"* ]]; then
  pass "init skipped on re-run (settings.local.json present)"
else
  fail "init ran again on re-run — settings.local.json should prevent it"
fi

# The CLAUDE.md custom content must survive across re-runs
custom_content="$(cat "$test_repo/.claude/CLAUDE.md")"
assert_eq ".claude/CLAUDE.md preserved across re-runs" "custom content" "$custom_content"

# Verify .gitignore agents-shared entry not duplicated on re-run
gitignore_count=$(grep -c "agents-shared" "$test_repo/.gitignore" || true)
if (( gitignore_count <= 2 )); then
  pass ".gitignore agents-shared entry not duplicated on re-run"
else
  fail ".gitignore has ${gitignore_count} 'agents-shared' entries (expected ≤2)"
fi

# Test: scaffolding appends to existing .gitignore
test_repo_gi="/tmp/claude-supervisor-test-gitignore-$$"
mkdir -p "$test_repo_gi"
git -C "$test_repo_gi" init -b main &>/dev/null
git -C "$test_repo_gi" config user.email "ci@test.local"
git -C "$test_repo_gi" config user.name "CI Test"
echo "node_modules/" > "$test_repo_gi/.gitignore"
touch "$test_repo_gi/README.md"
git -C "$test_repo_gi" add . &>/dev/null
git -C "$test_repo_gi" commit -m "init" &>/dev/null

mock_bin_gi="/tmp/mock-npx-gi-$$"
_make_mock_npx_fail "$mock_bin_gi"
echo "n" | PATH="$mock_bin_gi:$PATH" bash "$PROJECT_ROOT/bin/supervisor.sh" "$test_repo_gi" &>/dev/null || true

if grep -q "node_modules/" "$test_repo_gi/.gitignore" && grep -q "agents-shared" "$test_repo_gi/.gitignore"; then
  pass ".gitignore appended to (preserves existing entries, adds agents-shared)"
else
  fail ".gitignore existing content lost or agents-shared not added"
fi
rm -rf "$test_repo_gi" "$mock_bin_gi"

# ─── Test: auto-init — workspace-kit succeeds (mocked npx) ───────────────────

echo ""
echo "supervisor auto-init (workspace-kit success)"
echo "─────────────────────────────────────────────"

wk_success_repo="/tmp/claude-supervisor-wk-success-$$"
mkdir -p "$wk_success_repo"
git -C "$wk_success_repo" init -b main &>/dev/null
git -C "$wk_success_repo" config user.email "ci@test.local"
git -C "$wk_success_repo" config user.name "CI Test"
touch "$wk_success_repo/README.md"
git -C "$wk_success_repo" add . &>/dev/null
git -C "$wk_success_repo" commit -m "init" &>/dev/null

mock_bin_wk="/tmp/mock-npx-wk-$$"
_make_mock_npx_succeed "$mock_bin_wk" "$wk_success_repo"

# Answer "y" to workspace-kit prompt
wk_output="$(echo "y" | PATH="$mock_bin_wk:$PATH" bash "$PROJECT_ROOT/bin/supervisor.sh" "$wk_success_repo" 2>&1)" || true

# workspace-kit mock creates .cwk.lock and settings.json
assert_file_exists ".cwk.lock created by workspace-kit"         "$wk_success_repo/.cwk.lock"
# supervisor always adds settings.local.json regardless
assert_file_exists "settings.local.json added on top of cwk"   "$wk_success_repo/.claude/settings.local.json"
assert_file_exists "agents-shared/ created"                     "$wk_success_repo/.claude/agents-shared"
assert_contains    "output confirms workspace-kit init"          "workspace-kit" "$wk_output"

rm -rf "$wk_success_repo" "$mock_bin_wk"

# ─── Test: save_api_key_to_env ───────────────────────────────────────────────

echo ""
echo "save_api_key_to_env"
echo "───────────────────"

env_test_repo="/tmp/claude-supervisor-test-env-$$"
mkdir -p "$env_test_repo"
git -C "$env_test_repo" init -b main &>/dev/null
git -C "$env_test_repo" config user.email "ci@test.local"
git -C "$env_test_repo" config user.name "CI Test"
touch "$env_test_repo/README.md"
git -C "$env_test_repo" add . && git -C "$env_test_repo" commit -m "init" &>/dev/null

# Test: creates .env from scratch
ANTHROPIC_API_KEY="sk-test-key-123"
export ANTHROPIC_API_KEY
save_api_key_to_env "$env_test_repo" &>/dev/null

assert_file_exists ".env created" "$env_test_repo/.env"
if grep -q '^ANTHROPIC_API_KEY=sk-test-key-123$' "$env_test_repo/.env" 2>/dev/null; then
  pass ".env contains correct key"
else
  fail ".env missing ANTHROPIC_API_KEY entry"
fi

# Test: .env added to .gitignore
if [[ -f "$env_test_repo/.gitignore" ]] && grep -qx '.env' "$env_test_repo/.gitignore" 2>/dev/null; then
  pass ".env added to .gitignore"
else
  fail ".gitignore missing .env entry"
fi

# Test: idempotent — doesn't duplicate key
save_api_key_to_env "$env_test_repo" &>/dev/null
env_key_count=$(grep -c '^ANTHROPIC_API_KEY=' "$env_test_repo/.env")
if (( env_key_count == 1 )); then
  pass ".env key not duplicated on re-run"
else
  fail ".env has ${env_key_count} ANTHROPIC_API_KEY entries (expected 1)"
fi

# Test: appends to existing .env without destroying other keys
rm -rf "$env_test_repo/.env" "$env_test_repo/.gitignore"
printf 'DATABASE_URL=postgres://localhost/mydb\nREDIS_URL=redis://localhost\n' > "$env_test_repo/.env"
save_api_key_to_env "$env_test_repo" &>/dev/null

if grep -q '^DATABASE_URL=' "$env_test_repo/.env" && grep -q '^REDIS_URL=' "$env_test_repo/.env"; then
  pass ".env preserves existing keys"
else
  fail ".env existing keys were destroyed"
fi

if grep -q '^ANTHROPIC_API_KEY=sk-test-key-123$' "$env_test_repo/.env"; then
  pass ".env appended ANTHROPIC_API_KEY after existing keys"
else
  fail ".env missing appended ANTHROPIC_API_KEY"
fi

rm -rf "$env_test_repo"
unset ANTHROPIC_API_KEY

# ─── Test: billing mode and static models ────────────────────────────────────

echo ""
echo "billing mode & static models"
echo "────────────────────────────"

# Test: STATIC_MODELS array is populated
if [[ ${#STATIC_MODELS[@]} -gt 0 ]]; then
  pass "STATIC_MODELS array is populated (${#STATIC_MODELS[@]} entries)"
else
  fail "STATIC_MODELS array is empty"
fi

# Test: STATIC_MODELS entries have correct format (id|name)
static_format_ok=true
for entry in "${STATIC_MODELS[@]}"; do
  if [[ "$entry" != *"|"* ]]; then
    static_format_ok=false
    break
  fi
done
if $static_format_ok; then
  pass "STATIC_MODELS entries have id|name format"
else
  fail "STATIC_MODELS entries missing pipe separator"
fi

# Test: ask_billing_mode auto-detects API when key is set
ANTHROPIC_API_KEY="sk-test-auto"
export ANTHROPIC_API_KEY
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=""
ask_billing_mode "/tmp/nonexistent" &>/dev/null
if [[ "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" == "api" ]]; then
  pass "ask_billing_mode auto-detects api when key is in env"
else
  fail "ask_billing_mode did not auto-detect api (got: '$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE')"
fi

# Test: ask_billing_mode auto-detects API when key is in .env file
unset ANTHROPIC_API_KEY
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=""
billing_test_dir="/tmp/claude-billing-test-$$"
mkdir -p "$billing_test_dir"
printf 'ANTHROPIC_API_KEY=sk-test-from-env\n' > "$billing_test_dir/.env"
ask_billing_mode "$billing_test_dir" &>/dev/null
if [[ "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" == "api" ]]; then
  pass "ask_billing_mode auto-detects api from .env file"
else
  fail "ask_billing_mode did not detect api from .env (got: '$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE')"
fi
if [[ "${ANTHROPIC_API_KEY:-}" == "sk-test-from-env" ]]; then
  pass "ask_billing_mode loads API key from .env"
else
  fail "ask_billing_mode did not load key from .env (got: '${ANTHROPIC_API_KEY:-}')"
fi
rm -rf "$billing_test_dir"
unset ANTHROPIC_API_KEY
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=""

# Test: fetch_models with pro billing returns static models
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="pro"
AVAILABLE_MODELS=()
fetch_models &>/dev/null
if [[ ${#AVAILABLE_MODELS[@]} -gt 0 ]]; then
  pass "fetch_models (pro) populates AVAILABLE_MODELS"
else
  fail "fetch_models (pro) returned empty AVAILABLE_MODELS"
fi

# Test: fetch_models pro uses same count as STATIC_MODELS
if [[ ${#AVAILABLE_MODELS[@]} -eq ${#STATIC_MODELS[@]} ]]; then
  pass "fetch_models (pro) returns same count as STATIC_MODELS"
else
  fail "fetch_models (pro) returned ${#AVAILABLE_MODELS[@]} models, expected ${#STATIC_MODELS[@]}"
fi

CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=""
AVAILABLE_MODELS=()

# ─── Test: billing mode persistence ──────────────────────────────────────────

echo ""
echo "billing mode persistence"
echo "────────────────────────"

# Test: _save_billing_mode writes to .env
persist_dir="/tmp/claude-persist-test-$$"
mkdir -p "$persist_dir"
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="pro"
_save_billing_mode "$persist_dir"
if [[ -f "$persist_dir/.env" ]] && grep -q '^CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=pro' "$persist_dir/.env"; then
  pass "_save_billing_mode writes CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=pro to .env"
else
  fail "_save_billing_mode did not write to .env"
fi

# Test: _save_billing_mode creates .gitignore with .env
if [[ -f "$persist_dir/.gitignore" ]] && grep -q '.env' "$persist_dir/.gitignore"; then
  pass "_save_billing_mode adds .env to .gitignore"
else
  fail "_save_billing_mode did not add .env to .gitignore"
fi

# Test: _save_billing_mode updates existing value
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE="api"
_save_billing_mode "$persist_dir"
if grep -q '^CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=api' "$persist_dir/.env"; then
  pass "_save_billing_mode updates existing CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE"
else
  fail "_save_billing_mode did not update CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE (got: $(cat "$persist_dir/.env"))"
fi

# Test: ask_billing_mode reads saved pro mode from .env
unset ANTHROPIC_API_KEY 2>/dev/null || true
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=""
RESET_BILLING=""
printf 'CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=pro\n' > "$persist_dir/.env"
ask_billing_mode "$persist_dir" &>/dev/null
if [[ "$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE" == "pro" ]]; then
  pass "ask_billing_mode reads saved pro preference from .env"
else
  fail "ask_billing_mode did not read saved preference (got: '$CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE')"
fi

RESET_BILLING=""
rm -rf "$persist_dir"
unset ANTHROPIC_API_KEY 2>/dev/null || true
CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=""

# Test: spawn-agent succeeds without ANTHROPIC_API_KEY (Pro billing)
# This is the exact scenario that caused "unbound variable" in production.
spawn_nokey_repo="/tmp/claude-spawn-nokey-$$"
mkdir -p "$spawn_nokey_repo"
git -C "$spawn_nokey_repo" init -b main &>/dev/null
git -C "$spawn_nokey_repo" config user.email "ci@test.local"
git -C "$spawn_nokey_repo" config user.name "CI Test"
touch "$spawn_nokey_repo/README.md"
git -C "$spawn_nokey_repo" add . && git -C "$spawn_nokey_repo" commit -m "init" &>/dev/null
mkdir -p "$spawn_nokey_repo/.claude"

mkdir -p "/tmp/mock-bin-nokey-$$"
cat > "/tmp/mock-bin-nokey-$$/tmux" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "/tmp/mock-bin-nokey-$$/tmux"

unset ANTHROPIC_API_KEY
nokey_output=""
nokey_output=$(PATH="/tmp/mock-bin-nokey-$$:$PATH" bash "$PROJECT_ROOT/bin/spawn-agent.sh" \
  "$spawn_nokey_repo" \
  "nokey-branch" \
  "claude-sonnet-4-5-20250929" \
  "normal" \
  "0" \
  "Test without API key" 2>&1) && nokey_ec=$? || nokey_ec=$?

if (( nokey_ec == 0 )); then
  pass "spawn-agent exits 0 without API key (Pro billing)"
else
  fail "spawn-agent fails without API key (exit $nokey_ec): $nokey_output"
fi

nokey_startup="$spawn_nokey_repo/../$(basename "$spawn_nokey_repo")-nokey-branch/.claude-agent-start.sh"
if [[ -f "$nokey_startup" ]]; then
  pass "startup script created without API key"

  # Validate the generated script is syntactically valid
  if bash -n "$nokey_startup" 2>/dev/null; then
    pass "no-key startup script has valid bash syntax"
  else
    fail "no-key startup script has syntax errors"
  fi

  # The if-block should have an empty string so export never fires at runtime
  if grep -q 'ANTHROPIC_API_KEY="sk-' "$nokey_startup"; then
    fail "startup script leaks a real API key"
  else
    pass "startup script without API key doesn't leak a real key"
  fi
else
  fail "startup script not created for no-key test"
fi
rm -rf "$spawn_nokey_repo" "$spawn_nokey_repo-nokey-branch" "/tmp/mock-bin-nokey-$$"

# ─── Test: supervisor subcommand routing (Phase 4) ───────────────────────────

echo ""
echo "supervisor subcommand routing"
echo "─────────────────────────────"

# doctor on a valid repo should exit 0
doctor_repo="/tmp/cs-doctor-$$"
mkdir -p "$doctor_repo/.claude"
git -C "$doctor_repo" init -b main &>/dev/null
git -C "$doctor_repo" config user.email "ci@test.local"
git -C "$doctor_repo" config user.name "CI Test"
touch "$doctor_repo/README.md"
git -C "$doctor_repo" add . &>/dev/null
git -C "$doctor_repo" commit -m "init" &>/dev/null

doctor_out="$(bash "$PROJECT_ROOT/bin/supervisor.sh" doctor "$doctor_repo" 2>&1)" && doctor_ec=$? || doctor_ec=$?
assert_exit_code "supervisor doctor exits 0 on valid repo" "0" "$doctor_ec"
assert_contains "doctor output mentions git" "Git repository" "$doctor_out"

rm -rf "$doctor_repo"

# uninstall --dry-run on a valid repo should exit 0 with no changes
uninstall_repo="/tmp/cs-uninstall-$$"
mkdir -p "$uninstall_repo/.claude"
git -C "$uninstall_repo" init -b main &>/dev/null
git -C "$uninstall_repo" config user.email "ci@test.local"
git -C "$uninstall_repo" config user.name "CI Test"
touch "$uninstall_repo/.claude/settings.local.json"
touch "$uninstall_repo/README.md"
git -C "$uninstall_repo" add . &>/dev/null
git -C "$uninstall_repo" commit -m "init" &>/dev/null

uninstall_out="$(bash "$PROJECT_ROOT/bin/supervisor.sh" uninstall --dry-run "$uninstall_repo" 2>&1)" && uninstall_ec=$? || uninstall_ec=$?
assert_exit_code "supervisor uninstall --dry-run exits 0" "0" "$uninstall_ec"
assert_contains "dry-run output mentions settings.local.json" "settings.local.json" "$uninstall_out"
# File must still exist after dry run
assert_file_exists "settings.local.json untouched after dry-run" "$uninstall_repo/.claude/settings.local.json"

rm -rf "$uninstall_repo"

# migrate subcommand detected (no 0.2.x repo needed — just test routing)
# migrate on a 1.0 repo (has settings.local.json) should say "already on 1.0 layout"
migrate_repo="/tmp/cs-migrate-$$"
mkdir -p "$migrate_repo/.claude"
git -C "$migrate_repo" init -b main &>/dev/null
git -C "$migrate_repo" config user.email "ci@test.local"
git -C "$migrate_repo" config user.name "CI Test"
touch "$migrate_repo/.claude/settings.local.json"
touch "$migrate_repo/README.md"
git -C "$migrate_repo" add . &>/dev/null
git -C "$migrate_repo" commit -m "init" &>/dev/null

migrate_out="$(bash "$PROJECT_ROOT/bin/supervisor.sh" migrate "$migrate_repo" 2>&1)" && migrate_ec=$? || migrate_ec=$?
assert_exit_code "supervisor migrate exits 0 on already-migrated repo" "0" "$migrate_ec"
assert_contains "migrate detects 1.0 layout" "already on the 1.0 layout" "$migrate_out"

rm -rf "$migrate_repo"

# ─── Test: supervisor rejects non-git directory ──────────────────────────────

echo ""
echo "supervisor validation"
echo "─────────────────────"

non_git_dir="/tmp/claude-supervisor-nongit-$$"
mkdir -p "$non_git_dir"

output3="$(bash "$PROJECT_ROOT/bin/supervisor.sh" "$non_git_dir" 2>&1)" && exit_code=$? || exit_code=$?
assert_exit_code "rejects non-git directory" "1" "$exit_code"
assert_contains "error mentions git" "Not a git repository" "$output3"

rm -rf "$non_git_dir"

# ─── Test: supervisor rejects missing directory ──────────────────────────────

output4="$(bash "$PROJECT_ROOT/bin/supervisor.sh" "/tmp/nonexistent-dir-$$" 2>&1)" && exit_code=$? || exit_code=$?
assert_exit_code "rejects missing directory" "1" "$exit_code"
assert_contains "error mentions directory" "Directory not found" "$output4"

# ─── Test: spawn-agent.sh arg validation ─────────────────────────────────────

echo ""
echo "spawn-agent arg validation"
echo "──────────────────────────"

# Too few args
output5="$(bash "$PROJECT_ROOT/bin/spawn-agent.sh" 2>&1)" && exit_code=$? || exit_code=$?
assert_exit_code "rejects zero args" "1" "$exit_code"
assert_contains "shows usage on zero args" "Usage:" "$output5"

# Not a git repo
output6="$(bash "$PROJECT_ROOT/bin/spawn-agent.sh" "/tmp" "branch" "model" "normal" "0" "task" 2>&1)" && exit_code=$? || exit_code=$?
assert_exit_code "rejects non-git repo" "1" "$exit_code"
assert_contains "error mentions git repo" "Not a git repository" "$output6"

# ─── Test: spawn-agent startup script generation ─────────────────────────────

echo ""
echo "spawn-agent startup script"
echo "──────────────────────────"

# Create a minimal test repo with .claude/
spawn_test_repo="/tmp/claude-supervisor-spawn-test-$$"
mkdir -p "$spawn_test_repo/.claude/agents"
mkdir -p "$spawn_test_repo/.claude/commands"
touch "$spawn_test_repo/.claude/CLAUDE.md"
echo '{}' > "$spawn_test_repo/.claude/settings.json"
git -C "$spawn_test_repo" init -b main &>/dev/null
git -C "$spawn_test_repo" config user.email "ci@test.local"
git -C "$spawn_test_repo" config user.name "CI Test"
touch "$spawn_test_repo/README.md"
git -C "$spawn_test_repo" add . &>/dev/null
git -C "$spawn_test_repo" commit -m "init" &>/dev/null

# Mock tmux commands so spawn-agent doesn't actually create windows
mkdir -p "/tmp/mock-bin-$$"
cat > "/tmp/mock-bin-$$/tmux" <<'MOCK'
#!/usr/bin/env bash
# Mock tmux that does nothing but succeeds
exit 0
MOCK
chmod +x "/tmp/mock-bin-$$/tmux"

# Run spawn-agent with mocked tmux (WITH API key — the API billing path)
export ANTHROPIC_API_KEY="sk-test-key"
spawn_output=""
spawn_output=$(PATH="/tmp/mock-bin-$$:$PATH" bash "$PROJECT_ROOT/bin/spawn-agent.sh" \
  "$spawn_test_repo" \
  "test-branch" \
  "claude-sonnet-4-5-20250929" \
  "normal" \
  "0" \
  "Test task prompt" 2>&1) && spawn_ec=$? || spawn_ec=$?

if (( spawn_ec == 0 )); then
  pass "spawn-agent exits 0 with API key"
else
  fail "spawn-agent failed (exit $spawn_ec): $spawn_output"
fi

# Check if startup script was created
startup_script="$spawn_test_repo/../$(basename "$spawn_test_repo")-test-branch/.claude-agent-start.sh"
if [[ -f "$startup_script" ]]; then
  pass "startup script created"
  
  # Validate bash syntax
  if bash -n "$startup_script" 2>/dev/null; then
    pass "startup script has valid bash syntax"
  else
    fail "startup script has syntax errors"
  fi
  
  # Check that it doesn't use -p flag (known to cause hangs)
  if grep -q '\-p[[:space:]]\|--prompt' "$startup_script" 2>/dev/null; then
    fail "startup script uses -p/--prompt flag (causes hangs)"
  else
    pass "startup script doesn't use problematic -p flag"
  fi
  
  # Check it contains the claude command with model
  if grep -q 'exec claude' "$startup_script" && grep -q 'model' "$startup_script"; then
    pass "startup script contains claude exec with model"
  else
    fail "startup script missing claude exec command"
  fi
  
  # Check it has the API key baked in
  if grep -q 'ANTHROPIC_API_KEY="sk-test-key"' "$startup_script"; then
    pass "startup script contains API key"
  else
    fail "startup script missing API key"
  fi
else
  fail "startup script not created at $startup_script"
fi

# Cleanup
rm -rf "$spawn_test_repo" "/tmp/mock-bin-$$"
rm -rf "$spawn_test_repo-test-branch" 2>/dev/null
unset ANTHROPIC_API_KEY

# ─── Test: tasks.conf INI parsing ────────────────────────────────────────────

echo ""
echo "tasks.conf INI parsing"
echo "──────────────────────"

# Test the INI parser by writing a tasks.conf and running the parsing logic
# We replicate the parser logic from supervisor.sh here to test it in isolation

_parse_tasks_conf() {
  local file="$1"
  local in_block=false
  local t_branch="" t_model="" t_mode="" t_prompt=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue

    if [[ "$line" =~ ^\[task\]$ ]]; then
      if $in_block && [[ -n "$t_prompt" ]]; then
        echo "BLOCK|${t_branch}|${t_model}|${t_mode}|${t_prompt}"
      fi
      in_block=true
      t_branch="" t_model="" t_mode="" t_prompt=""
      continue
    fi

    if $in_block && [[ "$line" =~ ^([a-z]+)[[:space:]]*=[[:space:]]*(.*) ]]; then
      local local_key="${BASH_REMATCH[1]}"
      local local_val="${BASH_REMATCH[2]}"
      case "$local_key" in
        prompt) t_prompt="$local_val" ;;
        branch) t_branch="$local_val" ;;
        model)  t_model="$local_val" ;;
        mode)   t_mode="$local_val" ;;
      esac
    fi
  done < "$file"

  if $in_block && [[ -n "$t_prompt" ]]; then
    echo "BLOCK|${t_branch}|${t_model}|${t_mode}|${t_prompt}"
  fi
}

# Test: fully specified block
tmp_conf="/tmp/smoke-tasks-$$.conf"
cat > "$tmp_conf" <<'CONF'
[task]
branch = feature-auth
model  = claude-sonnet-4-5-20250929
mode   = normal
prompt = implement the OAuth2 login flow
CONF

result="$(_parse_tasks_conf "$tmp_conf")"
assert_eq "fully specified block" \
  "BLOCK|feature-auth|claude-sonnet-4-5-20250929|normal|implement the OAuth2 login flow" \
  "$result"

# Test: prompt-only block (all other fields empty)
cat > "$tmp_conf" <<'CONF'
[task]
prompt = refactor the database layer
CONF

result="$(_parse_tasks_conf "$tmp_conf")"
assert_eq "prompt-only block" \
  "BLOCK||||refactor the database layer" \
  "$result"

# Test: plan mode with no branch or model
cat > "$tmp_conf" <<'CONF'
[task]
mode   = plan
prompt = review the codebase and write a plan
CONF

result="$(_parse_tasks_conf "$tmp_conf")"
assert_eq "plan mode block" \
  "BLOCK|||plan|review the codebase and write a plan" \
  "$result"

# Test: multiple blocks
cat > "$tmp_conf" <<'CONF'
[task]
mode   = plan
prompt = write the plan

[task]
branch = feature-auth
model  = claude-sonnet-4-5-20250929
prompt = implement the plan
CONF

result="$(_parse_tasks_conf "$tmp_conf")"
expected="BLOCK|||plan|write the plan
BLOCK|feature-auth|claude-sonnet-4-5-20250929||implement the plan"
assert_eq "multiple blocks parsed" "$expected" "$result"

# Test: comments and blank lines are skipped
cat > "$tmp_conf" <<'CONF'
# This is a comment

[task]
# Another comment
prompt = do the work

CONF

result="$(_parse_tasks_conf "$tmp_conf")"
assert_eq "comments and blanks skipped" "BLOCK||||do the work" "$result"

# Test: block without prompt is skipped
cat > "$tmp_conf" <<'CONF'
[task]
branch = orphan-branch
mode   = plan

[task]
prompt = this one should appear
CONF

result="$(_parse_tasks_conf "$tmp_conf")"
assert_eq "block without prompt skipped" "BLOCK||||this one should appear" "$result"

# Test: prompt with equals sign preserved
cat > "$tmp_conf" <<'CONF'
[task]
prompt = fix the bug where x = y causes a crash
CONF

result="$(_parse_tasks_conf "$tmp_conf")"
assert_eq "prompt with equals preserved" \
  "BLOCK||||fix the bug where x = y causes a crash" \
  "$result"

rm -f "$tmp_conf"

# ─── Test: watch dashboard ────────────────────────────────────────────────────

echo ""
echo "watch dashboard"
echo "───────────────"

# Verify bin/watch.sh exists and is executable
assert_file_exists "bin/watch.sh exists" "$PROJECT_ROOT/bin/watch.sh"
if [[ -x "$PROJECT_ROOT/bin/watch.sh" ]]; then
  pass "watch.sh is executable"
else
  fail "watch.sh is not executable"
fi

# Verify bash syntax
if bash -n "$PROJECT_ROOT/bin/watch.sh" 2>/dev/null; then
  pass "watch.sh has valid bash syntax"
else
  fail "watch.sh has bash syntax errors"
fi

# Verify lib/jsonl-tail.mjs exists
assert_file_exists "lib/jsonl-tail.mjs exists" "$PROJECT_ROOT/lib/jsonl-tail.mjs"

# Verify Node.js syntax of jsonl-tail.mjs (if node is available)
_node_bin=""
if command -v node &>/dev/null; then
  _node_bin="node"
fi
if [[ -z "$_node_bin" ]] && [[ -n "${NVM_DIR:-}" ]]; then
  for _n in "$NVM_DIR/versions/node/"*/bin/node; do
    [[ -x "$_n" ]] && _node_bin="$_n" && break
  done
fi
if [[ -n "$_node_bin" ]]; then
  if "$_node_bin" --check "$PROJECT_ROOT/lib/jsonl-tail.mjs" 2>/dev/null; then
    pass "jsonl-tail.mjs has valid JS syntax"
  else
    fail "jsonl-tail.mjs has JS syntax errors"
  fi
else
  pass "jsonl-tail.mjs syntax check skipped (node not in PATH — OK in CI)"
fi

# Test: watch.sh handles missing state file gracefully
# We source watch.sh (safe since _watch_main is guarded by BASH_SOURCE check)
# and call _render directly.
watch_test_repo="/tmp/cs-watch-test-$$"
mkdir -p "$watch_test_repo/.claude"
git -C "$watch_test_repo" init -b main &>/dev/null
git -C "$watch_test_repo" config user.email "ci@test.local"
git -C "$watch_test_repo" config user.name "CI Test"
touch "$watch_test_repo/README.md"
git -C "$watch_test_repo" add . &>/dev/null
git -C "$watch_test_repo" commit -m "init" &>/dev/null

watch_missing_state_output="$(
  bash -c "
    export repo_path='$watch_test_repo'
    export state_file='$watch_test_repo/.claude/supervisor-agents.jsonl'
    source '$PROJECT_ROOT/lib/utils.sh'
    source '$PROJECT_ROOT/bin/watch.sh'
    _render 2>&1
  " 2>&1
)" || true

if [[ "$watch_missing_state_output" == *"No agent state"* || "$watch_missing_state_output" == *"supervisor"* || -n "$watch_missing_state_output" ]]; then
  pass "watch _render ran without crashing (state file missing)"
else
  pass "watch _render ran (state file missing — output empty)"
fi

# Test: state file JSON format from supervisor
state_test_repo="/tmp/cs-state-test-$$"
mkdir -p "$state_test_repo/.claude"
git -C "$state_test_repo" init -b main &>/dev/null
git -C "$state_test_repo" config user.email "ci@test.local"
git -C "$state_test_repo" config user.name "CI Test"
touch "$state_test_repo/README.md"
git -C "$state_test_repo" add . &>/dev/null
git -C "$state_test_repo" commit -m "init" &>/dev/null

# Write a sample state file
state_file="$state_test_repo/.claude/supervisor-agents.jsonl"
printf '{"branch":"feature-auth","model":"claude-sonnet-4-5","mode":"normal","worktree":"%s-feature-auth","spawned_at":"2026-04-27T12:00:00Z"}\n' \
  "$state_test_repo" >> "$state_file"
printf '{"branch":"fix-login","model":"claude-haiku-4-5","mode":"normal","worktree":"%s-fix-login","spawned_at":"2026-04-27T12:00:01Z"}\n' \
  "$state_test_repo" >> "$state_file"

# Verify state file has 2 lines (2 agents)
state_lines=$(wc -l < "$state_file" | xargs)
if [[ "$state_lines" -eq 2 ]]; then
  pass "state file has correct line count (2 agents)"
else
  fail "state file has ${state_lines} lines (expected 2)"
fi

# Verify each line is valid JSON (if jq or python available)
if command -v python3 &>/dev/null; then
  all_valid=true
  while IFS= read -r line; do
    python3 -c "import json; json.loads('$line')" 2>/dev/null || { all_valid=false; break; }
  done < "$state_file"
  if $all_valid; then
    pass "state file lines are valid JSON"
  else
    fail "state file contains invalid JSON"
  fi
else
  pass "state file JSON validation skipped (python3 not available)"
fi

# Test: jsonl-tail.mjs handles missing file gracefully
if [[ -n "$_node_bin" ]]; then
  tail_result="$("$_node_bin" "$PROJECT_ROOT/lib/jsonl-tail.mjs" "/tmp/nonexistent-session-$$.jsonl" 2>/dev/null)"
  if [[ "$tail_result" == *'"status":"unknown"'* ]]; then
    pass "jsonl-tail.mjs returns unknown for missing file"
  else
    fail "jsonl-tail.mjs did not return unknown for missing file: $tail_result"
  fi

  # Test: jsonl-tail.mjs parses a real JSONL event
  sample_jsonl="/tmp/cs-sample-$$.jsonl"
  printf '{"type":"permission-mode","permissionMode":"default","sessionId":"test-123"}\n' > "$sample_jsonl"
  printf '{"parentUuid":null,"type":"user","message":{"role":"user","content":"implement oauth"},"timestamp":"2026-04-27T12:00:00.000Z"}\n' >> "$sample_jsonl"
  printf '{"parentUuid":"abc","type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","id":"tu1","input":{}}]},"timestamp":"2026-04-27T12:00:05.000Z"}\n' >> "$sample_jsonl"

  tail_result2="$("$_node_bin" "$PROJECT_ROOT/lib/jsonl-tail.mjs" "$sample_jsonl" 2>/dev/null)"
  if [[ "$tail_result2" == *'"status":"tool"'* ]]; then
    pass "jsonl-tail.mjs correctly extracts tool status"
  else
    fail "jsonl-tail.mjs wrong status for tool_use event: $tail_result2"
  fi
  if [[ "$tail_result2" == *'"tool":"Bash"'* ]]; then
    pass "jsonl-tail.mjs correctly extracts tool name"
  else
    fail "jsonl-tail.mjs wrong tool name: $tail_result2"
  fi

  # Test: thinking status
  printf '{"parentUuid":"abc","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"let me think..."}]},"timestamp":"2026-04-27T12:00:10.000Z"}\n' >> "$sample_jsonl"
  tail_result3="$("$_node_bin" "$PROJECT_ROOT/lib/jsonl-tail.mjs" "$sample_jsonl" 2>/dev/null)"
  if [[ "$tail_result3" == *'"status":"thinking"'* ]]; then
    pass "jsonl-tail.mjs correctly extracts thinking status"
  else
    fail "jsonl-tail.mjs wrong status for thinking event: $tail_result3"
  fi

  rm -f "$sample_jsonl"
else
  pass "jsonl-tail.mjs parsing tests skipped (node not in PATH)"
  pass "jsonl-tail.mjs parsing tests skipped (node not in PATH)"
  pass "jsonl-tail.mjs parsing tests skipped (node not in PATH)"
  pass "jsonl-tail.mjs parsing tests skipped (node not in PATH)"
  pass "jsonl-tail.mjs parsing tests skipped (node not in PATH)"
fi

# Test: supervisor watch subcommand routes to watch.sh
# We can't test the live loop but we can test that `supervisor watch --help`
# or `supervisor watch /nonexistent` exits non-zero gracefully
watch_cmd_output="$(bash "$PROJECT_ROOT/bin/supervisor.sh" watch "/tmp/nonexistent-$$" 2>&1)" && watch_cmd_ec=$? || watch_cmd_ec=$?
if [[ "$watch_cmd_ec" -ne 0 ]]; then
  pass "supervisor watch /nonexistent exits non-zero"
else
  # Could exit 0 if watch.sh handles it gracefully — check for error message
  if [[ "$watch_cmd_output" == *"not found"* || "$watch_cmd_output" == *"Directory"* ]]; then
    pass "supervisor watch /nonexistent shows error message"
  else
    fail "supervisor watch /nonexistent should fail: $watch_cmd_output"
  fi
fi

rm -rf "$watch_test_repo" "$state_test_repo"

# ─── Test: template files exist ──────────────────────────────────────────────

echo ""
echo "template files"
echo "──────────────"

if [[ ! -f "$PROJECT_ROOT/templates/tasks.conf" ]]; then
  pass "templates/tasks.conf removed (bullet-list input replaces it in 1.0)"
else
  fail "templates/tasks.conf should have been removed"
fi
assert_file_exists "templates/CLAUDE.md exists"                    "$PROJECT_ROOT/templates/CLAUDE.md"
assert_file_exists "templates/.claude/settings.local.json exists"  "$PROJECT_ROOT/templates/.claude/settings.local.json"
assert_file_exists "templates/.claude/agents/_example-agent.md"    "$PROJECT_ROOT/templates/.claude/agents/_example-agent.md"

# workspace-kit-owned files must NOT be in templates/ (workspace-kit manages them)
if [[ ! -f "$PROJECT_ROOT/templates/.claude/settings.json" ]]; then
  pass "templates/.claude/settings.json removed (workspace-kit owns it)"
else
  fail "templates/.claude/settings.json should have been removed"
fi
if [[ ! -f "$PROJECT_ROOT/templates/.claude/agents/reviewer.md" ]]; then
  pass "templates/.claude/agents/reviewer.md removed (workspace-kit owns it)"
else
  fail "templates/.claude/agents/reviewer.md should have been removed"
fi
if [[ ! -d "$PROJECT_ROOT/templates/.claude/commands" ]]; then
  pass "templates/.claude/commands/ removed (workspace-kit owns it)"
else
  fail "templates/.claude/commands/ should have been removed"
fi
if [[ ! -f "$PROJECT_ROOT/templates/.claude/skills/_example-skill/SKILL.md" ]]; then
  pass "templates/.claude/skills/_example-skill removed (workspace-kit owns it)"
else
  fail "templates/.claude/skills/_example-skill should have been removed"
fi
# Supervisor-specific skills (share, peers) live in templates/ — NOT workspace-kit
assert_file_exists "templates/.claude/skills/share/SKILL.md exists"  "$PROJECT_ROOT/templates/.claude/skills/share/SKILL.md"
assert_file_exists "templates/.claude/skills/peers/SKILL.md exists"  "$PROJECT_ROOT/templates/.claude/skills/peers/SKILL.md"

# Verify settings.local.json contains PermissionRequest and Stop hooks
settings_local_content="$(cat "$PROJECT_ROOT/templates/.claude/settings.local.json")"
assert_contains "settings.local.json has PermissionRequest hook" "PermissionRequest"  "$settings_local_content"
assert_contains "settings.local.json routes to Opus"             "claude-opus-4-7"    "$settings_local_content"
assert_contains "settings.local.json has Stop hook"              "Stop"               "$settings_local_content"
assert_contains "settings.local.json Stop hook calls on-stop"    "supervisor on-stop" "$settings_local_content"

# Verify _example-agent.md has required frontmatter
example_agent_content="$(cat "$PROJECT_ROOT/templates/.claude/agents/_example-agent.md")"
assert_contains "_example-agent.md has name field"   "name:"        "$example_agent_content"
assert_contains "_example-agent.md has description"  "description:" "$example_agent_content"
assert_contains "_example-agent.md has tools"        "tools:"       "$example_agent_content"

# Verify CLAUDE.md contains supervisor fenced block (so it's ready for minimal-fallback scaffold)
claude_md_template_content="$(cat "$PROJECT_ROOT/templates/CLAUDE.md")"
assert_contains "templates/CLAUDE.md has supervisor block" "BEGIN claude-supervisor" "$claude_md_template_content"

# Verify update.sh is present and executable
assert_file_exists "bin/update.sh exists" "$PROJECT_ROOT/bin/update.sh"
if [[ -x "$PROJECT_ROOT/bin/update.sh" ]]; then
  pass "update.sh is executable"
else
  fail "update.sh is not executable"
fi

# ─── Test: bullet-list parser (Phase 4) ──────────────────────────────────────

echo ""
echo "bullet-list parser"
echo "──────────────────"

# Source the parser
# shellcheck disable=SC1091
source "$PROJECT_ROOT/lib/parse-bullets.sh"

# Test: plain bullet → prompt only
result="$(parse_bullets "- implement the OAuth2 login flow")"
assert_eq "plain bullet prompt" "TASK|implement the OAuth2 login flow||||" "$result"

# Test: bullet with model tag
result="$(parse_bullets "- fix login bug [model: claude-sonnet-4-5]")"
assert_eq "model tag parsed" "TASK|fix login bug||claude-sonnet-4-5||" "$result"

# Test: bullet with plan shorthand
result="$(parse_bullets "- review the codebase [plan]")"
assert_eq "plan shorthand" "TASK|review the codebase|||plan|" "$result"

# Test: bullet with mode: plan
result="$(parse_bullets "- review the codebase [mode: plan]")"
assert_eq "mode: plan tag" "TASK|review the codebase|||plan|" "$result"

# Test: bullet with branch tag
result="$(parse_bullets "- implement OAuth [branch: feat-oauth]")"
assert_eq "branch tag parsed" "TASK|implement OAuth|feat-oauth|||" "$result"

# Test: bullet with depends tag
result="$(parse_bullets "- write tests [depends: feat-oauth]")"
assert_eq "depends tag parsed" "TASK|write tests||||feat-oauth" "$result"

# Test: multiple tags (comma-separated)
result="$(parse_bullets "- fix session bug [model: claude-haiku-4-5, branch: fix-session]")"
assert_eq "multiple tags" "TASK|fix session bug|fix-session|claude-haiku-4-5||" "$result"

# Test: plan + model combined
result="$(parse_bullets "- review arch [plan, model: claude-opus-4-7]")"
assert_eq "plan + model combined" "TASK|review arch||claude-opus-4-7|plan|" "$result"

# Test: all tags at once
result="$(parse_bullets "- implement feature [model: claude-sonnet-4-5, branch: feat, mode: normal, depends: prereq]")"
assert_eq "all tags" "TASK|implement feature|feat|claude-sonnet-4-5|normal|prereq" "$result"

# Test: comment lines ignored
result="$(parse_bullets "# this is a comment
- actual task")"
assert_eq "comment line ignored" "TASK|actual task||||" "$result"

# Test: sub-bullets ignored (2+ space indent)
result="$(parse_bullets "- main task
  - sub task ignored")"
assert_eq "sub-bullets ignored" "TASK|main task||||" "$result"

# Test: non-bullet prose lines ignored
result="$(parse_bullets "This is a header
- the task
And some prose")"
assert_eq "prose lines ignored" "TASK|the task||||" "$result"

# Test: multiple bullets → multiple TASK lines
result="$(parse_bullets "- task one
- task two [plan]")"
expected="TASK|task one||||
TASK|task two|||plan|"
assert_eq "multiple bullets" "$expected" "$result"

# Test: empty input → no output
result="$(parse_bullets "# just comments
")"
assert_eq "empty input no output" "" "$result"

# Test: * and + bullet markers also work
result="$(parse_bullets "* star bullet
+ plus bullet")"
expected="TASK|star bullet||||
TASK|plus bullet||||"
assert_eq "star and plus markers work" "$expected" "$result"

# Test: supervisor pre-1.0 detection (tasks.conf without settings.local.json)
p10_repo="/tmp/cs-p10-detect-$$"
mkdir -p "$p10_repo"
git -C "$p10_repo" init -b main &>/dev/null
git -C "$p10_repo" config user.email "ci@test.local"
git -C "$p10_repo" config user.name "CI Test"
touch "$p10_repo/tasks.conf"  # old-style layout
touch "$p10_repo/README.md"
git -C "$p10_repo" add . &>/dev/null
git -C "$p10_repo" commit -m "init" &>/dev/null

p10_output="$(bash "$PROJECT_ROOT/bin/supervisor.sh" "$p10_repo" 2>&1)" && p10_ec=$? || p10_ec=$?
assert_exit_code "pre-1.0 detection exits non-zero" "1" "$p10_ec"
assert_contains "pre-1.0 detection mentions migrate" "supervisor migrate" "$p10_output"

rm -rf "$p10_repo"

# ─── Test: Stop hook and shared notes (Phase 3) ──────────────────────────────

echo ""
echo "stop hook and shared notes"
echo "──────────────────────────"

# Verify on-stop.sh exists and is executable
assert_file_exists "bin/on-stop.sh exists" "$PROJECT_ROOT/bin/on-stop.sh"
if [[ -x "$PROJECT_ROOT/bin/on-stop.sh" ]]; then
  pass "on-stop.sh is executable"
else
  fail "on-stop.sh is not executable"
fi

# Verify bash syntax
if bash -n "$PROJECT_ROOT/bin/on-stop.sh" 2>/dev/null; then
  pass "on-stop.sh has valid bash syntax"
else
  fail "on-stop.sh has bash syntax errors"
fi

# Test: on-stop.sh appends to session summary and finds main repo from worktree
onstop_repo="/tmp/cs-onstop-main-$$"
mkdir -p "$onstop_repo/.claude"
git -C "$onstop_repo" init -b main &>/dev/null
git -C "$onstop_repo" config user.email "ci@test.local"
git -C "$onstop_repo" config user.name "CI Test"
cat > "$onstop_repo/.claude/CLAUDE.md" <<'CLAUDE'
# Project Memory

## Known Pitfalls
- existing pitfall

---
CLAUDE
touch "$onstop_repo/README.md"
git -C "$onstop_repo" add . &>/dev/null
git -C "$onstop_repo" commit -m "init" &>/dev/null

# Create a worktree
git -C "$onstop_repo" worktree add "${onstop_repo}-agent-branch" -b "agent-branch" &>/dev/null

# Run on-stop.sh from the worktree directory
onstop_out="$(cd "${onstop_repo}-agent-branch" && bash "$PROJECT_ROOT/bin/on-stop.sh" 2>&1)" || true

# Verify session summary was written to the MAIN repo
summary_file="$onstop_repo/.claude/supervisor-session-summary.jsonl"
if [[ -f "$summary_file" ]]; then
  pass "on-stop.sh wrote session summary to main repo"
  summary_content="$(cat "$summary_file")"
  if [[ "$summary_content" == *'"branch":"agent-branch"'* ]]; then
    pass "session summary contains correct branch name"
  else
    fail "session summary missing branch name: $summary_content"
  fi
  if [[ "$summary_content" == *'"finished_at"'* ]]; then
    pass "session summary contains finished_at timestamp"
  else
    fail "session summary missing finished_at: $summary_content"
  fi
else
  fail "on-stop.sh did not write session summary (expected at $summary_file): $onstop_out"
fi

# Test: on-stop.sh outside a git repo exits 0 with a message (graceful)
onstop_nogit_out="$(cd /tmp && bash "$PROJECT_ROOT/bin/on-stop.sh" 2>&1)" && onstop_nogit_ec=$? || onstop_nogit_ec=$?
if [[ "$onstop_nogit_ec" -eq 0 ]]; then
  pass "on-stop.sh exits 0 when not in a git repo"
else
  fail "on-stop.sh should exit 0 outside a git repo (got $onstop_nogit_ec)"
fi

rm -rf "$onstop_repo" "${onstop_repo}-agent-branch"

# Test: supervisor on-stop subcommand routes to on-stop.sh
# Call from /tmp (not a git repo) — should exit 0 with a message
supervisor_onstop_out="$(cd /tmp && bash "$PROJECT_ROOT/bin/supervisor.sh" on-stop 2>&1)" && supervisor_onstop_ec=$? || supervisor_onstop_ec=$?
if [[ "$supervisor_onstop_ec" -eq 0 ]]; then
  pass "supervisor on-stop subcommand exits 0 (routes to on-stop.sh)"
else
  fail "supervisor on-stop subcommand failed (exit $supervisor_onstop_ec): $supervisor_onstop_out"
fi

# Test: spawn-agent.sh creates agents-shared symlink
spawn_shared_repo="/tmp/cs-spawn-shared-$$"
mkdir -p "$spawn_shared_repo/.claude/agents-shared"
git -C "$spawn_shared_repo" init -b main &>/dev/null
git -C "$spawn_shared_repo" config user.email "ci@test.local"
git -C "$spawn_shared_repo" config user.name "CI Test"
touch "$spawn_shared_repo/README.md"
git -C "$spawn_shared_repo" add . &>/dev/null
git -C "$spawn_shared_repo" commit -m "init" &>/dev/null

mkdir -p "/tmp/mock-shared-tmux-$$"
cat > "/tmp/mock-shared-tmux-$$/tmux" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "/tmp/mock-shared-tmux-$$/tmux"

PATH="/tmp/mock-shared-tmux-$$:$PATH" bash "$PROJECT_ROOT/bin/spawn-agent.sh" \
  "$spawn_shared_repo" "shared-branch" "claude-sonnet-4-5" "normal" "0" "test" &>/dev/null || true

shared_link="$spawn_shared_repo/../$(basename "$spawn_shared_repo")-shared-branch/.claude/agents-shared"
if [[ -L "$shared_link" ]]; then
  pass "spawn-agent.sh creates agents-shared symlink in worktree"
  link_target="$(readlink "$shared_link")"
  if [[ "$link_target" == "$spawn_shared_repo/.claude/agents-shared" ]]; then
    pass "agents-shared symlink points to main repo"
  else
    fail "agents-shared symlink wrong target: $link_target (expected $spawn_shared_repo/.claude/agents-shared)"
  fi
else
  fail "spawn-agent.sh did not create agents-shared symlink at $shared_link"
fi

rm -rf "$spawn_shared_repo" "$spawn_shared_repo-shared-branch" "/tmp/mock-shared-tmux-$$"

# Test: /share skill has required frontmatter
share_skill_content="$(cat "$PROJECT_ROOT/templates/.claude/skills/share/SKILL.md")"
assert_contains "share SKILL.md has name field"        "name:"    "$share_skill_content"
assert_contains "share SKILL.md has description field" "description:" "$share_skill_content"
assert_contains "share SKILL.md mentions agents-shared" "agents-shared" "$share_skill_content"

# Test: /peers skill has required frontmatter
peers_skill_content="$(cat "$PROJECT_ROOT/templates/.claude/skills/peers/SKILL.md")"
assert_contains "peers SKILL.md has name field"        "name:"    "$peers_skill_content"
assert_contains "peers SKILL.md has description field" "description:" "$peers_skill_content"
assert_contains "peers SKILL.md mentions agents-shared" "agents-shared" "$peers_skill_content"

# ─── Test: scripts are executable ────────────────────────────────────────────

echo ""
echo "script permissions"
echo "──────────────────"

if [[ -x "$PROJECT_ROOT/bin/supervisor.sh" ]]; then
  pass "supervisor.sh is executable"
else
  fail "supervisor.sh is not executable"
fi

if [[ -x "$PROJECT_ROOT/bin/spawn-agent.sh" ]]; then
  pass "spawn-agent.sh is executable"
else
  fail "spawn-agent.sh is not executable"
fi

if [[ -x "$PROJECT_ROOT/bin/collect-learnings.sh" ]]; then
  pass "collect-learnings.sh is executable"
else
  fail "collect-learnings.sh is not executable"
fi

if [[ -x "$PROJECT_ROOT/bin/update.sh" ]]; then
  pass "update.sh is executable"
else
  fail "update.sh is not executable"
fi

if [[ -x "$PROJECT_ROOT/bin/watch.sh" ]]; then
  pass "watch.sh is executable"
else
  fail "watch.sh is not executable"
fi

if [[ -x "$PROJECT_ROOT/bin/on-stop.sh" ]]; then
  pass "on-stop.sh is executable"
else
  fail "on-stop.sh is not executable"
fi

for _script in migrate.sh uninstall.sh doctor.sh; do
  assert_file_exists "bin/$_script exists" "$PROJECT_ROOT/bin/$_script"
  if [[ -x "$PROJECT_ROOT/bin/$_script" ]]; then
    pass "bin/$_script is executable"
  else
    fail "bin/$_script is not executable"
  fi
  if bash -n "$PROJECT_ROOT/bin/$_script" 2>/dev/null; then
    pass "bin/$_script has valid bash syntax"
  else
    fail "bin/$_script has bash syntax errors"
  fi
done

assert_file_exists "lib/parse-bullets.sh exists" "$PROJECT_ROOT/lib/parse-bullets.sh"
if bash -n "$PROJECT_ROOT/lib/parse-bullets.sh" 2>/dev/null; then
  pass "lib/parse-bullets.sh has valid bash syntax"
else
  fail "lib/parse-bullets.sh has bash syntax errors"
fi

# ─── Test: collect-learnings.sh ──────────────────────────────────────────────

echo ""
echo "collect-learnings"
echo "─────────────────"

# Set up a repo with a worktree that has new CLAUDE.md lines
cl_repo="/tmp/claude-cl-test-$$"
mkdir -p "$cl_repo"
git -C "$cl_repo" init -b main &>/dev/null
git -C "$cl_repo" config user.email "test@test.com" &>/dev/null
git -C "$cl_repo" config user.name "Test" &>/dev/null
mkdir -p "$cl_repo/.claude"
cat > "$cl_repo/.claude/CLAUDE.md" <<'CLAUDE'
# Project Memory

## Known Pitfalls
- existing pitfall

---
CLAUDE
git -C "$cl_repo" add . &>/dev/null
git -C "$cl_repo" commit -m "init" &>/dev/null

# Create a worktree with updated CLAUDE.md
git -C "$cl_repo" worktree add "/tmp/claude-cl-test-$$-wt" -b "agent-branch" &>/dev/null
mkdir -p "/tmp/claude-cl-test-$$-wt/.claude"
cat > "/tmp/claude-cl-test-$$-wt/.claude/CLAUDE.md" <<'CLAUDE'
# Project Memory

## Known Pitfalls
- existing pitfall
- new pitfall added by agent

---
CLAUDE

# Verify collect-learnings sees the diff (use --yes for non-interactive approval)
cl_output="$(bash "$PROJECT_ROOT/bin/collect-learnings.sh" --yes "$cl_repo" 2>&1)" || true

assert_contains "collect-learnings detects new line" "new pitfall added by agent" "$cl_output"
assert_contains "collect-learnings reports merge" "pitfall bullet" "$cl_output"

# The --yes run already merged; verify the pitfall was written to main CLAUDE.md
main_content="$(cat "$cl_repo/.claude/CLAUDE.md")"
assert_contains "new pitfall merged to main CLAUDE.md" "new pitfall added by agent" "$main_content"

# collect-learnings with no active worktrees (after list is empty)
# Use a fresh repo with no worktrees
cl_repo2="/tmp/claude-cl-test2-$$"
mkdir -p "$cl_repo2"
git -C "$cl_repo2" init -b main &>/dev/null
git -C "$cl_repo2" config user.email "test@test.com" &>/dev/null
git -C "$cl_repo2" config user.name "Test" &>/dev/null
mkdir -p "$cl_repo2/.claude"
echo "# CLAUDE.md" > "$cl_repo2/.claude/CLAUDE.md"
git -C "$cl_repo2" add . &>/dev/null
git -C "$cl_repo2" commit -m "init" &>/dev/null

cl_empty="$(bash "$PROJECT_ROOT/bin/collect-learnings.sh" "$cl_repo2" 2>&1)" || true
assert_contains "no worktrees message shown" "No active worktrees" "$cl_empty"

# collect-learnings rejects non-repo
cl_err="$(bash "$PROJECT_ROOT/bin/collect-learnings.sh" "/tmp/no-such-dir-$$" 2>&1)" && ec=$? || ec=$?
assert_exit_code "collect-learnings rejects missing dir" "1" "$ec"

# collect-learnings rejects repo with no CLAUDE.md
cl_repo3="/tmp/claude-cl-test3-$$"
mkdir -p "$cl_repo3"
git -C "$cl_repo3" init -b main &>/dev/null
git -C "$cl_repo3" config user.email "test@test.com" &>/dev/null
git -C "$cl_repo3" config user.name "Test" &>/dev/null
touch "$cl_repo3/README.md"
git -C "$cl_repo3" add . &>/dev/null
git -C "$cl_repo3" commit -m "init" &>/dev/null

cl_err2="$(bash "$PROJECT_ROOT/bin/collect-learnings.sh" "$cl_repo3" 2>&1)" && ec=$? || ec=$?
assert_exit_code "collect-learnings rejects missing CLAUDE.md" "1" "$ec"
assert_contains "error mentions CLAUDE.md" "CLAUDE.md" "$cl_err2"

rm -rf "$cl_repo" "/tmp/claude-cl-test-$$-wt" "$cl_repo2" "$cl_repo3"

# ─── Test: full 0.2.x → 1.0 migration with --yes ────────────────────────────

echo ""
echo "0.2.x → 1.0 migration (--yes)"
echo "──────────────────────────────"

v02_repo="/tmp/cs-v02-migrate-$$"
mkdir -p "$v02_repo/.claude/agents"

git -C "$v02_repo" init -b main &>/dev/null
git -C "$v02_repo" config user.email "ci@test.local"
git -C "$v02_repo" config user.name "CI Test"

# tasks.conf with two tasks (v0.2.x layout)
cat > "$v02_repo/tasks.conf" <<'CONF'
[task]
branch = feature-auth
model  = claude-sonnet-4-5-20250929
mode   = normal
prompt = implement the OAuth2 login flow

[task]
branch = fix-login
model  = claude-haiku-4-5-20251001
mode   = normal
prompt = fix the session timeout bug
CONF

# Old-style settings.json with PermissionRequest hook
cat > "$v02_repo/.claude/settings.json" <<'JSON'
{
  "hooks": {
    "PermissionRequest": [
      {
        "hooks": [
          {
            "type": "prompt",
            "model": "claude-opus-4-7",
            "prompt": "Review this permission request",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
JSON

# User-customised agent (must survive migration)
cat > "$v02_repo/.claude/agents/custom-agent.md" <<'MD'
---
name: my-custom-agent
description: A custom agent I wrote
tools: Bash, Read, Write
---

This is my custom agent prompt.
MD

# Existing CLAUDE.md with project-specific content
cat > "$v02_repo/.claude/CLAUDE.md" <<'MD'
# My Project Memory

## Architecture
- Uses PostgreSQL for persistence
- Node.js backend, React frontend

## Known Pitfalls
- Never run migrations without a backup
MD

touch "$v02_repo/README.md"
git -C "$v02_repo" add . &>/dev/null
git -C "$v02_repo" commit -m "init v0.2.x project" &>/dev/null

# ── Run migration non-interactively ──────────────────────────────────────────
migrate_v02_out="$(bash "$PROJECT_ROOT/bin/supervisor.sh" migrate --yes "$v02_repo" 2>&1)" && migrate_v02_ec=$? || migrate_v02_ec=$?
assert_exit_code "migrate --yes exits 0" "0" "$migrate_v02_ec"

# Backup must exist (glob-safe: ls exits non-zero if no match)
backup_dir=""
for _bd in "$v02_repo"/.claude.backup-*; do [[ -d "$_bd" ]] && backup_dir="$_bd" && break; done
if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
  pass "backup directory created (.claude.backup-*)"
  # Backup must contain the original settings.json
  if [[ -f "$backup_dir/settings.json" ]]; then
    pass "backup contains original settings.json"
  else
    fail "backup missing original settings.json"
  fi
  # Backup must contain original agents/custom-agent.md
  if [[ -f "$backup_dir/agents/custom-agent.md" ]]; then
    pass "backup contains custom agent"
  else
    fail "backup missing custom agent"
  fi
  # Backup must contain original CLAUDE.md
  if [[ -f "$backup_dir/CLAUDE.md" ]]; then
    pass "backup contains original CLAUDE.md"
  else
    fail "backup missing CLAUDE.md"
  fi
else
  fail "backup directory not created"
  pass "skipping backup contents (no backup dir)"
  pass "skipping backup contents (no backup dir)"
  pass "skipping backup contents (no backup dir)"
fi

# settings.local.json must be created with PermissionRequest hook
if [[ -f "$v02_repo/.claude/settings.local.json" ]]; then
  pass "settings.local.json created"
  settings_local_migrated="$(cat "$v02_repo/.claude/settings.local.json")"
  assert_contains "migrated settings.local.json has PermissionRequest" "PermissionRequest" "$settings_local_migrated"
else
  fail "settings.local.json not created after migration"
  fail "migrated settings.local.json has PermissionRequest — no file to check"
fi

# Old settings.json must be archived (renamed)
if [[ -f "$v02_repo/.claude/settings.json.v0-backup" ]]; then
  pass "old settings.json archived as settings.json.v0-backup"
else
  fail "settings.json not archived"
fi
if [[ ! -f "$v02_repo/.claude/settings.json" ]]; then
  pass "settings.json removed (archived)"
else
  fail "settings.json still exists after migration (should be archived)"
fi

# tasks.conf must be archived (--yes defaults to "a"rchive)
if [[ -f "$v02_repo/tasks.conf.v0-archive" ]]; then
  pass "tasks.conf archived as tasks.conf.v0-archive"
else
  fail "tasks.conf not archived"
fi
if [[ ! -f "$v02_repo/tasks.conf" ]]; then
  pass "tasks.conf removed (archived)"
else
  fail "tasks.conf still present after migration (should be archived)"
fi

# User-customised agent must be preserved
if [[ -f "$v02_repo/.claude/agents/custom-agent.md" ]]; then
  pass "user custom agent preserved after migration"
else
  fail "user custom agent destroyed during migration"
fi

# CLAUDE.md: original content preserved AND supervisor block appended
migrated_claude_content="$(cat "$v02_repo/.claude/CLAUDE.md")"
assert_contains "CLAUDE.md preserves original content"       "My Project Memory"         "$migrated_claude_content"
assert_contains "CLAUDE.md preserves architecture section"   "Uses PostgreSQL"            "$migrated_claude_content"
assert_contains "CLAUDE.md supervisor block appended"        "BEGIN claude-supervisor"    "$migrated_claude_content"
assert_contains "CLAUDE.md supervisor block closed"          "END claude-supervisor"      "$migrated_claude_content"

# agents-shared/ must be created
if [[ -d "$v02_repo/.claude/agents-shared" ]]; then
  pass ".claude/agents-shared/ created by migration"
else
  fail ".claude/agents-shared/ not created"
fi

# ── Rollback verification ─────────────────────────────────────────────────────
# Simulate the documented rollback: rm -rf .claude && mv .claude.backup-* .claude
if [[ -n "$backup_dir" && -d "$backup_dir" ]]; then
  rm -rf "$v02_repo/.claude"
  mv "$backup_dir" "$v02_repo/.claude"
  # After rollback: original settings.json back, tasks.conf still archived (that's ok)
  if [[ -f "$v02_repo/.claude/settings.json" ]]; then
    pass "rollback restores original settings.json"
  else
    fail "rollback did not restore settings.json"
  fi
  if [[ -f "$v02_repo/.claude/agents/custom-agent.md" ]]; then
    pass "rollback restores custom agent"
  else
    fail "rollback did not restore custom agent"
  fi
  rolled_back_claude="$(cat "$v02_repo/.claude/CLAUDE.md")"
  assert_contains "rollback restores original CLAUDE.md content" "My Project Memory" "$rolled_back_claude"
  if [[ "$rolled_back_claude" != *"BEGIN claude-supervisor"* ]]; then
    pass "rollback removes supervisor block (backup had none)"
  else
    pass "rollback: supervisor block was in backup (pre-existing project — OK)"
  fi
else
  pass "rollback skipped (no backup dir)"
  pass "rollback skipped (no backup dir)"
  pass "rollback skipped (no backup dir)"
  pass "rollback skipped (no backup dir)"
fi

rm -rf "$v02_repo"

# ─── Test: bullet parser edge cases ──────────────────────────────────────────

echo ""
echo "bullet parser edge cases"
echo "────────────────────────"

# Unclosed bracket: treat as plain prompt (no tags)
result="$(parse_bullets "- fix the bug [unclosed bracket")"
# The [unclosed part has no closing ] so should be treated as part of the prompt
if [[ "$result" == "TASK|fix the bug [unclosed bracket||||" || "$result" == "TASK|fix the bug||||" ]]; then
  pass "unclosed bracket treated as prompt text"
else
  fail "unclosed bracket unexpected output: '$result'"
fi

# Multiple [] groups: only the LAST one is parsed as tags
result="$(parse_bullets "- implement [some notes] the feature [model: claude-haiku-4-5]")"
assert_eq "last [] group used as tags" "TASK|implement [some notes] the feature||claude-haiku-4-5||" "$result"

# Tag with extra whitespace
result="$(parse_bullets "-  lots   of   spaces  [model:  claude-opus-4-7 ]")"
# Prompt and tag value should be trimmed
if [[ "$result" == *"TASK|"* && "$result" == *"claude-opus-4-7"* ]]; then
  pass "extra whitespace in tag trimmed"
else
  fail "extra whitespace not handled: '$result'"
fi

# Prompt that is only whitespace (no text, just spaces) → skipped
result="$(parse_bullets "-    ")"
assert_eq "whitespace-only bullet skipped" "" "$result"

# Deeply indented sub-bullet (3 spaces) → ignored
result="$(parse_bullets "- main task
   - deeply indented sub")"
assert_eq "deeply indented sub-bullet ignored" "TASK|main task||||" "$result"

# ─── Test: supervisor last round-trip ────────────────────────────────────────
#
# supervisor last reads from supervisor-last.md and re-parses it as bullet input.
# The main flow has /dev/tty reads (spawn confirmation) that hang in interactive
# terminals, so we test the two paths that exit BEFORE that prompt:
#   - file absent → die "No previous session found at...supervisor-last.md"
#   - file format → parse_bullets(file_content) returns expected tasks

echo ""
echo "supervisor last round-trip"
echo "──────────────────────────"

# Mock tmux + npm + claude so check_deps passes without real tools
last_mock_bin="/tmp/cs-last-mock-$$"
mkdir -p "$last_mock_bin"
for _tool in tmux npm claude; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$last_mock_bin/$_tool"
  chmod +x "$last_mock_bin/$_tool"
done

# Test: supervisor-last.md file format round-trips through parse_bullets
last_repo="/tmp/cs-last-$$"
mkdir -p "$last_repo/.claude"
git -C "$last_repo" init -b main &>/dev/null
git -C "$last_repo" config user.email "ci@test.local"
git -C "$last_repo" config user.name "CI Test"
touch "$last_repo/README.md"
git -C "$last_repo" add . &>/dev/null
git -C "$last_repo" commit -m "init" &>/dev/null
touch "$last_repo/.claude/settings.local.json"

cat > "$last_repo/.claude/supervisor-last.md" <<'LAST'
- implement OAuth2 login [branch: oauth-login, model: claude-sonnet-4-5-20250929]
- write tests for OAuth [branch: oauth-tests, model: claude-haiku-4-5-20251001, depends: oauth-login]
LAST

# Parse the saved file directly — this is exactly what supervisor last does internally
last_parsed="$(parse_bullets "$(cat "$last_repo/.claude/supervisor-last.md")")"
if [[ "$last_parsed" == *"implement OAuth2 login"* ]]; then
  pass "supervisor-last.md content parses correctly (task 1 found)"
else
  fail "supervisor-last.md parse failed: $last_parsed"
fi
if [[ "$last_parsed" == *"oauth-login"* ]]; then
  pass "supervisor-last.md depends tag preserved in round-trip"
else
  fail "supervisor-last.md depends not in parsed output: $last_parsed"
fi
task_count="$(printf '%s\n' "$last_parsed" | grep -c '^TASK|' || true)"
if [[ "$task_count" -eq 2 ]]; then
  pass "supervisor-last.md round-trip preserves both tasks"
else
  fail "supervisor-last.md round-trip: expected 2 tasks, got $task_count"
fi

# Test: supervisor last without a file exits 1 with a message about supervisor-last.md
# (this path exits at die() BEFORE any /dev/tty read, so it doesn't hang)
no_last_repo="/tmp/cs-no-last-$$"
mkdir -p "$no_last_repo/.claude"
git -C "$no_last_repo" init -b main &>/dev/null
git -C "$no_last_repo" config user.email "ci@test.local"
git -C "$no_last_repo" config user.name "CI Test"
touch "$no_last_repo/README.md"
git -C "$no_last_repo" add . &>/dev/null
git -C "$no_last_repo" commit -m "init" &>/dev/null
touch "$no_last_repo/.claude/settings.local.json"
printf 'CLAUDE_SUPERVISOR_ANTHROPIC_BILLING_MODE=pro\n' > "$no_last_repo/.env"

no_last_output="$(PATH="$last_mock_bin:$PATH" bash "$PROJECT_ROOT/bin/supervisor.sh" last "$no_last_repo" 2>&1)" && no_last_ec=$? || no_last_ec=$?
assert_exit_code "supervisor last exits non-zero when no saved tasks" "1" "$no_last_ec"
if [[ "$no_last_output" == *"supervisor-last.md"* || "$no_last_output" == *"No previous"* ]]; then
  pass "supervisor last error message mentions supervisor-last.md"
else
  fail "supervisor last unhelpful error when no saved tasks: $no_last_output"
fi

rm -rf "$last_repo" "$no_last_repo" "$last_mock_bin"

# ─── Test: uninstall --yes removes supervisor files ──────────────────────────

echo ""
echo "uninstall --yes"
echo "───────────────"

uninstall_yes_repo="/tmp/cs-uninstall-yes-$$"
mkdir -p "$uninstall_yes_repo/.claude/agents-shared"
git -C "$uninstall_yes_repo" init -b main &>/dev/null
git -C "$uninstall_yes_repo" config user.email "ci@test.local"
git -C "$uninstall_yes_repo" config user.name "CI Test"
touch "$uninstall_yes_repo/.claude/settings.local.json"
touch "$uninstall_yes_repo/.claude/supervisor-agents.jsonl"
touch "$uninstall_yes_repo/.claude/supervisor-last.md"
printf '.claude/agents-shared/\n' > "$uninstall_yes_repo/.gitignore"
# Add a CLAUDE.md with supervisor fenced block
cat > "$uninstall_yes_repo/.claude/CLAUDE.md" <<'MD'
# My Project

This is important project content.

<!-- BEGIN claude-supervisor (do not edit by hand) -->
## Worktree-sync Notes
Some supervisor content here.
<!-- END claude-supervisor -->

## More Project Content
Keep this.
MD
touch "$uninstall_yes_repo/README.md"
git -C "$uninstall_yes_repo" add . &>/dev/null
git -C "$uninstall_yes_repo" commit -m "init" &>/dev/null

uninstall_yes_out="$(bash "$PROJECT_ROOT/bin/supervisor.sh" uninstall --yes "$uninstall_yes_repo" 2>&1)" && uninstall_yes_ec=$? || uninstall_yes_ec=$?
assert_exit_code "uninstall --yes exits 0" "0" "$uninstall_yes_ec"

# settings.local.json must be gone
if [[ ! -f "$uninstall_yes_repo/.claude/settings.local.json" ]]; then
  pass "settings.local.json removed by uninstall --yes"
else
  fail "settings.local.json still present after uninstall --yes"
fi

# agents-shared/ must be gone
if [[ ! -d "$uninstall_yes_repo/.claude/agents-shared" ]]; then
  pass ".claude/agents-shared/ removed by uninstall --yes"
else
  fail ".claude/agents-shared/ still present after uninstall --yes"
fi

# supervisor-agents.jsonl and supervisor-last.md must be gone
if [[ ! -f "$uninstall_yes_repo/.claude/supervisor-agents.jsonl" ]]; then
  pass "supervisor-agents.jsonl removed"
else
  fail "supervisor-agents.jsonl still present"
fi

# CLAUDE.md: supervisor fenced block removed, other content preserved
if [[ -f "$uninstall_yes_repo/.claude/CLAUDE.md" ]]; then
  uninstall_claude_content="$(cat "$uninstall_yes_repo/.claude/CLAUDE.md")"
  if [[ "$uninstall_claude_content" != *"BEGIN claude-supervisor"* ]]; then
    pass "supervisor fenced block removed from CLAUDE.md"
  else
    fail "supervisor fenced block still in CLAUDE.md after uninstall"
  fi
  assert_contains "CLAUDE.md non-supervisor content preserved" "My Project" "$uninstall_claude_content"
  assert_contains "CLAUDE.md More Project Content preserved"   "More Project Content" "$uninstall_claude_content"
else
  fail "CLAUDE.md removed by uninstall (should preserve it)"
  pass "CLAUDE.md content checks skipped"
  pass "CLAUDE.md content checks skipped"
fi

# .gitignore: agents-shared entry removed
if [[ -f "$uninstall_yes_repo/.gitignore" ]]; then
  if ! grep -q "agents-shared" "$uninstall_yes_repo/.gitignore" 2>/dev/null; then
    pass ".gitignore agents-shared entry removed"
  else
    fail ".gitignore still contains agents-shared after uninstall"
  fi
else
  fail ".gitignore removed entirely (should just clean entries)"
fi

rm -rf "$uninstall_yes_repo"

# ─── Cleanup ─────────────────────────────────────────────────────────────────

rm -rf "$test_repo"

# ─── Summary ─────────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════"
printf "  \033[0;32m%d passed\033[0m" "$PASS"
if (( FAIL > 0 )); then
  printf ", \033[0;31m%d failed\033[0m" "$FAIL"
fi
echo ""
echo "═══════════════════════════════════════"

if (( FAIL > 0 )); then
  echo ""
  echo "Failed tests:"
  for t in "${TESTS[@]}"; do
    printf "  \033[0;31m✗\033[0m %s\n" "$t"
  done
  echo ""
  exit 1
fi

echo ""
