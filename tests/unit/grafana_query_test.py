"""Unit tests for scripts/grafana_query.py.

Run with: python3 -m pytest tests/unit/grafana_query_test.py -v

Tests cover:
  - Intent matching for all 8 native metrics + 5 log-event intents
  - Window parsing from natural language
  - Sparkline rendering
  - Render functions on canned API responses

Stdlib only — no pytest-mock dependency. We monkeypatch with the unittest.mock
helpers and use a fake urllib.request.urlopen for transport tests.
"""

from __future__ import annotations

import json
import os
import sys
from io import BytesIO
from pathlib import Path
from unittest.mock import patch

import pytest

# Add scripts/ to sys.path so we can import the module under test.
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import grafana_query as gq  # noqa: E402


# ─────────────────────────────────────────────────────────────────────────
# Intent matching
# ─────────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("phrase,expected_intent", [
    ("how many sessions today",                 "session-count-window"),
    ("session count this week",                 "session-count-window"),
    ("fresh vs resume sessions",                "session-count-by-start-type"),
    ("tokens this week",                        "tokens-by-type"),
    ("tokens by model last 7 days",             "tokens-by-model"),
    ("input vs output tokens last 24h",         "tokens-by-type"),
    ("cost this week",                          "cost-window"),
    ("cost by model",                           "cost-by-model"),
    ("daily cost trend",                        "cost-trend"),
    ("lines of code added this week",           "lines-of-code"),
    ("commits today",                           "commits"),
    ("pull requests this month",                "pull-requests"),
    ("edit decisions today",                    "tool-decisions"),
    ("how long was I active this week",         "active-time"),
    ("recent prompts",                          "recent-prompts"),
    ("recent tool calls",                       "recent-tool-calls"),
    ("show me tool errors",                     "tool-errors"),
    ("compactions in the last hour",            "compactions"),
    ("mcp connections",                         "mcp-connections"),
])
def test_intent_match(phrase: str, expected_intent: str):
    intent, score = gq.match_intent(phrase)
    assert intent is not None, f"No match for {phrase!r}"
    assert intent.name == expected_intent, (
        f"Got {intent.name} for {phrase!r}; expected {expected_intent}"
    )
    assert score > 0


def test_unrecognized_intent_returns_none():
    intent, score = gq.match_intent("the weather on mars yesterday")
    assert intent is None or score == 0


# ─────────────────────────────────────────────────────────────────────────
# Window parsing
# ─────────────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("phrase,default,expected", [
    ("today",                       "1h",  "1d"),
    ("this week",                   "1h",  "7d"),
    ("this month",                  "1h",  "30d"),
    ("this year",                   "1h",  "365d"),
    ("last 5 minutes",              "1h",  "5m"),
    ("past 30 min",                 "1h",  "30m"),
    ("over 2 hours",                "1h",  "2h"),
    ("last 7 days",                 "1h",  "7d"),
    ("last 3 weeks",                "1h",  "3w"),
    ("over 6 months",               "1h",  "180d"),
    ("nothing about time here",     "1h",  "1h"),
    ("nothing about time here",     "30d", "30d"),
])
def test_parse_window(phrase: str, default: str, expected: str):
    assert gq.parse_window(phrase, default) == expected


def test_window_to_seconds():
    assert gq.window_to_seconds("5m") == 300
    assert gq.window_to_seconds("1h") == 3600
    assert gq.window_to_seconds("1d") == 86400
    assert gq.window_to_seconds("1w") == 604800
    # Unknown format falls back to 1h.
    assert gq.window_to_seconds("garbage") == 3600


# ─────────────────────────────────────────────────────────────────────────
# Render
# ─────────────────────────────────────────────────────────────────────────

def test_render_query_substitutes_window():
    intent = gq.INTENT_TABLE[0]
    out = gq.render_query(intent, "5m")
    assert "[5m]" in out
    assert "{window}" not in out


def test_sparkline_returns_string_of_correct_length():
    s = gq.sparkline([1.0, 2.0, 3.0, 4.0, 5.0])
    assert len(s) == 5
    assert all(c in gq.SPARK_BARS for c in s)


def test_sparkline_handles_empty():
    assert gq.sparkline([]) == ""


def test_sparkline_handles_constant():
    s = gq.sparkline([7.0, 7.0, 7.0])
    assert len(s) == 3


def test_render_prom_with_data():
    canned = {
        "data": {"result": [
            {"metric": {"start_type": "fresh"},
             "values": [["1700000000", "1.0"], ["1700000060", "2.5"]]},
            {"metric": {"start_type": "resume"},
             "values": [["1700000000", "0.0"], ["1700000060", "1.0"]]},
        ]}
    }
    out = gq.render_prom(canned)
    assert "fresh" in out
    assert "resume" in out
    assert "Series" in out  # markdown header
    assert "Sum" in out


def test_render_prom_empty():
    assert gq.render_prom({"data": {"result": []}}) == "_No data._"


def test_render_loki_with_data():
    canned = {
        "data": {"result": [{
            "stream": {"event_name": "UserPromptSubmit"},
            "values": [
                ["1700000000000000000", '{"prompt": "hello"}'],
                ["1700000060000000000", '{"prompt": "world"}'],
            ],
        }]}
    }
    out = gq.render_loki(canned)
    assert "UserPromptSubmit" in out
    assert "hello" in out
    assert "world" in out


def test_render_loki_empty():
    assert gq.render_loki({"data": {"result": []}}) == "_No matching log lines._"


# ─────────────────────────────────────────────────────────────────────────
# load_env
# ─────────────────────────────────────────────────────────────────────────

def test_load_env_reads_kv_from_file(tmp_path: Path):
    env_file = tmp_path / ".env"
    env_file.write_text(
        "# comment\n"
        "KEY1=value1\n"
        "\n"
        "KEY2 = value 2\n"
        "BAD_LINE_NO_EQUALS\n"
    )
    out = gq.load_env(env_file)
    assert out["KEY1"] == "value1"
    assert out["KEY2"] == "value 2"
    assert "BAD_LINE_NO_EQUALS" not in out


def test_load_env_missing_file_returns_os_environ(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("MARKER_VAR", "yes")
    out = gq.load_env(tmp_path / "does-not-exist")
    assert out["MARKER_VAR"] == "yes"


def test_load_env_does_not_override_os_environ(tmp_path: Path, monkeypatch):
    monkeypatch.setenv("CONFLICT", "from-os")
    env_file = tmp_path / ".env"
    env_file.write_text("CONFLICT=from-file\n")
    out = gq.load_env(env_file)
    assert out["CONFLICT"] == "from-os"


# ─────────────────────────────────────────────────────────────────────────
# GrafanaClient — mocked transport
# ─────────────────────────────────────────────────────────────────────────

class _FakeResponse:
    def __init__(self, body: dict):
        self._body = json.dumps(body).encode()
    def read(self):
        return self._body
    def __enter__(self):
        return self
    def __exit__(self, *a):
        pass


def test_grafana_client_requires_token():
    with pytest.raises(SystemExit):
        gq.GrafanaClient({})


def test_grafana_client_query_prom_builds_correct_url():
    captured = {}
    def fake_urlopen(req, timeout):
        captured["url"] = req.full_url
        captured["headers"] = dict(req.headers)
        return _FakeResponse({"data": {"result": []}})

    env = {
        "GRAFANA_CLOUD_STACK_URL": "https://test.grafana.net",
        "GRAFANA_CLOUD_API_TOKEN": "glsa_xxx",
        "GRAFANA_CLOUD_PROM_DATASOURCE_UID": "prom-uid-123",
        "GRAFANA_CLOUD_LOKI_DATASOURCE_UID": "loki-uid-456",
    }
    client = gq.GrafanaClient(env)
    with patch("urllib.request.urlopen", fake_urlopen):
        client.query_prom("up", "5m")
    assert "https://test.grafana.net/api/datasources/proxy/uid/prom-uid-123/api/v1/query_range" in captured["url"]
    assert "Authorization" in captured["headers"]
    assert captured["headers"]["Authorization"] == "Bearer glsa_xxx"


def test_grafana_client_discovers_datasources():
    sequence = [
        # First call: GET /api/datasources
        _FakeResponse([
            {"uid": "p1", "type": "prometheus"},
            {"uid": "l1", "type": "loki"},
        ]),
        # Second call: actual query
        _FakeResponse({"data": {"result": []}}),
    ]
    def fake_urlopen(req, timeout):
        return sequence.pop(0)

    env = {
        "GRAFANA_CLOUD_STACK_URL": "https://test.grafana.net",
        "GRAFANA_CLOUD_API_TOKEN": "glsa_xxx",
    }
    client = gq.GrafanaClient(env)
    with patch("urllib.request.urlopen", fake_urlopen):
        client.query_prom("up", "5m")
    assert client.prom_uid == "p1"
    assert client.loki_uid == "l1"


def test_grafana_client_picks_logs_loki_over_alert_state_history():
    """Grafana Cloud has 3 Loki datasources. Pick the real logs one."""
    cloud_datasources = [
        {"uid": "grafanacloud-alert-state-history", "type": "loki",
         "name": "grafanacloud-mystack-alert-state-history"},
        {"uid": "grafanacloud-cardinality-management", "type": "grafanacloud-cardinality-datasource",
         "name": "grafanacloud-cardinality"},
        {"uid": "grafanacloud-logs", "type": "loki",
         "name": "grafanacloud-mystack-logs"},
        {"uid": "grafanacloud-usage-insights", "type": "loki",
         "name": "grafanacloud-mystack-usage-insights"},
        {"uid": "grafanacloud-prom", "type": "prometheus",
         "name": "grafanacloud-mystack-prom"},
        {"uid": "grafanacloud-usage", "type": "prometheus",
         "name": "grafanacloud-usage"},
    ]
    sequence = [
        _FakeResponse(cloud_datasources),
        _FakeResponse({"data": {"result": []}}),
    ]
    def fake_urlopen(req, timeout):
        return sequence.pop(0)

    env = {
        "GRAFANA_CLOUD_STACK_URL": "https://test.grafana.net",
        "GRAFANA_CLOUD_API_TOKEN": "glsa_xxx",
    }
    client = gq.GrafanaClient(env)
    with patch("urllib.request.urlopen", fake_urlopen):
        client.query_prom("up", "5m")
    # The actual logs one, not the alerting/usage variants.
    assert client.loki_uid == "grafanacloud-logs"
    # Primary metrics, not the usage one.
    assert client.prom_uid == "grafanacloud-prom"


def test_grafana_client_falls_back_when_no_logs_named_loki():
    """If no Loki has 'logs' in name, fall back to first candidate."""
    sequence = [
        _FakeResponse([
            {"uid": "myloki", "type": "loki", "name": "self-hosted-loki"},
            {"uid": "promds", "type": "prometheus", "name": "self-prom"},
        ]),
        _FakeResponse({"data": {"result": []}}),
    ]
    def fake_urlopen(req, timeout):
        return sequence.pop(0)

    env = {
        "GRAFANA_CLOUD_STACK_URL": "https://test.grafana.net",
        "GRAFANA_CLOUD_API_TOKEN": "glsa_xxx",
    }
    client = gq.GrafanaClient(env)
    with patch("urllib.request.urlopen", fake_urlopen):
        client.query_prom("up", "5m")
    assert client.loki_uid == "myloki"
    assert client.prom_uid == "promds"
