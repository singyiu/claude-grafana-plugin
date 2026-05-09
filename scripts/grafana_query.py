#!/usr/bin/env python3
"""Natural-language → PromQL/LogQL query translator for the Claude Code metrics
emitted by the claude-grafana plugin. Stdlib only — no third-party deps.

Usage:
    grafana_query.py --intent "cost this week by model"
    grafana_query.py --raw --type prom --query 'sum(rate(claude_code_session_count[5m]))'
    grafana_query.py --raw --type loki --query '{service_name="claude-code"} |= "PreToolUse"'
    grafana_query.py --list-intents

Design:
    1. Load .env from CLAUDE_PLUGIN_ROOT (or --env-file).
    2. If --intent: classify against the INTENT_TABLE below and pick the closest
       match. Print the chosen PromQL/LogQL and (unless --no-confirm) ask for
       confirmation before executing.
    3. Hit /api/datasources/proxy/uid/<UID>/api/v1/query_range (Prom) or
       /loki/api/v1/query_range (Loki) with Bearer auth.
    4. Render result as a markdown table with an ASCII sparkline column for
       time series.

Exit codes:
    0  success
    1  config / connectivity error
    2  intent unrecognized; raw query suggestion printed
    3  query executed but returned no data
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

# ────────────────────────────────────────────────────────────────────────────
# Env loading
# ────────────────────────────────────────────────────────────────────────────

def plugin_root() -> Path:
    env_root = os.environ.get("CLAUDE_PLUGIN_ROOT")
    if env_root:
        return Path(env_root)
    return Path(__file__).resolve().parent.parent


def claude_grafana_data_dir() -> Path:
    """Stable user-state directory. Honors XDG."""
    if (custom := os.environ.get("CLAUDE_GRAFANA_DATA_DIR")):
        return Path(custom)
    xdg = os.environ.get("XDG_CONFIG_HOME")
    if xdg:
        return Path(xdg) / "claude-grafana"
    return Path.home() / ".config" / "claude-grafana"


def claude_grafana_env_file() -> Path:
    return claude_grafana_data_dir() / ".env"


def load_env(env_file: Path | None = None) -> dict[str, str]:
    """Load KEY=value pairs from .env. Lines starting with # ignored.

    Default location: ~/.config/claude-grafana/.env
    Legacy fallback (during migration): $CLAUDE_PLUGIN_ROOT/.env
    """
    if env_file is None:
        env_file = claude_grafana_env_file()
    out: dict[str, str] = dict(os.environ)
    candidates: list[Path] = [env_file]
    legacy = plugin_root() / ".env"
    if legacy != env_file:
        candidates.append(legacy)
    for path in candidates:
        if not path.exists():
            continue
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out.setdefault(k.strip(), v.strip())
        break  # first file wins
    return out


# ────────────────────────────────────────────────────────────────────────────
# Intent table — all 8 native Claude Code metrics + common log/event queries.
# Each entry: { name, datasource (prom|loki), query, description, default_window }
# ────────────────────────────────────────────────────────────────────────────

@dataclass(frozen=True)
class Intent:
    name: str
    keywords: tuple[str, ...]
    datasource: str   # 'prom' | 'loki'
    query: str
    description: str
    default_window: str = "1h"


INTENT_TABLE: list[Intent] = [
    # NOTE on PromQL choice: Claude Code emits per-session counter series
    # (session_id is a label). Most session-scoped series have only ONE
    # sample (the cumulative final value at session end), so increase() over
    # any window returns 0. Use `last_over_time` to read each series' final
    # cumulative value, then aggregate. For one-shot events (session.count,
    # commit.count, lines_of_code.count), `count_over_time` is also useful
    # for "how many events fired" semantics.

    # ── Sessions ────────────────────────────────────────────────────────────
    Intent(
        name="session-count-window",
        keywords=("session", "sessions", "count", "started"),
        datasource="prom",
        query="count(count_over_time(claude_code_session_count_total[{window}]))",
        description="Total Claude Code sessions started in the window.",
    ),
    Intent(
        name="session-count-by-start-type",
        keywords=("session", "fresh", "resume", "continue", "start_type"),
        datasource="prom",
        query="count by (start_type) (count_over_time(claude_code_session_count_total[{window}]))",
        description="Sessions split by how they were started (fresh / resume / continue).",
    ),

    # ── Tokens ──────────────────────────────────────────────────────────────
    Intent(
        name="tokens-by-type",
        keywords=("token", "tokens", "input", "output", "usage"),
        datasource="prom",
        query="sum by (type) (last_over_time(claude_code_token_usage_tokens_total[{window}]))",
        description="Tokens consumed in the window, split by input vs output.",
    ),
    Intent(
        name="tokens-by-model",
        keywords=("token", "tokens", "model", "by model", "per model"),
        datasource="prom",
        query="sum by (model) (last_over_time(claude_code_token_usage_tokens_total[{window}]))",
        description="Token usage split by model.",
        default_window="7d",
    ),

    # ── Cost ────────────────────────────────────────────────────────────────
    Intent(
        name="cost-window",
        keywords=("cost", "spend", "spending", "usd", "dollar"),
        datasource="prom",
        query="sum(last_over_time(claude_code_cost_usage_USD_total[{window}]))",
        description="Approximate USD spent in the window (note: cost is approximate).",
        default_window="7d",
    ),
    Intent(
        name="cost-by-model",
        keywords=("cost", "model", "by model", "per model"),
        datasource="prom",
        query="sum by (model) (last_over_time(claude_code_cost_usage_USD_total[{window}]))",
        description="Approximate USD spent per model in the window.",
        default_window="7d",
    ),
    Intent(
        name="cost-trend",
        keywords=("cost", "trend", "daily", "over time"),
        datasource="prom",
        query="sum(last_over_time(claude_code_cost_usage_USD_total[1d]))",
        description="Daily approximate cost trend over the window.",
        default_window="30d",
    ),

    # ── Lines of code / git ─────────────────────────────────────────────────
    Intent(
        name="lines-of-code",
        keywords=("lines", "loc", "code", "added", "removed"),
        datasource="prom",
        query="sum by (type) (last_over_time(claude_code_lines_of_code_count_total[{window}]))",
        description="Lines of code added vs removed.",
        default_window="7d",
    ),
    Intent(
        name="commits",
        keywords=("commit", "commits", "git"),
        datasource="prom",
        query="count(count_over_time(claude_code_commit_count_total[{window}]))",
        description="Git commits Claude Code created in the window.",
        default_window="7d",
    ),
    Intent(
        name="pull-requests",
        keywords=("pr", "pull request", "pull requests", "prs"),
        datasource="prom",
        query="count(count_over_time(claude_code_pull_request_count_total[{window}]))",
        description="Pull requests Claude Code created in the window.",
        default_window="30d",
    ),

    # ── Tool decisions ──────────────────────────────────────────────────────
    Intent(
        name="tool-decisions",
        keywords=("edit decision", "tool decision", "decisions", "approved", "denied", "permission decision", "approval rate"),
        datasource="prom",
        query="sum by (decision, tool) (last_over_time(claude_code_code_edit_tool_decision_count_total[{window}]))",
        description="Code-edit tool permission decisions split by tool and outcome.",
    ),

    # ── Active time ─────────────────────────────────────────────────────────
    Intent(
        name="active-time",
        keywords=("active", "how long", "engagement", "active time", "duration"),
        datasource="prom",
        query="sum(last_over_time(claude_code_active_time_seconds_total[{window}])) / 60",
        description="Total active minutes in the window.",
        default_window="7d",
    ),

    # ── Loki / events ───────────────────────────────────────────────────────
    Intent(
        name="recent-prompts",
        keywords=("prompt", "prompts", "user prompt", "recent prompts"),
        datasource="loki",
        query='{service_name="claude-code"} |= "UserPromptSubmit" | json',
        description="Recent UserPromptSubmit events.",
    ),
    Intent(
        name="recent-tool-calls",
        keywords=("tool call", "pretooluse", "posttooluse", "tool events"),
        datasource="loki",
        query='{service_name="claude-code"} |~ "(PreToolUse|PostToolUse)" | json',
        description="Recent tool-call events.",
    ),
    Intent(
        name="tool-errors",
        keywords=("tool error", "errors", "tool failure", "failed"),
        datasource="loki",
        query='{service_name="claude-code"} |= "PostToolUseFailure" | json',
        description="Recent tool failures.",
    ),
    Intent(
        name="compactions",
        keywords=("compaction", "compact", "context", "compress"),
        datasource="loki",
        query='{service_name="claude-code"} |= "compaction" | json',
        description="Recent context compaction events.",
    ),
    Intent(
        name="mcp-connections",
        keywords=("mcp", "mcp server", "connection"),
        datasource="loki",
        query='{service_name="claude-code"} |= "mcp_server_connection" | json',
        description="MCP server connect / disconnect / fail events.",
    ),
]


# ────────────────────────────────────────────────────────────────────────────
# Intent matching — simple keyword scoring.
# ────────────────────────────────────────────────────────────────────────────

WINDOW_RE = re.compile(
    r"(?:last|past|over)?\s*(\d+)\s*(minute|min|hour|hr|day|week|month)s?",
    re.I,
)
NAMED_WINDOWS = {
    "today": "1d",
    "this week": "7d",
    "this month": "30d",
    "this year": "365d",
}


def parse_window(text: str, default: str) -> str:
    text_l = text.lower()
    for name, w in NAMED_WINDOWS.items():
        if name in text_l:
            return w
    m = WINDOW_RE.search(text_l)
    if not m:
        return default
    n, unit = int(m.group(1)), m.group(2)
    unit_short = {
        "minute": "m", "min": "m",
        "hour": "h", "hr": "h",
        "day": "d", "week": "w", "month": "d",  # months → 30d
    }[unit]
    if unit == "month":
        n *= 30
    return f"{n}{unit_short}"


def match_intent(text: str) -> tuple[Intent | None, int]:
    """Return (best_match, score). Multi-word keyword hits weight more than
    single-word ones so 'tool call' beats 'tool', 'edit decision' beats 'tool'."""
    text_l = text.lower()
    best: tuple[Intent | None, int] = (None, 0)
    for intent in INTENT_TABLE:
        score = 0
        for kw in intent.keywords:
            if kw in text_l:
                score += 2 if " " in kw else 1
        if score > best[1]:
            best = (intent, score)
    return best


def render_query(intent: Intent, window: str) -> str:
    return intent.query.replace("{window}", window)


# ────────────────────────────────────────────────────────────────────────────
# HTTP client
# ────────────────────────────────────────────────────────────────────────────

class GrafanaClient:
    def __init__(self, env: dict[str, str]):
        self.stack = env.get("GRAFANA_CLOUD_STACK_URL", "").rstrip("/")
        self.token = env.get("GRAFANA_CLOUD_API_TOKEN", "")
        self.prom_uid = env.get("GRAFANA_CLOUD_PROM_DATASOURCE_UID", "")
        self.loki_uid = env.get("GRAFANA_CLOUD_LOKI_DATASOURCE_UID", "")
        if not self.stack or not self.token:
            raise SystemExit(
                "Missing GRAFANA_CLOUD_STACK_URL or GRAFANA_CLOUD_API_TOKEN. Run /grafana-setup."
            )

    def _get(self, url: str, params: dict[str, str] | None = None, timeout: int = 30) -> dict[str, Any]:
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/json",
        })
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())

    def discover_datasources(self) -> None:
        if self.prom_uid and self.loki_uid:
            return
        data = self._get(f"{self.stack}/api/datasources")
        if not isinstance(data, list):
            return
        prom_cands = [d for d in data if d.get("type") in ("prometheus", "grafana-prometheus-datasource")]
        loki_cands = [d for d in data if d.get("type") in ("loki", "grafana-loki-datasource")]

        # Prefer primary metrics datasource (not usage / cardinality).
        if not self.prom_uid and prom_cands:
            preferred = [d for d in prom_cands
                         if "usage" not in d.get("uid", "").lower()
                         and "cardinality" not in d.get("uid", "").lower()]
            chosen = preferred or prom_cands
            self.prom_uid = chosen[0].get("uid", "")

        # Grafana Cloud has 3 Loki datasources; prefer the actual logs one
        # over alert-state-history / usage-insights.
        def loki_score(ds: dict) -> int:
            uid = ds.get("uid", "").lower()
            name = ds.get("name", "").lower()
            if "alert-state-history" in uid or "alert-state-history" in name:
                return -10
            if "usage-insights" in uid or "usage-insights" in name:
                return -5
            if uid.endswith("-logs") or name.endswith("-logs") or "logs" in uid:
                return 10
            return 0
        if not self.loki_uid and loki_cands:
            ranked = sorted(loki_cands, key=loki_score, reverse=True)
            self.loki_uid = ranked[0].get("uid", "")

    def query_prom(self, expr: str, window: str = "1h") -> dict[str, Any]:
        self.discover_datasources()
        if not self.prom_uid:
            raise SystemExit("No Prometheus datasource UID. Re-run /grafana-setup.")
        seconds = window_to_seconds(window)
        end = int(time.time())
        start = end - seconds
        step = max(seconds // 60, 15)
        return self._get(
            f"{self.stack}/api/datasources/proxy/uid/{self.prom_uid}/api/v1/query_range",
            params={
                "query": expr,
                "start": str(start),
                "end": str(end),
                "step": str(step),
            },
        )

    def query_loki(self, expr: str, window: str = "1h", limit: int = 50) -> dict[str, Any]:
        self.discover_datasources()
        if not self.loki_uid:
            raise SystemExit("No Loki datasource UID. Re-run /grafana-setup.")
        seconds = window_to_seconds(window)
        end_ns = time.time_ns()
        start_ns = end_ns - seconds * 1_000_000_000
        return self._get(
            f"{self.stack}/api/datasources/proxy/uid/{self.loki_uid}/loki/api/v1/query_range",
            params={
                "query": expr,
                "start": str(start_ns),
                "end": str(end_ns),
                "limit": str(limit),
                "direction": "backward",
            },
        )


def window_to_seconds(window: str) -> int:
    m = re.match(r"^(\d+)([mhdw])$", window)
    if not m:
        return 3600
    n, unit = int(m.group(1)), m.group(2)
    return n * {"m": 60, "h": 3600, "d": 86400, "w": 604800}[unit]


# ────────────────────────────────────────────────────────────────────────────
# Rendering — markdown tables + ASCII sparkline
# ────────────────────────────────────────────────────────────────────────────

SPARK_BARS = "▁▂▃▄▅▆▇█"


def sparkline(values: list[float]) -> str:
    nums = [v for v in values if v is not None]
    if not nums:
        return ""
    lo, hi = min(nums), max(nums)
    span = hi - lo if hi != lo else 1.0
    return "".join(SPARK_BARS[min(len(SPARK_BARS) - 1, int((v - lo) / span * (len(SPARK_BARS) - 1)))] for v in nums)


def render_prom(result: dict[str, Any]) -> str:
    series = result.get("data", {}).get("result", [])
    if not series:
        return "_No data._"
    lines = ["| Series | Sum | Last | Trend |", "|---|---|---|---|"]
    for s in series:
        labels = s.get("metric", {})
        label_str = ", ".join(f"{k}={v}" for k, v in labels.items() if k != "__name__") or "(total)"
        values = [(float(v[1]) if v[1] != "NaN" else 0.0) for v in s.get("values", [])]
        if not values:
            continue
        lines.append(
            f"| {label_str} | {sum(values):.3f} | {values[-1]:.3f} | `{sparkline(values)}` |"
        )
    return "\n".join(lines)


def render_loki(result: dict[str, Any]) -> str:
    series = result.get("data", {}).get("result", [])
    if not series:
        return "_No matching log lines._"
    lines = ["| Time | Stream | Line |", "|---|---|---|"]
    rows: list[tuple[float, str, str]] = []
    for s in series:
        stream = s.get("stream", {})
        stream_str = (
            stream.get("event_name") or stream.get("event")
            or stream.get("name") or stream.get("level") or ""
        )
        for ts_str, line in s.get("values", []):
            ts = int(ts_str) / 1_000_000_000
            line_short = line[:120].replace("|", "\\|").replace("\n", " ")
            rows.append((ts, stream_str, line_short))
    rows.sort(key=lambda r: r[0], reverse=True)
    for ts, stream, line in rows[:50]:
        ts_iso = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(ts))
        lines.append(f"| {ts_iso} | {stream} | {line} |")
    return "\n".join(lines)


# ────────────────────────────────────────────────────────────────────────────
# CLI
# ────────────────────────────────────────────────────────────────────────────

def cmd_list_intents() -> int:
    print("# Recognized intents\n")
    for intent in INTENT_TABLE:
        print(f"### {intent.name}")
        print(f"- **Datasource:** {intent.datasource}")
        print(f"- **Description:** {intent.description}")
        print(f"- **Default window:** {intent.default_window}")
        print(f"- **Query template:** `{intent.query}`")
        print(f"- **Triggers on:** {', '.join(intent.keywords)}\n")
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Query Claude Code metrics from Grafana Cloud.")
    parser.add_argument("--intent", help="Natural-language query intent")
    parser.add_argument("--raw", action="store_true", help="Run --query directly without intent matching")
    parser.add_argument("--type", choices=["prom", "loki"], default="prom", help="Datasource for --raw mode")
    parser.add_argument("--query", help="Raw PromQL or LogQL query")
    parser.add_argument("--window", help="Time window override, e.g. 5m / 1h / 7d")
    parser.add_argument("--no-confirm", action="store_true", help="Don't prompt before running matched query")
    parser.add_argument("--list-intents", action="store_true", help="Print intent table and exit")
    parser.add_argument("--env-file", help="Path to .env (default: ~/.config/claude-grafana/.env)")
    args = parser.parse_args(argv)

    if args.list_intents:
        return cmd_list_intents()

    env = load_env(Path(args.env_file) if args.env_file else None)
    client = GrafanaClient(env)

    # Raw query mode
    if args.raw:
        if not args.query:
            print("--raw requires --query.", file=sys.stderr)
            return 1
        try:
            if args.type == "prom":
                res = client.query_prom(args.query, args.window or "1h")
                print(render_prom(res))
            else:
                res = client.query_loki(args.query, args.window or "1h")
                print(render_loki(res))
        except urllib.error.HTTPError as e:
            print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
            return 1
        return 0

    # Intent mode
    if not args.intent:
        parser.error("Either --intent or (--raw + --query) required.")

    intent, score = match_intent(args.intent)
    if not intent or score == 0:
        print(f"No matching intent. Try `/grafana-query --list-intents` for the catalog.", file=sys.stderr)
        print(f"Or run a raw query: --raw --type prom --query '<your PromQL>'", file=sys.stderr)
        return 2

    window = args.window or parse_window(args.intent, intent.default_window)
    rendered_query = render_query(intent, window)

    print(f"## Intent: `{intent.name}` (score {score})")
    print(f"- **Description:** {intent.description}")
    print(f"- **Datasource:** {intent.datasource}")
    print(f"- **Window:** {window}")
    print(f"- **Query:** `{rendered_query}`\n")

    try:
        if intent.datasource == "prom":
            res = client.query_prom(rendered_query, window)
            print(render_prom(res))
        else:
            res = client.query_loki(rendered_query, window)
            print(render_loki(res))
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode()}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
