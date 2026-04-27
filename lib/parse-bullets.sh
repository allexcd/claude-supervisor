#!/usr/bin/env bash
# lib/parse-bullets.sh — Parse markdown bullet-list task input
#
# Source this file to use parse_bullets().
#
# Usage:
#   source lib/parse-bullets.sh
#   while IFS='|' read -r _ prompt branch model mode depends; do
#     ...
#   done < <(parse_bullets "$input_text")
#
# Output format: one "TASK|prompt|branch|model|mode|depends" line per valid bullet.
#
# Bullet grammar:
#   - <text> [model: id, branch: name, plan, mode: plan, depends: branch]
#   Lines starting with # are comments (ignored).
#   Indented sub-bullets (2+ spaces before - * +) are ignored.
#   Non-bullet lines (prose, headers) are ignored.
#   Multiple [...] groups on a line: only the last one is parsed as tags.

[[ -n "${_PARSE_BULLETS_LOADED:-}" ]] && return
_PARSE_BULLETS_LOADED=1

parse_bullets() {
  local input="$1"
  local line text prompt branch model mode depends tags_line tag

  while IFS= read -r line; do
    # Skip comment lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    # Skip indented sub-bullets (at least 2 spaces before the bullet marker)
    [[ "$line" =~ ^[[:space:]][[:space:]][-*+] ]] && continue
    # Must be a top-level bullet: optional leading space, then - * or +
    [[ "$line" =~ ^[[:space:]]*[-*+][[:space:]]+(.*) ]] || continue

    text="${BASH_REMATCH[1]}"
    prompt="" branch="" model="" mode="" depends="" tags_line=""

    # Extract the LAST [...] group as tags; everything before it is the prompt
    if [[ "$text" =~ (.*)\[([^\]]+)\][[:space:]]*$ ]]; then
      prompt="${BASH_REMATCH[1]}"
      tags_line="${BASH_REMATCH[2]}"
    else
      prompt="$text"
    fi

    # Trim whitespace from prompt
    prompt="${prompt## }"; prompt="${prompt%% }"
    [[ -z "$prompt" ]] && continue

    # Parse comma-separated tags
    if [[ -n "$tags_line" ]]; then
      while IFS= read -r tag; do
        # Trim whitespace
        tag="${tag#"${tag%%[![:space:]]*}"}"; tag="${tag%"${tag##*[![:space:]]}"}"
        [[ -z "$tag" ]] && continue
        if [[ "$tag" == "plan" ]]; then
          mode="plan"
        elif [[ "$tag" =~ ^mode:[[:space:]]*(.+) ]]; then
          mode="${BASH_REMATCH[1]%% }"
        elif [[ "$tag" =~ ^model:[[:space:]]*(.+) ]]; then
          model="${BASH_REMATCH[1]%% }"
        elif [[ "$tag" =~ ^branch:[[:space:]]*(.+) ]]; then
          branch="${BASH_REMATCH[1]%% }"
        elif [[ "$tag" =~ ^depends:[[:space:]]*(.+) ]]; then
          depends="${BASH_REMATCH[1]%% }"
        fi
      done < <(printf '%s\n' "$tags_line" | tr ',' '\n')
    fi

    printf 'TASK|%s|%s|%s|%s|%s\n' "$prompt" "$branch" "$model" "$mode" "$depends"
  done <<< "$input"
}
