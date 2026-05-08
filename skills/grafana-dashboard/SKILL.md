---
name: grafana-dashboard
description: Use when the user wants to create, install, list, or delete a Grafana dashboard for Claude Code observability. Triggers on "create dashboard", "build observability dashboard", "install baseline dashboards", "make a dashboard for tool latency", "dashboard for hooks performance", "list claude dashboards", "delete dashboard <uid>", or any request to visualize Claude Code metrics in Grafana.
---

# /grafana-dashboard

Manage Grafana Cloud dashboards backed by Claude Code OTel telemetry. Three modes:

1. **`install-baseline`** — push the three pre-built dashboards (`claude-overview`, `claude-cost`, `claude-tools`) into the user's stack.
2. **`generate <intent>`** — generate a custom dashboard from natural language intent ("dashboard for tool error rate by tool name") via Claude itself, validate, and push.
3. **`list` / `delete <uid>`** — manage dashboards under the `claude-grafana` folder.

## When to use

- User has finished `/grafana-setup` and wants to see dashboards.
- User wants a custom dashboard cut for a specific concern.
- User wants to clean up dashboards.

## Prerequisites

`.env` must contain `GRAFANA_CLOUD_STACK_URL` and `GRAFANA_CLOUD_API_TOKEN` with `dashboards:write` and `folders:write` scopes. Run `/grafana-setup` if missing.

## Subcommand: install-baseline

The default action when the user says "install dashboards" or "set up baseline dashboards".

!`python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_dashboard.py" install-baseline`

Pushes three JSON files from `dashboards/` into a `claude-grafana` folder, creating the folder if needed. Re-running overwrites by `uid`, so any user edits get reverted. The script prints each dashboard URL — surface them in your reply so the user can click through.

## Subcommand: generate

When the user wants a custom dashboard:

1. Parse the user's intent (e.g. "tool latency by hook", "MCP error rate over the last week").
2. Author a Grafana dashboard JSON spec yourself, following the [Grafana JSON model](https://grafana.com/docs/grafana/latest/dashboards/build-dashboards/view-dashboard-json-model/) and using the metrics catalog below.
3. Pipe it through the validator + uploader.

### Metrics catalog you can use

Native Claude Code metrics:

| Metric | Type | Common attributes |
|--------|------|-------------------|
| `claude_code_session_count_total` | counter | `start_type` (`fresh`/`resume`/`continue`) |
| `claude_code_token_usage_tokens_total` | counter | `type` (input/output), `model` |
| `claude_code_cost_usage_USD_total` | counter | `model` |
| `claude_code_lines_of_code_count_total` | counter | `type` (added/removed) |
| `claude_code_commit_count_total` | counter | — |
| `claude_code_pull_request_count_total` | counter | — |
| `claude_code_code_edit_tool_decision_count_total` | counter | `tool`, `decision` |
| `claude_code_active_time_total_seconds_total` | counter | — |

Loki streams:

- `{service_namespace="claude-code"}` — all event log records.
- Filter further with `|= "<event_name>"` (e.g. `PreToolUse`, `PostToolUseFailure`, `compaction`, `mcp_server_connection`, `tool_decision`).
- Add `| json` to extract structured fields.

### Required dashboard skeleton

```json
{
  "uid": "claude-grafana-<short-slug>",
  "title": "Claude Code — <Topic>",
  "description": "<one line>",
  "tags": ["claude-grafana"],
  "schemaVersion": 39,
  "version": 1,
  "timezone": "browser",
  "time": { "from": "now-24h", "to": "now" },
  "templating": {
    "list": [
      { "name": "datasource", "type": "datasource", "query": "prometheus", "refresh": 1 }
    ]
  },
  "panels": [
    /* one or more panels with type, title, gridPos, datasource, targets, fieldConfig */
  ]
}
```

Every panel MUST have: `type`, `title`, `gridPos`, `datasource`, `targets` (with `expr` and `refId`).

### Generation flow

1. You (the model) draft the dashboard JSON in a fenced ```json block.
2. Pipe stdin through the extractor + validator + uploader:

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_dashboard.py" extract <<'JSON'
<paste your dashboard JSON here>
JSON
```

The script extracts the JSON (from a fenced block or raw), validates required keys + each panel's `type`/`title`, and pushes it to the `claude-grafana` folder. On validation failure it prints the exact errors so you can iterate.

## Subcommand: list

!`python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_dashboard.py" list`

## Subcommand: delete

!`python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_dashboard.py" delete $1`

(`$1` = dashboard UID; ask user for it if not provided.)

## Don't

- Don't invent metric names beyond the 8 native ones — Grafana will accept the JSON but the panel will be empty forever.
- Don't omit `tags: ["claude-grafana"]` — `list` and the folder filter rely on it.
- Don't push large free-form HTML/markdown panels with PII. The dashboards are visible to anyone with stack access.
- Don't generate more than ~12 panels per dashboard. Past that, Grafana renders slowly and the dashboard becomes unscannable.
