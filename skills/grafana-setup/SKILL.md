---
name: grafana-setup
description: Use when the user wants to set up Grafana Cloud observability for Claude Code, install or configure the Alloy collector, generate a Grafana Cloud token, or wire Claude Code's OTel telemetry to a backend. Triggers on "set up grafana", "install observability", "connect claude to grafana cloud", "configure alloy for claude", "enable claude telemetry", "set up claude monitoring".
---

# /grafana-setup

Guided onboarding wizard for the `claude-grafana` plugin. Walks the user through installing or detecting Grafana Alloy, generating a Grafana Cloud token, configuring the Alloy collector non-destructively, enabling Claude Code's OTel exporter, and validating the round-trip end-to-end.

## When to use

The user wants to start collecting Claude Code observability data in Grafana Cloud and has not yet completed setup. Also use this when the user explicitly says they want to reset or re-do the setup — every step is idempotent.

## Prerequisites — verify before running

- The user has a Grafana Cloud account (free tier is fine). If not, point them at https://grafana.com/auth/sign-up before continuing.
- The host is Linux (systemd) or macOS (launchd via `brew services`). On other platforms, fall back to manual instructions in `docs/TROUBLESHOOTING.md`.
- `curl`, `jq`, `python3` are available. Run `command -v curl jq python3` first; if any missing, ask the user to install them.

## Process

Run each step. Each script is idempotent — safe to re-run. Log every step to the user; don't proceed silently.

### Step 1 — detect or install Alloy

!`bash "${CLAUDE_SKILL_DIR}/../../scripts/01-install-alloy.sh"`

If Alloy is already installed and `alloy.service` is active, this is a no-op. If not, the script picks the right installer for the host (Homebrew / apt / dnf / static binary) and starts the systemd unit.

### Step 2 — onboard the Grafana Cloud token

!`bash "${CLAUDE_SKILL_DIR}/../../scripts/02-onboard-token.sh"`

The script opens the Grafana Cloud UI in the user's browser and prompts them to paste back five values: the stack URL, OTLP endpoint, OTLP instance ID, OTLP push token, and HTTP API token. It writes a chmod-600 `.env` in the plugin root and smoke-tests the API token against `/api/datasources`.

**Two tokens** are required (different scopes):
- **OTLP push token** — `metrics:write`, `logs:write` — Alloy uses this.
- **HTTP API token** — `dashboards:write`, `datasources:read` — the query and dashboard skills use this.

### Step 3 — configure the Alloy collector

!`bash "${CLAUDE_SKILL_DIR}/../../scripts/03-configure-alloy.sh"`

The script classifies the user's existing `/etc/alloy/config.alloy`:

- **missing/empty** → write a fresh claude-only config (`replace`).
- **already has claude.alloy import** → re-render the module file only (`module-only`).
- **has another OTLP receiver on 4317** → abort with a clear error.
- **has unrelated pipelines** → ask the user to choose: `merge` (drop a separate `claude.alloy` module + add one `import.file` line — recommended), `replace` (back up + overwrite, destructive), or `skip` (print a snippet for manual paste).

Always backs up modified files to `<file>.pre-claude-grafana.bak`. Validates with `alloy fmt` before reloading the systemd unit. Rolls back on validation failure.

### Step 4 — enable Claude Code OTel export

!`bash "${CLAUDE_SKILL_DIR}/../../scripts/04-enable-claude-otel.sh"`

Patches `~/.claude/settings.json` to add the OTel env vars under the `env` block:

```
CLAUDE_CODE_ENABLE_TELEMETRY=1
OTEL_METRICS_EXPORTER=otlp
OTEL_LOGS_EXPORTER=otlp
OTEL_EXPORTER_OTLP_PROTOCOL=grpc
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
OTEL_LOG_TOOL_DETAILS=1
OTEL_RESOURCE_ATTRIBUTES=service.name=claude-code,service.namespace=local,host.name=<hostname>
```

Existing keys outside this set are preserved. Backs up `settings.json` before writing.

### Step 5 — validate end-to-end

!`bash "${CLAUDE_SKILL_DIR}/../../scripts/05-validate-setup.sh"`

The script:
1. Confirms Alloy is listening on `127.0.0.1:4317`.
2. Confirms the Claude Code env vars are in `settings.json`.
3. Discovers the Prometheus and Loki datasource UIDs in Grafana Cloud and writes them back to `.env`.
4. Pushes a synthetic OTLP metric (`claude_grafana_setup_probe`) directly to local Alloy.
5. Polls Grafana Cloud Prometheus for that metric every 5s for up to 60s.

Pass = setup is healthy. Fail = print exact diagnostics with next-step commands.

### Step 6 — install the baseline dashboards

!`python3 "${CLAUDE_SKILL_DIR}/../../scripts/grafana_dashboard.py" install-baseline`

Pushes `claude-overview`, `claude-cost`, `claude-tools` to a `claude-grafana` folder. Print the URLs the script returns so the user can click straight into them.

## When this finishes

Tell the user the next-step skills:

- `/grafana-status` — quick four-check probe.
- `/grafana-query "<intent>"` — natural-language query (e.g. `cost this week by model`).
- `/grafana-dashboard generate "<intent>"` — AI-generated custom dashboard.

Restart any open Claude Code sessions to pick up the new env vars — telemetry only starts on session start.

## Failure modes

- **Token rejected at step 2.** Tell the user the API token needs `dashboards:write` and `datasources:read`. Point at https://grafana.com/orgs/<org>/access-policies.
- **Step 3 conflict on 127.0.0.1:4317.** The user already has another OTLP receiver. Either remove it or change its endpoint, then re-run.
- **Step 5 timeout.** Often means OTLP-token scopes are wrong (needs `metrics:write`) or the OTLP endpoint URL doesn't match the user's stack region. `sudo journalctl -u alloy -n 50` shows the export errors.
- **macOS without Homebrew.** Step 1 will fail; ask the user to install Homebrew first or follow the manual install at https://grafana.com/docs/alloy/latest/set-up/install/.

## Don't

- Don't enable `CLAUDE_CODE_ENABLE_TELEMETRY` without also configuring an exporter — it'll spam the local console.
- Don't skip the backup step. Setup must always be reversible via `scripts/uninstall.sh`.
- Don't push tokens into version control. The `.env` is gitignored — keep it that way.
