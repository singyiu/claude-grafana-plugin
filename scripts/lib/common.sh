#!/usr/bin/env bash
# Shared helpers for claude-grafana setup scripts. Source this file:
#   . "${CLAUDE_PLUGIN_ROOT:-$(dirname "$0")/..}/scripts/lib/common.sh"
#
# Provides:
#   - logging   : log_info, log_warn, log_err, log_ok, log_step
#   - env       : load_env, require_env
#   - prompts   : prompt_choice, prompt_secret, prompt_value, confirm
#   - files     : backup_file, atomic_write, ensure_dir
#   - JSON      : json_merge_env, json_get
#   - alloy     : detect_alloy, alloy_config_path
#   - settings  : claude_settings_path, claude_settings_backup
#   - misc      : DRY_RUN, run_or_print, require_cmd

set -euo pipefail

# ─── Module guard ────────────────────────────────────────────────────────────
if [ "${_CLAUDE_GRAFANA_COMMON_LOADED:-}" = "1" ]; then
  return 0
fi
_CLAUDE_GRAFANA_COMMON_LOADED=1

# ─── Plugin paths ────────────────────────────────────────────────────────────
# CLAUDE_PLUGIN_ROOT is set by Claude Code at runtime. When scripts run
# standalone, fall back to two-up from this file.
if [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  _self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  CLAUDE_PLUGIN_ROOT="$(cd "$_self/../.." && pwd)"
  export CLAUDE_PLUGIN_ROOT
fi

PLUGIN_NAME="claude-grafana"
PLUGIN_TAG="claude-grafana"
BACKUP_SUFFIX=".pre-${PLUGIN_TAG}.bak"

# ─── DRY_RUN ─────────────────────────────────────────────────────────────────
DRY_RUN="${DRY_RUN:-0}"
for arg in "${@-}"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
  esac
done
export DRY_RUN

# ─── Logging ─────────────────────────────────────────────────────────────────
if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
  C_RESET=$'\033[0m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_BOLD=$'\033[1m'
else
  C_RESET= C_DIM= C_RED= C_GREEN= C_YELLOW= C_BLUE= C_BOLD=
fi

_log() { printf '%s\n' "$*" >&2; }
log_info() { _log "${C_BLUE}ℹ${C_RESET}  $*"; }
log_warn() { _log "${C_YELLOW}⚠${C_RESET}  $*"; }
log_err()  { _log "${C_RED}✗${C_RESET}  $*"; }
log_ok()   { _log "${C_GREEN}✓${C_RESET}  $*"; }
log_step() { _log ""; _log "${C_BOLD}${C_BLUE}▶${C_RESET}  ${C_BOLD}$*${C_RESET}"; }
log_dim()  { _log "${C_DIM}$*${C_RESET}"; }

die() { log_err "$*"; exit 1; }

# ─── Command checks ──────────────────────────────────────────────────────────
require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    die "Missing required command: $cmd. Install it and re-run."
  fi
}

# ─── DRY_RUN execution wrapper ───────────────────────────────────────────────
run_or_print() {
  if [ "$DRY_RUN" = "1" ]; then
    log_dim "  [dry-run] $*"
  else
    "$@"
  fi
}

# ─── Env loading ─────────────────────────────────────────────────────────────
# Loads .env from $CLAUDE_PLUGIN_ROOT or current directory. Silent if missing.
load_env() {
  local env_file="${1:-$CLAUDE_PLUGIN_ROOT/.env}"
  if [ -f "$env_file" ]; then
    # Allow comments and blank lines. Don't choke on values with spaces.
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
    log_dim "Loaded env from $env_file"
  fi
}

require_env() {
  local var="$1"
  if [ -z "${!var:-}" ]; then
    die "Required env var $var is not set. Run /grafana-setup or edit \$CLAUDE_PLUGIN_ROOT/.env."
  fi
}

# ─── Prompts ─────────────────────────────────────────────────────────────────
# prompt_choice "Question?" "default" "opt1" "opt2" "opt3"
prompt_choice() {
  local question="$1"; shift
  local default="$1"; shift
  local i=1
  local options=("$@")
  _log ""
  _log "${C_BOLD}${question}${C_RESET}"
  for opt in "${options[@]}"; do
    if [ "$opt" = "$default" ]; then
      _log "  ${C_GREEN}${i})${C_RESET} ${opt} ${C_DIM}(default)${C_RESET}"
    else
      _log "  ${i}) ${opt}"
    fi
    i=$((i + 1))
  done
  local choice
  printf "Choose 1-%d [%s]: " "${#options[@]}" "$default" >&2
  read -r choice
  if [ -z "$choice" ]; then
    printf '%s\n' "$default"
    return 0
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
    printf '%s\n' "${options[$((choice - 1))]}"
    return 0
  fi
  die "Invalid choice: $choice"
}

prompt_value() {
  local question="$1"
  local default="${2:-}"
  local val
  if [ -n "$default" ]; then
    printf "%s [%s]: " "$question" "$default" >&2
  else
    printf "%s: " "$question" >&2
  fi
  read -r val
  if [ -z "$val" ]; then
    val="$default"
  fi
  printf '%s\n' "$val"
}

prompt_secret() {
  local question="$1"
  local val
  printf "%s (input hidden): " "$question" >&2
  read -rs val
  printf '\n' >&2
  printf '%s\n' "$val"
}

confirm() {
  local question="$1"
  local default="${2:-y}"
  local hint
  if [ "$default" = "y" ]; then hint="[Y/n]"; else hint="[y/N]"; fi
  local ans
  printf "%s %s " "$question" "$hint" >&2
  read -r ans
  ans="${ans:-$default}"
  case "$ans" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ─── File operations ─────────────────────────────────────────────────────────
ensure_dir() {
  local d="$1"
  if [ ! -d "$d" ]; then
    run_or_print mkdir -p "$d"
  fi
}

# Back up a file once. Subsequent calls are no-ops (so re-running setup
# doesn't overwrite the original .bak with already-modified content).
backup_file() {
  local f="$1"
  if [ ! -e "$f" ]; then
    return 0
  fi
  local b="${f}${BACKUP_SUFFIX}"
  if [ -e "$b" ]; then
    log_dim "Backup already exists: $b"
    return 0
  fi
  run_or_print cp -p "$f" "$b"
  log_ok "Backed up $f → $b"
}

# Atomic file write: write to temp in same dir then rename. Preserves perms.
# Usage: atomic_write /path/to/file <<EOF
# content
# EOF
atomic_write() {
  local target="$1"
  local mode="${2:-0644}"
  local dir tmp
  dir="$(dirname "$target")"
  ensure_dir "$dir"
  if [ "$DRY_RUN" = "1" ]; then
    log_dim "  [dry-run] atomic_write → $target (mode $mode)"
    cat >/dev/null
    return 0
  fi
  tmp="$(mktemp "${dir}/.${PLUGIN_TAG}.XXXXXX")"
  cat >"$tmp"
  chmod "$mode" "$tmp"
  mv "$tmp" "$target"
}

# ─── JSON helpers (jq-based) ─────────────────────────────────────────────────
# json_merge_env <file> <key1=val1> <key2=val2> ...
# Merges the given env keys into the .env object of a Claude Code settings.json.
# Idempotent: re-running with same values is a no-op.
json_merge_env() {
  require_cmd jq
  local file="$1"; shift
  local args=()
  local jq_filter='.env = (.env // {})'
  local i=0
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    args+=(--arg "k$i" "$k" --arg "v$i" "$v")
    jq_filter="${jq_filter} | .env[\$k${i}] = \$v${i}"
    i=$((i + 1))
  done
  local tmp
  tmp="$(mktemp)"
  if [ -f "$file" ]; then
    jq "${args[@]}" "$jq_filter" "$file" >"$tmp"
  else
    echo '{}' | jq "${args[@]}" "$jq_filter" >"$tmp"
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log_dim "  [dry-run] would write to $file:"
    sed 's/^/    /' "$tmp" >&2
    rm -f "$tmp"
  else
    mv "$tmp" "$file"
    chmod 0644 "$file"
  fi
}

json_get() {
  require_cmd jq
  local file="$1"
  local path="$2"
  if [ ! -f "$file" ]; then
    return 1
  fi
  jq -er "$path" "$file" 2>/dev/null
}

# ─── Alloy detection ─────────────────────────────────────────────────────────
detect_alloy() {
  if command -v alloy >/dev/null 2>&1; then
    return 0
  fi
  for p in /usr/local/bin/alloy /opt/homebrew/bin/alloy "$HOME/.local/bin/alloy"; do
    if [ -x "$p" ]; then
      return 0
    fi
  done
  return 1
}

alloy_config_path() {
  if [ -n "${ALLOY_CONFIG_PATH:-}" ]; then
    printf '%s\n' "$ALLOY_CONFIG_PATH"
    return 0
  fi
  for p in \
    /etc/alloy/config.alloy \
    "$(brew --prefix 2>/dev/null)/etc/alloy/config.alloy" \
    "$HOME/.config/alloy/config.alloy"; do
    if [ -f "$p" ]; then
      printf '%s\n' "$p"
      return 0
    fi
  done
  printf '/etc/alloy/config.alloy\n'
}

alloy_module_path() {
  local main_path
  main_path="$(alloy_config_path)"
  printf '%s/claude.alloy\n' "$(dirname "$main_path")"
}

alloy_envfile_path() {
  if [ -d /etc/systemd/system ]; then
    printf '/etc/alloy/claude.env\n'
  else
    printf '%s/.config/alloy/claude.env\n' "$HOME"
  fi
}

# True if the running user has write access to the system Alloy config dir.
alloy_needs_sudo() {
  local p
  p="$(alloy_config_path)"
  local d
  d="$(dirname "$p")"
  [ -w "$d" ] && return 1 || return 0
}

# Wrapper that prepends sudo if needed and shells out otherwise.
maybe_sudo() {
  if alloy_needs_sudo && [ "$EUID" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      run_or_print sudo "$@"
    else
      die "Need root to write to $(alloy_config_path) but sudo is unavailable."
    fi
  else
    run_or_print "$@"
  fi
}

# ─── Claude settings ─────────────────────────────────────────────────────────
claude_settings_path() {
  printf '%s/.claude/settings.json\n' "$HOME"
}
