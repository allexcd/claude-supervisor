# Contributing

## Prerequisites

Same as the README: git, tmux, Node.js/npm, Claude Code CLI.

## Running tests

```bash
bash tests/smoke.sh
```

All 114 tests run without an API key, tmux, or Claude installed.

## Making changes

1. Fork the repo and create a branch
2. Make your changes
3. Run `bash tests/smoke.sh` — all tests must pass
4. Open a PR against `main`

CI runs automatically on every PR. The PR must pass before merging.

## Releasing (maintainers only)

```bash
npm version patch     # or minor / major — bumps VERSION, commits, tags
git push && git push --tags   # triggers the publish workflow on GitHub Actions
```
