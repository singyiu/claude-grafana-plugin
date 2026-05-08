---
name: grafana-query
description: Use when the user wants to query Claude Code observability data, ask about token usage, cost, sessions, tool errors, or any other Claude Code metric or event in Grafana Cloud. Triggers on "show claude metrics", "query observability data", "how many tokens did I use", "what did claude cost this week", "show recent tool errors", "how many sessions today", "tool error rate", anything that asks for numbers from the observability backend.
---

# /grafana-query

Run a natural-language query against Grafana Cloud Prometheus or Loki backed by the Claude Code OTel telemetry. The skill maps the intent to a curated PromQL or LogQL template and renders the result as a markdown table with an ASCII sparkline.

## When to use

User wants to know something quantitative about Claude Code itself: how many tokens, what the cost trend is, how often a tool fails, how many sessions today, etc. Also use when they ask for raw query passthrough.

## Prerequisites

`/grafana-setup` must have been run successfully. If `.env` doesn't exist or is missing `GRAFANA_CLOUD_API_TOKEN`, the script will tell the user to run `/grafana-setup` first.

## Process

Run the query script with the user's intent. The script:

1. Loads `.env`.
2. Matches the intent against a curated table of 17 intents covering all 8 native Claude Code metrics + named log events.
3. Picks the closest match by keyword overlap.
4. Auto-derives the time window from phrases like "today", "this week", "last 24h", "past 7 days".
5. Prints the chosen PromQL/LogQL.
6. Hits Grafana Cloud datasource proxy, renders results.

!`python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_query.py" --intent "$ARGUMENTS"`

If the intent is ambiguous (`exit code 2`), the script prints the matching catalog and asks the user to be more specific. Help the user pick by surfacing the most relevant 2-3 intents.

## Recognized intents (catalog)

Eight native Claude Code metrics plus named events. Run `python3 ${CLAUDE_SKILL_DIR}/../../scripts/grafana_query.py --list-intents` for the full list with query templates.

| Intent group | Examples the user might say |
|---|---|
| Sessions | "how many sessions today", "session count this week", "fresh vs resume sessions" |
| Tokens | "tokens this week", "tokens by model", "input vs output tokens last 24h" |
| Cost | "cost this week", "cost by model", "daily cost trend" |
| Code | "lines of code added this week", "commits today", "pull requests this month" |
| Tool decisions | "edit decisions today", "approval rate", "decisions by tool" |
| Active time | "how long was I active this week" |
| Events (Loki) | "recent prompts", "recent tool calls", "tool errors", "compactions", "mcp connections" |

## Raw query mode

If the user explicitly wants to run their own query:

```bash
python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_query.py" --raw --type prom --query 'sum(rate(claude_code_session_count_total[5m]))'
python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_query.py" --raw --type loki --query '{service_namespace="claude-code"} |= "PreToolUse"'
```

## Output format

Prom queries: a markdown table with **Series**, **Sum**, **Last**, **Trend** (ASCII sparkline) columns.
Loki queries: a markdown table with **Time**, **Stream**, **Line** columns, most recent first.

If results are empty, the script prints `_No data._` rather than failing — telemetry just hasn't accumulated yet, or the time window is wrong.

## Don't

- Don't fabricate metric names. The 8 supported ones are: `claude_code_session_count`, `claude_code_token_usage_tokens`, `claude_code_cost_usage_USD`, `claude_code_lines_of_code_count`, `claude_code_commit_count`, `claude_code_pull_request_count`, `claude_code_code_edit_tool_decision_count`, `claude_code_active_time_total_seconds`. Anything else is either a derived expression or doesn't exist.
- Don't paste tokens into the query. The script handles auth.
- Don't bypass the script and call the Grafana API directly — the script handles datasource discovery, retry, and error rendering.
