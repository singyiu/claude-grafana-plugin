#!/usr/bin/env bash
# Configure the running Alloy collector to receive Claude Code OTLP and
# forward to Grafana Cloud.
#
# Architecture (v0.2.1+): the OTel pipeline lives in a *marker-fenced
# section* directly inside the main config file. Markers:
#   // >>> claude-grafana managed BEGIN
#   ...components...
#   // <<< claude-grafana managed END
# Re-running the script does an in-place replace of the section. Old v0.1.x
# installs that used `import.file "claude" {...}` are detected and migrated
# (the import line + the orphan /etc/alloy/claude.alloy file are removed).
#
# Modes (--mode):
#   merge    (default for has-other) — append/replace the fenced section in
#            the existing config; non-destructive to other components.
#   replace  — back up existing config, write a config that contains ONLY
#            the fenced section.
#   skip     — print the snippet for manual paste.
#
# Sudo: the script needs sudo to write to /etc/alloy/. It checks `sudo -n`
# is primed up front and aborts with a clear message if not.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

# ── Args ────────────────────────────────────────────────────────────────────
EXPLICIT_MODE=""
FORCE=0
prev=""
for arg in "$@"; do
  case "$arg" in
    --force)        FORCE=1 ;;
    --mode=*)       EXPLICIT_MODE="${arg#--mode=}" ;;
    --mode)         ;;  # next iter sets it
  esac
  if [ "$prev" = "--mode" ]; then EXPLICIT_MODE="$arg"; fi
  prev="$arg"
done
case "$EXPLICIT_MODE" in
  ""|merge|replace|skip) ;;
  *) die "Invalid --mode value: $EXPLICIT_MODE (allowed: merge|replace|skip)" ;;
esac

log_step "Step 3/5: Configure Alloy"

require_cmd alloy

# ── Env ─────────────────────────────────────────────────────────────────────
ENV_FILE="$(claude_grafana_env_file)"
if [ ! -f "$ENV_FILE" ]; then
  legacy="$CLAUDE_PLUGIN_ROOT/.env"
  [ -f "$legacy" ] && ENV_FILE="$legacy" \
    || die ".env missing at $ENV_FILE — run /grafana-setup or scripts/02-onboard-token.sh first."
fi
load_env "$ENV_FILE"

# ── Paths ───────────────────────────────────────────────────────────────────
MAIN_CFG="$(alloy_config_path)"
ENV_DROPIN="$(alloy_envfile_path)"
SD_DROPIN="/etc/systemd/system/alloy.service.d/claude.conf"
TMPL="$CLAUDE_PLUGIN_ROOT/alloy/claude.alloy.tmpl"
LEGACY_MOD="$(dirname "$MAIN_CFG")/claude.alloy"

VERSION="$(json_get "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" '.version' || echo 'unknown')"

log_dim "Main config: $MAIN_CFG"
log_dim "Env file:    $ENV_DROPIN"
log_dim "SD dropin:   $SD_DROPIN (linux-only)"

# ── Sudo preflight ──────────────────────────────────────────────────────────
if alloy_needs_sudo; then
  if ! sudo -n true 2>/dev/null; then
    die "Step 3 needs sudo to write to /etc/alloy/. In your terminal, run:
        sudo -v
    to cache credentials, then re-run this step. (sudo's tty_tickets prevents
    me from prompting for a password from this shell.)"
  fi
fi

# ── Classify ────────────────────────────────────────────────────────────────
classification="$("$CLAUDE_PLUGIN_ROOT/scripts/alloy_config_detect.sh" "$MAIN_CFG")"
log_info "Existing config classification: $classification"

choice=""
case "$classification" in
  missing|empty)
    choice="${EXPLICIT_MODE:-replace}"
    ;;
  has-claude)
    # Re-render the fenced section. --mode honored if given.
    choice="${EXPLICIT_MODE:-merge}"
    ;;
  has-otlp)
    die "Existing config declares an otelcol.receiver.otlp on 127.0.0.1:4317 NOT scoped to claude.
    Either remove that receiver or change its endpoint, then re-run."
    ;;
  has-other)
    if [ -n "$EXPLICIT_MODE" ]; then
      choice="$EXPLICIT_MODE"
    elif [ "$FORCE" -eq 1 ]; then
      choice="merge"
    elif [ -t 0 ]; then
      cat >&2 <<EOF

Your existing $MAIN_CFG has unrelated Alloy components.
Three ways to add the claude pipeline:

  merge   - append a fenced section to the existing config. NON-DESTRUCTIVE.
  replace - back up the existing config and write a claude-only one. DESTRUCTIVE.
  skip    - print the snippet for manual paste.

EOF
      choice="$(prompt_choice 'Choose:' 'merge' merge replace skip)"
    else
      die "Existing config has unrelated pipelines and no --mode was passed.
Re-run with --mode=merge (recommended), --mode=replace, or --mode=skip."
    fi
    ;;
  perms-blocked)
    die "Cannot read $MAIN_CFG. Run 'sudo -v' first to cache credentials."
    ;;
  unreadable)
    die "$MAIN_CFG exists but cannot be read. Fix permissions or re-run with sudo."
    ;;
  *)
    die "Unknown classification: $classification"
    ;;
esac

# ── Render the fenced section ──────────────────────────────────────────────
RENDERED_FENCE="$(sed "s/{{VERSION}}/$VERSION/g" "$TMPL")"

# ── Helpers ─────────────────────────────────────────────────────────────────
run_priv() {
  # Run a command with sudo if needed to write to /etc/alloy/.
  if alloy_needs_sudo; then
    run_or_print sudo "$@"
  else
    run_or_print "$@"
  fi
}

# Write content to a destination path with optional mode + group.
# Usage: write_priv <dest> <mode> <group?>  (content on stdin)
write_priv() {
  local dest="$1" mode="${2:-0644}" grp="${3:-}"
  if [ "$DRY_RUN" = "1" ]; then
    log_dim "  [dry-run] would write $dest (mode $mode${grp:+, group $grp})"
    cat >/dev/null
    return 0
  fi
  if alloy_needs_sudo; then
    sudo mkdir -p "$(dirname "$dest")"
    sudo tee "$dest" >/dev/null
    sudo chmod "$mode" "$dest"
    [ -n "$grp" ] && sudo chgrp "$grp" "$dest" 2>/dev/null || true
  else
    ensure_dir "$(dirname "$dest")"
    cat >"$dest"
    chmod "$mode" "$dest"
    [ -n "$grp" ] && chgrp "$grp" "$dest" 2>/dev/null || true
  fi
}

# Read a (possibly perms-blocked) file via sudo if needed.
read_priv() {
  local p="$1"
  if [ -r "$p" ]; then
    cat "$p"
  elif sudo -n test -r "$p" 2>/dev/null; then
    sudo -n cat "$p"
  else
    return 1
  fi
}

# Backup with .pre-claude-grafana.bak, idempotent.
backup_priv() {
  local f="$1" b="${1}${BACKUP_SUFFIX}"
  if ! sudo -n test -e "$f" 2>/dev/null && [ ! -e "$f" ]; then return 0; fi
  if sudo -n test -e "$b" 2>/dev/null || [ -e "$b" ]; then
    log_dim "Backup already exists: $b"
    return 0
  fi
  if [ "$DRY_RUN" = "1" ]; then
    log_dim "  [dry-run] would back up $f -> $b"
    return 0
  fi
  if alloy_needs_sudo; then
    sudo cp -p "$f" "$b"
  else
    cp -p "$f" "$b"
  fi
  log_ok "Backed up $f -> $b"
}

# ── Render artifacts ────────────────────────────────────────────────────────
render_envfile() {
  local content
  content="$(cat <<EOF
# Generated by claude-grafana on $(date -Iseconds). Do not edit by hand.
# chmod 0640, group=$(alloy_service_group || echo alloy).
GRAFANA_CLOUD_OTLP_ENDPOINT=$GRAFANA_CLOUD_OTLP_ENDPOINT
GRAFANA_CLOUD_OTLP_INSTANCE_ID=$GRAFANA_CLOUD_OTLP_INSTANCE_ID
GRAFANA_CLOUD_OTLP_API_TOKEN=$GRAFANA_CLOUD_OTLP_API_TOKEN
EOF
)"
  log_info "Writing env file: $ENV_DROPIN"
  printf '%s\n' "$content" | write_priv "$ENV_DROPIN" 0640 "$(alloy_service_group)"
}

render_systemd_dropin() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_dim "systemctl not present — skipping systemd drop-in."
    return 0
  fi
  log_info "Writing systemd drop-in: $SD_DROPIN"
  cat <<EOF | write_priv "$SD_DROPIN" 0644
# Generated by claude-grafana. Sources $ENV_DROPIN for OTLP credentials.
[Service]
EnvironmentFile=$ENV_DROPIN
EOF
  if [ "$DRY_RUN" != "1" ]; then
    run_priv systemctl daemon-reload
  fi
}

# Write the fenced section into the main config.
# Three behaviors based on $choice and current content:
#   replace  : main = just the fence
#   merge    : if main has a fence, replace it in place; else append fence
#   skip     : print snippet to stderr; don't touch main config
write_main_config() {
  local existing=""
  existing="$(read_priv "$MAIN_CFG" 2>/dev/null || true)"
  case "$choice" in
    skip)
      cat >&2 <<EOF

Paste this snippet into $MAIN_CFG (or a separate imported file):

──────────────────────────────────────────────────────────────────────
$RENDERED_FENCE
──────────────────────────────────────────────────────────────────────

Then ensure $ENV_DROPIN is sourced by the Alloy service (drop-in at $SD_DROPIN
with EnvironmentFile=$ENV_DROPIN).
EOF
      return 0
      ;;
    replace)
      backup_priv "$MAIN_CFG"
      printf '// Generated by claude-grafana on %s.\n%s\n' "$(date -Iseconds)" "$RENDERED_FENCE" \
        | write_priv "$MAIN_CFG" 0644
      log_ok "Wrote claude-only $MAIN_CFG"
      return 0
      ;;
    merge)
      backup_priv "$MAIN_CFG"
      local new_content
      if printf '%s\n' "$existing" | grep -q 'claude-grafana managed BEGIN'; then
        # In-place replace between the markers.
        log_info "Updating existing claude-grafana fenced section in $MAIN_CFG"
        new_content="$(printf '%s\n' "$existing" | python3 -c '
import re, sys
text = sys.stdin.read()
fence = sys.argv[1]
new = re.sub(
    r"//\s*>>> claude-grafana managed BEGIN.*?//\s*<<< claude-grafana managed END\s*\n?",
    fence + "\n",
    text,
    count=1,
    flags=re.S,
)
sys.stdout.write(new)
' "$RENDERED_FENCE")"
      elif printf '%s\n' "$existing" | grep -Eq 'import\.file[[:space:]]+"claude"|otelcol\.receiver\.otlp[[:space:]]+"claude'; then
        # v0.1.x legacy: strip the import line / strip the inline claude_code receiver, then append.
        log_info "Migrating legacy claude config — removing import.file/legacy receiver"
        new_content="$(printf '%s\n' "$existing" | python3 -c '
import re, sys
text = sys.stdin.read()
# Remove `import.file "claude" {...}` block.
text = re.sub(r"//\s*claude-grafana:.*\n?", "", text)
text = re.sub(r"import\.file\s+\"claude\"\s*\{[^}]*\}\s*\n?", "", text, flags=re.S)
# Remove a top-level claude_code receiver block, balanced.
def strip_block(t, marker_re):
    m = re.search(marker_re, t)
    if not m:
        return t
    # find matching close brace by depth
    start = m.start()
    i = m.end()
    depth = 1
    while i < len(t) and depth > 0:
        if t[i] == "{":
            depth += 1
        elif t[i] == "}":
            depth -= 1
        i += 1
    return t[:start] + t[i:].lstrip("\n")
for marker in [
    r"otelcol\.receiver\.otlp\s+\"claude_code\"\s*\{",
    r"otelcol\.processor\.batch\s+\"claude(_grafana)?\"\s*\{",
    r"otelcol\.processor\.attributes\s+\"claude(_grafana)?\"\s*\{",
    r"otelcol\.exporter\.otlphttp\s+\"(claude_grafana|grafana_cloud)\"\s*\{",
    r"otelcol\.auth\.basic\s+\"(claude_grafana|grafana_cloud)\"\s*\{",
]:
    text = strip_block(text, marker)
sys.stdout.write(text.rstrip() + "\n\n" + sys.argv[1] + "\n")
' "$RENDERED_FENCE")"
      else
        log_info "Appending fenced section to $MAIN_CFG"
        new_content="$(printf '%s\n\n%s\n' "$existing" "$RENDERED_FENCE")"
      fi
      printf '%s' "$new_content" | write_priv "$MAIN_CFG" 0644
      log_ok "Updated $MAIN_CFG"
      ;;
  esac
}

cleanup_legacy_module() {
  # v0.1.x wrote /etc/alloy/claude.alloy as an `import.file` module. v0.2.1+
  # inlines everything; the orphan file is invalid (its top-level logging block
  # and components are illegal in a module). Nuke if present.
  if sudo -n test -e "$LEGACY_MOD" 2>/dev/null || [ -e "$LEGACY_MOD" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      log_dim "  [dry-run] would remove legacy module file $LEGACY_MOD"
      return 0
    fi
    log_info "Removing legacy module file $LEGACY_MOD"
    run_priv rm -f "$LEGACY_MOD"
    log_ok "Removed $LEGACY_MOD"
  fi
}

# ── Validate ────────────────────────────────────────────────────────────────
validate_alloy() {
  log_info "Validating Alloy config syntax..."
  if [ "$DRY_RUN" = "1" ]; then
    log_dim "  [dry-run] would run: alloy fmt $MAIN_CFG"
    return 0
  fi
  # Plain alloy fmt parses the file and exits non-zero on syntax error.
  # `--test` is intentionally NOT used (it conflates whitespace formatting
  # with syntax validity).
  if ! run_priv alloy fmt "$MAIN_CFG" >/dev/null 2>&1; then
    log_err "alloy fmt rejected $MAIN_CFG. Recent backup: ${MAIN_CFG}${BACKUP_SUFFIX}"
    die "Syntax error in $MAIN_CFG. Restore the .bak and inspect the rejected diff."
  fi
  log_ok "Alloy config parses cleanly."
}

reload_alloy() {
  if ! command -v systemctl >/dev/null 2>&1; then
    log_warn "systemctl not present. Reload Alloy manually."
    return 0
  fi
  log_info "Reloading alloy.service ..."
  if [ "$DRY_RUN" = "1" ]; then
    log_dim "  [dry-run] would run: systemctl reload-or-restart alloy"
    return 0
  fi
  run_priv systemctl reload-or-restart alloy
  sleep 1
  if run_priv systemctl is-active --quiet alloy; then
    log_ok "alloy.service is active."
  else
    log_err "alloy.service failed to start. Recent logs:"
    run_priv journalctl -u alloy --no-pager -n 30 >&2 || true
    die "Rolling back via the .pre-claude-grafana.bak files (manual: sudo cp <file>.pre-claude-grafana.bak <file>)."
  fi
}

# ── Execute ─────────────────────────────────────────────────────────────────
case "$choice" in
  skip)
    render_envfile
    write_main_config
    log_warn "Manual paste required. /grafana-status will show red until done."
    ;;
  *)
    render_envfile
    render_systemd_dropin
    cleanup_legacy_module
    write_main_config
    validate_alloy
    reload_alloy
    ;;
esac

log_ok "Step 3/5 complete."
