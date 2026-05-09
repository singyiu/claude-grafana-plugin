# Changelog

All notable changes to `claude-grafana` are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-05-08
### Changed (BREAKING for setup flow only)
- `.env` location moved from `<plugin-root>/.env` to `~/.config/claude-grafana/.env` (XDG-aware via `XDG_CONFIG_HOME`). The plugin cache directory gets garbage-collected on plugin updates, which would have wiped tokens. Legacy plugin-root `.env` is still read as a fallback during migration.
- `grafana-setup` skill rewritten as a Claude-driven procedural guide. Previously the SKILL.md auto-ran scripts via `!` bash injection — those scripts use `read` for prompts, but bash injection has no TTY, so all prompts returned empty and the wizard silently failed (typical symptom: step 3 errored with `.env missing`). The new flow has Claude collect values via `AskUserQuestion` and pass them to the scripts as env vars.
- `02-onboard-token.sh` is now non-interactive when called with `CLAUDE_GRAFANA_*` env vars set. Falls back to interactive prompts only when stdin is a TTY. Exits 64 (EX_USAGE) with a clear missing-vars list when run non-interactively without all values.
- `03-configure-alloy.sh` accepts `--mode merge|replace|skip` to skip the prompt. Required when classification is `has-other` and stdin is not a TTY.
- `uninstall.sh`: now preserves `~/.config/claude-grafana/` by default; pass `--purge-env` to also delete it.

### Fixed
- Step 3 of `/grafana-setup` no longer errors with `.env missing` when invoked from a Claude session, because the wizard no longer relies on TTY-based prompts and the `.env` is in a stable location.

## [0.1.2] - 2026-05-08
### Fixed
- `marketplace.json`: changed `"source": "."` to `"source": "./"` so Claude Code recognizes it as a filesystem source. Older form failed install with "This plugin uses a source type your Claude Code version does not support."
- Removed unsupported `$schema` and `owner.url` fields; added a `metadata` block per the working anthropic / financial-services / context-mode marketplace shape.

## [0.1.1] - 2026-05-08
### Fixed
- GitHub owner references in `plugin.json`, `marketplace.json`, `README.md`, and `CONTRIBUTING.md` now point at `singyiu/claude-grafana-plugin` (the actual repo location).

## [0.1.0] - 2026-05-08
### Added
- Initial public release.
- `grafana-setup` skill — guided onboarding wizard (Alloy detect/install, token onboarding, Alloy config merge/replace/skip, Claude Code OTel env injection, end-to-end validation).
- `grafana-query` skill — natural-language → PromQL/LogQL with mappings for all 8 native Claude Code metrics.
- `grafana-dashboard` skill — install baseline dashboard pack, AI-generate dashboards from intent, list, delete.
- `grafana-status` skill — four-check health probe.
- Three baseline dashboards: `claude-overview`, `claude-cost`, `claude-tools`.
- Alloy module template with OTLP receiver, batch processor, OTLP/HTTP exporter to Grafana Cloud over Basic auth.
- Uninstall script.
