#!/usr/bin/env bash
# Manual end-to-end smoke checklist for claude-grafana.
#
# This is documentation-as-code: each numbered block is a step you can run
# and verify by eye. There's no automated assertions because the test runs
# against a real Grafana Cloud stack and a real Claude Code install.
#
# Prerequisites:
#   - A Grafana Cloud free-tier (or paid) stack
#   - claude CLI installed
#   - bash, jq, curl, python3 in $PATH
#
# Run from the plugin root.

set -euo pipefail

SECTION() { printf '\n══════════════════════════════════════════════════════════\n%s\n══════════════════════════════════════════════════════════\n' "$1"; }

SECTION "1. Plugin loads and lists 4 skills"
echo "Run:"
echo "  cd $(pwd) && claude --plugin ."
echo
echo "Expected: 4 skills under claude-grafana:* —"
echo "  claude-grafana:grafana-setup"
echo "  claude-grafana:grafana-query"
echo "  claude-grafana:grafana-dashboard"
echo "  claude-grafana:grafana-status"

SECTION "2. /grafana-setup completes against a fresh stack"
echo "From a Claude Code session inside the plugin dir:"
echo "  /grafana-setup"
echo
echo "Expected: 5 steps PASS, dashboards installed, baseline URLs printed."
echo "Total time: ~5 minutes (dominated by waiting for first metric round-trip)."

SECTION "3. Telemetry round-trip ≥1 within 2 minutes"
echo "Run:"
echo "  /grafana-query \"session count last 10 minutes\""
echo
echo "Expected: a markdown table with non-zero session count."
echo "If empty, wait 60s and re-try (free-tier ingest can be slow on first event)."

SECTION "4. Logs round-trip"
echo "Run:"
echo "  /grafana-query \"recent prompts\""
echo
echo "Expected: a table of recent UserPromptSubmit events."

SECTION "5. Baseline dashboards visible"
echo "Open in browser:"
echo "  https://<your-stack>.grafana.net/dashboards"
echo "Filter to folder 'claude-grafana'. Expected 3 dashboards:"
echo "  - Claude Code — Overview"
echo "  - Claude Code — Cost"
echo "  - Claude Code — Tools"
echo "Each renders panels with live data (or 'no data' on a brand-new install — that's ok for the first 5min)."

SECTION "6. AI-generated dashboard works"
echo "Run:"
echo "  /grafana-dashboard generate \"tool error rate by tool name\""
echo
echo "Expected: Claude drafts a dashboard JSON, the script extracts/validates/pushes."
echo "Output line: ✓ generated dashboard → https://...."

SECTION "7. /grafana-status all green"
echo "Run:"
echo "  /grafana-status"
echo
echo "Expected: 4 lines, all prefixed ✓:"
echo "  ✓ alloy.service is active"
echo "  ✓ Claude Code telemetry env present"
echo "  ✓ Grafana Cloud receiving metrics (last 5min)"
echo "  ✓ Grafana Cloud receiving log events (last 5min)"

SECTION "8. Idempotency"
echo "Re-run /grafana-setup. Expected: no diff in main alloy config or settings.json."
echo "Verify:"
echo "  diff /etc/alloy/config.alloy /etc/alloy/config.alloy.pre-claude-grafana.bak  # should differ on the import line, that's it"
echo "  /grafana-dashboard list   # should still show exactly 3 dashboards (not 6)"

SECTION "9. Uninstall + re-status"
echo "Run:"
echo "  bash scripts/uninstall.sh"
echo "  /grafana-status"
echo
echo "Expected: status now reports ✗ on every check (or ? if .env still has the API token)."
echo "Re-run /grafana-setup to recover."

SECTION "Done"
echo "If every section passes, the plugin is ready for tag + release."
