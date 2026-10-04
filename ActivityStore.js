.pragma library
// SPDX-License-Identifier: AGPL-3.0-only

function key(task) {
  return JSON.stringify([task.kind || "", task.hostId || "", task.id]);
}
function runKey(task) {
  return String(task.runId || task.startedAt || task.updatedAt || "");
}
function completionKey(task) {
  return key(task) + ":" + String(task.completedAt || task.updatedAt || 0);
}
function update(previous, tasks, now) {
  var histories = Object.assign({}, previous.histories || {});
  var recent = (previous.recent || []).slice();
  var dismissed = previous.dismissed || [];
  tasks.forEach(function (task) {
    var id = key(task),
      history = histories[id];
    if (!history || history.run !== runKey(task))
      history = { run: runKey(task), items: [] };
    var text = task.progressText || "",
      items = history.items.slice();
    if (text && (!items.length || items[items.length - 1].fullText !== text)) {
      // Streaming extensions update the same comment instead of filling the history.
      if (items.length && text.indexOf(items[items.length - 1].fullText) === 0)
        items.pop();
      items.push({
        text: text.slice(0, 2000),
        fullText: text,
        at: task.progressUpdatedAt || now,
      });
      items = items.slice(-5);
    }
    histories[id] = { run: history.run, items: items };
    if (task.state === "review") {
      var fingerprint = completionKey(task);
      recent = recent.filter(function (item) {
        return key(item) !== id;
      });
      if (dismissed.indexOf(fingerprint) < 0)
        recent.push(
          Object.assign({}, task, {
            recent: true,
            completedAt: task.completedAt || task.updatedAt || now,
            completionPreview:
              task.completionPreview ||
              (items.length ? items[items.length - 1].text.slice(0, 240) : ""),
          }),
        );
    } else
      recent = recent.filter(function (item) {
        return key(item) !== id;
      });
  });
  recent.sort(function (a, b) {
    return b.completedAt - a.completedAt;
  });
  recent = recent.slice(0, 5);
  var retained = {};
  tasks
    .concat(recent)
    .slice(0, 105)
    .forEach(function (task) {
      var id = key(task);
      if (histories[id]) retained[id] = histories[id];
    });
  return {
    histories: retained,
    recent: recent,
    dismissed: dismissed.slice(-100),
  };
}
function snoozed(task, snoozes, now) {
  var value = snoozes[key(task)];
  return (
    !!value && (value.until ? value.until > now : value.run === runKey(task))
  );
}
function pruneSnoozes(tasks, snoozes, now) {
  var copy = {};
  Object.keys(snoozes).forEach(function (id) {
    var value = snoozes[id],
      task = tasks.find(function (item) {
        return key(item) === id;
      });
    if (value.until ? value.until > now : !task || value.run === runKey(task))
      copy[id] = value;
  });
  return copy;
}
function visible(
  tasks,
  recent,
  snoozes,
  now,
  recentExpanded,
  onlyAttention,
  showSnoozed,
) {
  return tasks
    .filter(function (task) {
      return task.state !== "review";
    })
    .concat(recentExpanded && !onlyAttention ? recent : [])
    .filter(function (task) {
      return (
        (showSnoozed || !snoozed(task, snoozes, now)) &&
        (!onlyAttention || task.state === "waiting" || task.state === "failed")
      );
    })
    .map(function (task) {
      return Object.assign({}, task, { snoozed: snoozed(task, snoozes, now) });
    });
}
function attention(tasks, snoozes, now) {
  return tasks.filter(function (task) {
    return (
      (task.state === "waiting" || task.state === "failed") &&
      !snoozed(task, snoozes, now)
    );
  });
}
function duration(seconds) {
  var value = Math.max(0, Math.floor(seconds));
  if (value < 60) return value + "s";
  if (value < 3600) return Math.floor(value / 60) + "m";
  return (
    Math.floor(value / 3600) + "h " + Math.floor((value % 3600) / 60) + "m"
  );
}
function timing(task, now) {
  if (task.recent)
    return "Finished " + duration(now - task.completedAt) + " ago";
  var parts = [];
  if (task.startedAt) parts.push(duration(now - task.startedAt));
  if (task.progressUpdatedAt)
    parts.push("Updated " + duration(now - task.progressUpdatedAt) + " ago");
  return parts.join(" · ");
}
function source(task) {
  var app =
    task.kind === "t3"
      ? "T3 Code"
      : task.kind === "chatgpt"
        ? "ChatGPT"
        : "Codex desktop";
  var provider =
    {
      codex: "Codex",
      openai: "OpenAI",
      chatgpt: "OpenAI",
      claude: "Claude",
      anthropic: "Anthropic",
      gemini: "Gemini",
      google: "Google",
      opencode: "OpenCode",
    }[task.provider] || task.provider;
  return [app, provider, task.model].filter(Boolean).join(" · ");
}

// Keep transient UI state bounded to the threads still represented in the tray.
function retainKeys(values, tasks) {
  var retained = {};
  tasks.slice(0, 105).forEach(function (task) {
    var id = key(task);
    if (Object.prototype.hasOwnProperty.call(values, id))
      retained[id] = values[id];
  });
  return retained;
}
function cleanSnoozes(values) {
  var cleaned = {};
  if (!values || typeof values !== "object" || Array.isArray(values))
    return cleaned;
  Object.keys(values)
    .slice(-100)
    .forEach(function (id) {
      var item = values[id];
      if (!item || typeof item !== "object") return;
      if (
        typeof item.until === "number" &&
        isFinite(item.until) &&
        item.until > 0
      )
        cleaned[id] = { until: item.until };
      else if (typeof item.run === "string" && item.run)
        cleaned[id] = { run: item.run };
    });
  return cleaned;
}
function normalizeTask(task, previous, now) {
  var copy = Object.assign({}, task);
  var old = previous.find(function (item) {
    return key(item) === key(copy);
  });
  if (!copy.startedAt && copy.state !== "review")
    copy.startedAt =
      old && ["running", "waiting"].indexOf(old.state) >= 0
        ? old.startedAt
        : now;
  if (copy.kind !== "t3" && copy.runId === copy.id) {
    if (copy.state === "review" && old && old.startedAt)
      copy.startedAt = old.startedAt;
    if (copy.startedAt) copy.runId = copy.id + ":" + copy.startedAt;
  }
  return copy;
}
