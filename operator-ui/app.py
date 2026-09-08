#!/usr/bin/env python3
"""Minimal operator chat UI backend for the QSR agent (stdlib only).

Serves a single-page chat UI and forwards each operator question to the Hermes
agent via `hermes -z`, reusing the exact path verified on the CLI. No web
framework and no pip installs, so it runs anywhere the agent runs.

Run:
    python3 operator-ui/app.py            # then open http://127.0.0.1:8600
Environment:
    QSR_UI_HOST   bind host   (default 127.0.0.1)
    QSR_UI_PORT   bind port   (default 8600)
    HERMES_BIN    hermes path (default ~/.local/bin/hermes)
    HERMES_TIMEOUT  per-question seconds (default 300)
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HOST = os.environ.get("QSR_UI_HOST", "127.0.0.1")
PORT = int(os.environ.get("QSR_UI_PORT", "8600"))
HERMES_BIN = os.environ.get("HERMES_BIN", os.path.expanduser("~/.local/bin/hermes"))
HERMES_TIMEOUT = float(os.environ.get("HERMES_TIMEOUT", "300"))

_INDEX_PATH = Path(__file__).parent / "static" / "index.html"


def _resolve_hermes() -> str | None:
    if os.path.isfile(HERMES_BIN) and os.access(HERMES_BIN, os.X_OK):
        return HERMES_BIN
    return shutil.which("hermes")


def _agent_env(hermes: str) -> dict:
    env = os.environ.copy()
    env["PATH"] = os.path.dirname(hermes) + os.pathsep + env.get("PATH", "")
    # Loopback must bypass any corporate proxy or the OVMS call fails with 403.
    env["NO_PROXY"] = "localhost,127.0.0.1,::1"
    env["no_proxy"] = "localhost,127.0.0.1,::1"
    return env


_ANSI = re.compile(r"\x1b\[[0-9;]*m")


def list_servers() -> dict:
    """Return the MCP services Hermes is connected to (enabled registrations)."""
    hermes = _resolve_hermes()
    if not hermes:
        return {"ok": False, "servers": [], "count": 0, "error": "hermes not found"}
    try:
        proc = subprocess.run(
            [hermes, "mcp", "list"],
            capture_output=True,
            text=True,
            timeout=30,
            stdin=subprocess.DEVNULL,
            env=_agent_env(hermes),
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "servers": [], "count": 0, "error": "mcp list timed out"}

    servers: list[str] = []
    for line in (proc.stdout or "").splitlines():
        line = _ANSI.sub("", line)
        if "enabled" not in line:
            continue
        cleaned = line.replace("│", " ").replace("✓", " ").strip()
        parts = cleaned.split()
        if not parts or parts[0].lower() == "name":
            continue
        servers.append(parts[0])
    return {"ok": True, "servers": servers, "count": len(servers)}


_STATUS_CACHE: dict[str, object] = {"ts": 0.0, "data": {}}
_STATUS_TTL = 15.0
_TOOLS_RE = re.compile(r"Tools discovered:\s*(\d+)")


def check_status(force: bool = False) -> dict:
    """Per-service reachability via `hermes mcp test`, cached to avoid hammering."""
    import time

    now = time.monotonic()
    if not force and (now - float(_STATUS_CACHE["ts"])) < _STATUS_TTL:
        return {"ok": True, "services": _STATUS_CACHE["data"]}  # type: ignore[dict-item]

    hermes = _resolve_hermes()
    if not hermes:
        return {"ok": False, "services": {}, "error": "hermes not found"}

    env = _agent_env(hermes)
    result: dict[str, dict] = {}
    for name in list_servers().get("servers", []):
        try:
            proc = subprocess.run(
                [hermes, "mcp", "test", name],
                capture_output=True,
                text=True,
                timeout=20,
                stdin=subprocess.DEVNULL,
                env=env,
            )
            out = _ANSI.sub("", proc.stdout or "")
            connected = "Connected" in out
            m = _TOOLS_RE.search(out)
            result[name] = {"ok": connected, "tools": int(m.group(1)) if m else 0}
        except subprocess.TimeoutExpired:
            result[name] = {"ok": False, "tools": 0}

    _STATUS_CACHE["ts"] = now
    _STATUS_CACHE["data"] = result
    return {"ok": True, "services": result}


def ask_hermes(question: str) -> dict:
    """Run one non-interactive Hermes turn and return its answer text."""
    hermes = _resolve_hermes()
    if not hermes:
        return {"ok": False, "error": "hermes binary not found"}

    env = _agent_env(hermes)

    try:
        proc = subprocess.run(
            [hermes, "-z", question],
            capture_output=True,
            text=True,
            timeout=HERMES_TIMEOUT,
            stdin=subprocess.DEVNULL,
            env=env,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": f"Hermes timed out after {HERMES_TIMEOUT:.0f}s"}

    answer = (proc.stdout or "").strip()
    if not answer and proc.returncode != 0:
        return {"ok": False, "error": (proc.stderr or "Hermes returned no output").strip()[:2000]}
    return {"ok": True, "answer": answer or "(no answer)"}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/index.html"):
            self._send(200, _INDEX_PATH.read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/health":
            self._send(200, b'{"status":"ok"}', "application/json")
        elif self.path == "/servers":
            body = json.dumps(list_servers()).encode("utf-8")
            self._send(200, body, "application/json")
        elif self.path == "/status" or self.path == "/status?force=1":
            body = json.dumps(check_status(force=self.path.endswith("force=1"))).encode("utf-8")
            self._send(200, body, "application/json")
        else:
            self._send(404, b"not found", "text/plain; charset=utf-8")

    def do_POST(self) -> None:  # noqa: N802
        if self.path != "/ask":
            self._send(404, b'{"ok":false,"error":"not found"}', "application/json")
            return
        length = int(self.headers.get("Content-Length", "0") or "0")
        raw = self.rfile.read(length) if length else b"{}"
        try:
            question = (json.loads(raw or b"{}").get("question") or "").strip()
        except json.JSONDecodeError:
            self._send(400, b'{"ok":false,"error":"invalid JSON"}', "application/json")
            return
        if not question:
            self._send(400, b'{"ok":false,"error":"empty question"}', "application/json")
            return
        result = ask_hermes(question)
        self._send(200, json.dumps(result).encode("utf-8"), "application/json")

    def log_message(self, *_args) -> None:  # keep stdout clean
        pass


def main() -> None:
    if not _resolve_hermes():
        print(f"WARNING: hermes not found at {HERMES_BIN} or on PATH")
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Operator UI on http://{HOST}:{PORT}  (Ctrl-C to stop)")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
