#!/usr/bin/env bash
# bin/release.sh — Bump version and open a release branch (step 1 of 2)
#
# Usage: npm run release -- [major|minor|patch]
#
# After this script runs:
#   1. Open a PR for the release branch and merge it
#   2. Run: npm run release:tag

set -euo pipefail

bump="${1:-patch}"

if [[ "$bump" != "major" && "$bump" != "minor" && "$bump" != "patch" ]]; then
  printf 'Usage: npm run release -- [major|minor|patch]\n' >&2
  exit 1
fi

# Bump version in package.json only (no git commit or tag yet)
npm version "$bump" --no-git-tag-version

version="$(node -p "require('./package.json').version")"
branch="chore/release-${version}"

# VERSION file is updated by the npm version lifecycle hook
# but since we used --no-git-tag-version it didn't run — update manually
printf '%s' "$version" > VERSION

git checkout -b "$branch"
git add package.json VERSION
git commit -m "chore: release ${version}"
git push -u origin "$branch"

printf '\n'
printf 'Release branch "%s" pushed.\n' "$branch"
printf 'Open a PR titled "chore: Release %s", merge it, then run:\n' "$version"
printf '\n'
printf '  npm run release:tag\n'
printf '\n'
