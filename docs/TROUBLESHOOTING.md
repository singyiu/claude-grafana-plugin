# Troubleshooting

If something's broken, run `/grafana-status` first. The four red/green lines tell you which component is failing. Then drill in below.

## "I ran setup but `/grafana-status` is red on every check"

Most common cause: you ran setup but haven't started a fresh Claude Code session yet. The OTel env vars only take effect on session start.

```bash
# Verify env vars are in place:
jq '.env | with_entries(select(.key | test("^(CLAUDE_CODE_ENABLE_TELEMETRY|OTEL_)")))' ~/.claude/settings.json

# Start a fresh session (close any existing ones first):
claude
```

Wait 60-90 seconds for the metric round-trip, then re-check.

## "Alloy fails to start after merge"

Recover via the backup:

```bash
sudo systemctl stop alloy
sudo cp /etc/alloy/config.alloy.pre-claude-grafana.bak /etc/alloy/config.alloy
sudo systemctl start alloy
```

Then look at the failure cause:

```bash
sudo alloy fmt /etc/alloy/claude.alloy           # check the module file
sudo alloy fmt /etc/alloy/config.alloy           # check the main file
sudo journalctl -u alloy -n 50 --no-pager
```

Common causes:
- **Two `otelcol.receiver.otlp` blocks competing for 4317.** Remove the old one or change its endpoint, then re-run `/grafana-setup`.
- **Missing env file.** `EnvironmentFile=/etc/alloy/claude.env` exists in `/etc/systemd/system/alloy.service.d/claude.conf` but the file is missing or unreadable. Re-run `scripts/03-configure-alloy.sh`.

## "Dashboards installed but show no data"

1. **Datasource template variable**: open the dashboard in Grafana, top-left dropdown, confirm `datasource` resolves to your Prometheus datasource (not Loki, not Tempo).
2. **Time range**: the baseline dashboards default to "last 24h" / "last 30d". A brand-new install won't have 30 days of data — change to "last 1h" first.
3. **Schema version**: dashboards use Grafana schema 39 (Grafana 11.x). On older Grafana Cloud stacks, manually re-import via the UI which auto-upgrades.

## "Token invalid" / scope errors

`/api/datasources` returning 401/403:

- The HTTP API token must have `dashboards:write` and `datasources:read`. `admin:*` works but is overpriviliged — don't use it.
- The OTLP push token (different from the API token) must have `metrics:write` and `logs:write`.
- Tokens are stack-scoped. A token from stack A won't work on stack B.

Re-mint at `https://grafana.com/orgs/<org>/access-policies`.

## "macOS / non-systemd hosts"

The plugin uses `brew services start alloy` on macOS. If you don't have Homebrew, install it first (https://brew.sh) or follow the manual install at https://grafana.com/docs/alloy/latest/set-up/install/.

The systemd drop-in step is skipped on macOS — instead, the env file is read at the location stored in `$ALLOY_ENV_FILE` (set in your shell rc) or pointed at via the `--env` flag when running Alloy manually. macOS support is best-effort in v0.1.0; PRs welcome.

## "I see metrics but `/grafana-query` returns no data"

- Confirm metric naming. Prometheus appends `_total` to OTLP counters. The query script uses `claude_code_session_count_total`, not `claude_code.session.count`. If you wrote a raw query, check the names in `docs/METRICS.md`.
- Confirm Mimir vs Prometheus datasource type. Both work, but the script auto-discovers; if the auto-discovered UID points at the wrong source, set `GRAFANA_CLOUD_PROM_DATASOURCE_UID` manually in `~/.config/claude-grafana/.env`.

## "Tools showing up as `null`"

Set `OTEL_LOG_TOOL_DETAILS=1` (the plugin already does this). Without it, Claude Code emits the event record but omits `tool_name`/`tool_args`. Verify with:

```bash
jq '.env.OTEL_LOG_TOOL_DETAILS' ~/.claude/settings.json
# Should print "1"
```

## "Setup is stuck at step 5 — round-trip never succeeds"

Step 5 emits one synthetic metric and waits up to 60s. If it times out:

1. Confirm Alloy received the synthetic metric: `sudo journalctl -u alloy --since "1 minute ago" | grep -i metric`. Should see batch send logs.
2. Confirm Alloy's OTLP/HTTP exporter has correct creds: `sudo journalctl -u alloy -n 50 | grep -i 'auth\|401\|403\|push'`.
3. Confirm the OTLP endpoint URL matches your stack region. The OpenTelemetry tile in your stack shows it explicitly.

If everything looks right, your stack might just be slow on first ingest (free tier can take 2-3 minutes for the first metric to be queryable). Re-run step 5 manually:

```bash
bash $CLAUDE_PLUGIN_ROOT/scripts/05-validate-setup.sh
```

## How do I add traces?

See [`docs/ARCHITECTURE.md` § Why no traces](ARCHITECTURE.md#why-no-traces). v0.1.0 doesn't ship a trace pipeline because Claude Code's trace export is gated beta. PRs welcome.

## Resetting / starting over

```bash
# Restore everything we touched:
$CLAUDE_PLUGIN_ROOT/scripts/uninstall.sh

# Then re-run:
claude /grafana-setup
```

`uninstall.sh` restores the `.pre-claude-grafana.bak` files for `~/.claude/settings.json`, the Alloy main config, and the systemd drop-in. It removes `/etc/alloy/claude.alloy` and `/etc/alloy/claude.env`. By default it preserves `~/.config/claude-grafana/.env` so your tokens survive — pass `--purge-env` to also delete that. Dashboards in Grafana Cloud are NOT removed — use `/grafana-dashboard list` then `/grafana-dashboard delete <uid>` for each.

## Filing a bug

See [`CONTRIBUTING.md` § Filing issues](../CONTRIBUTING.md#filing-issues). Please redact tokens before pasting any output.
