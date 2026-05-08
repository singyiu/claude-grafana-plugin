# Baseline dashboards

Three hand-authored Grafana dashboard JSON files installed by `/grafana-dashboard install-baseline` (which calls `scripts/grafana_dashboard.py install-baseline`).

| File | What it shows | Default time |
|------|----------------|--------------|
| `claude-overview.json` | Session count, cost, tokens, lines of code, active time. Quick at-a-glance health. | last 24h |
| `claude-cost.json` | Cost stat panels (total, per session, per 1M tokens), daily cost by model, model-share bar, tokens-vs-cost trend. | last 30d |
| `claude-tools.json` | Edit-tool decisions (counts, approval %, by tool), tool failure logs, MCP connection logs. | last 6h |

## Datasource variables

Every dashboard exposes `$datasource` (Prometheus) and `$loki` (when used) as templating variables. On import, Grafana auto-resolves them to the datasources discovered by the setup script. You can swap them in the dashboard settings if you have multiple Prom/Loki sources.

## Editing

You can edit the dashboards in Grafana — `overwrite=true` is set on push, so re-running `install-baseline` will revert local edits. To preserve your changes:

1. **Save As** with a new title in Grafana → that dashboard is preserved on re-install.
2. Or copy your edits back into the file in this directory and submit a PR.

## Schema version

All three dashboards use `schemaVersion: 39` (Grafana 11.x). They render on Grafana Cloud out of the box.

## Tags

All baseline dashboards carry the `claude-grafana` tag. `/grafana-dashboard list` and `delete` only operate on dashboards under that tag, so user-created dashboards in other folders aren't affected.
