#!/usr/bin/env bash
# Uninstall the claude-grafana plugin's runtime artifacts.
#
# Restores from .pre-claude-grafana.bak files:
#   ~/.claude/settings.json
#   /etc/alloy/config.alloy (or the active main config)
#
# Removes:
#   /etc/alloy/claude.alloy
#   /etc/alloy/claude.env
#   /etc/systemd/system/alloy.service.d/claude.conf
#
# Does NOT touch:
#   - dashboards in Grafana Cloud (use /grafana-dashboard list/delete)
#   - the OTLP push token or HTTP API token in Grafana Cloud
#   - the plugin checkout itself
#
# Pass --purge-env to also remove ~/.config/claude-grafana/ (default: keep it).

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

PURGE_ENV=0
for arg in "$@"; do
  case "$arg" in
    --purge-env) PURGE_ENV=1 ;;
  esac
done

log_step "Uninstalling claude-grafana runtime"

restore() {
  local f="$1"
  local b="${f}${BACKUP_SUFFIX}"
  if [ -f "$b" ]; then
    log_info "Restoring $f from $b"
    if alloy_needs_sudo && [ "$EUID" -ne 0 ] && [[ "$f" =~ ^/etc/ ]]; then
      maybe_sudo cp -p "$b" "$f"
      maybe_sudo rm -f "$b"
    else
      cp -p "$b" "$f"
      rm -f "$b"
    fi
    log_ok "Restored $f"
  elif [ -e "$f" ]; then
    log_warn "$f exists but no backup at $b — leaving in place."
  else
    log_dim "$f does not exist — nothing to restore."
  fi
}

remove() {
  local f="$1"
  if [ -e "$f" ]; then
    log_info "Removing $f"
    if alloy_needs_sudo && [ "$EUID" -ne 0 ] && [[ "$f" =~ ^/etc/ ]]; then
      maybe_sudo rm -f "$f"
    else
      rm -f "$f"
    fi
    log_ok "Removed $f"
  fi
}

# Restore Claude Code settings.
restore "$(claude_settings_path)"

# Restore Alloy main config.
MAIN_CFG="$(alloy_config_path)"
restore "$MAIN_CFG"

# Remove our claude module + env file + systemd drop-in.
MOD_CFG="$(alloy_module_path)"
ENV_DROPIN="$(alloy_envfile_path)"
SD_DROPIN="/etc/systemd/system/alloy.service.d/claude.conf"
remove "$MOD_CFG"
remove "$ENV_DROPIN"
remove "$SD_DROPIN"

# Reload systemd if applicable.
if command -v systemctl >/dev/null 2>&1; then
  log_info "Reloading systemd and restarting alloy"
  maybe_sudo systemctl daemon-reload
  if maybe_sudo systemctl is-active --quiet alloy; then
    maybe_sudo systemctl reload-or-restart alloy
  fi
fi

if [ "$PURGE_ENV" -eq 1 ]; then
  data_dir="$(claude_grafana_data_dir)"
  if [ -d "$data_dir" ]; then
    log_info "Purging $data_dir (--purge-env)"
    run_or_print rm -rf "$data_dir"
    log_ok "Removed $data_dir"
  fi
fi

log_ok "Uninstall complete."
log_dim ""
log_dim "Notes:"
log_dim "  - Dashboards in Grafana Cloud are NOT removed. Use:"
log_dim "      python3 \$CLAUDE_PLUGIN_ROOT/scripts/grafana_dashboard.py list"
log_dim "      python3 \$CLAUDE_PLUGIN_ROOT/scripts/grafana_dashboard.py delete <uid>"
log_dim "  - Your tokens in Grafana Cloud are NOT revoked. Revoke them manually if you want:"
log_dim "      https://grafana.com/orgs/<your-org>/access-policies"
log_dim "  - .env preserved at $(claude_grafana_env_file). Delete manually to remove tokens locally."
log_dim "  - Pass --purge-env to this script to delete it."
