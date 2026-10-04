import json
import socket
import struct
import threading
import unittest
from unittest.mock import patch

from bridge import AppTools, MAX_FRAME, Observer, summarize


def entry(id="a", status="active", unread=False, kind="codex", host="local"):
    return {"id": id, "status": status, "isUnread": unread, "kind": kind, "hostId": host, "updatedAt": 10}


class StateTests(unittest.TestCase):
    def test_waiting_dominates_other_activity(self):
        entries = [entry(), entry("b", "active"), entry("c", "idle", True)]
        details = {("codex", "local", "b"): {"thread": {"status": {"type": "active", "activeFlags": ["waitingOnUserInput"]}}}}
        result = summarize(entries, details)
        self.assertEqual(result["state"], "waiting")
        self.assertEqual(result["counts"], {"waiting": 1, "failed": 0, "running": 1, "review": 1})
        self.assertEqual(result["tasks"][0]["id"], "b")

    def test_completion_does_not_mask_other_running_task(self):
        self.assertEqual(summarize([entry("done", "idle", True), entry("busy")])["state"], "running")

    def test_read_completion_and_unloaded_are_idle(self):
        self.assertEqual(summarize([entry(status="idle"), entry("old", "notLoaded")])["state"], "idle")

    def test_duplicate_pin_and_recent_item_count_once(self):
        a = entry()
        self.assertEqual(summarize([a, a])["counts"]["running"], 1)

    def test_chatgpt_completion_is_review(self):
        result = summarize([entry(status="idle", unread=True, kind="chatgpt", host=None)])
        self.assertEqual(result["state"], "review")

    def test_failed_task_is_visible(self):
        result = summarize([entry(status="systemError")])
        self.assertEqual(result["state"], "failed")

    def test_adapter_reads_no_output_and_wave_only_on_real_completion(self):
        class Client:
            entries = [entry()]
            calls = []
            def call(self, tool, args):
                self.calls.append((tool, args))
                if tool == "list_threads": return {"threads": self.entries}
                return {"thread": {"status": {"type": self.entries[0]["status"], "activeFlags": []}}}
        client = Client()
        observer = Observer(client)
        self.assertEqual(observer.sample()["state"], "running")
        self.assertEqual(client.calls[-1][1]["maxOutputCharsPerItem"], 0)
        client.entries = [entry(status="idle")]
        self.assertEqual(observer.sample()["state"], "waving")
        client.entries = []
        observer.wave_until = 0
        self.assertEqual(observer.sample()["state"], "idle")


class TransportTests(unittest.TestCase):
    def test_fragmented_native_response(self):
        client = AppTools("origin")
        client.sock, peer = socket.socketpair()
        client.sock.settimeout(1)
        def respond():
            header = peer.recv(4)
            size = struct.unpack("<I", header)[0]
            request = json.loads(peer.recv(size))
            result = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": {"ok": True}}).encode()
            frame = struct.pack("<I", len(result)) + result
            for byte in frame: peer.send(bytes([byte]))
            peer.close()
        worker = threading.Thread(target=respond)
        worker.start()
        try: self.assertEqual(client.request("tools/list"), {"ok": True})
        finally: client.close(); worker.join()

    def test_oversized_response_is_rejected(self):
        client = AppTools("origin")
        client.sock, peer = socket.socketpair()
        peer.sendall(struct.pack("<I", MAX_FRAME + 1))
        try:
            with self.assertRaises(ValueError): client.request("tools/list")
        finally: client.close(); peer.close()

    def test_other_app_operations_are_rejected(self):
        client = AppTools("origin")
        with self.assertRaises(ValueError): client.call("send_message_to_thread", {})


if __name__ == "__main__": unittest.main()
