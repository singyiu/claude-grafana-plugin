#!/usr/bin/env bash
# Detect or install Grafana Alloy.
#
# Strategy:
#   1. If `alloy` is already on PATH, do nothing.
#   2. On macOS with Homebrew: `brew install grafana/grafana/alloy`.
#   3. On Linux with apt: add the Grafana apt repo and install.
#   4. On Linux with dnf: add the Grafana yum repo and install.
#   5. On Linux without either: download the static binary from grafana.com to ~/.local/bin.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

install_static_binary() {
  local arch
  case "$(uname -m)" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Unsupported arch: $(uname -m)" ;;
  esac
  require_cmd curl
  require_cmd unzip
  local url="https://github.com/grafana/alloy/releases/latest/download/alloy-linux-${arch}.zip"
  local tmp
  tmp="$(mktemp -d)"
  log_info "Downloading $url"
  run_or_print curl -fsSL "$url" -o "$tmp/alloy.zip"
  run_or_print unzip -q "$tmp/alloy.zip" -d "$tmp"
  ensure_dir "$HOME/.local/bin"
  run_or_print mv "$tmp/alloy-linux-$arch" "$HOME/.local/bin/alloy"
  run_or_print chmod +x "$HOME/.local/bin/alloy"
  rm -rf "$tmp"
  log_ok "Installed to $HOME/.local/bin/alloy. Make sure ~/.local/bin is on PATH."
  log_warn "No systemd unit installed for the static binary. Set one up or run alloy manually."
}

log_step "Step 1/5: Detect or install Grafana Alloy"

if detect_alloy; then
  v="$(alloy --version 2>&1 | head -1 || true)"
  log_ok "Alloy already installed: ${v:-unknown version}"
  if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet alloy 2>/dev/null; then
      log_ok "alloy.service is active"
    else
      log_warn "alloy.service is not active. Enable with: sudo systemctl enable --now alloy"
    fi
  fi
  exit 0
fi

uname_s="$(uname -s)"

case "$uname_s" in
  Darwin)
    log_info "macOS detected. Installing via Homebrew."
    require_cmd brew
    run_or_print brew install grafana/grafana/alloy
    run_or_print brew services start alloy
    ;;
  Linux)
    if command -v apt-get >/dev/null 2>&1; then
      log_info "Debian/Ubuntu detected. Installing from Grafana apt repo."
      require_cmd curl
      maybe_sudo bash -c '
        set -e
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor -o /etc/apt/keyrings/grafana.gpg
        echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
        apt-get update -qq
        apt-get install -y alloy
        systemctl enable --now alloy
      '
    elif command -v dnf >/dev/null 2>&1; then
      log_info "Fedora/RHEL detected. Installing from Grafana yum repo."
      maybe_sudo bash -c '
        set -e
        cat >/etc/yum.repos.d/grafana.repo <<REPO
[grafana]
name=grafana
baseurl=https://rpm.grafana.com
repo_gpgcheck=1
enabled=1
gpgcheck=1
gpgkey=https://rpm.grafana.com/gpg.key
REPO
        dnf install -y alloy
        systemctl enable --now alloy
      '
    else
      log_warn "No supported package manager found. Installing static binary."
      install_static_binary
    fi
    ;;
  *)
    die "Unsupported OS: $uname_s. Install Alloy manually: https://grafana.com/docs/alloy/latest/set-up/install/"
    ;;
esac

if detect_alloy; then
  log_ok "Alloy installed: $(alloy --version 2>&1 | head -1)"
else
  die "Install completed but \`alloy\` is still not on PATH. Open a new shell and re-run."
fi
