# Changelog

All notable changes to `claude-grafana` are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
