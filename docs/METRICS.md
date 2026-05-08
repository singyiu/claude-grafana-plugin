# Metrics & events reference

Everything Claude Code emits when telemetry is enabled, plus the canonical PromQL/LogQL forms used by the query skill.

## Resource attributes (apply to every metric and log record)

Set via `OTEL_RESOURCE_ATTRIBUTES` (see [Claude Code docs](https://docs.claude.com/en/docs/claude-code/monitoring-usage)). The plugin defaults to:

| Attribute | Value | Source |
|-----------|-------|--------|
| `service.name` | `claude-code` | Plugin sets |
| `service.namespace` | `local` (also added by Alloy attribute processor as `claude-code`) | Plugin sets |
| `host.name` | from `hostname -s` | Plugin sets |
| `user.id` | installation-scoped UUID | Claude Code |
| `session.id` | per-session | Claude Code |
| `user.email` | when signed in with Claude account | Claude Code |
| `user.account_uuid` | when signed in with Claude account | Claude Code |
| `organization.id` | when signed in with Claude account | Claude Code |

When using direct API key / Bedrock / Vertex / Foundry, Claude Code does NOT populate `user.email`. Add `enduser.id=<email>,enduser.directory_id=<sid>` via your own `OTEL_RESOURCE_ATTRIBUTES` for attribution in those cases.

## Metrics

Eight native Claude Code metrics. All are counters, exported as `<name>_total` in Prometheus.

| Metric (OTel name) | Prom name | Unit | Per-event attributes |
|--------------------|-----------|------|----------------------|
| `claude_code.session.count` | `claude_code_session_count_total` | count | `start_type` ∈ {`fresh`, `resume`, `continue`} |
| `claude_code.lines_of_code.count` | `claude_code_lines_of_code_count_total` | count | `type` ∈ {`added`, `removed`} |
| `claude_code.pull_request.count` | `claude_code_pull_request_count_total` | count | — |
| `claude_code.commit.count` | `claude_code_commit_count_total` | count | — |
| `claude_code.cost.usage` | `claude_code_cost_usage_USD_total` | USD | `model` |
| `claude_code.token.usage` | `claude_code_token_usage_tokens_total` | tokens | `type` ∈ {`input`, `output`}, `model` |
| `claude_code.code_edit_tool.decision` | `claude_code_code_edit_tool_decision_count_total` | count | `tool`, `decision` |
| `claude_code.active_time.total` | `claude_code_active_time_total_seconds_total` | seconds | — |

> **Cost is approximate.** For canonical billing, use Claude Console / Bedrock billing / Vertex billing. The cost metric is computed at the SDK level and does not account for retries, prompt cache hits versus misses with full fidelity, or pricing changes mid-window.

### Common PromQL recipes

```promql
# Sessions in window
sum(increase(claude_code_session_count_total[$__range]))

# Sessions by start type
sum by (start_type) (increase(claude_code_session_count_total[$__range]))

# Tokens by model
sum by (model) (increase(claude_code_token_usage_tokens_total[$__range]))

# Cost per session
sum(increase(claude_code_cost_usage_USD_total[$__range]))
  /
clamp_min(sum(increase(claude_code_session_count_total[$__range])), 1)

# Tool approval rate (%)
100 * sum(increase(claude_code_code_edit_tool_decision_count_total{decision="accept"}[$__range]))
    / clamp_min(sum(increase(claude_code_code_edit_tool_decision_count_total[$__range])), 1)

# Active time in minutes
sum(increase(claude_code_active_time_total_seconds_total[$__range])) / 60
```

## Log events

Claude Code emits structured event records as OTel logs (one OTel log record per event). Visible in Loki under `{service_namespace="claude-code"}`. Each record carries the full set of standard attributes plus event-specific fields.

| Event | When it fires | Notable attributes |
|-------|---------------|---------------------|
| `SessionStart` | session begins/resumes | `session.id`, `start_type` |
| `Setup` | `--init-only` / `-p --init` | `setup_kind` |
| `UserPromptSubmit` | user submits a prompt | `prompt_length` |
| `UserPromptExpansion` | typed command expands to a prompt | `expansion_source` |
| `PreToolUse` | before a tool call | `tool_name`, `tool_args` (with `OTEL_LOG_TOOL_DETAILS=1`) |
| `PermissionRequest` | permission dialog appears | `tool_name` |
| `PermissionDenied` | tool call denied by classifier | `tool_name`, `reason` |
| `PostToolUse` | tool call succeeded | `tool_name`, `duration_ms` |
| `PostToolUseFailure` | tool call failed | `tool_name`, `error` |
| `PostToolBatch` | parallel tool batch resolved | `batch_size`, `total_duration_ms` |
| `Notification` | Claude Code notification | `category` |
| `SubagentStart` | subagent spawned | `subagent_type` |
| `SubagentStop` | subagent finished | `subagent_type`, `duration_ms` |
| `TaskCreated` | TaskCreate tool fired | `task_id` |
| `TaskCompleted` | task marked completed | `task_id`, `duration_ms` |
| `Stop` | turn finished | — |
| `StopFailure` | turn ended in API error | `error`, `error_type` |
| `TeammateIdle` | agent-team teammate idle | — |
| `InstructionsLoaded` | CLAUDE.md / .claude/rules loaded | `source_path` |
| `compaction` | context compaction | `trigger`, `success`, `duration_ms`, `pre_tokens`, `post_tokens`, `error` |
| `mcp_server_connection` | MCP connect / disconnect / fail | `server_name`, `result` |

`OTEL_LOG_TOOL_DETAILS=1` (set by the plugin) enables full call detail on every MCP / Bash / file-edit event. Without it, you get the names but not the arguments.

### Common LogQL recipes

```logql
# All events in a window
{service_namespace="claude-code"}

# Tool failures
{service_namespace="claude-code"} |= "PostToolUseFailure" | json

# All MCP server activity
{service_namespace="claude-code"} |= "mcp_server_connection" | json

# Compactions with their token deltas
{service_namespace="claude-code"} |= "compaction" | json | line_format "{{ .timestamp }} {{ .pre_tokens }}→{{ .post_tokens }} ({{ .trigger }})"

# Tool failure rate per minute
sum(rate({service_namespace="claude-code"} |= "PostToolUseFailure" [1m]))
```

## Notes on cardinality

- `model` and `tool` are bounded — safe to aggregate.
- `user.id` is per-installation; `session.id` is per-session and unbounded over time. Don't `sum by (session_id)` over long windows or you'll blow out cardinality.
- `user.email` is bounded by your team size; reasonable for `by` aggregations.
- Free-text fields like `tool_args` should never be used as a `by` clause; filter on them with `|=` / regex.

## Versioning

This reference is current as of Claude Code 1.x (May 2026). The metric and event lists may grow over time. The plugin's NL→PromQL mapping table (`scripts/grafana_query.py` `INTENT_TABLE`) is the source of truth for what's queryable via the skill — extend it when new metrics ship upstream.
