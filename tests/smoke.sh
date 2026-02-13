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

pass() { ((PASS++)); printf "  \033[0;32m✓\033[0m %s\n" "$1"; }
fail() { ((FAIL++)); printf "  \033[0;31m✗\033[0m %s\n" "$1"; TESTS+=("$1"); }

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

# ─── Test: auto-init (supervisor first run) ──────────────────────────────────

echo ""
echo "supervisor auto-init"
echo "────────────────────"

test_repo="/tmp/claude-supervisor-test-$$"
mkdir -p "$test_repo"
git -C "$test_repo" init -b main &>/dev/null
touch "$test_repo/README.md"
git -C "$test_repo" add . &>/dev/null
git -C "$test_repo" commit -m "init" &>/dev/null

# Run supervisor — should scaffold and exit 0
output="$(bash "$PROJECT_ROOT/bin/supervisor.sh" "$test_repo" 2>&1)" || true

assert_file_exists "tasks.conf created" "$test_repo/tasks.conf"
assert_file_exists ".claude/ created" "$test_repo/.claude"
assert_file_exists ".claude/CLAUDE.md created" "$test_repo/.claude/CLAUDE.md"
assert_file_exists ".claude/settings.json created" "$test_repo/.claude/settings.json"
assert_file_exists ".claude/agents/ created" "$test_repo/.claude/agents"
assert_file_exists ".claude/agents/techdebt.md created" "$test_repo/.claude/agents/techdebt.md"
assert_contains "init message mentions tasks.conf" "tasks.conf" "$output"

# Verify file contents are not empty
tasks_size=$(wc -c < "$test_repo/tasks.conf")
if (( tasks_size > 100 )); then
  pass "tasks.conf has content (${tasks_size} bytes)"
else
  fail "tasks.conf seems empty (${tasks_size} bytes)"
fi

claude_md_size=$(wc -c < "$test_repo/.claude/CLAUDE.md")
if (( claude_md_size > 100 )); then
  pass "CLAUDE.md has content (${claude_md_size} bytes)"
else
  fail "CLAUDE.md seems empty (${claude_md_size} bytes)"
fi

settings_size=$(wc -c < "$test_repo/.claude/settings.json")
if (( settings_size > 50 )); then
  pass "settings.json has content (${settings_size} bytes)"
else
  fail "settings.json seems empty (${settings_size} bytes)"
fi

# ─── Test: auto-init skips if .claude/ already exists ────────────────────────

echo ""
echo "auto-init idempotency"
echo "─────────────────────"

# Remove tasks.conf but keep .claude/ — re-run should NOT overwrite .claude/
rm "$test_repo/tasks.conf"
echo "custom content" > "$test_repo/.claude/CLAUDE.md"

output2="$(bash "$PROJECT_ROOT/bin/supervisor.sh" "$test_repo" 2>&1)" || true

custom_content="$(cat "$test_repo/.claude/CLAUDE.md")"
assert_eq ".claude/CLAUDE.md preserved when .claude/ exists" \
  "custom content" \
  "$custom_content"
assert_contains "warns about existing .claude/" ".claude/ directory already exists" "$output2"

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

# ─── Test: template files exist ──────────────────────────────────────────────

echo ""
echo "template files"
echo "──────────────"

assert_file_exists "templates/tasks.conf exists" "$PROJECT_ROOT/templates/tasks.conf"
assert_file_exists "templates/CLAUDE.md exists" "$PROJECT_ROOT/templates/CLAUDE.md"
assert_file_exists "templates/.claude/settings.json exists" "$PROJECT_ROOT/templates/.claude/settings.json"
assert_file_exists "templates/.claude/agents/techdebt.md exists" "$PROJECT_ROOT/templates/.claude/agents/techdebt.md"

# Verify tasks.conf uses INI block format
tasks_conf_content="$(cat "$PROJECT_ROOT/templates/tasks.conf")"
assert_contains "tasks.conf has [task] headers" "[task]" "$tasks_conf_content"
assert_contains "tasks.conf has prompt field" "prompt =" "$tasks_conf_content"

# Verify settings.json contains PermissionRequest hook
settings_content="$(cat "$PROJECT_ROOT/templates/.claude/settings.json")"
assert_contains "settings.json has PermissionRequest hook" "PermissionRequest" "$settings_content"
assert_contains "settings.json routes to Opus" "claude-opus-4-6" "$settings_content"

# Verify techdebt.md has required frontmatter
techdebt_content="$(cat "$PROJECT_ROOT/templates/.claude/agents/techdebt.md")"
assert_contains "techdebt.md has name field" "name: techdebt" "$techdebt_content"
assert_contains "techdebt.md has description" "description:" "$techdebt_content"
assert_contains "techdebt.md has tools" "tools:" "$techdebt_content"

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
