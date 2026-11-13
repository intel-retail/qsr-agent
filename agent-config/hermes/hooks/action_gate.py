#!/usr/bin/env python3
"""Hermes shell hook: state-changing MCP tools run only on an explicit operator command.

A local model sometimes answers "would a carrot ad be a good idea?" by actually switching the
live signage. This hook enforces the rule in code instead of in the prompt:

* ``pre_llm_call`` records whether the operator's message is an explicit command
  (imperative request, or a short confirmation such as "yes, do it"). Questions,
  conditionals and anything unrecognised are not commands.
* ``pre_tool_call`` blocks every MCP tool that is not recognisably read-only unless the
  current turn was recorded as a command. No record means blocked (fail closed).

Read-only tools are recognised by their verb prefix (get_, list_, query_, ...). A new tool with
another verb is treated as state-changing until it is added to READ_ONLY_TOOL.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import time
from pathlib import Path

STATE_TTL_SECONDS = 3600

READ_ONLY_TOOL = re.compile(
    r"(get|list|query|compare|describe|search|find|fetch|read|lookup|check|count|summari[sz]e|analy[sz]e|"
    r"estimate|forecast)(_|$)")

COMMAND_VERBS = frozenset(
    "show display trigger play run switch select clear remove stop cancel mark set inject start put use "
    "change turn push reset dismiss activate deactivate enable disable end revert restore release simulate "
    "flag post send replace override promote publish".split())

LEADING_FILLER = re.compile(r"^(?:(?:please|kindly|now|ok|okay|hey|then|just|and)[\s,]+)+")
POLITE_REQUEST = re.compile(r"^(?:can|could|would|will) you (?:please )?(\w+)\b")
CONFIRMATION = re.compile(
    r"(?:yes|yeah|yep|yup|sure|ok|okay|confirm|confirmed|approve|approved|proceed|go ahead|do it|go for it|"
    r"sounds good)(?:[\s,.!]+(?:please|do it|go ahead|proceed|confirm|thanks|thank you))*[\s.!]*")
CONDITIONAL = re.compile(r"\b(?:if|whether)\b")


def is_command(message: object) -> bool:
    if not isinstance(message, str):
        return False
    text = " ".join(message.lower().split())
    if not text or len(text) > 400 or CONDITIONAL.search(text):
        return False
    polite = POLITE_REQUEST.match(LEADING_FILLER.sub("", text))
    if polite:
        return polite.group(1) in COMMAND_VERBS and text.count("?") <= 1 and text.endswith(("?", ".", "!"))
    if "?" in text:
        return False
    text = LEADING_FILLER.sub("", text)
    if CONFIRMATION.fullmatch(text):
        return True
    return text.split(" ", 1)[0].strip(",.!") in COMMAND_VERBS


def is_read_only(tool_name: str) -> bool:
    return bool(READ_ONLY_TOOL.match(tool_name.rsplit("__", 1)[-1]))


def _state_file(session_id: str) -> Path:
    root = os.environ.get("QSR_ACTION_GATE_DIR")
    base = Path(root) if root else Path(os.environ.get("HERMES_HOME") or Path.home() / ".hermes") / "qsr-action-gate"
    return base / (hashlib.sha256(session_id.encode()).hexdigest()[:32] + ".json")


def record_turn(payload: dict) -> None:
    extra = payload.get("extra") or {}
    path = _state_file(str(payload.get("session_id") or ""))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({
        "command": is_command(extra.get("user_message")),
        "turn_id": str(extra.get("turn_id") or ""),
        "at": time.time(),
    }))


def decide(payload: dict) -> dict | None:
    tool = str(payload.get("tool_name") or "")
    if is_read_only(tool):
        return None
    extra = payload.get("extra") or {}
    try:
        record = json.loads(_state_file(str(payload.get("session_id") or "")).read_text())
    except (OSError, ValueError):
        record = {}
    turn_id = str(extra.get("turn_id") or "")
    current = (
        record.get("command") is True
        and time.time() - float(record.get("at") or 0) < STATE_TTL_SECONDS
        and (not turn_id or not record.get("turn_id") or turn_id == record["turn_id"])
    )
    if current:
        return None
    return {"action": "block", "message": (
        f"Blocked: {tool.rsplit('__', 1)[-1]} changes live state, and the operator's message was a "
        "question rather than an explicit command. Do not call it and do not retry. Answer from the "
        "read-only tools, say what you would do, and tell the operator to confirm with a command such "
        "as 'Show a carrot ad' or 'Clear the override ad'.")}


def main() -> int:
    payload = json.loads(sys.stdin.read() or "{}")
    event = payload.get("hook_event_name")
    try:
        if event == "pre_llm_call":
            record_turn(payload)
        elif event == "pre_tool_call":
            verdict = decide(payload)
            if verdict:
                print(json.dumps(verdict))
                return 0
    except Exception as exc:  # a broken gate must not let a state-changing tool through
        if event == "pre_tool_call" and not is_read_only(str(payload.get("tool_name") or "")):
            print(json.dumps({"action": "block", "message": f"Blocked: action gate error ({exc})."}))
            return 0
    print("{}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
