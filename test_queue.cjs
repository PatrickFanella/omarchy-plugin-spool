// SPDX-License-Identifier: AGPL-3.0-only
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const queue = {};
vm.runInNewContext(
  fs
    .readFileSync(`${__dirname}/TaskQueue.js`, "utf8")
    .replace(/^\.pragma library\s*/, ""),
  queue,
);

const a = { kind: "t3", hostId: "local", id: "a" };
const b = { kind: "t3", hostId: "local", id: "b" };
const c = { kind: "t3", hostId: "local", id: "c" };
const selected = queue.key(b);

// A poll can reorder tasks or replace their text without changing selection.
let state = queue.reconcile(
  [c, { ...b, progressText: "New progress" }, a],
  selected,
  true,
);
assert.equal(state.key, selected);
assert.equal(state.manual, true);
assert.equal(queue.index([b, a, c], selected), 0);

// Default selection follows the adapter's priority; removed selections reset.
state = queue.reconcile([c, a], selected, true);
assert.equal(state.key, queue.key(c));
assert.equal(state.manual, false);
assert.equal(queue.reconcile([c, b, a], selected, false).key, queue.key(c));

// Wheel/arrows reach every task and wrap in both directions.
assert.equal(queue.cycle([a, b, c], queue.key(a), -1), queue.key(c));
assert.equal(queue.cycle([a, b, c], queue.key(c), 1), queue.key(a));
assert.equal(queue.cycle([a, b, c], selected, 1), queue.key(c));

// Identical IDs from different adapters or hosts remain distinct.
assert.notEqual(queue.key(a), queue.key({ ...a, kind: "codex" }));
assert.notEqual(queue.key(a), queue.key({ ...a, hostId: "remote" }));

// Empty/disconnected queues have no selected card and cannot be cycled.
assert.equal(queue.index([], selected), -1);
assert.equal(queue.reconcile([], selected, true).key, "");
assert.equal(queue.cycle([], selected, 1), "");
console.log(
  "Task queue selection, refresh, removal, cycling, and identity checks passed.",
);

const older = {
  ...a,
  updatedAt: 10,
  progressUpdatedAt: 20,
  progressText: "Old",
};
const newer = {
  ...b,
  updatedAt: 5,
  progressUpdatedAt: 30,
  progressText: "New",
};
let ordered = queue.order([older, newer], "");
assert.equal(queue.key(ordered[0]), queue.key(b));
assert.equal(
  queue.key(queue.order([older, newer], queue.key(a))[0]),
  queue.key(a),
);
assert.equal(
  queue.select(ordered, queue.key(a), true, "", "old revision").key,
  queue.key(b),
);
assert.equal(
  queue.select(ordered, queue.key(a), true, "", queue.revision(ordered)).key,
  queue.key(a),
);
assert.equal(
  queue.select(ordered, queue.key(b), true, queue.key(a), "").key,
  queue.key(a),
);
assert.equal(
  queue.select(ordered, queue.key(a), true, "missing", "old revision").key,
  queue.key(b),
);
let refreshed = queue.updates(
  [{ ...a, updatedAt: 10, progressText: "Changed" }],
  [{ ...a, progressText: "Old" }],
  100,
);
assert.equal(refreshed[0].progressUpdatedAt, 100);
refreshed = queue.updates([{ ...a, progressText: "Changed" }], refreshed, 200);
assert.equal(refreshed[0].progressUpdatedAt, 100);
assert.equal(queue.logo({ provider: "codex" }), "openai");
assert.equal(queue.logo({ provider: "claude-code" }), "anthropic");
assert.equal(queue.logo({ provider: "gemini" }), "google");
assert.equal(queue.logo({ provider: "opencode" }), "opencode");
assert.equal(queue.logo({ provider: "custom" }), "");
console.log(
  "Latest progress ordering, pin precedence, refresh stability, and provider logos passed.",
);

const recent = { ...c, recent: true, completedAt: 100, updatedAt: 100 };
assert.equal(
  queue.key(queue.displayOrder([recent, older, newer], "")[0]),
  queue.key(b),
);
assert.equal(
  queue.key(queue.displayOrder([recent, older, newer], queue.key(recent))[0]),
  queue.key(recent),
);
console.log("Active/recent ordering and pinning completed threads passed.");
