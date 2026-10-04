#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
"""Read desktop task metadata and publish pet states as JSON lines."""

import argparse
import json
import os
import socket
import sqlite3
import stat
import struct
import subprocess
import time
import uuid
from contextlib import closing
from datetime import datetime
from pathlib import Path
from urllib.parse import unquote

MAX_FRAME = 8 * 1024 * 1024
STATES = {"idle", "running", "waiting", "failed", "review", "waving"}
MAX_PROGRESS_CHARS = 6000
DESKTOP_SAMPLE_TIMEOUT = 8
REQUEST_TIMEOUT = 5
MAX_DESKTOP_READS = 8


def timestamp(value):
    if not value:
        return 0
    if isinstance(value, (int, float)):
        return value / 1000 if value > 100_000_000_000 else value
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


class T3Observer:
    """Read T3's local projections in a read-only, short-lived transaction."""

    def __init__(self, directory=None):
        self.directory = Path(directory or Path.home() / ".t3/userdata").expanduser()

    def sample(self):
        runtime = json.loads((self.directory / "server-runtime.json").read_text())
        os.kill(int(runtime["pid"]), 0)
        database = self.directory / "statev2.sqlite"
        tasks, recent = [], []
        with closing(
            sqlite3.connect(
                database.resolve().as_uri() + "?mode=ro", uri=True, timeout=0.5
            )
        ) as db:
            db.row_factory = sqlite3.Row
            db.execute("BEGIN")
            rows = db.execute("""
                SELECT t.thread_id, t.title, t.payload_json AS thread_payload,
                       r.run_id, r.status, r.completed_at, r.payload_json AS run_payload,
                       EXISTS(SELECT 1 FROM orchestration_v2_projection_runtime_requests q
                         JOIN orchestration_v2_projection_nodes n ON n.node_id=q.node_id
                         WHERE q.thread_id=t.thread_id AND n.run_id=r.run_id
                           AND q.status='pending') AS needs_input
                FROM orchestration_v2_projection_threads t
                JOIN orchestration_v2_projection_runs r ON r.thread_id=t.thread_id
                WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
                  AND r.ordinal=(SELECT MAX(r2.ordinal)
                    FROM orchestration_v2_projection_runs r2 WHERE r2.thread_id=t.thread_id)
                ORDER BY CASE WHEN r.status IN ('preparing','queued','starting','running','waiting')
                              THEN 0 ELSE 1 END, r.requested_at DESC
                LIMIT 100
            """).fetchall()
            for row in rows:
                thread = json.loads(row["thread_payload"])
                run = json.loads(row["run_payload"])
                if (thread.get("lineage") or {}).get(
                    "relationshipToParent"
                ) == "subagent":
                    continue
                active = row["status"] in {
                    "preparing",
                    "queued",
                    "starting",
                    "running",
                    "waiting",
                }
                visited = timestamp(thread.get("lastVisitedAt"))
                completed = timestamp(row["completed_at"])
                recent_only = False
                if active:
                    state = (
                        "waiting"
                        if row["needs_input"] or row["status"] == "waiting"
                        else "running"
                    )
                elif row["status"] == "completed":
                    state = "review"
                    recent_only = (
                        completed <= visited
                        or thread.get("settledOverride") == "settled"
                        or bool(thread.get("settledAt"))
                    )
                elif thread.get("settledOverride") == "settled" or thread.get(
                    "settledAt"
                ):
                    continue
                elif completed > visited and row["status"] == "failed":
                    state = "failed"
                else:
                    continue
                task = {
                    "id": row["thread_id"],
                    "kind": "t3",
                    "hostId": "local",
                    "title": row["title"],
                    "state": state,
                    "runId": row["run_id"],
                    "startedAt": timestamp(run.get("requestedAt")),
                    "completedAt": completed,
                    "updatedAt": completed or timestamp(run.get("requestedAt")),
                    "progressText": "",
                    "provider": run.get("providerInstanceId")
                    or thread.get("providerInstanceId")
                    or "",
                    "model": (run.get("modelSelection") or {}).get("model", ""),
                }
                if active or state == "review":
                    # Extract bounded text only, never command outputs or prompts.
                    items = db.execute(
                        """
                        SELECT turn_item_id, type, updated_at,
                          substr(json_extract(payload_json,'$.text'),1,?) AS text
                        FROM orchestration_v2_projection_turn_items
                        WHERE thread_id=? AND run_id=? AND type IN ('assistant_message','reasoning')
                        ORDER BY ordinal DESC LIMIT 20
                    """,
                        (MAX_PROGRESS_CHARS, row["thread_id"], row["run_id"]),
                    ).fetchall()
                    for item in items:
                        if state == "review" and item["type"] != "assistant_message":
                            continue
                        if item["type"] == "reasoning":
                            # Codex identifies summary/raw streams separately in its item ID.
                            # Unknown reasoning formats remain excluded.
                            try:
                                identity = json.loads(
                                    unquote(
                                        item["turn_item_id"].split("native-item:", 1)[1]
                                    )
                                )
                            except (ValueError, IndexError):
                                continue
                            if (
                                not isinstance(identity, list)
                                or len(identity) < 3
                                or identity[2] != "summary"
                            ):
                                continue
                        if item["text"] and item["text"].strip():
                            field = "progressText" if active else "completionPreview"
                            task[field] = " ".join(item["text"].split())[
                                : MAX_PROGRESS_CHARS if active else 240
                            ]
                            task["progressUpdatedAt"] = timestamp(item["updated_at"])
                            break
                if state == "review":
                    recent.append(task)
                if not recent_only:
                    tasks.append(task)
        result = activity_result(tasks, "t3")
        result["recentTasks"] = sorted(recent, key=lambda task: -task["completedAt"])[
            :5
        ]
        return result


def focus_t3():
    """Reveal an existing T3 desktop window without creating a session."""
    clients = json.loads(
        subprocess.check_output(["hyprctl", "-j", "clients"], text=True)
    )
    for window in clients:
        if window.get("class") == "com.t3tools.T3Code":
            address = window["address"]
            # Addresses are compositor-generated hexadecimal values. Validate
            # before embedding one in the installed Hyprland's Lua dispatcher.
            if not isinstance(address, str) or not address.startswith("0x"):
                raise ValueError("invalid T3 window address")
            int(address[2:], 16)
            subprocess.run(
                [
                    "hyprctl",
                    "dispatch",
                    'hl.dsp.focus({window="address:' + address + '"})',
                ],
                check=True,
            )
            return
    raise RuntimeError("T3 Code desktop window is not open")


def activity_result(tasks, source):
    priority = {"waiting": 0, "failed": 1, "review": 2, "running": 3}
    tasks.sort(key=lambda task: (priority[task["state"]], -task["updatedAt"]))
    return {
        "state": tasks[0]["state"] if tasks else "idle",
        "connected": True,
        "source": source,
        "counts": {
            state: sum(t["state"] == state for t in tasks) for state in priority
        },
        "tasks": tasks,
    }


def progress_text(detail):
    """Use only the newest turn's public summaries or assistant updates."""
    turns = (detail or {}).get("turns", [])
    if not turns or turns[0].get("status") in {"completed", "failed", "interrupted"}:
        return ""
    # read_thread returns turns newest first. Never reuse an older turn's text.
    for item in reversed(turns[0].get("items", [])):
        value = None
        if item.get("type") == "reasoning":
            # Summary is displayable; raw reasoning content is not used.
            summary = item.get("summary", [])
            if isinstance(summary, list):
                value = " ".join(
                    part if isinstance(part, str) else part.get("text", "")
                    for part in summary
                    if isinstance(part, (str, dict))
                )
            elif isinstance(summary, str):
                value = summary
        elif item.get("type") == "agentMessage" and item.get("phase") != "final_answer":
            value = item.get("text")
        if isinstance(value, str) and value.strip():
            return " ".join(value.split())[:MAX_PROGRESS_CHARS]
    return ""


class AppTools:
    def __init__(self, origin_thread, pipe=None):
        self.origin_thread = origin_thread
        self.pipe = pipe
        self.sock = None
        self.request_id = 0
        self.deadline = None
        self.request_deadline = None

    def close(self):
        if self.sock:
            self.sock.close()
        self.sock = None

    def _read(self, length):
        data = bytearray()
        while len(data) < length:
            deadline = self.request_deadline
            if deadline is not None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("desktop request deadline exceeded")
                self.sock.settimeout(remaining)
            part = self.sock.recv(length - len(data))
            if not part:
                raise ConnectionError("desktop disconnected")
            data.extend(part)
        return bytes(data)

    def request(self, method, params=None):
        self.request_deadline = min(
            time.monotonic() + REQUEST_TIMEOUT, self.deadline or float("inf")
        )
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
            paths.extend(
                sorted(
                    directory.glob("*.sock"),
                    key=lambda p: p.stat().st_mtime,
                    reverse=True,
                )
            )
        for path in dict.fromkeys(paths):
            if self.deadline is not None and time.monotonic() >= self.deadline:
                break
            try:
                info = path.lstat()
                if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
                    continue
                self.sock = socket.socket(socket.AF_UNIX)
                self.sock.settimeout(
                    min(
                        REQUEST_TIMEOUT,
                        max(
                            0.001,
                            (self.deadline or time.monotonic() + REQUEST_TIMEOUT)
                            - time.monotonic(),
                        ),
                    )
                )
                self.sock.connect(str(path))
                tools = self.request("tools/list", {"threadStartKind": "all"})
                if not any(
                    t.get("name") == "list_threads"
                    and t.get("namespace") == "codex_app"
                    for t in tools.get("tools", [])
                ):
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
        result = self.request(
            "tools/call",
            {
                "namespace": "codex_app",
                "tool": tool,
                "arguments": arguments,
                "threadId": self.origin_thread,
                "hostId": "local",
                "callerSource": "codex",
                "turnId": "spool-bridge-" + str(uuid.uuid4()),
                "callId": "spool-bridge-" + str(uuid.uuid4()),
            },
        )
        if not result.get("success"):
            raise RuntimeError("desktop declined the operation")
        if tool == "navigate_to_codex_page":
            return result
        texts = [
            item["text"]
            for item in result.get("contentItems", [])
            if item.get("type") == "inputText"
        ]
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
        if any(
            any(
                word in str(flag).lower()
                for word in ("approval", "input", "permission")
            )
            for flag in flags
        ):
            return "waiting"
        return "running"
    if status in {"waiting", "needsAttention", "requires_action"}:
        return "waiting"
    if status in {"failed", "error", "systemError"}:
        return "failed"
    if entry.get("isUnread") and status == "idle":
        return "review"
    return "idle"


def desktop_task(entry, detail, state):
    turns = (detail or {}).get("turns", [])
    turn = turns[0] if turns else {}
    task = {
        "id": entry["id"],
        "hostId": entry.get("hostId"),
        "kind": entry.get("kind"),
        "state": state,
        "title": entry.get("title") or "Chat",
        "provider": "openai",
        "updatedAt": timestamp(entry.get("updatedAt")),
        "runId": turn.get("id") or turn.get("turnId") or entry["id"],
        "startedAt": timestamp(turn.get("startedAt")),
        "model": turn.get("model") or entry.get("model") or "",
    }
    if state == "review":
        task["completedAt"] = timestamp(turn.get("completedAt")) or task["updatedAt"]
        task["completionPreview"] = next(
            (
                " ".join(item["text"].split())[:240]
                for item in reversed(turn.get("items", []))
                if item.get("type") == "agentMessage"
                and isinstance(item.get("text"), str)
            ),
            "",
        )
    elif state in {"running", "waiting"}:
        task["progressText"] = progress_text(detail)
    return task


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
            task = desktop_task(entry, details.get(key), state)
            tasks.append(task)
    result = activity_result(tasks, "desktop-app")
    recent = []
    for entry in entries:
        identity = (entry.get("kind"), entry.get("hostId"), entry.get("id"))
        turns = (details.get(identity) or {}).get("turns", [])
        if (
            task_state(entry) != "idle"
            or not turns
            or turns[0].get("status") != "completed"
        ):
            continue
        recent.append(desktop_task(entry, details.get(identity), "review"))
    result["recentTasks"] = sorted(recent, key=lambda task: -task["completedAt"])[:5]
    return result


class Observer:
    def __init__(self, client):
        self.client = client
        self.previous_running = set()
        self.wave_until = 0

    def sample(self):
        self.client.deadline = time.monotonic() + DESKTOP_SAMPLE_TIMEOUT
        listing = self.client.call("list_threads", {"limit": 50})
        entries = listing.get("pinnedThreads", []) + listing.get("threads", [])
        details = {}
        candidates = []
        candidate_keys = set()
        # Prefer active tasks over unread completions, including pinned duplicates.
        for entry in sorted(
            entries,
            key=lambda e: (
                task_state(e) not in {"running", "waiting"},
                -(e.get("updatedAt") or 0),
            ),
        ):
            key = (entry.get("kind"), entry.get("hostId"), entry.get("id"))
            if key not in candidate_keys and (
                task_state(entry) in {"running", "waiting"} or entry.get("isUnread")
            ):
                candidates.append(entry)
                candidate_keys.add(key)
        # Recent read chats follow active/unread tasks within the same eight-read budget.
        for entry in sorted(entries, key=lambda e: -(e.get("updatedAt") or 0)):
            identity = (entry.get("kind"), entry.get("hostId"), entry.get("id"))
            if identity not in candidate_keys and task_state(entry) == "idle":
                candidates.append(entry)
                candidate_keys.add(identity)
        # Bounded assistant text reads; command/tool outputs remain excluded.
        for entry in candidates[:MAX_DESKTOP_READS]:
            args = {
                "threadId": entry["id"],
                "turnLimit": 1,
                "includeOutputs": False,
                "maxOutputCharsPerItem": MAX_PROGRESS_CHARS,
            }
            if entry.get("hostId"):
                args["hostId"] = entry["hostId"]
            try:
                detail = self.client.call("read_thread", args)
                details[(entry.get("kind"), entry.get("hostId"), entry["id"])] = detail
            except (RuntimeError, ValueError):
                pass
            except OSError:
                # A slow preview must not discard a successfully fetched status list.
                # Close the interrupted framed transport before the next poll.
                self.client.close()
                break
        result = summarize(entries, details)
        running = {
            (t["kind"], t["hostId"], t["id"])
            for t in result["tasks"]
            if t["state"] in {"running", "waiting"}
        }
        present = {(e.get("kind"), e.get("hostId"), e.get("id")): e for e in entries}
        completed = [
            present[key]
            for key in self.previous_running - running
            if key in present and present[key].get("status") == "idle"
        ]
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
    parser.add_argument("--origin-thread", default="")
    parser.add_argument("--pipe")
    parser.add_argument("--interval", type=float, default=5)
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--open", dest="open_thread")
    parser.add_argument("--source", choices=("t3", "desktop", "all"), default="t3")
    parser.add_argument(
        "--open-kind", choices=("t3", "codex", "chatgpt"), default="codex"
    )
    parser.add_argument("--t3-data-dir")
    args = parser.parse_args()
    client = AppTools(args.origin_thread, args.pipe)
    observer = Observer(client)
    t3 = T3Observer(args.t3_data_dir)
    try:
        if args.open_thread:
            if args.open_kind == "t3":
                focus_t3()
            else:
                client.call("navigate_to_codex_page", {"threadId": args.open_thread})
            return
        while True:
            start = time.monotonic()
            samples, unavailable = [], []
            for source, adapter in (("t3", t3), ("desktop", observer)):
                if args.source not in {source, "all"}:
                    continue
                try:
                    samples.append(adapter.sample())
                except (OSError, RuntimeError, ValueError, KeyError, sqlite3.Error):
                    unavailable.append(source)
                    if source == "desktop":
                        client.close()
                        observer.previous_running.clear()
                        observer.wave_until = 0
            result = activity_result(
                [task for sample in samples for task in sample["tasks"]], args.source
            )
            result["recentTasks"] = [
                task for sample in samples for task in sample.get("recentTasks", [])
            ]
            result["connected"] = bool(samples)
            if result["state"] == "idle" and any(
                s["state"] == "waving" for s in samples
            ):
                result["state"] = "waving"
            result["unavailableSources"] = unavailable
            result["sampledAt"] = int(time.time() * 1000)
            print(json.dumps(result, separators=(",", ":")), flush=True)
            if args.once:
                break
            time.sleep(max(0.1, max(2, args.interval) - (time.monotonic() - start)))
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        client.close()


if __name__ == "__main__":
    main()
