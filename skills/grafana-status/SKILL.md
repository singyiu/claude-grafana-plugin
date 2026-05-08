---
name: grafana-status
description: Use when the user wants to check whether Claude Code observability is working, verify the Alloy collector is running, confirm telemetry is flowing to Grafana Cloud, or diagnose a broken setup. Triggers on "is observability working", "check grafana setup", "is claude telemetry on", "is alloy running", "check claude monitoring", "grafana health check".
---

# /grafana-status

Quick four-check health probe for the claude-grafana setup. Returns a green/red line per check with exact remediation commands on failure.

## When to use

- User wants a fast confidence check after running `/grafana-setup`.
- User has just experienced a missing-data symptom and needs to know which step is broken.
- Periodic verification (e.g. "did anything break?").

## Prerequisites

`.env` should exist (i.e. `/grafana-setup` has run at least once). If it doesn't, this skill prints a single line directing the user to run setup.

## Process

Run all four checks in parallel via shell:

!`bash -c '
set +e
ROOT="${CLAUDE_PLUGIN_ROOT:-${CLAUDE_SKILL_DIR}/../..}"
[ -f "$ROOT/.env" ] || { echo "ERROR: .env missing — run /grafana-setup."; exit 1; }
. "$ROOT/.env"

# Check 1 — Alloy systemd unit active
if command -v systemctl >/dev/null 2>&1; then
  if systemctl is-active --quiet alloy 2>/dev/null; then
    echo "✓ alloy.service is active"
  else
    echo "✗ alloy.service NOT active — fix: sudo systemctl restart alloy"
  fi
else
  if pgrep -x alloy >/dev/null 2>&1; then
    echo "✓ alloy process running"
  else
    echo "✗ alloy process not running — fix: start it (brew services start alloy or run manually)"
  fi
fi

# Check 2 — Claude Code OTel env in settings.json
SETTINGS="$HOME/.claude/settings.json"
if [ -f "$SETTINGS" ] && grep -q "CLAUDE_CODE_ENABLE_TELEMETRY" "$SETTINGS"; then
  echo "✓ Claude Code telemetry env present in settings.json"
else
  echo "✗ Claude Code telemetry env MISSING — fix: re-run /grafana-setup"
fi

# Check 3 — recent metric in Grafana Cloud Prometheus (last 5min)
if [ -n "$GRAFANA_CLOUD_API_TOKEN" ] && [ -n "$GRAFANA_CLOUD_STACK_URL" ] && [ -n "$GRAFANA_CLOUD_PROM_DATASOURCE_UID" ]; then
  resp=$(curl -fsS -H "Authorization: Bearer $GRAFANA_CLOUD_API_TOKEN" \
    --data-urlencode "query=sum(increase(claude_code_session_count_total[5m]))" \
    -G "${GRAFANA_CLOUD_STACK_URL%/}/api/datasources/proxy/uid/$GRAFANA_CLOUD_PROM_DATASOURCE_UID/api/v1/query" 2>/dev/null)
  if echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get(\"data\",{}).get(\"result\") else 1)" 2>/dev/null; then
    echo "✓ Grafana Cloud receiving metrics (last 5min)"
  else
    echo "✗ No recent metrics in Grafana Cloud — fix: start a claude session, wait 60s, recheck. Or: sudo journalctl -u alloy -n 50"
  fi
else
  echo "? Cannot verify metrics — Prometheus UID unknown. Re-run /grafana-setup step 5."
fi

# Check 4 — recent log event (last 5min)
if [ -n "$GRAFANA_CLOUD_LOKI_DATASOURCE_UID" ]; then
  end_ns=$(($(date +%s) * 1000000000))
  start_ns=$((end_ns - 300000000000))
  resp=$(curl -fsS -H "Authorization: Bearer $GRAFANA_CLOUD_API_TOKEN" \
    --data-urlencode "query={service_namespace=\"claude-code\"}" \
    --data-urlencode "start=$start_ns" \
    --data-urlencode "end=$end_ns" \
    --data-urlencode "limit=1" \
    -G "${GRAFANA_CLOUD_STACK_URL%/}/api/datasources/proxy/uid/$GRAFANA_CLOUD_LOKI_DATASOURCE_UID/loki/api/v1/query_range" 2>/dev/null)
  if echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get(\"data\",{}).get(\"result\") else 1)" 2>/dev/null; then
    echo "✓ Grafana Cloud receiving log events (last 5min)"
  else
    echo "✗ No recent log events in Grafana Cloud — fix: confirm OTEL_LOGS_EXPORTER=otlp in settings.json"
  fi
else
  echo "? Cannot verify logs — Loki UID unknown. Re-run /grafana-setup step 5."
fi
'`

## Interpreting the output

- **All four ✓** — the pipeline is healthy. Telemetry is flowing.
- **Check 1 ✗** — Alloy isn't running. Almost always sudo systemctl restart alloy. If it crashes on restart, look at `journalctl -u alloy -n 50` for the parse/auth error and re-run `/grafana-setup`.
- **Check 2 ✗** — `~/.claude/settings.json` doesn't have the OTel env. Re-run `/grafana-setup` (it's safe to re-run).
- **Check 3 ✗** — Telemetry isn't reaching Grafana Cloud. Most likely causes: (a) no Claude session has run yet, (b) OTLP token scopes wrong, (c) wrong OTLP endpoint region.
- **Check 4 ✗** — Metrics work but log events don't. Confirm `OTEL_LOGS_EXPORTER=otlp` is set (check 2 covered this); if it is, check Alloy logs for log-export-specific errors.

## Don't

- Don't run any remediation automatically from this skill — it's a read-only probe. The user decides what to fix.
- Don't fall back to `/grafana-setup` automatically. The user might be debugging on purpose.
