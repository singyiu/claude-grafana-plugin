#!/usr/bin/env bash
# Classify the existing Alloy config for /grafana-setup.
#
# Usage: alloy_config_detect.sh [path-to-config.alloy]
# Output: one of {missing, empty, has-claude, has-otlp, has-other, perms-blocked, unreadable}
#   missing       : file does not exist (nor does any sudo-readable equivalent)
#   empty         : file exists but is empty / whitespace / comments only
#   has-claude    : file already contains the claude-grafana managed fence OR a
#                   "claude_code" otelcol receiver (legacy v0.1.x install)
#   has-otlp      : file declares an otelcol.receiver.otlp NOT scoped to claude
#   has-other     : file has unrelated non-OTLP components (prometheus, loki, etc.)
#   perms-blocked : file exists in a directory we can't traverse and sudo is
#                   not primed; caller should ask user to run `sudo -v`
#   unreadable    : exists but we can't read it AND sudo not available
#
# Stdout is a single token. Stderr carries diagnostics.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

CONFIG_PATH="${1:-$(alloy_config_path)}"

# ── Resolve content ──────────────────────────────────────────────────────────
content=""

if [ -f "$CONFIG_PATH" ] && [ -r "$CONFIG_PATH" ]; then
  content="$(cat "$CONFIG_PATH" 2>/dev/null || true)"
elif [ -e "$CONFIG_PATH" ]; then
  echo "unreadable"
  exit 0
else
  # Path doesn't appear to exist as cyngn. Check whether the dir is unreadable
  # (perms-blocked) — if so, try sudo -n to confirm.
  d="$(dirname "$CONFIG_PATH")"
  if [ -d "$d" ] && [ ! -r "$d" ]; then
    if sudo -n test -f "$CONFIG_PATH" 2>/dev/null; then
      content="$(sudo -n cat "$CONFIG_PATH" 2>/dev/null || true)"
    elif sudo -n test ! -e "$CONFIG_PATH" 2>/dev/null; then
      echo "missing"
      exit 0
    else
      # Sudo not primed — can't tell.
      echo "perms-blocked"
      exit 0
    fi
  else
    echo "missing"
    exit 0
  fi
fi

# Strip comments and blank lines for classification.
stripped="$(printf '%s\n' "$content" \
  | sed -E 's:/\*.*\*/::g; s://.*$::; /^\s*$/d')"

if [ -z "$stripped" ]; then
  echo "empty"
  exit 0
fi

# 1. Already has the claude-grafana managed fence.
if printf '%s\n' "$content" | grep -q 'claude-grafana managed BEGIN'; then
  echo "has-claude"
  exit 0
fi

# 2. Legacy: import.file "claude" or claude_code receiver from old versions.
if printf '%s\n' "$stripped" | grep -Eq 'import\.file[[:space:]]+"claude"|otelcol\.receiver\.otlp[[:space:]]+"claude'; then
  echo "has-claude"
  exit 0
fi

# 3. Has a non-claude OTLP receiver (we'd collide on 4317).
if printf '%s\n' "$stripped" | grep -Eq '^[[:space:]]*otelcol\.receiver\.otlp[[:space:]]+"'; then
  echo "has-otlp"
  exit 0
fi

# 4. Has any other Alloy components.
if printf '%s\n' "$stripped" | grep -Eq '^[[:space:]]*(prometheus|loki|otelcol|discovery|local|logging)\.'; then
  echo "has-other"
  exit 0
fi

# 5. Has a top-level block (logging, tracing, http) but no recognizable component.
if printf '%s\n' "$stripped" | grep -Eq '^[[:space:]]*(logging|tracing|http)[[:space:]]*\{'; then
  echo "has-other"
  exit 0
fi

# Edge case: file has content but nothing matches a component.
echo "empty"
