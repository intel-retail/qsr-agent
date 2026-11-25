# SPDX-FileCopyrightText: (C) 2026 Intel Corporation
# SPDX-License-Identifier: Apache-2.0
"""Operator answers never expose tool names or call syntax."""

from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class AnswerToolReferenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls._tmp = tempfile.TemporaryDirectory()
        cls._env = patch.dict("os.environ", {
            "QSR_AUTONOMY_DB": str(Path(cls._tmp.name) / "state.db"),
            "QSR_AUTONOMY_MODULES": "",
            "QSR_WARMUP": "false",
        })
        cls._env.start()
        spec = importlib.util.spec_from_file_location("qsr_answer_test", "operator-ui/app.py")
        cls.app = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.app)

    @classmethod
    def tearDownClass(cls):
        cls.app.AUTONOMY.store.close()
        cls._env.stop()
        cls._tmp.cleanup()

    def test_drops_the_sentence_that_names_a_tool(self):
        answer = ("Job ID: e57d1caf\nDeployment is in progress. Services are starting in order. "
                  'Check status with `mcp__deployer__get_deployment_status(job_id="e57d1caf")`.')
        self.assertEqual(self.app._normalize_answer(answer),
                         "Job ID: e57d1caf\nDeployment is in progress. Services are starting in order.")

    def test_drops_bare_deployer_tool_names(self):
        self.assertEqual(self.app._normalize_answer("Started. Call get_deployment_status to follow it."), "Started.")

    def test_leaves_normal_answers_unchanged(self):
        answer = "Kiosk queue depth is 4. Wait time is about 6 minutes."
        self.assertEqual(self.app._normalize_answer(answer), answer)

    def test_retries_once_in_a_new_session_when_the_session_is_paused(self):
        app = self.app

        class Gateway:
            def stream_chat(self, session_id, question, style):
                if session_id == "stale":
                    raise app.GatewayError("unknown_execution")
                yield {"event": "assistant.completed", "content": "Signage shows a menu.", "session_id": session_id}

        class Sessions:
            current = "stale"

            def get(self, *args):
                return self.current

            def forget(self, name):
                self.current = "fresh"

            def set(self, name, session_id):
                self.current = session_id

        with patch.object(app, "model_reachable", return_value=True), \
                patch.object(app, "operator_gateway", return_value=Gateway()), \
                patch.object(app, "SESSIONS", Sessions()):
            result = app.ask_hermes("What is on the digital signage?")
        self.assertEqual(result["answer"], "Signage shows a menu.")


if __name__ == "__main__":
    unittest.main()
