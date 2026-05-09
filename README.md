# claude-grafana

> Observability for [Claude Code](https://docs.claude.com/en/docs/claude-code) via [Grafana Cloud](https://grafana.com/products/cloud/) and the [Alloy](https://grafana.com/docs/alloy/) OpenTelemetry collector.

Claude Code already emits [native OpenTelemetry metrics and log events](https://docs.claude.com/en/docs/claude-code/monitoring-usage). This plugin wires them up to a real backend, ships baseline dashboards, and gives you natural-language skills to query the data and build new dashboards.

```
Claude Code ──OTLP/gRPC──► Alloy ──HTTPS+BasicAuth──► Grafana Cloud
                                                           │
                                                       Mimir (metrics)
                                                       Loki  (logs/events)
                                                           │
                                                  /grafana-query, /grafana-dashboard
```

## What you get

- **`/grafana-setup`** — Guided wizard. Detects Alloy, walks you through token creation, configures Alloy non-destructively, patches `~/.claude/settings.json`, validates round-trip.
- **`/grafana-query`** — "How many tokens did I use this week?" → PromQL → table with sparkline. Covers all 8 Claude Code metrics + named events.
- **`/grafana-dashboard`** — Installs three baseline dashboards (overview, cost, tools) and can AI-generate new ones from intent.
- **`/grafana-status`** — Four green/red checks: Alloy alive, telemetry env set, metrics flowing, logs flowing.

## Requirements

- [Claude Code](https://docs.claude.com/en/docs/claude-code) ≥ 1.x
- A [Grafana Cloud](https://grafana.com/products/cloud/) free-tier (or paid) stack
- Linux (systemd) or macOS (launchd via `brew services`); Windows not yet supported
- `jq`, `curl`, `python3` ≥ 3.9 in `$PATH`
- The plugin will install [Alloy](https://grafana.com/docs/alloy/) for you if it isn't already on the machine

## Install

### From the marketplace (once published)

```bash
claude /plugin marketplace add singyiu/claude-grafana-plugin
claude /plugin install claude-grafana
```

### From a local checkout

```bash
git clone https://github.com/singyiu/claude-grafana-plugin ~/dev/claude-grafana-plugin
cd ~/dev/claude-grafana-plugin
claude --plugin .
```

## Set up

```bash
claude /grafana-setup
```

The wizard will:

1. Detect or install Alloy.
2. Open the Grafana Cloud token UI in your browser. You paste back the OTLP endpoint, instance ID, and access-policy token.
3. Read your existing Alloy config and ask whether to **merge** (drop a `claude.alloy` module + add one `import.file` line), **replace**, or **skip** (print the snippet for manual paste).
4. Patch `~/.claude/settings.json` with the OTel env vars.
5. Run a round-trip test: emits one synthetic session metric and queries Grafana Cloud for it.
6. Push the three baseline dashboards.

Total time: about 5 minutes.

## Use

```bash
claude /grafana-query "cost this week by model"
claude /grafana-query "tool error rate last hour"
claude /grafana-query "session count today"

claude /grafana-dashboard install-baseline
claude /grafana-dashboard generate "tool latency by hook"

claude /grafana-status
```

You can also drop the slash and the skills will trigger on natural language — "show me my claude cost trend", "is observability working?", "create a dashboard for hooks performance".

## What's collected

See [`docs/METRICS.md`](docs/METRICS.md) for the full reference. Summary:

| Type | Examples |
|------|----------|
| Metrics (8) | `claude_code.session.count`, `claude_code.token.usage`, `claude_code.cost.usage`, `claude_code.lines_of_code.count`, `claude_code.commit.count`, `claude_code.pull_request.count`, `claude_code.code_edit_tool.decision`, `claude_code.active_time.total` |
| Log events (~20) | `UserPromptSubmit`, `SessionStart`, `PreToolUse`, `PostToolUse`, `compaction`, `mcp_server_connection`, `tool_decision`, ... |
| **Traces** | **Not collected.** Claude Code only emits trace spans behind a gated beta flag; this plugin covers metrics + logs. |

## Architecture

See [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md). Quick version: Claude Code → Alloy (local) → Grafana Cloud OTLP gateway → Mimir + Loki. Skills hit the Grafana HTTP API directly (no Grafana MCP server required).

## Security

Tokens live in `~/.config/claude-grafana/.env` (chmod 600), outside the plugin cache so updates don't wipe them. The plugin never writes tokens into version-controlled files. Rotation guidance: [`docs/SECURITY.md`](docs/SECURITY.md). For dynamic-rotation setups, point Claude Code at an `otelHeadersHelper` script — see the security doc.

## Troubleshooting

[`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md) covers:

- "I ran setup but `/grafana-status` is red"
- "Alloy fails to start after merge"
- "Dashboards installed but show no data"
- "Token invalid" / scope errors
- macOS / non-systemd hosts

## Uninstall

```bash
~/.claude/plugins/cache/claude-grafana/<version>/scripts/uninstall.sh
```

Restores `~/.claude/settings.json`, `/etc/alloy/config.alloy`, and the systemd drop-in from `.bak`. Removes `/etc/alloy/claude.alloy`. Does **not** delete dashboards from Grafana Cloud — use `/grafana-dashboard delete <uid>` for those.

## License

[MIT](LICENSE) — see file.

## Contributing

[`CONTRIBUTING.md`](CONTRIBUTING.md). Issues and PRs welcome.
