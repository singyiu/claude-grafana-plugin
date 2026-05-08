# Contributing to claude-grafana

Thanks for considering a contribution. This document covers how to file issues, propose changes, and run the test suite.

## Filing issues

Use [GitHub Issues](https://github.com/singyiu/claude-grafana-plugin/issues). Include:

- Plugin version (`cat .claude-plugin/plugin.json | jq .version`)
- Claude Code version (`claude --version`)
- Alloy version (`alloy --version`)
- OS and arch (`uname -srm`)
- The exact command you ran and the full output
- For setup-flow issues, include the contents of `~/.claude/settings.json` (`env` block only) and `/etc/alloy/claude.alloy` if it exists. **Redact tokens.**

## Local development

```bash
git clone https://github.com/singyiu/claude-grafana-plugin
cd claude-grafana-plugin

# Install the plugin from the local checkout
claude --plugin .

# Run unit tests
bats tests/unit/*.bats
python3 -m pytest tests/unit -v
```

## Code style

- **Shell scripts**: bash, `set -euo pipefail`, [shellcheck](https://www.shellcheck.net/)-clean. Source `scripts/lib/common.sh` for logging and idempotent edits — don't reinvent.
- **Python**: 3.9+, stdlib only (no `requests`, no `pyyaml`). Type-annotate public functions. Format with `python3 -m black scripts/`.
- **Skills**: every `SKILL.md` MUST have a frontmatter `description` that's specific enough to trigger on natural language; vague descriptions get rejected.
- **Alloy**: every `.alloy` change must `alloy fmt` clean and pass `alloy run --config.file=... --check`.

## Pull request workflow

1. Fork and create a topic branch (`feat/...`, `fix/...`, `docs/...`).
2. Add or update tests for the change. We don't merge untested logic changes.
3. Run the full local check: `make check` (or `bats tests/unit/*.bats && python3 -m pytest tests/unit`).
4. Update `CHANGELOG.md` under `[Unreleased]`.
5. Open the PR. CI must be green.
6. A maintainer will squash-merge after review.

## Releases

Maintainers tag `vX.Y.Z` on `main` after updating `CHANGELOG.md` and bumping `.claude-plugin/plugin.json` version. The marketplace entry picks up the new tag automatically.

## Security

Token handling and disclosure policy live in [`docs/SECURITY.md`](docs/SECURITY.md).
