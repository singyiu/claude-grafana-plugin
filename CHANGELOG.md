# Changelog

All notable changes to `claude-grafana` are documented here. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.4] - 2026-05-08

### Fixed
- **PromQL semantics**: Claude Code emits each session as its own counter series (session_id is a label). Most session-scoped series have only ONE sample (the cumulative final value at session end), so `sum(increase(metric[window]))` returns 0 even when sessions exist. Switched all INTENT_TABLE queries from `increase()` to `last_over_time()` (sums each session's final cumulative value) for token / cost / lines / decisions / active-time, and to `count(count_over_time(...))` for one-shot event counters (sessions / commits / PRs). Status check probe similarly uses `count(count_over_time(claude_code_session_count_total[1h]))` to detect any session activity in the last hour, which is staleness-aware (Prometheus drops series after 5min of no samples by default).
- **Status check window**: widened from 5min to 1h. The 5min default missed sessions that ended even slightly earlier.
- **`active_time` metric name**: was `claude_code_active_time_total_seconds_total` in the intent template — Mimir actually exposes it as `claude_code_active_time_seconds_total`. Corrected.

## [0.2.3] - 2026-05-08

### Fixed
- **Loki query filter**: all log queries (status check, intent table in `grafana_query.py`, `claude-tools` dashboard panels, docs/skill examples) used `{service_namespace="claude-code"}`. But Claude Code's resource attributes set `service.name=claude-code` and `service.namespace=local` — so the namespace filter never matched real telemetry. Switched everything to `{service_name="claude-code"}`. Affected: `skills/grafana-status/SKILL.md`, `skills/grafana-query/SKILL.md`, `skills/grafana-dashboard/SKILL.md`, `scripts/grafana_query.py` (5 INTENT_TABLE entries), `dashboards/claude-tools.json` (2 logs panels), `docs/METRICS.md` (5 LogQL recipes).

## [0.2.2] - 2026-05-08

### Fixed
- **HIGH: counter metric temporality.** Claude Code's OTel SDK emits counter metrics (`claude_code.session.count`, `claude_code.cost.usage`, `claude_code.token.usage`, `claude_code.active_time.total`, etc.) with **delta** temporality, but Grafana Cloud's OTLP gateway forwards to Mimir, which only accepts **cumulative**. Every counter was rejected with HTTP 400 `invalid temporality and type combination for metric ...` and dropped, so no Claude Code metrics ever landed in the stack. Two fixes applied (belt + suspenders):
  1. `04-enable-claude-otel.sh` now sets `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative` in `~/.claude/settings.json`, telling the SDK to emit cumulative directly.
  2. The Alloy pipeline gained an `otelcol.processor.deltatocumulative` stage between the receiver and the batch processor, converting any delta-temporality metrics that still slip through.
- Same fix applied to `alloy/claude-merge-snippet.alloy` for users who chose `--mode=skip`.

### Migration
Existing v0.2.1 users: re-run `/grafana-setup` (or just steps 3 + 4 directly). Both are idempotent; they'll add the new env var and rewrite the fenced Alloy section to include the new processor.

## [0.2.1] - 2026-05-08

Six bug fixes from live end-to-end testing of v0.2.0 against a real Grafana Cloud stack.

### Fixed
- **Architecture**: Drop the `import.file "claude"` module approach. Alloy modules can only contain `declare` and `import` blocks, so the previous design was rejected at runtime with `only declare and import blocks are allowed in a module, got logging`. Replaced with a single marker-fenced section (`// >>> claude-grafana managed BEGIN ... END`) inserted directly into the main config. Re-runs do an in-place replace between the markers (idempotent). Old v0.1.x `import.file` lines and orphan `/etc/alloy/claude.alloy` files are auto-detected and migrated.
- **Env file perms**: `/etc/alloy/claude.env` was written `0600 root:root`, but `alloy.service` runs as user `alloy` and could not source it. The OTLP receiver therefore failed to bind on `:4317`. Now writes `0640` and `chgrp` to the alloy service group (auto-detected from `systemctl show -p User alloy`).
- **Path detection**: `alloy_config_path()` and `alloy_config_detect.sh` confused "directory perms-blocked" with "file missing" because `[ -f /etc/alloy/config.alloy ]` returns false when cyngn can't traverse `/etc/alloy/`. Both now fall back to `sudo -n test -f` and `sudo -n cat` when the dir exists but is unreadable. New `perms-blocked` classification surfaces a clear error if sudo isn't primed.
- **`--mode` flag honored**: Previously, when the classifier returned `missing` (often a false negative), the script auto-picked `replace` and ignored an explicit `--mode=merge`. The flag is now respected for every classification.
- **Loki UID picker**: Grafana Cloud stacks have three Loki datasources (`-logs`, `-alert-state-history`, `-usage-insights`). The auto-discovery returned the first one (typically alert-state-history), which broke log queries. Now ranks candidates: prefer `-logs` suffix, deprioritize alert-state-history and usage-insights. Same fix applied to the Prometheus picker (deprioritize `-usage` and `-cardinality`).
- **Validation logic**: `alloy fmt --test` exits non-zero when reformatting *would* be needed (whitespace), not when syntax is invalid. The script's two-step validation (`--test` then plain) cascaded to a parse-error message even for valid configs in unusual indentation. Now uses plain `alloy fmt > /dev/null` only, with `sudo` when the file lives in a perms-blocked dir.

### Added
- **Sudo preflight in step 3**: Aborts early with `sudo -v` instructions if `sudo -n` is not primed, instead of silently failing later.
- **Legacy migration**: Detects v0.1.x installs (orphan `claude.alloy` module file, leftover `import.file "claude"` line, inline `otelcol.receiver.otlp "claude_code"` block) and rewrites them to the new fenced-section format.

### Changed
- `alloy/claude.alloy.tmpl` is now an *inline snippet* (no top-level `logging` block), wrapped in markers. Used as the source of truth for both the merge and replace paths.
- `--mode=module-only` removed (no module file anymore).

### Tests
- Pytest grew from 47 to 49 cases; new tests cover the Loki picker for the Grafana Cloud 3-datasource layout and the self-hosted single-datasource fallback.
- Bats grew with three classifier cases: marker-fenced detection, legacy `import.file` detection, legacy inline-receiver detection.

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
