"""Tests for the Hermes action-gate hook (state-changing MCP tools need an explicit command)."""

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

HOOK = Path("agent-config/hermes/hooks/action_gate.py")
spec = importlib.util.spec_from_file_location("action_gate", HOOK)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

COMMANDS = [
    "Show a carrot ad on the digital signage.",
    "Clear the override ad now.",
    "please trigger the pizza ad",
    "Can you show a banana ad?",
    "Switch to the iced coffee ad",
    "yes",
    "Yes, do it.",
    "go ahead",
]
NOT_COMMANDS = [
    "Would a carrot ad be a good idea right now?",
    "Should we show a banana ad?",
    "Which ad would work best for this weather?",
    "Is it worth showing a pizza ad at lunch?",
    "What ad is showing right now?",
    "Do you think we should clear the ad?",
    "Show a carrot ad if it is cold outside",
    "Show a carrot ad, would that work?",
    "Could you tell me which ad to show?",
    "I wonder whether to show a carrot ad",
    "",
    None,
]


class IntentTests(unittest.TestCase):
    def test_explicit_commands_are_commands(self):
        for message in COMMANDS:
            with self.subTest(message=message):
                self.assertTrue(gate.is_command(message))

    def test_questions_and_conditionals_are_not_commands(self):
        for message in NOT_COMMANDS:
            with self.subTest(message=message):
                self.assertFalse(gate.is_command(message))

    def test_read_only_tools_are_recognised_by_verb(self):
        for tool in ("mcp__digital_signage__get_current_ad", "mcp__digital_signage__describe",
                     "mcp__table_occupancy_service__get_table_history", "mcp__x__query_history",
                     "mcp__store_activity_service__compare_to_baseline"):
            self.assertTrue(gate.is_read_only(tool), tool)
        for tool in ("mcp__digital_signage__select_dynamic_ad", "mcp__digital_signage__trigger_ad",
                     "mcp__digital_signage__clear_ad", "mcp__table_occupancy_service__mark_table_cleared",
                     "mcp__store_activity_service__inject_event", "mcp__x__frobnicate"):
            self.assertFalse(gate.is_read_only(tool), tool)


class HookProcessTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.env = {**os.environ, "QSR_ACTION_GATE_DIR": self.tmp.name}

    def fire(self, payload: dict) -> dict:
        done = subprocess.run([sys.executable, str(HOOK)], input=json.dumps(payload), capture_output=True,
                              text=True, env=self.env, check=True)
        return json.loads(done.stdout)

    def start_turn(self, message: str, session: str = "s1", turn: str = "t1") -> None:
        self.assertEqual(self.fire({"hook_event_name": "pre_llm_call", "session_id": session,
                                    "extra": {"user_message": message, "turn_id": turn}}), {})

    def call(self, tool: str, session: str = "s1", turn: str = "t1") -> dict:
        return self.fire({"hook_event_name": "pre_tool_call", "tool_name": tool, "session_id": session,
                          "extra": {"turn_id": turn}})

    def test_question_blocks_state_changing_tool_but_not_reads(self):
        self.start_turn("Would a carrot ad be a good idea right now?")
        blocked = self.call("mcp__digital_signage__select_dynamic_ad")
        self.assertEqual(blocked["action"], "block")
        self.assertIn("select_dynamic_ad", blocked["message"])
        self.assertEqual(self.call("mcp__digital_signage__get_current_ad"), {})

    def test_command_allows_state_changing_tool(self):
        self.start_turn("Show a carrot ad on the digital signage.")
        self.assertEqual(self.call("mcp__digital_signage__trigger_ad"), {})

    def test_missing_record_fails_closed(self):
        self.assertEqual(self.call("mcp__digital_signage__clear_ad", session="never-seen")["action"], "block")

    def test_next_question_revokes_previous_command(self):
        self.start_turn("Show a carrot ad", turn="t1")
        self.assertEqual(self.call("mcp__digital_signage__trigger_ad", turn="t1"), {})
        self.start_turn("Is that a good ad?", turn="t2")
        self.assertEqual(self.call("mcp__digital_signage__trigger_ad", turn="t2")["action"], "block")

    def test_stale_turn_record_is_not_trusted(self):
        self.start_turn("Show a carrot ad", turn="t1")
        self.assertEqual(self.call("mcp__digital_signage__trigger_ad", turn="t2")["action"], "block")

    def test_sessions_are_isolated(self):
        self.start_turn("Show a carrot ad", session="a")
        self.assertEqual(self.call("mcp__digital_signage__trigger_ad", session="b")["action"], "block")

    def test_expired_record_is_not_trusted(self):
        self.start_turn("Show a carrot ad")
        with patch.dict(os.environ, {"QSR_ACTION_GATE_DIR": self.tmp.name}), \
                patch.object(gate.time, "time", return_value=gate.time.time() + gate.STATE_TTL_SECONDS + 5):
            verdict = gate.decide({"tool_name": "mcp__digital_signage__trigger_ad", "session_id": "s1",
                                   "extra": {"turn_id": "t1"}})
        self.assertEqual(verdict["action"], "block")

    def test_garbage_stdin_does_not_unblock_actions(self):
        done = subprocess.run([sys.executable, str(HOOK)], input="not json", capture_output=True, text=True,
                              env=self.env)
        self.assertNotEqual(done.returncode, 0)


if __name__ == "__main__":
    unittest.main()
