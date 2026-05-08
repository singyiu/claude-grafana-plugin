# Architecture

```
┌─────────────────┐    OTLP/gRPC      ┌──────────────────┐    HTTPS+Basic    ┌──────────────────┐
│  Claude Code    │ ─── 127.0.0.1 ──► │  Alloy           │ ─── auth ───────► │  Grafana Cloud   │
│  CLI (your dev  │   :4317 / :4318   │  (systemd)       │                   │  OTLP gateway    │
│  machine)       │                   │  otelcol receiver│                   │                  │
└─────────────────┘                   │  → batch         │                   │  ├─► Mimir       │
                                      │  → otlphttp      │                   │  │   (metrics)   │
                                      └──────────────────┘                   │  └─► Loki        │
                                                                             │      (logs/events)│
┌─────────────────┐                                                          └──────────────────┘
│  Skills         │                                                                    ▲
│  /grafana-query │  ─── HTTPS Bearer auth (separate API token) ──────────────────────┤
│  /grafana-dash  │                                                                    │
└─────────────────┘                                                                    │
                                                                                       │
                                                                              GET /api/datasources
                                                                              GET .../api/v1/query_range
                                                                              POST /api/dashboards/db
                                                                              POST /api/folders
```

## Components

### Claude Code (the producer)

Claude Code natively emits OpenTelemetry **metrics** and **logs/events** when `CLAUDE_CODE_ENABLE_TELEMETRY=1`. Configured exporters: `OTEL_METRICS_EXPORTER`, `OTEL_LOGS_EXPORTER`. Defaults to `otlp` (gRPC, port 4317).

Claude Code does NOT natively emit traces unless `ENABLE_BETA_TRACING_DETAILED=1` and `BETA_TRACING_ENDPOINT` are set, and your org is allow-listed. The plugin does not configure traces — see [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for how to add them later.

The plugin enables telemetry by writing the env vars into `~/.claude/settings.json` under the `env` block. They apply at session start; restart any open Claude Code sessions after install.

### Alloy (the collector)

[Grafana Alloy](https://grafana.com/docs/alloy/) is a vendor-agnostic OpenTelemetry Collector distribution with a programmable config language. We ship a single module file (`claude.alloy`) that:

1. Receives OTLP on `127.0.0.1:4317` (gRPC) and `127.0.0.1:4318` (HTTP).
2. Adds a `service.namespace=claude-code` resource attribute (so all telemetry is tag-filterable).
3. Batches.
4. Forwards via OTLP/HTTP to the Grafana Cloud gateway with Basic auth (instance ID as username, OTLP token as password).

For an existing Alloy install, the setup script offers three integration modes:

- **merge** (recommended) — drops `claude.alloy` next to the main config and adds a single `import.file` line. Existing pipelines continue to run.
- **replace** — backs up the main config and writes a claude-only one. Other pipelines stop.
- **skip** — prints a snippet for manual paste.

### Grafana Cloud (the backend)

Three services receive the data:

- **Mimir** — Prometheus-compatible metric storage. Skills query via the standard datasource proxy.
- **Loki** — log/event storage. Skills query via `/loki/api/v1/query_range`.
- **Grafana** itself — dashboards, folders, datasources. Skills create the `claude-grafana` folder and push baseline dashboards.

The OTLP gateway URL and instance ID are stack-specific and shown in the "Send Data → OpenTelemetry" tile inside your Grafana Cloud stack page.

### Skills (the consumers)

Four skills, all under `skills/`:

| Skill | Calls | Talks to |
|-------|-------|----------|
| `grafana-setup` | `scripts/0[1-5]-*.sh`, `grafana_dashboard.py install-baseline` | Local + Grafana Cloud |
| `grafana-query` | `scripts/grafana_query.py` | Grafana Cloud Prom + Loki |
| `grafana-dashboard` | `scripts/grafana_dashboard.py` | Grafana Cloud Folders + Dashboards API |
| `grafana-status` | inline shell + curl | Grafana Cloud |

All HTTP API calls use the **HTTP API token** (`GRAFANA_CLOUD_API_TOKEN`), which is distinct from the OTLP push token used by Alloy.

## Data flow timing

- **Metric scrape interval**: Claude Code defaults to 60s for metric export, 5s for logs. Override with `OTEL_METRIC_EXPORT_INTERVAL` and `OTEL_LOGS_EXPORT_INTERVAL` (ms).
- **Alloy batch flush**: default 200ms / 8192 records.
- **Grafana Cloud ingest delay**: typically <30s end-to-end on free tier.

Don't expect to see a metric you just emitted within 5 seconds. Round-trip is normally 60-90s.

## Security boundary

- Alloy listens **only on 127.0.0.1**. The OTLP receiver is not reachable from other machines.
- The OTLP push token (in `claude.env`, chmod 600) only has `metrics:write` + `logs:write` — it cannot read your stack data.
- The HTTP API token (in `.env`, chmod 600) has `dashboards:write` + `datasources:read`. It CAN read query data and modify dashboards. Don't grant it `admin:*`.
- See [SECURITY.md](SECURITY.md) for rotation and incident response.

## Why no traces

Claude Code only emits trace spans behind a beta flag (`ENABLE_BETA_TRACING_DETAILED=1`) plus a separate `BETA_TRACING_ENDPOINT`, and interactive sessions need org allow-listing. Standard distributed tracing is therefore out of scope for v0.1.0. To add it later:

1. Add a `tempo` exporter to `claude.alloy` (otelcol.exporter.otlp pointing at the Tempo gateway).
2. Add `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` + the beta flag to `~/.claude/settings.json`.
3. Add a `claude-traces.json` baseline dashboard.

## Why no file-scrape of cost-tracker.log / history.jsonl

Claude Code's native OTel emission supersedes everything we could scrape from the local files. Going through OTLP buys us:

- Structured attributes on every event (model, user.id, session.id, tool name).
- Ordering and de-duplication semantics from the OpenTelemetry SDK.
- Version compatibility — Claude Code can change the file formats; the OTel API is stable.

The plugin therefore ignores `~/.claude/*.log`, `~/.claude/history.jsonl`, etc. If a future Claude Code emits a metric we want but doesn't yet expose via OTel, that's the moment to add a file-scrape pipeline to Alloy.
