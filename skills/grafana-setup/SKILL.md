---
name: grafana-setup
description: Use when the user wants to set up Grafana Cloud observability for Claude Code, install or configure the Alloy collector, generate a Grafana Cloud token, or wire Claude Code's OTel telemetry to a backend. Triggers on "set up grafana", "install observability", "connect claude to grafana cloud", "configure alloy for claude", "enable claude telemetry", "set up claude monitoring".
---

# /grafana-setup

Guided onboarding wizard for the `claude-grafana` plugin. **You** (the model) drive the conversation: ask the user the right questions via `AskUserQuestion`, then call the helper scripts via `Bash` with the answers as env vars. Don't try to auto-run the scripts via `!` bash injection — they need values that only the user can provide.

## Process — follow this exactly

### Step 0 — preflight

Run these checks and tell the user the results:

```bash
command -v alloy && alloy --version | head -1
command -v jq && command -v curl && command -v python3 && echo "deps ok"
test -f ~/.claude/settings.json && echo "settings.json present"
```

If `alloy` is missing, run **Step 1** below. If any of `jq`, `curl`, `python3` are missing, stop and tell the user to install them first.

### Step 1 — install Alloy (only if missing)

Skip this step if `alloy --version` already worked.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/01-install-alloy.sh"
```

This script is non-interactive on Linux with apt/dnf and on macOS with Homebrew. Surface its output to the user and ask them to confirm `alloy.service` is running before proceeding.

### Step 2 — onboard Grafana Cloud token

**Tell the user this in plain English first:**

> I need 5 values from your Grafana Cloud stack. Open https://grafana.com/profile/org#access-policies in your browser, then:
> 1. **Stack URL** — the URL of your stack, e.g. `https://my-org.grafana.net`
> 2. **OTLP gateway endpoint** — go to your stack → "Send Data" → "OpenTelemetry" tile → copy the endpoint
> 3. **OTLP instance ID** — same tile, the numeric ID
> 4. **OTLP push token** — mint at the access-policies URL above with scopes `metrics:write`, `logs:write`
> 5. **HTTP API token** — mint a separate token with scopes `dashboards:write`, `datasources:read`

Then collect each value with `AskUserQuestion` (or accept them in one freeform message — your judgment). For tokens, **don't echo them back in your response**.

Once you have all 5, call:

```bash
CLAUDE_GRAFANA_STACK_URL="<value>" \
CLAUDE_GRAFANA_OTLP_ENDPOINT="<value>" \
CLAUDE_GRAFANA_OTLP_INSTANCE_ID="<value>" \
CLAUDE_GRAFANA_OTLP_API_TOKEN="<value>" \
CLAUDE_GRAFANA_API_TOKEN="<value>" \
bash "${CLAUDE_PLUGIN_ROOT}/scripts/02-onboard-token.sh" --no-open-browser
```

The script writes `~/.config/claude-grafana/.env` (chmod 600) and smoke-tests the API token. On 401/403 from `/api/datasources`, the API token's scopes are wrong — ask the user to re-mint with `dashboards:write` + `datasources:read`.

### Step 3 — configure Alloy

First, classify the user's existing Alloy config:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/alloy_config_detect.sh"
```

Output is one of: `missing`, `empty`, `has-claude`, `has-otlp`, `has-other`, `unreadable`.

Then act based on the classification:

| Output | What to do |
|--------|------------|
| `missing` / `empty` | Run step 3 with no `--mode` (defaults to `replace`). |
| `has-claude` | Run step 3 with no `--mode` (defaults to re-rendering the module). |
| `has-otlp` | **STOP.** Tell the user another OTLP receiver is already on `127.0.0.1:4317` and they must remove or move it before re-running setup. Don't proceed. |
| `has-other` | Use `AskUserQuestion` to ask the user **merge / replace / skip** (recommend **merge**, which is non-destructive). Then run step 3 with `--mode=<their choice>`. |
| `unreadable` | **STOP.** Tell the user to re-run with sudo or fix permissions. |

Run step 3:

```bash
# For missing/empty/has-claude — no --mode needed:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/03-configure-alloy.sh"

# For has-other — pass --mode:
bash "${CLAUDE_PLUGIN_ROOT}/scripts/03-configure-alloy.sh" --mode=merge
```

Watch for sudo prompts in the output — the script may need to write to `/etc/alloy/`. If it fails on systemd reload, surface the `journalctl -u alloy` output.

### Step 4 — enable Claude Code telemetry

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/04-enable-claude-otel.sh"
```

Patches `~/.claude/settings.json` to add the OTel env vars. Idempotent. Tell the user they need to **restart any running Claude Code sessions** for the new env to take effect — telemetry only starts on session start.

### Step 5 — validate end-to-end

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/05-validate-setup.sh"
```

Emits one synthetic OTLP metric to local Alloy and polls Grafana Cloud Prometheus for it. Pass = setup is healthy. Failure modes:

- **"Nothing listening on 127.0.0.1:4317"** → `sudo systemctl restart alloy`, then re-run.
- **"No Prometheus datasource found in stack"** → the user picked the wrong stack URL; re-run step 2.
- **Round-trip times out after 60s** → almost always wrong OTLP token scopes (`metrics:write`) or wrong endpoint region. Show the user `sudo journalctl -u alloy -n 50` for the actual error.

### Step 6 — install baseline dashboards

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/grafana_dashboard.py" install-baseline
```

Creates a `claude-grafana` folder and pushes 3 dashboards. Surface the URLs the script prints so the user can click straight into them.

## Configuration variables Claude Code recognizes

`${CLAUDE_PLUGIN_ROOT}` resolves to the plugin install dir at runtime (e.g. `~/.claude/plugins/cache/claude-grafana-marketplace/claude-grafana/<version>/`). The scripts use it to find their lib files. **You don't need to substitute it manually** — it's available in any `bash` you invoke from a skill body.

The token / endpoint values live in `~/.config/claude-grafana/.env` after step 2. That path is stable across plugin updates — do **not** suggest the user write secrets into the plugin cache directory, which gets garbage-collected.

## Don't

- Don't try to run any of the `0[1-5]-*.sh` scripts via `!` bash injection — they expect inputs and that pattern doesn't have a TTY.
- Don't echo OTLP / API tokens back to the user in your responses. Pass them as env vars on the script invocation only.
- Don't enable `CLAUDE_CODE_ENABLE_TELEMETRY` without the OTel exporter env vars also set — Claude Code will spam the local console otherwise.
- Don't skip the backup step. Setup must always be reversible via `${CLAUDE_PLUGIN_ROOT}/scripts/uninstall.sh`.

## After this finishes

Tell the user:
- Restart any open Claude Code sessions to pick up the new env.
- Try `/grafana-status` — should be 4 ✓.
- Try `/grafana-query "session count last hour"` — should return data after a few seconds of activity.
- If you want a custom view: `/grafana-dashboard generate "<your intent>"`.
