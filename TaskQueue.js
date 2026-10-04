.pragma library
// SPDX-License-Identifier: AGPL-3.0-only

function key(task) {
  return JSON.stringify([task.kind || "", task.hostId || "", task.id]);
}

function index(tasks, selectedKey) {
  for (var i = 0; i < tasks.length; i++)
    if (key(tasks[i]) === selectedKey) return i;
  return tasks.length ? 0 : -1;
}

function reconcile(tasks, selectedKey, manual) {
  if (manual) {
    for (var i = 0; i < tasks.length; i++) {
      if (key(tasks[i]) === selectedKey)
        return { key: selectedKey, manual: true };
    }
  }
  return { key: tasks.length ? key(tasks[0]) : "", manual: false };
}

function cycle(tasks, selectedKey, direction) {
  if (!tasks.length) return "";
  var next =
    (index(tasks, selectedKey) + (direction < 0 ? -1 : 1) + tasks.length) %
    tasks.length;
  return key(tasks[next]);
}

// Use source timestamps; detect text changes when an adapter lacks item timestamps.
function updates(tasks, previous, now) {
  return tasks.map(function (task) {
    var copy = Object.assign({}, task);
    var old = previous.find(function (item) {
      return key(item) === key(task);
    });
    if (!task.progressUpdatedAt && old) {
      copy.progressUpdatedAt =
        task.progressText !== old.progressText ? now : old.progressUpdatedAt;
    }
    return copy;
  });
}
function updated(task) {
  return task.progressUpdatedAt || task.updatedAt || 0;
}
function order(tasks, pinnedKey) {
  return tasks.slice().sort(function (a, b) {
    var pin = Number(key(b) === pinnedKey) - Number(key(a) === pinnedKey);
    return pin || updated(b) - updated(a) || key(a).localeCompare(key(b));
  });
}
function revision(tasks) {
  return tasks.length
    ? JSON.stringify([
        key(tasks[0]),
        updated(tasks[0]),
        tasks[0].progressText || "",
      ])
    : "";
}
function select(tasks, selectedKey, manual, pinnedKey, previousRevision) {
  var pinned = tasks.find(function (task) {
    return key(task) === pinnedKey;
  });
  if (pinned) return { key: pinnedKey, manual: false };
  return reconcile(
    tasks,
    selectedKey,
    manual && revision(tasks) === previousRevision,
  );
}
function logo(task) {
  var provider = (task.provider || task.kind || "").toLowerCase();
  if (/codex|openai|chatgpt/.test(provider)) return "openai";
  if (/claude|anthropic/.test(provider)) return "anthropic";
  if (/gemini|google/.test(provider)) return "google";
  if (/opencode/.test(provider)) return "opencode";
  return "";
}

function displayOrder(tasks, pinnedKey) {
  var ordered = order(tasks, pinnedKey);
  return ordered
    .filter(function (task) {
      return key(task) === pinnedKey;
    })
    .concat(
      ordered.filter(function (task) {
        return key(task) !== pinnedKey && !task.recent;
      }),
    )
    .concat(
      ordered
        .filter(function (task) {
          return key(task) !== pinnedKey && task.recent;
        })
        .sort(function (a, b) {
          return b.completedAt - a.completedAt;
        }),
    );
}
