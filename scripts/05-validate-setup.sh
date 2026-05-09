#!/usr/bin/env bash
# End-to-end validation: verify telemetry round-trips from Claude Code (or a
# synthetic OTLP client) → Alloy → Grafana Cloud → Prometheus query.
#
# Strategy:
#   1. Confirm Alloy is running and listening on 127.0.0.1:4317.
#   2. Confirm Claude Code env vars are set in ~/.claude/settings.json.
#   3. Discover Prom + Loki datasource UIDs from Grafana Cloud HTTP API.
#   4. Emit a synthetic metric via OTLP to localhost (using a tiny inline Python script).
#   5. Wait up to 60s, then query Prom for the metric. Pass if found.
#
# Non-zero exit on failure with diagnostics.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

log_step "Step 5/5: Validate end-to-end"

ENV_FILE="$(claude_grafana_env_file)"
if [ ! -f "$ENV_FILE" ]; then
  legacy="$CLAUDE_PLUGIN_ROOT/.env"
  [ -f "$legacy" ] && ENV_FILE="$legacy" \
    || die ".env missing at $ENV_FILE — run /grafana-setup first."
fi
load_env "$ENV_FILE"
require_env GRAFANA_CLOUD_STACK_URL
require_env GRAFANA_CLOUD_API_TOKEN

require_cmd curl
require_cmd python3

# ── Check 1: Alloy listening ──────────────────────────────────────────────
log_info "Check 1: Alloy listening on 127.0.0.1:4317"
if command -v ss >/dev/null 2>&1; then
  if ss -ltn 'sport = :4317' 2>/dev/null | grep -q 4317; then
    log_ok "Alloy is listening on 4317."
  else
    die "Nothing listening on 127.0.0.1:4317. Restart alloy: sudo systemctl restart alloy"
  fi
elif command -v lsof >/dev/null 2>&1; then
  if lsof -i :4317 -sTCP:LISTEN >/dev/null 2>&1; then
    log_ok "Alloy is listening on 4317."
  else
    die "Nothing listening on 127.0.0.1:4317."
  fi
else
  log_warn "Neither ss nor lsof available — skipping port check."
fi

# ── Check 2: Claude Code env present ──────────────────────────────────────
log_info "Check 2: Claude Code OTel env in settings.json"
SETTINGS="$(claude_settings_path)"
if [ ! -f "$SETTINGS" ]; then
  die "$SETTINGS missing. Run scripts/04-enable-claude-otel.sh."
fi
if ! json_get "$SETTINGS" '.env.CLAUDE_CODE_ENABLE_TELEMETRY' >/dev/null; then
  die "CLAUDE_CODE_ENABLE_TELEMETRY missing from $SETTINGS."
fi
log_ok "Claude Code telemetry env present."

# ── Check 3: Datasource UIDs ──────────────────────────────────────────────
log_info "Check 3: Discovering Prometheus + Loki datasource UIDs"
ds_json="$(curl -fsS -H "Authorization: Bearer $GRAFANA_CLOUD_API_TOKEN" \
  "${GRAFANA_CLOUD_STACK_URL%/}/api/datasources" 2>/dev/null)" \
  || die "Could not list datasources — token bad or stack URL wrong."

prom_uid="$(printf '%s' "$ds_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for ds in data:
    if ds.get("type") in ("prometheus", "grafana-prometheus-datasource"):
        print(ds["uid"])
        break
')"
loki_uid="$(printf '%s' "$ds_json" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for ds in data:
    if ds.get("type") in ("loki", "grafana-loki-datasource"):
        print(ds["uid"])
        break
')"

if [ -z "$prom_uid" ]; then
  die "No Prometheus datasource found in stack."
fi
log_ok "Prometheus UID: $prom_uid"
if [ -z "$loki_uid" ]; then
  log_warn "No Loki datasource — log-event validation will be skipped."
else
  log_ok "Loki UID: $loki_uid"
fi

# Persist UIDs back to .env so future runs skip discovery.
if [ "$DRY_RUN" != "1" ] && [ -w "$ENV_FILE" ]; then
  python3 - "$ENV_FILE" "$prom_uid" "$loki_uid" <<'PY'
import sys, re, pathlib
env, prom, loki = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(env)
text = p.read_text()
def upsert(t, k, v):
    if re.search(rf'^{k}=.*$', t, re.M):
        return re.sub(rf'^{k}=.*$', f'{k}={v}', t, flags=re.M)
    return t.rstrip() + f'\n{k}={v}\n'
text = upsert(text, 'GRAFANA_CLOUD_PROM_DATASOURCE_UID', prom)
text = upsert(text, 'GRAFANA_CLOUD_LOKI_DATASOURCE_UID', loki)
p.write_text(text)
PY
fi

# ── Check 4: Emit synthetic metric ────────────────────────────────────────
log_info "Check 4: Emitting synthetic OTLP metric"
test_metric_name="claude_grafana_setup_probe"
test_value="$(date +%s)"
python3 - "$test_metric_name" "$test_value" <<'PY'
"""Push one OTLP metric to localhost:4318 (HTTP/protobuf encoded as JSON)."""
import json, sys, time, urllib.request

name, val = sys.argv[1], int(sys.argv[2])
now_ns = time.time_ns()

payload = {
    "resourceMetrics": [{
        "resource": {"attributes": [
            {"key": "service.name", "value": {"stringValue": "claude-grafana-probe"}},
            {"key": "service.namespace", "value": {"stringValue": "local"}},
        ]},
        "scopeMetrics": [{
            "scope": {"name": "claude-grafana"},
            "metrics": [{
                "name": name,
                "gauge": {"dataPoints": [{
                    "timeUnixNano": str(now_ns),
                    "asInt": str(val),
                    "attributes": [],
                }]},
            }],
        }],
    }]
}
req = urllib.request.Request(
    "http://127.0.0.1:4318/v1/metrics",
    data=json.dumps(payload).encode(),
    headers={"Content-Type": "application/json"},
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        if 200 <= r.status < 300:
            print("OK")
        else:
            print(f"HTTP {r.status}")
            sys.exit(1)
except Exception as e:
    print(f"FAIL: {e}")
    sys.exit(1)
PY

log_ok "Synthetic metric emitted."

# ── Check 5: Round-trip query ─────────────────────────────────────────────
log_info "Check 5: Polling Grafana Cloud for the metric (up to 60s)"
deadline=$(( $(date +%s) + 60 ))
found=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  result="$(curl -fsS -G \
    -H "Authorization: Bearer $GRAFANA_CLOUD_API_TOKEN" \
    --data-urlencode "query=$test_metric_name" \
    "${GRAFANA_CLOUD_STACK_URL%/}/api/datasources/proxy/uid/$prom_uid/api/v1/query" \
    2>/dev/null || echo '{}')"
  if printf '%s' "$result" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
    sys.exit(0 if data.get("data", {}).get("result") else 1)
except Exception:
    sys.exit(1)
'; then
    found=1
    break
  fi
  sleep 5
done

if [ "$found" -eq 1 ]; then
  log_ok "Round-trip succeeded — metric is queryable in Grafana Cloud."
else
  log_err "Metric not visible in Grafana Cloud after 60s. Diagnostics:"
  log_dim "  - Check Alloy logs: sudo journalctl -u alloy -n 50"
  log_dim "  - Check Alloy is exporting: it should log batches every ~10s"
  log_dim "  - Check OTLP token scopes: needs metrics:write"
  log_dim "  - Check OTLP endpoint URL matches your stack region"
  exit 1
fi

log_ok "Step 5/5 complete. Setup verified end-to-end."
