#!/usr/bin/env bash
# Patch ~/.claude/settings.json to enable Claude Code OTel export to local Alloy.
#
# Idempotent: setting the same env keys to the same values is a no-op. Existing
# unrelated env keys are preserved. The settings.json is backed up to .pre-claude-grafana.bak
# the first time we touch it.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

log_step "Step 4/5: Enable Claude Code OTel export"

require_cmd jq

SETTINGS="$(claude_settings_path)"
ensure_dir "$(dirname "$SETTINGS")"

if [ ! -f "$SETTINGS" ]; then
  log_info "No $SETTINGS yet. Creating."
  if [ "$DRY_RUN" != "1" ]; then
    printf '%s\n' '{}' >"$SETTINGS"
    chmod 0644 "$SETTINGS"
  fi
fi

backup_file "$SETTINGS"

# Build the env keys we'll merge. Reuse the user's existing values when present
# so we don't blow away custom OTEL_RESOURCE_ATTRIBUTES, etc.
hostname="$(hostname -s 2>/dev/null || hostname || echo unknown)"
existing_attrs=""
if existing_attrs="$(jq -r '.env.OTEL_RESOURCE_ATTRIBUTES // ""' "$SETTINGS" 2>/dev/null)"; then
  :
fi

# Compose attributes: keep user-set values; ensure service.name and service.namespace are present.
attrs="service.name=claude-code,service.namespace=local,host.name=$hostname"
if [ -n "$existing_attrs" ] && [ "$existing_attrs" != "$attrs" ]; then
  # Merge: prepend user values, dedupe by key, then append our defaults.
  attrs="$(printf '%s,%s' "$existing_attrs" "$attrs" | awk -v RS=',' -v ORS=',' '{
    split($0, a, "=");
    if (!seen[a[1]]++) print
  }' | sed 's/,$//')"
fi

json_merge_env "$SETTINGS" \
  "CLAUDE_CODE_ENABLE_TELEMETRY=1" \
  "OTEL_METRICS_EXPORTER=otlp" \
  "OTEL_LOGS_EXPORTER=otlp" \
  "OTEL_EXPORTER_OTLP_PROTOCOL=grpc" \
  "OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317" \
  "OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative" \
  "OTEL_LOG_TOOL_DETAILS=1" \
  "OTEL_RESOURCE_ATTRIBUTES=$attrs"

log_ok "Claude Code telemetry env vars set in $SETTINGS"
log_dim "Active env vars:"
if [ "$DRY_RUN" != "1" ]; then
  jq -r '.env | to_entries[] | select(.key | test("^(CLAUDE_CODE_ENABLE_TELEMETRY|OTEL_)")) | "  \(.key)=\(.value)"' "$SETTINGS" >&2
fi

cat >&2 <<EOF

Restart any running Claude Code sessions to pick up the new env. The next
session will start emitting metrics + log events to 127.0.0.1:4317.
EOF
