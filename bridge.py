#!/usr/bin/env python3
"""Read desktop task metadata and publish pet states as JSON lines."""
import argparse
import json
import os
from pathlib import Path
import socket
import stat
import struct
import sys
import time
import uuid

MAX_FRAME = 8 * 1024 * 1024
STATES = {"idle", "running", "waiting", "failed", "review", "waving"}


class AppTools:
    def __init__(self, origin_thread, pipe=None):
        self.origin_thread = origin_thread
        self.pipe = pipe
        self.sock = None
        self.request_id = 0

    def close(self):
        if self.sock:
            self.sock.close()
        self.sock = None

    def _read(self, length):
        data = bytearray()
        while len(data) < length:
            part = self.sock.recv(length - len(data))
            if not part:
                raise ConnectionError("desktop disconnected")
            data.extend(part)
        return bytes(data)

    def request(self, method, params=None):
        self.request_id += 1
        message = {"id": self.request_id, "jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        payload = json.dumps(message).encode()
        self.sock.sendall(struct.pack("<I", len(payload)) + payload)
        length = struct.unpack("<I", self._read(4))[0]
        if length > MAX_FRAME:
            raise ValueError("desktop response exceeds limit")
        response = json.loads(self._read(length))
        if response.get("id") != self.request_id:
            raise ValueError("desktop response ID mismatch")
        if "error" in response:
            raise RuntimeError("desktop tool request failed")
        return response["result"]

    def connect(self):
        if self.sock is not None:
            return
        paths = []
        for explicit in (self.pipe, os.environ.get("CODEX_APP_TOOLS_PIPE_PATH")):
            if explicit:
                paths.append(Path(explicit))
        directory = Path("/tmp/codex-browser-use")
        if directory.exists():
            paths.extend(sorted(directory.glob("*.sock"), key=lambda p: p.stat().st_mtime, reverse=True))
        for path in dict.fromkeys(paths):
            try:
                info = path.lstat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                    continue
                self.sock = socket.socket(socket.AF_UNIX)
                self.sock.settimeout(5)
                self.sock.connect(str(path))
                tools = self.request("tools/list", {"threadStartKind": "all"})
                if not any(t.get("name") == "list_threads" and t.get("namespace") == "codex_app" for t in tools.get("tools", [])):
                    raise ValueError("not a desktop task endpoint")
                return
            except (OSError, ValueError, RuntimeError, KeyError):
                self.close()
        raise ConnectionError("desktop task endpoint unavailable")

    def call(self, tool, arguments):
        # This adapter has only three operations: two reads and explicit click-to-open.
        if tool not in {"list_threads", "read_thread", "navigate_to_codex_page"}:
            raise ValueError("unsupported adapter operation")
        self.connect()
        result = self.request("tools/call", {
            "namespace": "codex_app", "tool": tool, "arguments": arguments,
            "threadId": self.origin_thread, "hostId": "local", "callerSource": "codex",
            "turnId": "spool-bridge-" + str(uuid.uuid4()),
            "callId": "spool-bridge-" + str(uuid.uuid4())
        })
        if not result.get("success"):
            raise RuntimeError("desktop declined the operation")
        if tool == "navigate_to_codex_page":
            return result
        texts = [item["text"] for item in result.get("contentItems", []) if item.get("type") == "inputText"]
        for text in texts:
            try:
                return json.loads(text)
            except ValueError:
                pass
        raise ValueError("desktop returned no structured result")


def task_state(entry, detail=None):
    status = (detail or {}).get("thread", {}).get("status", entry.get("status"))
    flags = []
    if isinstance(status, dict):
        flags = status.get("activeFlags", [])
        status = status.get("type")
    if status in {"active", "running", "inProgress"}:
        if any(any(word in str(flag).lower() for word in ("approval", "input", "permission")) for flag in flags):
            return "waiting"
        return "running"
    if status in {"waiting", "needsAttention", "requires_action"}:
        return "waiting"
    if status in {"failed", "error", "systemError"}:
        return "failed"
    if entry.get("isUnread") and status == "idle":
        return "review"
    return "idle"


def summarize(entries, details=None):
    details = details or {}
    tasks = []
    seen = set()
    for entry in entries:
        key = (entry.get("kind"), entry.get("hostId"), entry.get("id"))
        if not entry.get("id") or key in seen:
            continue
        seen.add(key)
        state = task_state(entry, details.get(key))
        if state != "idle":
            tasks.append({"id": entry["id"], "hostId": entry.get("hostId"), "kind": entry.get("kind"), "state": state, "updatedAt": entry.get("updatedAt") or 0})
    priority = {"waiting": 0, "failed": 1, "running": 2, "review": 3}
    tasks.sort(key=lambda task: (priority[task["state"]], -task["updatedAt"]))
    counts = {state: sum(task["state"] == state for task in tasks) for state in priority}
    return {"state": tasks[0]["state"] if tasks else "idle", "connected": True,
            "source": "desktop-app", "counts": counts, "tasks": tasks}


class Observer:
    def __init__(self, client):
        self.client = client
        self.previous_running = set()
        self.wave_until = 0

    def sample(self):
        listing = self.client.call("list_threads", {"limit": 50})
        entries = listing.get("pinnedThreads", []) + listing.get("threads", [])
        details = {}
        candidates = [e for e in entries if e.get("status") == "active" or e.get("isUnread")]
        # Bounded reads obtain approval/input flags without fetching tool output.
        for entry in candidates[:8]:
            args = {"threadId": entry["id"], "turnLimit": 1, "includeOutputs": False, "maxOutputCharsPerItem": 0}
            if entry.get("hostId"):
                args["hostId"] = entry["hostId"]
            try:
                detail = self.client.call("read_thread", args)
                details[(entry.get("kind"), entry.get("hostId"), entry["id"])] = detail
            except (RuntimeError, ValueError):
                pass
        result = summarize(entries, details)
        running = {(t["kind"], t["hostId"], t["id"]) for t in result["tasks"] if t["state"] in {"running", "waiting"}}
        present = {(e.get("kind"), e.get("hostId"), e.get("id")): e for e in entries}
        completed = [present[key] for key in self.previous_running - running if key in present and present[key].get("status") == "idle"]
        if completed:
            self.wave_until = time.monotonic() + 3
        self.previous_running = running
        if result["state"] == "idle" and time.monotonic() < self.wave_until:
            result["state"] = "waving"
        result["unavailableSources"] = listing.get("unavailableSources", [])
        result["sampledAt"] = int(time.time() * 1000)
        return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--origin-thread", required=True)
    parser.add_argument("--pipe")
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--open", dest="open_thread")
    args = parser.parse_args()
    client = AppTools(args.origin_thread, args.pipe)
    observer = Observer(client)
    try:
        if args.open_thread:
            client.call("navigate_to_codex_page", {"threadId": args.open_thread})
            return
        while True:
            start = time.monotonic()
            try:
                result = observer.sample()
            except (OSError, RuntimeError, ValueError, KeyError):
                client.close()
                observer.previous_running.clear()
                observer.wave_until = 0
                result = {"state": "idle", "connected": False, "source": "desktop-app", "counts": {}, "tasks": [], "sampledAt": int(time.time() * 1000)}
            print(json.dumps(result, separators=(",", ":")), flush=True)
            if args.once:
                break
            time.sleep(max(.1, max(2, args.interval) - (time.monotonic() - start)))
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        client.close()


if __name__ == "__main__":
    main()
