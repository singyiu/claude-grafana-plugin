#!/usr/bin/env python3
"""Grafana Cloud dashboard CRUD for the claude-grafana plugin.

Subcommands:
    install-baseline   Push the three JSON files in dashboards/ into the Grafana
                       Cloud stack under a folder named "claude-grafana".
    list               List all dashboards in the claude-grafana folder.
    delete <uid>       Delete a dashboard by uid.
    push <file>        Push a single dashboard JSON.
    extract            Read an AI-generated dashboard JSON from stdin (or
                       extract from a fenced ```json block in stdin), validate,
                       and push.

Stdlib only — uses urllib for HTTP.

Auth: GRAFANA_CLOUD_API_TOKEN must have dashboards:write + folders:write.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

# Reuse env loader from the query script if available; else load inline.
sys.path.insert(0, str(Path(__file__).parent))
try:
    from grafana_query import load_env, plugin_root, claude_grafana_env_file  # type: ignore
except Exception:
    def plugin_root() -> Path:
        return Path(os.environ.get("CLAUDE_PLUGIN_ROOT", Path(__file__).resolve().parent.parent))
    def claude_grafana_env_file() -> Path:
        custom = os.environ.get("CLAUDE_GRAFANA_DATA_DIR")
        if custom:
            return Path(custom) / ".env"
        xdg = os.environ.get("XDG_CONFIG_HOME")
        if xdg:
            return Path(xdg) / "claude-grafana" / ".env"
        return Path.home() / ".config" / "claude-grafana" / ".env"
    def load_env(env_file: Path | None = None) -> dict[str, str]:
        if env_file is None:
            env_file = claude_grafana_env_file()
        out = dict(os.environ)
        for path in (env_file, plugin_root() / ".env"):
            if path.exists():
                for line in path.read_text().splitlines():
                    line = line.strip()
                    if line and not line.startswith("#") and "=" in line:
                        k, v = line.split("=", 1)
                        out.setdefault(k.strip(), v.strip())
                break
        return out


FOLDER_TITLE = "claude-grafana"
FOLDER_TAG = "claude-grafana"


class GrafanaAPI:
    def __init__(self, env: dict[str, str]):
        self.stack = env.get("GRAFANA_CLOUD_STACK_URL", "").rstrip("/")
        self.token = env.get("GRAFANA_CLOUD_API_TOKEN", "")
        self.folder_uid = env.get("GRAFANA_CLOUD_DASHBOARD_FOLDER_UID", "")
        if not self.stack or not self.token:
            raise SystemExit(
                "Missing GRAFANA_CLOUD_STACK_URL or GRAFANA_CLOUD_API_TOKEN. Run /grafana-setup."
            )

    def _request(
        self,
        method: str,
        path: str,
        body: dict[str, Any] | None = None,
        params: dict[str, str] | None = None,
        timeout: int = 30,
    ) -> dict[str, Any] | list[Any]:
        url = f"{self.stack}{path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        data = None
        if body is not None:
            data = json.dumps(body).encode()
        req = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        })
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                txt = r.read().decode()
                return json.loads(txt) if txt else {}
        except urllib.error.HTTPError as e:
            err_body = e.read().decode()
            raise SystemExit(f"HTTP {e.code} {method} {path}\n  {err_body}") from None

    # ── Folders ────────────────────────────────────────────────────────────
    def ensure_folder(self) -> str:
        """Return folder UID, creating it if needed."""
        if self.folder_uid:
            return self.folder_uid
        folders = self._request("GET", "/api/folders")
        if isinstance(folders, list):
            for f in folders:
                if f.get("title") == FOLDER_TITLE:
                    self.folder_uid = f["uid"]
                    return self.folder_uid
        # Create
        created = self._request("POST", "/api/folders", body={
            "title": FOLDER_TITLE,
        })
        self.folder_uid = created["uid"]  # type: ignore[index]
        return self.folder_uid

    # ── Dashboards ─────────────────────────────────────────────────────────
    def push_dashboard(self, dash: dict[str, Any]) -> dict[str, Any]:
        folder_uid = self.ensure_folder()
        # Strip id so Grafana treats it as new on first push, then overwrites by uid.
        dash = dict(dash)
        dash.pop("id", None)
        # Tag for findability.
        tags = set(dash.get("tags") or [])
        tags.add(FOLDER_TAG)
        dash["tags"] = sorted(tags)
        body = {
            "dashboard": dash,
            "folderUid": folder_uid,
            "overwrite": True,
            "message": "Updated by claude-grafana plugin.",
        }
        result = self._request("POST", "/api/dashboards/db", body=body)
        return result  # type: ignore[return-value]

    def list_dashboards(self) -> list[dict[str, Any]]:
        results = self._request("GET", "/api/search", params={
            "tag": FOLDER_TAG,
            "type": "dash-db",
        })
        return results  # type: ignore[return-value]

    def delete_dashboard(self, uid: str) -> None:
        self._request("DELETE", f"/api/dashboards/uid/{uid}")


# ────────────────────────────────────────────────────────────────────────────
# Dashboard validation — light schema check before pushing.
# ────────────────────────────────────────────────────────────────────────────

REQUIRED_KEYS = ("title", "panels")


def validate_dashboard(dash: dict[str, Any]) -> list[str]:
    errs: list[str] = []
    for k in REQUIRED_KEYS:
        if k not in dash:
            errs.append(f"missing required key: {k}")
    if "panels" in dash and not isinstance(dash["panels"], list):
        errs.append("'panels' must be a list")
    if "panels" in dash:
        for i, p in enumerate(dash.get("panels") or []):
            if not isinstance(p, dict):
                errs.append(f"panels[{i}] is not an object")
                continue
            if "type" not in p:
                errs.append(f"panels[{i}] missing 'type'")
            if "title" not in p:
                errs.append(f"panels[{i}] missing 'title'")
    return errs


# ────────────────────────────────────────────────────────────────────────────
# AI-generated dashboard extraction
# ────────────────────────────────────────────────────────────────────────────

JSON_FENCE_RE = re.compile(r"```(?:json)?\s*(\{[\s\S]+?\})\s*```", re.IGNORECASE)


def extract_dashboard_json(text: str) -> dict[str, Any]:
    """Pull a dashboard JSON object out of fenced markdown OR raw text."""
    text = text.strip()
    if text.startswith("{"):
        return json.loads(text)
    m = JSON_FENCE_RE.search(text)
    if not m:
        raise SystemExit(
            "No JSON object found. Wrap dashboard JSON in a ```json fenced block "
            "or pass raw JSON on stdin."
        )
    return json.loads(m.group(1))


# ────────────────────────────────────────────────────────────────────────────
# Subcommands
# ────────────────────────────────────────────────────────────────────────────

def cmd_install_baseline(api: GrafanaAPI) -> int:
    dash_dir = plugin_root() / "dashboards"
    files = sorted(p for p in dash_dir.glob("*.json") if not p.name.endswith(".local.json"))
    if not files:
        print(f"No JSON files in {dash_dir}", file=sys.stderr)
        return 1
    for f in files:
        try:
            dash = json.loads(f.read_text())
        except json.JSONDecodeError as e:
            print(f"Skipping {f.name}: invalid JSON — {e}", file=sys.stderr)
            continue
        errs = validate_dashboard(dash)
        if errs:
            print(f"Skipping {f.name}: " + "; ".join(errs), file=sys.stderr)
            continue
        result = api.push_dashboard(dash)
        url = f"{api.stack}{result.get('url', '')}"
        print(f"✓ {f.name}  →  {url}")
    return 0


def cmd_list(api: GrafanaAPI) -> int:
    dashes = api.list_dashboards()
    if not dashes:
        print("No claude-grafana dashboards found.")
        return 0
    print("| Title | UID | URL |")
    print("|---|---|---|")
    for d in dashes:
        url = f"{api.stack}{d.get('url', '')}"
        print(f"| {d.get('title', '')} | `{d.get('uid', '')}` | {url} |")
    return 0


def cmd_delete(api: GrafanaAPI, uid: str) -> int:
    api.delete_dashboard(uid)
    print(f"Deleted dashboard {uid}")
    return 0


def cmd_push(api: GrafanaAPI, path: Path) -> int:
    dash = json.loads(path.read_text())
    errs = validate_dashboard(dash)
    if errs:
        print("Validation errors:\n  - " + "\n  - ".join(errs), file=sys.stderr)
        return 1
    result = api.push_dashboard(dash)
    print(f"✓ {path.name}  →  {api.stack}{result.get('url', '')}")
    return 0


def cmd_extract(api: GrafanaAPI) -> int:
    text = sys.stdin.read()
    if not text.strip():
        print("No input on stdin.", file=sys.stderr)
        return 1
    dash = extract_dashboard_json(text)
    errs = validate_dashboard(dash)
    if errs:
        print("Validation errors:\n  - " + "\n  - ".join(errs), file=sys.stderr)
        return 1
    result = api.push_dashboard(dash)
    print(f"✓ generated dashboard  →  {api.stack}{result.get('url', '')}")
    return 0


# ────────────────────────────────────────────────────────────────────────────
# Entry point
# ────────────────────────────────────────────────────────────────────────────

def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Grafana Cloud dashboard CRUD for claude-grafana.")
    parser.add_argument("--env-file", help="Path to .env")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("install-baseline", help="Push the three baseline dashboards.")
    sub.add_parser("list", help="List dashboards under claude-grafana folder.")
    p_del = sub.add_parser("delete", help="Delete a dashboard by uid.")
    p_del.add_argument("uid")
    p_push = sub.add_parser("push", help="Push a single dashboard JSON file.")
    p_push.add_argument("file")
    sub.add_parser("extract", help="Read dashboard JSON from stdin, validate, and push.")

    args = parser.parse_args(argv)
    env = load_env(Path(args.env_file) if args.env_file else None)
    api = GrafanaAPI(env)

    if args.cmd == "install-baseline":
        return cmd_install_baseline(api)
    if args.cmd == "list":
        return cmd_list(api)
    if args.cmd == "delete":
        return cmd_delete(api, args.uid)
    if args.cmd == "push":
        return cmd_push(api, Path(args.file))
    if args.cmd == "extract":
        return cmd_extract(api)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
