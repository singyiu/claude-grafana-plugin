# Alloy configuration

This directory holds the Grafana Alloy configuration shipped with the plugin.

## Files

- **`claude.alloy.tmpl`** — Standalone module installed as `/etc/alloy/claude.alloy` (or `~/.config/alloy/claude.alloy` for non-root setups). Imported from the main `config.alloy` via:

  ```alloy
  import.file "claude" { filename = "/etc/alloy/claude.alloy" }
  ```

- **`claude-merge-snippet.alloy`** — Inline-form of the same pipeline for users who chose **skip** in `/grafana-setup` and want to paste the components into their own `config.alloy`.

## Pipeline

```
otelcol.receiver.otlp ──► attributes (add service.namespace) ──► batch ──► otlphttp ──► Grafana Cloud
                                                                              ▲
                                                              auth.basic (instance ID + API token)
```

The receiver listens on `127.0.0.1:4317` (gRPC) and `127.0.0.1:4318` (HTTP). The exporter pushes to the OTLP gateway URL in `$GRAFANA_CLOUD_OTLP_ENDPOINT` with Basic auth where the username is your numeric instance ID and password is your access-policy token.

## Environment variables

The setup script writes a systemd drop-in or a launchd plist that sources these from `claude.env`:

| Variable | Source | Purpose |
|----------|--------|---------|
| `GRAFANA_CLOUD_OTLP_ENDPOINT` | Stack → Send Data → OpenTelemetry tile | Where Alloy pushes |
| `GRAFANA_CLOUD_OTLP_INSTANCE_ID` | Same place — numeric ID | Basic-auth username |
| `GRAFANA_CLOUD_OTLP_API_TOKEN` | Access policy token (`metrics:write`, `logs:write`) | Basic-auth password |

## Validating

```bash
alloy fmt /etc/alloy/claude.alloy
alloy run /etc/alloy/config.alloy --check
```

The setup script runs both before reloading the systemd service. On failure it rolls back to the `.pre-claude-grafana.bak` file.
