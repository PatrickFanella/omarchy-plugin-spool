# SPDX-License-Identifier: AGPL-3.0-only
import json
import os
import sqlite3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from urllib.parse import quote

from bridge import T3Observer, focus_t3


class T3Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        (self.directory / "server-runtime.json").write_text(
            json.dumps({"pid": os.getpid(), "port": 3773})
        )
        (self.directory / "environment-id").write_text("local-env\n")
        self.db = sqlite3.connect(self.directory / "statev2.sqlite")
        self.addCleanup(self.db.close)
        self.db.executescript("""
            CREATE TABLE orchestration_v2_projection_threads (
                thread_id TEXT PRIMARY KEY, title TEXT, payload_json TEXT,
                deleted_at TEXT, archived_at TEXT);
            CREATE TABLE orchestration_v2_projection_runs (
                run_id TEXT PRIMARY KEY, thread_id TEXT, ordinal INTEGER,
                status TEXT, requested_at TEXT, completed_at TEXT, payload_json TEXT);
            CREATE TABLE orchestration_v2_projection_nodes (node_id TEXT, run_id TEXT);
            CREATE TABLE orchestration_v2_projection_runtime_requests (
                thread_id TEXT, node_id TEXT, status TEXT);
            CREATE TABLE orchestration_v2_projection_turn_items (
                turn_item_id TEXT, thread_id TEXT, run_id TEXT, type TEXT,
                ordinal INTEGER, updated_at TEXT, payload_json TEXT);
        """)
        self.observer = T3Observer(self.directory)

    def thread(
        self,
        id="a",
        status="running",
        visited=None,
        settled=None,
        archived=None,
        relation=None,
    ):
        payload = {
            "lastVisitedAt": visited,
            "settledOverride": settled,
            "lineage": {"relationshipToParent": relation},
        }
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_threads VALUES (?,?,?,?,?)",
            (id, "Task " + id, json.dumps(payload), None, archived),
        )
        self.add_run(id, id + "-run", 1, status)

    def add_run(self, thread, id, ordinal, status):
        requested = "2026-10-04T20:00:00Z"
        completed = (
            "2026-10-04T20:01:00Z"
            if status in {"completed", "failed", "cancelled"}
            else None
        )
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_runs VALUES (?,?,?,?,?,?,?)",
            (
                id,
                thread,
                ordinal,
                status,
                requested,
                completed,
                json.dumps(
                    {
                        "requestedAt": requested,
                        "providerInstanceId": "codex",
                        "modelSelection": {"model": "gpt-6.1-sol"},
                    }
                ),
            ),
        )
        self.db.commit()

    def item(
        self, text, type="assistant_message", ordinal=1, run="a-run", stream="summary"
    ):
        id = "turn-item:provider:codex:native-item:" + quote(
            json.dumps(["turn", "item", stream, 0])
        )
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_turn_items VALUES (?,?,?,?,?,?,?)",
            (
                id,
                "a",
                run,
                type,
                ordinal,
                "2026-10-04T20:02:00Z",
                json.dumps({"text": text}),
            ),
        )
        self.db.commit()

    def test_changing_current_run_text_excludes_raw_reasoning_and_prompts(self):
        self.thread()
        self.item("Checking the API", "reasoning")
        self.assertEqual(
            self.observer.sample()["tasks"][0]["progressText"], "Checking the API"
        )
        self.item("Running the tests", ordinal=2)
        self.item("raw reasoning", "reasoning", 3, stream="raw")
        self.item("private prompt", "user_message", 4)
        self.item("private output", "command_execution", 5)
        self.assertEqual(
            self.observer.sample()["tasks"][0]["progressText"], "Running the tests"
        )

    def test_long_progress_and_provider_metadata(self):
        self.thread()
        self.item("More progress. " * 100)
        task = self.observer.sample()["tasks"][0]
        self.assertGreater(len(task["progressText"]), 300)
        self.assertGreater(task["progressUpdatedAt"], task["updatedAt"])
        self.assertEqual(task["provider"], "codex")
        self.assertEqual(task["model"], "gpt-6.1-sol")

    def test_new_run_does_not_reuse_previous_turn_text_or_pending_request(self):
        self.thread()
        self.item("Old progress")
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_nodes VALUES ('old-node','a-run')"
        )
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('a','old-node','pending')"
        )
        self.add_run("a", "new-run", 2, "running")
        task = self.observer.sample()["tasks"][0]
        self.assertEqual(task["state"], "running")
        self.assertEqual(task["progressText"], "")

    def test_current_pending_input_is_waiting(self):
        self.thread()
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_nodes VALUES ('node','a-run')"
        )
        self.db.execute(
            "INSERT INTO orchestration_v2_projection_runtime_requests VALUES ('a','node','pending')"
        )
        self.db.commit()
        self.assertEqual(self.observer.sample()["state"], "waiting")

    def test_review_and_failure_clear_when_visited_settled_or_archived(self):
        self.thread("unread", "completed")
        self.thread("failed", "failed")
        self.thread("read", "completed", visited="2026-10-04T20:02:00Z")
        self.thread("settled", "completed", settled="settled")
        self.thread("archived", archived="2026-10-04T20:02:00Z")
        self.thread("child", relation="subagent")
        self.thread("cancelled", "cancelled")
        result = self.observer.sample()
        self.assertEqual(
            result["counts"], {"waiting": 0, "failed": 1, "running": 0, "review": 1}
        )
        self.assertEqual({t["id"] for t in result["tasks"]}, {"unread", "failed"})

    def test_read_completion_has_preview_only_in_recent(self):
        self.thread(status="completed", visited="2026-10-04T20:02:00Z")
        self.item("Completed successfully. " * 30)
        self.item("raw thoughts", "reasoning", ordinal=2, stream="raw")
        result = self.observer.sample()
        self.assertEqual(result["tasks"], [])
        self.assertEqual(len(result["recentTasks"]), 1)
        recent = result["recentTasks"][0]
        self.assertEqual(len(recent["completionPreview"]), 240)
        self.assertTrue(
            recent["completionPreview"].startswith("Completed successfully.")
        )
        self.assertEqual(recent["progressText"], "")

    def test_click_focuses_existing_t3_window(self):
        clients = [
            {"class": "vivaldi-stable", "address": "0x1"},
            {"class": "com.t3tools.T3Code", "address": "0x2"},
        ]
        with (
            patch("bridge.subprocess.check_output", return_value=json.dumps(clients)),
            patch("bridge.subprocess.run") as run,
        ):
            focus_t3()
        run.assert_called_once_with(
            ["hyprctl", "dispatch", 'hl.dsp.focus({window="address:0x2"})'], check=True
        )

    def test_missing_t3_window_does_not_launch_browser_or_create_chat(self):
        with (
            patch("bridge.subprocess.check_output", return_value="[]"),
            patch("bridge.subprocess.run") as run,
        ):
            with self.assertRaises(RuntimeError):
                focus_t3()
        run.assert_not_called()

    def test_missing_database_is_not_created(self):
        missing = self.directory / "missing"
        missing.mkdir()
        (missing / "server-runtime.json").write_text(json.dumps({"pid": os.getpid()}))
        with self.assertRaises(sqlite3.Error):
            T3Observer(missing).sample()
        self.assertFalse((missing / "statev2.sqlite").exists())

    def test_sample_does_not_write_database(self):
        self.thread()
        before = (self.directory / "statev2.sqlite").read_bytes()
        self.observer.sample()
        self.assertEqual((self.directory / "statev2.sqlite").read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
