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
assert_file_exists ".claude/agents/reviewer.md created" "$test_repo/.claude/agents/reviewer.md"
assert_file_exists ".claude/agents/debugger.md created" "$test_repo/.claude/agents/debugger.md"
assert_file_exists ".claude/agents/test-writer.md created" "$test_repo/.claude/agents/test-writer.md"
assert_file_exists ".claude/commands/ created" "$test_repo/.claude/commands"
assert_file_exists ".claude/commands/techdebt.md created" "$test_repo/.claude/commands/techdebt.md"
assert_file_exists ".claude/commands/explain.md created" "$test_repo/.claude/commands/explain.md"
assert_file_exists ".claude/commands/diagram.md created" "$test_repo/.claude/commands/diagram.md"
assert_file_exists ".claude/commands/learn.md created" "$test_repo/.claude/commands/learn.md"
assert_contains "init message mentions tasks.conf" "tasks.conf" "$output"

# Verify tasks.conf is added to .gitignore
assert_file_exists ".gitignore created" "$test_repo/.gitignore"
if grep -qx "tasks.conf" "$test_repo/.gitignore" 2>/dev/null; then
  pass ".gitignore contains tasks.conf"
else
  fail ".gitignore missing tasks.conf entry"
fi

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

# Verify .gitignore was not duplicated on re-run
gitignore_count=$(grep -cx "tasks.conf" "$test_repo/.gitignore")
if (( gitignore_count == 1 )); then
  pass ".gitignore tasks.conf entry not duplicated on re-run"
else
  fail ".gitignore has ${gitignore_count} 'tasks.conf' entries (expected 1)"
fi

# Test: scaffolding appends to existing .gitignore
test_repo_gi="/tmp/claude-supervisor-test-gitignore-$$"
mkdir -p "$test_repo_gi"
git -C "$test_repo_gi" init -b main &>/dev/null
echo "node_modules/" > "$test_repo_gi/.gitignore"
touch "$test_repo_gi/README.md"
git -C "$test_repo_gi" add . &>/dev/null
git -C "$test_repo_gi" commit -m "init" &>/dev/null

bash "$PROJECT_ROOT/bin/supervisor.sh" "$test_repo_gi" &>/dev/null || true

if grep -q "node_modules/" "$test_repo_gi/.gitignore" && grep -qx "tasks.conf" "$test_repo_gi/.gitignore"; then
  pass ".gitignore appended to (preserves existing entries)"
else
  fail ".gitignore existing content lost or tasks.conf not added"
fi
rm -rf "$test_repo_gi"

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
assert_file_exists "templates/.claude/agents/reviewer.md exists" "$PROJECT_ROOT/templates/.claude/agents/reviewer.md"
assert_file_exists "templates/.claude/agents/debugger.md exists" "$PROJECT_ROOT/templates/.claude/agents/debugger.md"
assert_file_exists "templates/.claude/agents/test-writer.md exists" "$PROJECT_ROOT/templates/.claude/agents/test-writer.md"
assert_file_exists "templates/.claude/agents/_example-agent.md exists" "$PROJECT_ROOT/templates/.claude/agents/_example-agent.md"
assert_file_exists "templates/.claude/commands/techdebt.md exists" "$PROJECT_ROOT/templates/.claude/commands/techdebt.md"
assert_file_exists "templates/.claude/commands/explain.md exists" "$PROJECT_ROOT/templates/.claude/commands/explain.md"
assert_file_exists "templates/.claude/commands/diagram.md exists" "$PROJECT_ROOT/templates/.claude/commands/diagram.md"
assert_file_exists "templates/.claude/commands/learn.md exists" "$PROJECT_ROOT/templates/.claude/commands/learn.md"

# Verify tasks.conf uses INI block format
tasks_conf_content="$(cat "$PROJECT_ROOT/templates/tasks.conf")"
assert_contains "tasks.conf has [task] headers" "[task]" "$tasks_conf_content"
assert_contains "tasks.conf has prompt field" "prompt =" "$tasks_conf_content"

# Verify settings.json contains PermissionRequest hook
settings_content="$(cat "$PROJECT_ROOT/templates/.claude/settings.json")"
assert_contains "settings.json has PermissionRequest hook" "PermissionRequest" "$settings_content"
assert_contains "settings.json routes to Opus" "claude-opus-4-6" "$settings_content"

# Verify techdebt.md (command) has required frontmatter
techdebt_content="$(cat "$PROJECT_ROOT/templates/.claude/commands/techdebt.md")"
assert_contains "techdebt.md has description" "description:" "$techdebt_content"
assert_contains "techdebt.md has allowed-tools" "allowed-tools:" "$techdebt_content"

# Verify reviewer.md (subagent) has required frontmatter
reviewer_content="$(cat "$PROJECT_ROOT/templates/.claude/agents/reviewer.md")"
assert_contains "reviewer.md has name field" "name: reviewer" "$reviewer_content"
assert_contains "reviewer.md has description" "description:" "$reviewer_content"
assert_contains "reviewer.md has tools" "tools:" "$reviewer_content"

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
