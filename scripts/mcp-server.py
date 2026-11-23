#!/usr/bin/env python3
"""
Antigravity Image Quota Tracker - Zero-Dependency MCP App Stdio Server (macOS / Linux Python 3.8+)

Serves the interactive Image Quota Dashboard MCP App (`ui://image-quota/dashboard.html`)
with both `aux_pane` (side pane) and `global` (left sidebar) entrypoints.
"""

from __future__ import annotations

import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
HOOK_SCRIPT = SCRIPT_DIR / "hook.py"
DASHBOARD_HTML = PLUGIN_ROOT / "ui" / "dashboard.html"
APP_URI = "ui://image-quota/dashboard.html"


def invoke_hook_cli(args: List[str]) -> Dict[str, Any]:
    proc = subprocess.run(
        [sys.executable, str(HOOK_SCRIPT), *args],
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    out = (proc.stdout or "").strip()
    if not out:
        return {}
    try:
        return json.loads(out)
    except Exception:
        return {"raw": out}


def get_snapshot() -> Dict[str, Any]:
    return {
        "status": invoke_hook_cli(["status"]),
        "analysis": invoke_hook_cli(["analyze"]),
        "serverTimeLocal": datetime.now().strftime("%H:%M:%S"),
    }


def format_summary(snap: Dict[str, Any]) -> str:
    st = snap.get("status") or {}
    if st.get("inCooldown"):
        return (
            f"生图额度冷却中（预计 {st.get('cooldownUntilLocal')} 恢复）｜"
            f"近 {st.get('windowHours')}h 已用 {st.get('usedUnits')} 点（{st.get('usedCount')} 张）。"
        )
    return (
        f"生图额度估算：近 {st.get('windowHours')}h 已用 {st.get('usedUnits')} / ~{st.get('estimatedLimitUnits')} 点"
        f"（{st.get('usedCount')} / ~{st.get('estimatedLimitCount')} 张），预计剩余 ~{st.get('remainingUnits')} 点。"
    )


def send(obj: Dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(obj, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def send_result(req_id: Any, result: Dict[str, Any]) -> None:
    send({"jsonrpc": "2.0", "id": req_id, "result": result})


def send_error(req_id: Any, code: int, message: str) -> None:
    send({"jsonrpc": "2.0", "id": req_id, "error": {"code": code, "message": message}})


def tools_list() -> List[Dict[str, Any]]:
    return [
        {
            "name": "open_image_quota",
            "title": "Image Quota",
            "description": "Open the interactive Image Quota Tracker dashboard showing rolling 5-hour usage, resolution-weighted estimates, cooldown status, and calibration controls.",
            "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
            "_meta": {
                "ui": {"resourceUri": APP_URI},
                "com.google.antigravity/ui": {
                    "entrypoints": [
                        {"type": "aux_pane", "title": "Image Quota"},
                        {"type": "global", "title": "Image Quota"},
                    ]
                },
            },
        },
        {
            "name": "quota_action",
            "title": "Image Quota Action",
            "description": "App-only backend action for refreshing, logging manual usage, updating config, calibrating, or resetting image quota state.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "action": {"type": "string", "enum": ["refresh", "add", "delete", "config", "calibrate", "clear-cooldown", "reset"]},
                    "eventId": {"type": "string"},
                    "tier": {"type": "string"},
                    "count": {"type": "integer"},
                    "resetText": {"type": "string"},
                    "settings": {"type": "object"},
                },
                "required": ["action"],
            },
            "_meta": {"ui": {"visibility": ["app"]}},
        },
    ]


def handle_tool_call(name: str, args: Dict[str, Any]) -> Dict[str, Any]:
    if name == "open_image_quota":
        snap = get_snapshot()
        return {
            "content": [{"type": "text", "text": format_summary(snap)}],
            "structuredContent": snap,
        }
    if name == "quota_action":
        act = str(args.get("action") or "refresh")
        if act == "add":
            invoke_hook_cli(["add", str(args.get("tier") or "1K"), str(args.get("count") or 1)])
        elif act == "delete" and args.get("eventId"):
            invoke_hook_cli(["delete", str(args.get("eventId"))])
        elif act == "clear-cooldown":
            invoke_hook_cli(["clear-cooldown"])
        elif act == "config":
            settings = args.get("settings") or {}
            pairs = ["config"] + [f"{k}={v}" for k, v in settings.items()]
            if len(pairs) > 1:
                invoke_hook_cli(pairs)
        elif act == "calibrate":
            invoke_hook_cli(["calibrate", str(args.get("resetText") or "5h 0m")])
        elif act == "reset":
            invoke_hook_cli(["reset"])
        snap = get_snapshot()
        return {
            "content": [{"type": "text", "text": format_summary(snap)}],
            "structuredContent": snap,
        }
    return {"isError": True, "content": [{"type": "text", "text": f"Unknown tool: {name}"}]}


def main() -> None:
    for line in sys.stdin:
        if not line.strip():
            continue
        try:
            req = json.loads(line)
        except Exception:
            continue
        has_id = "id" in req
        req_id = req.get("id")
        method = str(req.get("method") or "")
        params = req.get("params") or {}

        try:
            if method == "initialize":
                proto = str(params.get("protocolVersion") or "2025-03-26")
                send_result(req_id, {
                    "protocolVersion": proto,
                    "capabilities": {
                        "tools": {"listChanged": False},
                        "resources": {"subscribe": False, "listChanged": False},
                    },
                    "serverInfo": {"name": "image-quota-tracker", "version": "0.3.0"},
                })
            elif method == "notifications/initialized":
                pass
            elif method == "ping":
                if has_id:
                    send_result(req_id, {})
            elif method == "tools/list":
                send_result(req_id, {"tools": tools_list()})
            elif method == "tools/call":
                res = handle_tool_call(str(params.get("name") or ""), params.get("arguments") or {})
                send_result(req_id, res)
            elif method == "resources/list":
                send_result(req_id, {
                    "resources": [{
                        "uri": APP_URI,
                        "name": "Image Quota Dashboard",
                        "description": "Interactive visual dashboard for Antigravity Image Quota Tracker",
                        "mimeType": "text/html;profile=mcp-app",
                        "_meta": {"ui": {"prefersBorder": False}},
                    }]
                })
            elif method == "resources/read":
                uri = str(params.get("uri") or "")
                if uri == APP_URI and DASHBOARD_HTML.is_file():
                    send_result(req_id, {
                        "contents": [{
                            "uri": APP_URI,
                            "mimeType": "text/html;profile=mcp-app",
                            "text": DASHBOARD_HTML.read_text(encoding="utf-8"),
                            "_meta": {"ui": {"prefersBorder": False}},
                        }]
                    })
                else:
                    send_error(req_id, -32602, f"Resource not found: {uri}")
            elif has_id:
                send_error(req_id, -32601, f"Method not found: {method}")
        except Exception as exc:
            if has_id:
                send_error(req_id, -32603, str(exc))


if __name__ == "__main__":
    main()
