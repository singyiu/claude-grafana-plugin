#!/usr/bin/env bats
# Tests for scripts/alloy_config_detect.sh.
#
# Run with: bats tests/unit/alloy_config_detect.bats

setup() {
  PLUGIN_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  SCRIPT="$PLUGIN_ROOT/scripts/alloy_config_detect.sh"
  TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMP"
}

@test "missing file → 'missing'" {
  run "$SCRIPT" "$TMP/does-not-exist.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "missing" ]
}

@test "empty file → 'empty'" {
  : > "$TMP/empty.alloy"
  run "$SCRIPT" "$TMP/empty.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "empty" ]
}

@test "whitespace-only file → 'empty'" {
  printf '   \n\n  \n' > "$TMP/ws.alloy"
  run "$SCRIPT" "$TMP/ws.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "empty" ]
}

@test "comments-only file → 'empty'" {
  cat > "$TMP/comments.alloy" <<'EOF'
// This is just a comment
/* block comment */
// and another
EOF
  run "$SCRIPT" "$TMP/comments.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "empty" ]
}

@test "import.file claude → 'has-claude'" {
  cat > "$TMP/imports.alloy" <<'EOF'
logging { level = "info" }

import.file "claude" {
  filename = "/etc/alloy/claude.alloy"
}
EOF
  run "$SCRIPT" "$TMP/imports.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "has-claude" ]
}

@test "claude.alloy reference comment → 'has-claude'" {
  cat > "$TMP/ref.alloy" <<'EOF'
// claude.alloy module included via import.file below
import.file "claude" { filename = "/x" }
EOF
  run "$SCRIPT" "$TMP/ref.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "has-claude" ]
}

@test "otelcol receiver named 'claude' → 'has-claude'" {
  cat > "$TMP/inline.alloy" <<'EOF'
otelcol.receiver.otlp "claude_code" {
  grpc { endpoint = "127.0.0.1:4317" }
}
EOF
  run "$SCRIPT" "$TMP/inline.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "has-claude" ]
}

@test "otelcol receiver with non-claude name → 'has-otlp'" {
  cat > "$TMP/conflict.alloy" <<'EOF'
otelcol.receiver.otlp "default" {
  grpc { endpoint = "127.0.0.1:4317" }
}
EOF
  run "$SCRIPT" "$TMP/conflict.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "has-otlp" ]
}

@test "prometheus scrape only → 'has-other'" {
  cat > "$TMP/prom.alloy" <<'EOF'
prometheus.scrape "default" {
  targets    = [{"__address__" = "localhost:9100"}]
  forward_to = []
}
EOF
  run "$SCRIPT" "$TMP/prom.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "has-other" ]
}

@test "loki source → 'has-other'" {
  cat > "$TMP/loki.alloy" <<'EOF'
loki.source.file "logs" {
  targets    = []
  forward_to = []
}
EOF
  run "$SCRIPT" "$TMP/loki.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "has-other" ]
}

@test "logging block alone → 'has-other'" {
  cat > "$TMP/logging.alloy" <<'EOF'
logging {
  level  = "info"
  format = "logfmt"
}
EOF
  run "$SCRIPT" "$TMP/logging.alloy"
  [ "$status" -eq 0 ]
  [ "$output" = "has-other" ]
}
