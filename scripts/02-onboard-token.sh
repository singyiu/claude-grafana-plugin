#!/usr/bin/env bash
# Write the Grafana Cloud token + endpoint values to ~/.config/claude-grafana/.env.
#
# This script is designed to run BOTH interactively (from a terminal) AND
# non-interactively (when called from a Claude skill that has already collected
# the values via AskUserQuestion). Behavior is governed by env vars:
#
#   CLAUDE_GRAFANA_STACK_URL          required: e.g. https://my-org.grafana.net
#   CLAUDE_GRAFANA_OTLP_ENDPOINT      required: e.g. https://otlp-gateway-prod-us-central-0.grafana.net/otlp
#   CLAUDE_GRAFANA_OTLP_INSTANCE_ID   required: numeric instance ID
#   CLAUDE_GRAFANA_OTLP_API_TOKEN     required: glc_... or glsa_... (metrics+logs:write)
#   CLAUDE_GRAFANA_API_TOKEN          required: glsa_... (dashboards:write, datasources:read)
#
# When all five are set, the script runs non-interactively. When any are
# missing AND stdin is a TTY, the script prompts. When any are missing AND
# stdin is NOT a TTY, the script exits non-zero and prints which env vars are
# missing — for the calling skill to surface to the user.
#
# Optional flags:
#   --skip-verify        skip the curl smoke-test against /api/datasources
#   --no-open-browser    don't try xdg-open / open the token UI

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

SKIP_VERIFY=0
OPEN_BROWSER=1
for arg in "$@"; do
  case "$arg" in
    --skip-verify) SKIP_VERIFY=1 ;;
    --no-open-browser) OPEN_BROWSER=0 ;;
  esac
done

log_step "Step 2/5: Onboard Grafana Cloud token"

DATA_DIR="$(claude_grafana_data_dir)"
ENV_FILE="$(claude_grafana_env_file)"

# Pull values from env vars (preferred) or interactive prompts (fallback).
stack_url="${CLAUDE_GRAFANA_STACK_URL:-${GRAFANA_CLOUD_STACK_URL:-}}"
otlp_endpoint="${CLAUDE_GRAFANA_OTLP_ENDPOINT:-${GRAFANA_CLOUD_OTLP_ENDPOINT:-}}"
instance_id="${CLAUDE_GRAFANA_OTLP_INSTANCE_ID:-${GRAFANA_CLOUD_OTLP_INSTANCE_ID:-}}"
otlp_token="${CLAUDE_GRAFANA_OTLP_API_TOKEN:-${GRAFANA_CLOUD_OTLP_API_TOKEN:-}}"
api_token="${CLAUDE_GRAFANA_API_TOKEN:-${GRAFANA_CLOUD_API_TOKEN:-}}"

# Pre-fill from existing .env if present.
if [ -f "$ENV_FILE" ]; then
  load_env "$ENV_FILE"
  : "${stack_url:=${GRAFANA_CLOUD_STACK_URL:-}}"
  : "${otlp_endpoint:=${GRAFANA_CLOUD_OTLP_ENDPOINT:-}}"
  : "${instance_id:=${GRAFANA_CLOUD_OTLP_INSTANCE_ID:-}}"
  : "${otlp_token:=${GRAFANA_CLOUD_OTLP_API_TOKEN:-}}"
  : "${api_token:=${GRAFANA_CLOUD_API_TOKEN:-}}"
fi

# Identify missing vars.
missing=()
[ -z "$stack_url"     ] && missing+=("CLAUDE_GRAFANA_STACK_URL")
[ -z "$otlp_endpoint" ] && missing+=("CLAUDE_GRAFANA_OTLP_ENDPOINT")
[ -z "$instance_id"   ] && missing+=("CLAUDE_GRAFANA_OTLP_INSTANCE_ID")
[ -z "$otlp_token"    ] && missing+=("CLAUDE_GRAFANA_OTLP_API_TOKEN")
[ -z "$api_token"     ] && missing+=("CLAUDE_GRAFANA_API_TOKEN")

if [ "${#missing[@]}" -gt 0 ]; then
  if [ -t 0 ]; then
    # Interactive — prompt the user.
    cat >&2 <<EOF

Need 5 values from your Grafana Cloud stack:
  1) Stack URL                    e.g. https://my-org.grafana.net
  2) OTLP gateway endpoint        from Send Data → OpenTelemetry tile
  3) OTLP instance ID             numeric, same place as endpoint
  4) OTLP push token              scopes: metrics:write, logs:write
  5) HTTP API token               scopes: dashboards:write, datasources:read

Mint tokens at: https://grafana.com/profile/org#access-policies
EOF
    if [ "$OPEN_BROWSER" -eq 1 ]; then
      url="https://grafana.com/profile/org#access-policies"
      if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$url" >/dev/null 2>&1 || true
      elif command -v open >/dev/null 2>&1; then
        open "$url" >/dev/null 2>&1 || true
      fi
    fi
    [ -z "$stack_url"     ] && stack_url="$(prompt_value 'Stack URL' "$stack_url")"
    [ -z "$otlp_endpoint" ] && otlp_endpoint="$(prompt_value 'OTLP gateway endpoint' "$otlp_endpoint")"
    [ -z "$instance_id"   ] && instance_id="$(prompt_value 'OTLP instance ID' "$instance_id")"
    [ -z "$otlp_token"    ] && otlp_token="$(prompt_secret 'OTLP push token')"
    [ -z "$api_token"     ] && api_token="$(prompt_secret 'HTTP API token')"
  else
    # Non-interactive — fail with a clear message the skill can surface.
    log_err "Non-interactive run is missing required values."
    log_err "Set these env vars before invoking the script:"
    for v in "${missing[@]}"; do log_err "    $v"; done
    exit 64  # EX_USAGE
  fi
fi

# Re-validate.
for var in stack_url otlp_endpoint instance_id otlp_token api_token; do
  if [ -z "${!var}" ]; then
    die "Internal error: $var still empty after collection."
  fi
done

# Validate URL shape.
case "$stack_url" in
  https://*.grafana.net|https://*.grafana.net/) ;;
  *) log_warn "Stack URL doesn't look like https://<your>.grafana.net — continuing anyway." ;;
esac
case "$otlp_endpoint" in
  https://*) ;;
  *) die "OTLP endpoint must be https://" ;;
esac

# Smoke-test the API token unless skipped.
if [ "$SKIP_VERIFY" -eq 0 ] && command -v curl >/dev/null 2>&1; then
  log_info "Verifying HTTP API token against $stack_url ..."
  http_code="$(curl -fsS -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer $api_token" \
    "${stack_url%/}/api/datasources" 2>/dev/null || echo "000")"
  case "$http_code" in
    200) log_ok "HTTP API token works." ;;
    401|403) die "HTTP API token rejected ($http_code). Check it has datasources:read." ;;
    000) log_warn "Could not reach $stack_url. Continuing — verify connectivity later." ;;
    *) log_warn "Unexpected response from /api/datasources: $http_code. Continuing." ;;
  esac
fi

# Write atomically with chmod 600.
ensure_dir "$DATA_DIR"
chmod 0700 "$DATA_DIR" 2>/dev/null || true

tmp="$(mktemp "${DATA_DIR}/.env.XXXXXX")"
chmod 0600 "$tmp"
cat >"$tmp" <<EOF
# Generated by claude-grafana /grafana-setup on $(date -Iseconds)
# DO NOT COMMIT. This file holds Grafana Cloud tokens.

GRAFANA_CLOUD_STACK_URL=$stack_url
GRAFANA_CLOUD_OTLP_ENDPOINT=$otlp_endpoint
GRAFANA_CLOUD_OTLP_INSTANCE_ID=$instance_id
GRAFANA_CLOUD_OTLP_API_TOKEN=$otlp_token

GRAFANA_CLOUD_API_TOKEN=$api_token

GRAFANA_CLOUD_PROM_DATASOURCE_UID=
GRAFANA_CLOUD_LOKI_DATASOURCE_UID=
GRAFANA_CLOUD_DASHBOARD_FOLDER_UID=
EOF

if [ "$DRY_RUN" = "1" ]; then
  log_dim "  [dry-run] would write $ENV_FILE (chmod 600)"
  rm -f "$tmp"
else
  mv "$tmp" "$ENV_FILE"
  chmod 0600 "$ENV_FILE"
  log_ok "Wrote $ENV_FILE (chmod 600)"
fi
