# Security

## What this plugin handles

Two secrets, both Grafana Cloud access tokens:

1. **OTLP push token** — `metrics:write`, `logs:write`. Used by Alloy. Stored in `/etc/alloy/claude.env` (or `~/.config/alloy/claude.env` for non-root installs), chmod 600.
2. **HTTP API token** — `dashboards:write`, `datasources:read`. Used by the query and dashboard skills. Stored in `<plugin-root>/.env`, chmod 600.

Neither is a generic credential — both are scoped, stack-bound, and revocable from the Grafana Cloud access-policies UI.

## File locations and permissions

| File | Mode | Owner | Contents |
|------|------|-------|----------|
| `<plugin-root>/.env` | 0600 | user | HTTP API token + stack URL + datasource UIDs |
| `/etc/alloy/claude.env` (Linux) | 0600 | root (read-only by alloy user) | OTLP push token + endpoint + instance ID |
| `~/.config/alloy/claude.env` (non-root) | 0600 | user | same as above |
| `~/.claude/settings.json` | 0644 | user | NO TOKENS — only OTel env keys with non-secret values |

The plugin never writes a token into `settings.json`, the Alloy config, dashboards, logs, or any version-controlled file.

## .gitignore coverage

```gitignore
.env
.env.local
.env.*.local
*.pem
*.key
*.bak
*.pre-claude-grafana.bak
```

CI should run a secret-scanner (e.g. `gitleaks`, `trufflehog`) on every PR. We don't include one in v0.1.0.

## Token rotation

### OTLP push token

1. Mint a new token in https://grafana.com/orgs/<org>/access-policies with `metrics:write` + `logs:write`.
2. Update `/etc/alloy/claude.env`:
   ```bash
   sudo sed -i "s|^GRAFANA_CLOUD_OTLP_API_TOKEN=.*|GRAFANA_CLOUD_OTLP_API_TOKEN=glc_NEW...|" /etc/alloy/claude.env
   ```
3. Restart Alloy:
   ```bash
   sudo systemctl restart alloy
   ```
4. Revoke the old token in the Grafana UI.

### HTTP API token

1. Mint a new token with `dashboards:write` + `datasources:read`.
2. Update `<plugin-root>/.env`:
   ```bash
   sed -i "s|^GRAFANA_CLOUD_API_TOKEN=.*|GRAFANA_CLOUD_API_TOKEN=glsa_NEW...|" "$CLAUDE_PLUGIN_ROOT/.env"
   ```
3. No restart needed — skills read `.env` on each invocation.
4. Revoke the old token.

For automated/dynamic rotation, point Claude Code at an `otelHeadersHelper` script. See https://docs.claude.com/en/docs/claude-code/monitoring-usage#dynamic-headers and the Claude Code settings reference.

## What can someone with each token do?

### OTLP push token (compromise)

- Push fake metrics into your Mimir + fake logs into your Loki.
- Cannot read your data.
- Cannot mutate dashboards, alerts, or users.

Mitigation: revoke, rotate, monitor for unexpected push volume.

### HTTP API token (compromise)

- Read all dashboards and datasource configs (datasources:read returns connection details, not the underlying data — but it can read query *results* via the proxy).
- Create, modify, and delete dashboards.
- Cannot mutate users, alerts, datasources themselves, or stack settings.

Mitigation: revoke, rotate, audit dashboard activity in Grafana → Activity log.

## What the plugin does NOT do

- The plugin does **not** store user prompts or tool arguments anywhere on disk. Tool detail logging (`OTEL_LOG_TOOL_DETAILS=1`) sends them to Loki — they are then your stack's data, governed by your stack's retention.
- The plugin does **not** ship telemetry to any third party. Only to your Grafana Cloud stack.
- The plugin does **not** modify the running Claude Code process — it only edits `~/.claude/settings.json`. No injection, no monkey-patching, no shimming.

## PII considerations

Claude Code's standard attributes include `user.email` and `user.account_uuid` when signed in with a Claude account. These propagate to every metric and log record.

If your team is uncomfortable with email-level attribution in Grafana Cloud:

1. Override `OTEL_RESOURCE_ATTRIBUTES` in `~/.claude/settings.json` to scrub `enduser.id` to a hash.
2. Or, wrap your `claude` invocation in a shell that strips identity attributes before exec.
3. Or, configure Loki retention to drop logs after N days.

By default the plugin keeps the upstream Claude Code identity attributes — they're useful for cost attribution and don't reveal more than your stack's existing user accounts.

## Reporting a vulnerability

Email sing.cheung@cyngn.com with subject `[claude-grafana SECURITY]`. Please do NOT file public GitHub issues for vulnerabilities. We aim to acknowledge within 48 hours.

## Audit log

To audit who has done what via the HTTP API token, look at Grafana → Server admin → Settings → Activity log (Grafana Cloud Pro/Advanced). On Free tier, action attribution is limited to "the token" rather than per-skill — the plugin doesn't add per-skill identity to API requests.
