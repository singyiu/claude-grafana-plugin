#!/usr/bin/env bash
# Classify the existing Alloy config for /grafana-setup.
#
# Usage: alloy_config_detect.sh [path-to-config.alloy]
# Output: one of {missing, empty, has-claude, has-otlp, has-other, unreadable}
#   missing       : file does not exist
#   empty         : file exists but is empty / whitespace only
#   has-claude    : file already imports/contains a claude.alloy module
#   has-otlp      : file declares an otelcol.receiver.otlp NOT scoped to claude
#   has-other     : file has unrelated non-OTLP components (prometheus, loki, etc.)
#   unreadable    : exists but we cannot read it (permissions)
#
# Stdout is a single token. Stderr carries diagnostics.

set -euo pipefail

# shellcheck disable=SC1091
. "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

CONFIG_PATH="${1:-$(alloy_config_path)}"

if [ ! -e "$CONFIG_PATH" ]; then
  echo "missing"
  exit 0
fi

if [ ! -r "$CONFIG_PATH" ]; then
  echo "unreadable"
  exit 0
fi

# Read once.
content="$(cat "$CONFIG_PATH" 2>/dev/null || true)"

# Strip comments and blank lines for classification.
stripped="$(printf '%s\n' "$content" \
  | sed -E 's:/\*.*\*/::g; s://.*$::; /^\s*$/d')"

if [ -z "$stripped" ]; then
  echo "empty"
  exit 0
fi

# 1. Already references claude.alloy via import.file.
if printf '%s\n' "$stripped" | grep -Eq 'import\.file[[:space:]]+"claude"|claude\.alloy'; then
  echo "has-claude"
  exit 0
fi

# 2. Has a non-claude OTLP receiver (we'd collide).
if printf '%s\n' "$stripped" | grep -Eq '^[[:space:]]*otelcol\.receiver\.otlp[[:space:]]+"'; then
  # ...unless the only OTLP receiver IS our claude one.
  if printf '%s\n' "$stripped" | grep -Eq '^[[:space:]]*otelcol\.receiver\.otlp[[:space:]]+"claude'; then
    echo "has-claude"
  else
    echo "has-otlp"
  fi
  exit 0
fi

# 3. Has any other Alloy components.
if printf '%s\n' "$stripped" | grep -Eq '^[[:space:]]*(prometheus|loki|otelcol|discovery|local|logging)\.'; then
  echo "has-other"
  exit 0
fi

# Edge case: file has content but nothing matches a component.
echo "empty"
