// SPDX-License-Identifier: AGPL-3.0-only
const assert = require("node:assert/strict");
const fs = require("node:fs"),
  vm = require("node:vm");
const store = {};
vm.runInNewContext(
  fs
    .readFileSync(`${__dirname}/ActivityStore.js`, "utf8")
    .replace(/^\.pragma library\s*/, ""),
  store,
);
const a = {
  kind: "t3",
  hostId: "local",
  id: "a",
  runId: "run-a",
  startedAt: 100,
  updatedAt: 100,
  state: "running",
  progressText: "First comment",
  progressUpdatedAt: 110,
};
let state = store.update({}, [a], 120);
state = store.update(state, [a], 130);
assert.equal(state.histories[store.key(a)].items.length, 1);
state = store.update(
  state,
  [{ ...a, progressText: "Second comment", progressUpdatedAt: 130 }],
  130,
);
assert.equal(state.histories[store.key(a)].items.length, 2);
state = store.update(
  state,
  [{ ...a, progressText: "Second comment extended", progressUpdatedAt: 131 }],
  131,
);
assert.equal(state.histories[store.key(a)].items.length, 2);
for (let i = 0; i < 8; i++)
  state = store.update(
    state,
    [{ ...a, progressText: `Distinct ${i}` }],
    140 + i,
  );
assert.equal(state.histories[store.key(a)].items.length, 5);
const done = {
  ...a,
  state: "review",
  completedAt: 200,
  completionPreview: "Tests passed",
  progressText: "",
};
state = store.update(state, [done], 200);
assert.equal(state.recent.length, 1);
assert.equal(state.recent[0].completionPreview, "Tests passed");
state = store.update(state, [], 201); // Visiting or a provider outage doesn't erase recent history.
assert.equal(state.recent.length, 1);
state = { ...state, dismissed: [store.completionKey(done)], recent: [] };
state = store.update(state, [done], 202);
assert.equal(state.recent.length, 0);
state = store.update(
  state,
  [{ ...done, runId: "run-next", completedAt: 300 }],
  300,
);
assert.equal(state.recent.length, 1); // A later completion isn't permanently dismissed.
state = store.update(
  {},
  Array.from({ length: 8 }, (_, i) => ({
    ...done,
    id: String(i),
    completedAt: 200 + i,
  })),
  210,
);
assert.equal(state.recent.length, 5);
assert.equal(state.recent[0].id, "7");
state = store.update(
  state,
  [{ ...a, runId: "new-run", progressText: "New run" }],
  301,
);
assert.equal(state.histories[store.key(a)].items.length, 1);
const snoozes = { [store.key(a)]: { until: 300 } };
assert.equal(store.snoozed(a, snoozes, 299), true);
assert.equal(store.snoozed(a, snoozes, 300), false);
const next = { [store.key(a)]: { run: store.runKey(a) } };
assert.equal(store.snoozed(a, next, 300), true);
assert.equal(store.snoozed({ ...a, runId: "new" }, next, 300), false);
assert.equal(
  Object.keys(store.pruneSnoozes([{ ...a, runId: "new" }], next, 300)).length,
  0,
);
assert.equal(
  store.visible([a], [], snoozes, 299, true, false, false).length,
  0,
);
assert.equal(
  store.visible([a], [], snoozes, 299, true, false, true)[0].snoozed,
  true,
);
const waiting = { ...a, id: "waiting", state: "waiting" },
  failed = { ...a, id: "failed", state: "failed" };
assert.equal(store.attention([a, waiting, failed], {}, 300).length, 2);
assert.equal(
  store.visible([a, waiting, failed], state.recent, {}, 300, true, true, false)
    .length,
  2,
);
assert.equal(
  store.visible([], state.recent, {}, 300, false, false, false).length,
  0,
);
assert.equal(store.duration(3700), "1h 1m");
assert.equal(store.timing(a, 160), "1m · Updated 50s ago");
assert.equal(
  store.source({ ...a, provider: "codex", model: "gpt-6.1-sol" }),
  "T3 Code · Codex · gpt-6.1-sol",
);
console.log(
  "History, streaming, recent completions, dismissal, snooze expiry, next-run snoozes, attention filters, and timing passed.",
);

// Desktop sources without turn IDs keep a run stable through completion/readback.
const raw = {
  id: "desktop",
  kind: "codex",
  runId: "desktop",
  state: "running",
};
const running = store.normalizeTask(raw, [], 100);
const completion = store.normalizeTask(
  { ...raw, state: "review" },
  [running],
  110,
);
assert.equal(completion.runId, running.runId);
const readback = store.normalizeTask(
  { ...raw, state: "review" },
  [completion],
  120,
);
assert.equal(readback.runId, running.runId);
assert.notEqual(store.normalizeTask(raw, [readback], 130).runId, running.runId);
assert.equal(raw.startedAt, undefined);
const id = store.key(a);
assert.equal(
  Object.keys(store.retainKeys({ [id]: "keep", stale: "drop" }, [a])).length,
  1,
);
assert.equal(
  Object.keys(store.cleanSnoozes({ bad: null, other: 7, [id]: { until: 500 } }))
    .length,
  1,
);
console.log(
  "Run normalization, stale UI state pruning, and saved snooze validation passed.",
);
