#!/usr/bin/env bash
# bin/release-tag.sh — Tag and push after the release PR is merged (step 2 of 2)
#
# Usage: npm run release:tag
#
# Triggers the publish.yml workflow which runs tests, publishes to npm,
# and creates a GitHub Release automatically.

set -euo pipefail

git checkout main && git pull

version="$(node -p "require('./package.json').version")"
tag="v${version}"

if git tag | grep -qx "$tag"; then
  printf 'Tag %s already exists locally — delete it first if you want to re-tag.\n' "$tag" >&2
  exit 1
fi

git tag "$tag"
git push origin "$tag"

printf '\n'
printf 'Tag %s pushed.\n' "$tag"
printf 'GitHub Actions will now run tests, publish to npm, and create a GitHub Release.\n'
printf '\n'
