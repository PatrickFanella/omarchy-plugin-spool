# SPDX-License-Identifier: AGPL-3.0-only
import json
import socket
import struct
import threading
import unittest

from bridge import (
    MAX_FRAME,
    MAX_PROGRESS_CHARS,
    AppTools,
    Observer,
    progress_text,
    summarize,
)


def entry(id="a", status="active", unread=False, kind="codex", host="local"):
    return {
        "id": id,
        "status": status,
        "isUnread": unread,
        "kind": kind,
        "hostId": host,
        "updatedAt": 10,
    }


class StateTests(unittest.TestCase):
    def test_waiting_dominates_other_activity(self):
        entries = [entry(), entry("b", "active"), entry("c", "idle", True)]
        details = {
            ("codex", "local", "b"): {
                "thread": {
                    "status": {"type": "active", "activeFlags": ["waitingOnUserInput"]}
                }
            }
        }
        result = summarize(entries, details)
        self.assertEqual(result["state"], "waiting")
        self.assertEqual(
            result["counts"], {"waiting": 1, "failed": 0, "running": 1, "review": 1}
        )
        self.assertEqual(result["tasks"][0]["id"], "b")

    def test_unread_completion_precedes_running_without_hiding_it(self):
        result = summarize([entry("done", "idle", True), entry("busy")])
        self.assertEqual(result["state"], "review")
        self.assertEqual([t["id"] for t in result["tasks"]], ["done", "busy"])

    def test_pet_priority_matches_input_blocked_ready_running(self):
        result = summarize(
            [
                entry("busy"),
                entry("ready", "idle", True),
                entry("blocked", "failed"),
                entry("input", "waiting"),
            ]
        )
        self.assertEqual(
            [t["id"] for t in result["tasks"]], ["input", "blocked", "ready", "busy"]
        )

    def test_read_completion_and_unloaded_are_idle(self):
        self.assertEqual(
            summarize([entry(status="idle"), entry("old", "notLoaded")])["state"],
            "idle",
        )

    def test_duplicate_pin_and_recent_item_count_once(self):
        a = entry()
        self.assertEqual(summarize([a, a])["counts"]["running"], 1)

    def test_chatgpt_completion_is_review(self):
        result = summarize(
            [entry(status="idle", unread=True, kind="chatgpt", host=None)]
        )
        self.assertEqual(result["state"], "review")

    def test_failed_task_is_visible(self):
        result = summarize([entry(status="systemError")])
        self.assertEqual(result["state"], "failed")

    def test_adapter_excludes_tool_output_and_wave_only_on_real_completion(self):
        class Client:
            entries = [entry()]
            calls = []

            def call(self, tool, args):
                self.calls.append((tool, args))
                if tool == "list_threads":
                    return {"threads": self.entries}
                return {
                    "thread": {
                        "status": {"type": self.entries[0]["status"], "activeFlags": []}
                    }
                }

        client = Client()
        observer = Observer(client)
        self.assertEqual(observer.sample()["state"], "running")
        self.assertEqual(
            client.calls[-1][1]["maxOutputCharsPerItem"], MAX_PROGRESS_CHARS
        )
        self.assertFalse(client.calls[-1][1]["includeOutputs"])
        client.entries = [entry(status="idle")]
        self.assertEqual(observer.sample()["state"], "waving")
        client.entries = []
        observer.wave_until = 0
        self.assertEqual(observer.sample()["state"], "idle")

    def test_progress_changes_between_samples_and_clears_on_completion(self):
        class Client:
            text = "Checking the API"
            status = "active"

            def call(self, tool, args):
                if tool == "list_threads":
                    return {"threads": [entry(status=self.status, unread=True)]}
                return {
                    "thread": {"status": self.status},
                    "turns": [
                        {
                            "items": [
                                {
                                    "type": "agentMessage",
                                    "phase": "commentary",
                                    "text": self.text,
                                }
                            ]
                        }
                    ],
                }

        client = Client()
        observer = Observer(client)
        self.assertEqual(
            observer.sample()["tasks"][0]["progressText"], "Checking the API"
        )
        client.text = "Running the checks"
        self.assertEqual(observer.sample()["tasks"][0]["progressText"], client.text)
        client.status = "idle"
        result = observer.sample()
        self.assertEqual(result["state"], "review")
        self.assertNotIn("progressText", result["tasks"][0])

    def test_active_reads_take_priority_over_unread_and_duplicate_pins(self):
        class Client:
            calls = []

            def call(self, tool, args):
                if tool == "list_threads":
                    return {
                        "pinnedThreads": [entry("busy")] * 8,
                        "threads": [entry(str(i), "idle", True) for i in range(10)]
                        + [entry("other")],
                    }
                self.calls.append(args["threadId"])
                return {}

        client = Client()
        Observer(client).sample()
        self.assertEqual(client.calls[:2], ["busy", "other"])
        self.assertEqual(len(client.calls), 8)

    def test_detail_timeout_preserves_listed_activity(self):
        class Client:
            closed = False

            def call(self, name, args):
                if name == "list_threads":
                    return {"threads": [entry("busy")]}
                raise TimeoutError("slow preview")

            def close(self):
                self.closed = True

        client = Client()
        result = Observer(client).sample()
        self.assertTrue(result["connected"])
        self.assertEqual(result["tasks"][0]["id"], "busy")
        self.assertTrue(client.closed)


class ProgressTests(unittest.TestCase):
    def test_latest_public_update_ignores_user_tool_and_raw_reasoning(self):
        detail = {
            "turns": [
                {
                    "items": [
                        {"type": "userMessage", "text": "private prompt"},
                        {
                            "type": "reasoning",
                            "summary": [{"text": "Checking options"}],
                            "content": "raw reasoning",
                        },
                        {
                            "type": "agentMessage",
                            "phase": "commentary",
                            "text": "Testing\n the change",
                        },
                        {"type": "commandExecution", "output": "private tool output"},
                        {"type": "reasoning", "content": "raw reasoning"},
                    ]
                }
            ]
        }
        self.assertEqual(progress_text(detail), "Testing the change")

    def test_reasoning_summary_and_chatgpt_assistant_message(self):
        for item in (
            {"type": "reasoning", "summary": ["Checking the result"]},
            {"type": "agentMessage", "text": "Checking the result"},
        ):
            self.assertEqual(
                progress_text({"turns": [{"items": [item]}]}), "Checking the result"
            )

    def test_no_old_turn_final_answer_or_completed_text(self):
        old = {"items": [{"type": "agentMessage", "text": "Old update"}]}
        self.assertEqual(progress_text({"turns": [{"items": []}, old]}), "")
        self.assertEqual(
            progress_text(
                {
                    "turns": [
                        {
                            "items": [
                                {
                                    "type": "agentMessage",
                                    "phase": "final_answer",
                                    "text": "Done",
                                }
                            ]
                        }
                    ]
                }
            ),
            "",
        )
        self.assertEqual(progress_text({"turns": [{**old, "status": "completed"}]}), "")

    def test_text_is_bounded(self):
        self.assertEqual(
            len(
                progress_text(
                    {
                        "turns": [
                            {
                                "items": [
                                    {
                                        "type": "agentMessage",
                                        "text": "a" * (MAX_PROGRESS_CHARS + 1000),
                                    }
                                ]
                            }
                        ]
                    }
                )
            ),
            MAX_PROGRESS_CHARS,
        )


class TransportTests(unittest.TestCase):
    def test_fragmented_native_response(self):
        client = AppTools("origin")
        client.sock, peer = socket.socketpair()
        client.sock.settimeout(1)

        def respond():
            header = peer.recv(4)
            size = struct.unpack("<I", header)[0]
            request = json.loads(peer.recv(size))
            result = json.dumps(
                {"jsonrpc": "2.0", "id": request["id"], "result": {"ok": True}}
            ).encode()
            frame = struct.pack("<I", len(result)) + result
            for byte in frame:
                peer.send(bytes([byte]))
            peer.close()

        worker = threading.Thread(target=respond)
        worker.start()
        try:
            self.assertEqual(client.request("tools/list"), {"ok": True})
        finally:
            client.close()
            worker.join()

    def test_expired_sample_deadline_rejects_even_a_connected_socket(self):
        client = AppTools("origin")
        client.sock, peer = socket.socketpair()
        client.deadline = 0.001
        try:
            with self.assertRaises(TimeoutError):
                client.request("tools/list")
        finally:
            client.close()
            peer.close()

    def test_oversized_response_is_rejected(self):
        client = AppTools("origin")
        client.sock, peer = socket.socketpair()
        peer.sendall(struct.pack("<I", MAX_FRAME + 1))
        try:
            with self.assertRaises(ValueError):
                client.request("tools/list")
        finally:
            client.close()
            peer.close()

    def test_other_app_operations_are_rejected(self):
        client = AppTools("origin")
        with self.assertRaises(ValueError):
            client.call("send_message_to_thread", {})


if __name__ == "__main__":
    unittest.main()
