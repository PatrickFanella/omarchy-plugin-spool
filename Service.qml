// SPDX-License-Identifier: AGPL-3.0-only
import "ActivityStore.js" as ActivityStore
import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import "TaskQueue.js" as TaskQueue

Item {
    id: root

    property var shell: null
    property var manifest: null
    property var pluginRegistry: null
    property string omarchyPath: ""
    property bool shown: true
    property int petSize: 128
    property string monitorName: ""
    property real rightOffset: 24
    property real bottomOffset: 24
    property bool followPointer: true
    property bool wander: false
    property bool reducedMotion: false
    property bool hideFullscreen: true
    property bool autoActivity: true
    property string activitySource: "t3"
    property string originThread: ""
    property string activityState: "idle"
    property var activity: ({
        "connected": false,
        "counts": {
        },
        "tasks": []
    })
    property bool activityExpanded: true
    property bool miniMode: false
    property string selectedTaskKey: ""
    property bool taskManuallySelected: false
    property string pinnedTaskKey: ""
    property var progressOffsets: ({
    })
    property double clockNow: Date.now() / 1000
    property double filterNow: Date.now() / 1000
    property string hoveredSourceKey: ""
    property bool pausePet: false
    property bool onlyAttention: false
    property bool recentExpanded: true
    property bool showSnoozed: false
    property var snoozes: ({
    })
    property var activityStore: ({
        "histories": {
        },
        "recent": [],
        "dismissed": []
    })
    property var historyExpanded: ({
    })
    property string snoozeMenuKey: ""
    property var attentionTasks: ActivityStore.attention(activity.tasks || [], snoozes, filterNow)
    property var displayedTasks: ActivityStore.visible(activity.tasks || [], activityStore.recent, snoozes, filterNow, recentExpanded, onlyAttention, showSnoozed)
    property var orderedTasks: TaskQueue.displayOrder(displayedTasks, pinnedTaskKey)
    property bool motionPaused: reducedMotion || pausePet
    property int selectedTaskIndex: TaskQueue.index(orderedTasks, selectedTaskKey)
    property var selectedTask: selectedTaskIndex >= 0 ? orderedTasks[selectedTaskIndex] : null
    property var savedPreferences: ({
    })
    property double lastActivityAt: 0
    property string bridgeScript: decodeURIComponent(Qt.resolvedUrl("bridge.py").toString().replace(/^file:\/\//, ""))
    property bool menuOpen: false
    property bool dragging: false
    property string state: "idle"
    property int frame: 0
    property int gaze: -1
    property real lastCursorX: -99999
    property real lastCursorY: -99999
    property double gazeUntil: 0
    property var rows: ({
        "idle": 0,
        "running-right": 1,
        "running-left": 2,
        "waving": 3,
        "jumping": 4,
        "failed": 5,
        "waiting": 6,
        "running": 7,
        "review": 8
    })
    property var timings: [[280, 110, 110, 140, 140, 320], [120, 120, 120, 120, 120, 120, 120, 220], [120, 120, 120, 120, 120, 120, 120, 220], [140, 140, 140, 280], [140, 140, 140, 140, 280], [140, 140, 140, 140, 140, 140, 140, 240], [150, 150, 150, 150, 150, 260], [120, 120, 120, 120, 120, 220], [150, 150, 150, 150, 150, 280]]
    property var targetScreen: {
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) if (screens[i].name === monitorName) {
            return screens[i];
        }
        return screens.length ? screens[0] : null;
    }
    property var targetMonitor: {
        var monitors = Hyprland.monitors.values;
        for (var i = 0; i < monitors.length; i++) if (targetScreen && monitors[i].name === targetScreen.name) {
            return monitors[i];
        }
        return null;
    }
    property bool fullscreen: hideFullscreen && targetMonitor && targetMonitor.activeWorkspace ? targetMonitor.activeWorkspace.hasFullscreen : false
    property bool active: shown && !fullscreen && targetScreen !== null
    property int spriteRow: !motionPaused && gaze >= 0 && state === "idle" ? 9 + Math.floor(gaze / 8) : rows[state]
    property int spriteFrame: motionPaused ? 0 : (!motionPaused && gaze >= 0 && state === "idle" ? gaze % 8 : frame)

    function settings() {
        return {
            "shown": shown,
            "size": petSize,
            "monitor": monitorName,
            "right": rightOffset,
            "bottom": bottomOffset,
            "followPointer": followPointer,
            "wander": wander,
            "reducedMotion": reducedMotion,
            "hideFullscreen": hideFullscreen,
            "autoActivity": autoActivity,
            "activitySource": activitySource,
            "activityExpanded": activityExpanded,
            "miniMode": miniMode,
            "pinnedTaskKey": pinnedTaskKey,
            "pausePet": pausePet,
            "onlyAttention": onlyAttention,
            "recentExpanded": recentExpanded,
            "snoozes": snoozes,
            "dismissedCompletions": activityStore.dismissed,
            "originThread": originThread
        };
    }

    function apply(s) {
        if (s.shown !== undefined)
            shown = !!s.shown;

        if (s.size !== undefined)
            petSize = Math.max(64, Math.min(256, Number(s.size) || 128));

        if (s.monitor !== undefined)
            monitorName = String(s.monitor);

        if (s.right !== undefined)
            rightOffset = Math.max(0, Number(s.right) || 0);

        if (s.bottom !== undefined)
            bottomOffset = Math.max(0, Number(s.bottom) || 0);

        if (s.snoozes && typeof s.snoozes === "object" && !Array.isArray(s.snoozes))
            snoozes = ActivityStore.cleanSnoozes(s.snoozes);

        if (Array.isArray(s.dismissedCompletions))
            activityStore = Object.assign({
        }, activityStore, {
            "dismissed": s.dismissedCompletions.slice(-100)
        });

        if (s.pinnedTaskKey !== undefined)
            pinnedTaskKey = String(s.pinnedTaskKey);

        if (s.originThread !== undefined)
            originThread = String(s.originThread);

        if (["t3", "desktop", "all"].indexOf(s.activitySource) >= 0)
            activitySource = s.activitySource;

        for (var key of ["followPointer", "wander", "reducedMotion", "hideFullscreen", "autoActivity", "activityExpanded", "pausePet", "onlyAttention", "recentExpanded", "miniMode"]) if (s[key] !== undefined) {
            root[key] = !!s[key];
        }
    }

    function save() {
        var value = settings();
        savedPreferences = value;
        var text = JSON.stringify(value);
        if (preferenceFile.text() !== text)
            preferenceFile.setText(text);

        if (shell)
            shell.updateEntryInline("onnwee.spool", value);

    }

    function readSettings() {
        try {
            if (!configFile.loaded)
                return ;

            apply(savedPreferences);
            var config = JSON.parse(configFile.text());
            for (var entry of (config.plugins || [])) if (entry.id === "onnwee.spool") {
                apply(entry);
                return ;
            }
        } catch (e) {
            console.warn("Spool settings:", e);
        }
    }

    function animate(name) {
        if (rows[name] === undefined)
            return "unknown state";

        state = name;
        frame = 0;
        gaze = -1;
        if (active && !motionPaused)
            animation.restart();
        else
            animation.stop();
        return "ok";
    }

    function normalizeTask(task, now) {
        return ActivityStore.normalizeTask(task, (activity.tasks || []).concat(activityStore.recent), now);
    }

    function receiveActivity(data) {
        if (["idle", "running", "waiting", "failed", "review", "waving"].indexOf(data.state) < 0)
            return ;

        var scrollY = taskList.contentY;
        var previousRevision = TaskQueue.revision(orderedTasks);
        data.tasks = TaskQueue.updates(data.tasks || [], activity.tasks || [], Date.now() / 1000);
        var now = Date.now() / 1000;
        filterNow = now;
        data.tasks = data.tasks.map(function(task) {
            return root.normalizeTask(task, now);
        });
        var observed = data.tasks.concat((data.recentTasks || []).filter(function(task) {
            return !data.tasks.some(function(active) {
                return TaskQueue.key(active) === TaskQueue.key(task);
            });
        }).map(function(task) {
            return root.normalizeTask(task, now);
        }));
        activityStore = ActivityStore.update(activityStore, observed, now);
        var represented = observed.concat(activityStore.recent);
        progressOffsets = ActivityStore.retainKeys(progressOffsets, represented);
        historyExpanded = ActivityStore.retainKeys(historyExpanded, represented);
        var nextSnoozes = ActivityStore.pruneSnoozes(observed, snoozes, now);
        var snoozesChanged = JSON.stringify(nextSnoozes) !== JSON.stringify(snoozes);
        snoozes = nextSnoozes;
        activity = data;
        lastActivityAt = Date.now();
        if (snoozesChanged)
            save();

        var selection = TaskQueue.select(orderedTasks, selectedTaskKey, taskManuallySelected, pinnedTaskKey, previousRevision);
        if (TaskQueue.revision(orderedTasks) !== previousRevision)
            scrollY = 0;

        selectedTaskKey = selection.key;
        taskManuallySelected = selection.manual;
        if (activityExpanded)
            Qt.callLater(function() {
            taskList.forceLayout();
            taskList.contentY = Math.max(0, Math.min(scrollY, Math.max(0, taskList.contentHeight - taskList.height)));
        });

        var previous = activityState;
        activityState = autoActivity ? data.state : "idle";
        if (activityState !== previous && (state === previous || state === "idle" || ["running", "waiting", "failed", "review"].indexOf(state) >= 0))
            animate(activityState);

    }

    function openTask() {
        var task = selectedTask;
        if (!task)
            return ;

        Quickshell.execDetached(["python3", bridgeScript, "--origin-thread", originThread, "--open", task.id, "--open-kind", task.kind]);
    }

    function cycleActivity(direction) {
        selectedTaskKey = TaskQueue.cycle(orderedTasks, selectedTaskKey, direction);
        taskManuallySelected = selectedTaskKey !== "";
        if (activityExpanded && selectedTaskIndex >= 0)
            taskList.positionViewAtIndex(selectedTaskIndex, ListView.Contain);

    }

    function togglePin(task) {
        if (!task)
            return ;

        var key = TaskQueue.key(task);
        pinnedTaskKey = pinnedTaskKey === key ? "" : key;
        selectedTaskKey = orderedTasks.length ? TaskQueue.key(orderedTasks[0]) : "";
        taskManuallySelected = false;
        taskList.contentY = 0;
        save();
    }

    function snoozeTask(task, mode) {
        if (!task || ["15m", "1h", "next"].indexOf(mode) < 0)
            return ;

        var values = Object.assign({
        }, snoozes);
        values[TaskQueue.key(task)] = mode === "next" ? {
            "run": ActivityStore.runKey(task)
        } : {
            "until": Date.now() / 1000 + (mode === "15m" ? 900 : 3600)
        };
        snoozes = values;
        snoozeMenuKey = "";
        selectedTaskKey = orderedTasks.length ? TaskQueue.key(orderedTasks[0]) : "";
        save();
    }

    function resumeTask(task) {
        var values = Object.assign({
        }, snoozes);
        delete values[TaskQueue.key(task)];
        snoozes = values;
        save();
    }

    function dismissTask(task) {
        if (!task || !task.recent)
            return ;

        activityStore = Object.assign({
        }, activityStore, {
            "recent": activityStore.recent.filter(function(item) {
                return TaskQueue.key(item) !== TaskQueue.key(task);
            }),
            "dismissed": activityStore.dismissed.concat([ActivityStore.completionKey(task)]).slice(-100)
        });
        selectedTaskKey = orderedTasks.length ? TaskQueue.key(orderedTasks[0]) : "";
        save();
    }

    function toggleHistory(task) {
        if (!task)
            return ;

        var values = Object.assign({
        }, historyExpanded), key = TaskQueue.key(task);
        values[key] = !values[key];
        historyExpanded = values;
    }

    function taskText(task) {
        if (!task)
            return "";

        var history = activityStore.histories[TaskQueue.key(task)];
        if (historyExpanded[TaskQueue.key(task)] && history && history.items.length)
            return history.items.map(function(item) {
            return new Date(item.at * 1000).toLocaleTimeString() + " · " + item.text;
        }).join("\n\n");

        return task.recent ? task.completionPreview || "Completed" : task.progressText || (task.state === "running" ? "Thinking" : "");
    }

    function trayAction(index) {
        if (index === 0) {
            recentExpanded = !recentExpanded;
        } else if (index === 1) {
            showSnoozed = !showSnoozed;
        } else if (index === 2) {
            onlyAttention = !onlyAttention;
        } else {
            snoozes = ({
            });
            showSnoozed = false;
        }
        save();
    }

    function navigationAction(index) {
        if (index === 5) {
            miniMode = true;
            save();
        } else if (index === 3) {
            togglePin(selectedTask);
        } else if (index === 4) {
            activityExpanded = !activityExpanded;
            save();
        } else {
            cycleActivity(index === 0 ? -1 : 1);
        }
    }

    function menuAction(index) {
        switch (index) {
        case 0:
            root.animate("waving");
            break;
        case 1:
            root.animate("jumping");
            break;
        case 2:
            root.petSize = root.petSize >= 192 ? 64 : root.petSize + 32;
            break;
        case 3:
            root.followPointer = !root.followPointer;
            root.gaze = -1;
            break;
        case 4:
            root.wander = !root.wander;
            break;
        case 5:
            root.reducedMotion = !root.reducedMotion;
            root.gaze = -1;
            break;
        case 6:
            root.cycleMonitor();
            break;
        case 7:
            root.autoActivity = !root.autoActivity;
            break;
        case 8:
            root.activitySource = ({
                "t3": "desktop",
                "desktop": "all",
                "all": "t3"
            })[root.activitySource];
            break;
        case 9:
            root.pausePet = !root.pausePet;
            break;
        case 10:
            root.onlyAttention = !root.onlyAttention;
            break;
        case 11:
            root.miniMode = !root.miniMode;
            root.menuOpen = false;
            if (!root.miniMode)
                root.activityExpanded = true;

            break;
        case 12:
            root.shown = false;
            root.menuOpen = false;
            break;
        case 13:
            root.menuOpen = false;
            break;
        }
        root.save();
    }

    function setMini(value) {
        miniMode = value;
        if (!value)
            activityExpanded = true;

        save();
    }

    function showAttention() {
        if (!attentionTasks.length)
            return ;

        miniMode = false;
        var task = attentionTasks[0];
        selectedTaskKey = TaskQueue.key(task);
        taskManuallySelected = true;
        activityExpanded = true;
        taskList.positionViewAtIndex(selectedTaskIndex, ListView.Contain);
        save();
    }

    function activityLabel(task) {
        if (!task)
            return "";

        return (task.kind === "t3" ? "T3 · " : "") + ({
            "running": "Running",
            "waiting": "Needs input",
            "failed": "Blocked",
            "review": "Ready"
        })[task.state];
    }

    function cycleMonitor() {
        var screens = Quickshell.screens;
        for (var i = 0; i < screens.length; i++) if (targetScreen === screens[i]) {
            monitorName = screens[(i + 1) % screens.length].name;
            break;
        }
        save();
    }

    onAutoActivityChanged: {
        if (!autoActivity) {
            activityBridge.running = false;
            receiveActivity({
                "state": "idle",
                "connected": false,
                "counts": {
                },
                "tasks": []
            });
        }
    }
    onOriginThreadChanged: activityBridge.running = false
    onActivitySourceChanged: {
        activityBridge.running = false;
        receiveActivity({
            "state": "idle",
            "connected": false,
            "counts": {
            },
            "tasks": []
        });
    }

    Process {
        id: activityBridge

        command: ["python3", root.bridgeScript, "--origin-thread", root.originThread, "--source", root.activitySource]
        running: root.autoActivity && (root.activitySource !== "desktop" || root.originThread !== "")

        stdout: SplitParser {
            onRead: (data) => {
                try {
                    root.receiveActivity(JSON.parse(data));
                } catch (e) {
                    console.warn("Spool activity data invalid");
                }
            }
        }

    }

    Timer {
        interval: 1000
        repeat: true
        running: root.active
        onTriggered: root.clockNow = Date.now() / 1000
    }

    Timer {
        interval: 5000
        repeat: true
        running: root.autoActivity && (root.activitySource !== "desktop" || root.originThread !== "")
        onTriggered: {
            root.filterNow = Date.now() / 1000;
            if (!activityBridge.running)
                activityBridge.running = true;

        }
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.autoActivity
        onTriggered: {
            if (root.lastActivityAt > 0 && Date.now() - root.lastActivityAt > 45000 && root.activity.connected) {
                root.receiveActivity({
                "state": "idle",
                "connected": false,
                "counts": {
                },
                "tasks": []
            });
            }
        }
    }

    FileView {
        id: preferenceFile

        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/spool/preferences.json"
        atomicWrites: true
        printErrors: false
        onLoaded: {
            try {
                root.savedPreferences = JSON.parse(text());
                root.readSettings();
            } catch (e) {
                console.warn("Spool saved preferences invalid");
            }
        }
    }

    FileView {
        id: configFile

        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/omarchy/shell.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.readSettings()
    }

    Timer {
        id: animation

        interval: root.timings[root.rows[root.state]][root.frame]
        running: root.active && !root.motionPaused
        repeat: true
        onTriggered: {
            var count = root.timings[root.rows[root.state]].length;
            root.frame = (root.frame + 1) % count;
            if (root.frame === 0 && ["waving", "jumping", "failed", "running-right", "running-left"].indexOf(root.state) >= 0 && !(root.state === "failed" && root.autoActivity && root.activityState === "failed")) {
                root.state = root.autoActivity && root.activityState !== "waving" ? root.activityState : "idle";
                root.frame = 0;
                root.save();
            }
            if (root.gaze >= 0 && Date.now() > root.gazeUntil)
                root.gaze = -1;

            if (root.wander && !root.dragging && !root.menuOpen && ["running-right", "running-left"].indexOf(root.state) >= 0)
                root.rightOffset = Math.max(0, Math.min(win.width - root.petSize, root.rightOffset + (root.state === "running-left" ? 4 : -4)));

        }
    }

    Timer {
        interval: 12000
        repeat: true
        running: root.active && root.wander && !root.motionPaused && !root.dragging && !root.menuOpen
        onTriggered: {
            if (root.state === "idle") {
                root.animate(Math.random() > 0.5 ? "running-left" : "running-right");
            }
        }
    }

    Timer {
        interval: 250
        repeat: true
        running: root.active && root.followPointer && !root.motionPaused && !root.menuOpen && !root.dragging && root.state === "idle"
        onTriggered: {
            if (!cursor.running) {
                cursor.running = true;
            }
        }
    }

    Process {
        id: cursor

        command: ["hyprctl", "-j", "cursorpos"]

        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var pos = JSON.parse(text), monitor = root.targetMonitor;
                    if (!monitor)
                        return ;

                    if (pos.x === root.lastCursorX && pos.y === root.lastCursorY)
                        return ;

                    root.lastCursorX = pos.x;
                    root.lastCursorY = pos.y;
                    var x = pos.x - monitor.x, y = pos.y - monitor.y;
                    if (x < 0 || y < 0 || x > win.width || y > win.height) {
                        root.gaze = -1;
                        return ;
                    }
                    var dx = x - (pet.x + pet.width / 2), dy = y - (pet.y + pet.height / 2);
                    if (Math.hypot(dx, dy) < root.petSize / 2) {
                        root.gaze = -1;
                        return ;
                    }
                    root.gaze = Math.round(((Math.atan2(dx, -dy) * 180 / Math.PI + 360) % 360) / 22.5) % 16;
                    root.gazeUntil = Date.now() + 1100;
                } catch (e) {
                    console.warn("Spool cursor:", e);
                }
            }
        }

    }

    IpcHandler {
        function status() : string {
            return JSON.stringify({
                "shown": root.shown,
                "visible": win.visible,
                "state": root.state,
                "frame": root.frame,
                "gaze": root.gaze,
                "monitor": root.targetScreen ? root.targetScreen.name : "",
                "size": root.petSize,
                "right": root.rightOffset,
                "bottom": root.bottomOffset,
                "imageReady": sheet.status === Image.Ready,
                "fullscreen": root.fullscreen,
                "menu": root.menuOpen,
                "autoActivity": root.autoActivity,
                "activityState": root.activityState,
                "activity": root.activity,
                "activityExpanded": root.activityExpanded,
                "miniMode": root.miniMode,
                "activityBadgeHeight": activityBadge.height,
                "selectedTaskIndex": root.selectedTaskIndex,
                "selectedTaskKey": root.selectedTaskKey,
                "pinnedTaskKey": root.pinnedTaskKey,
                "orderedTaskKeys": root.orderedTasks.map(TaskQueue.key),
                "attentionCount": root.attentionTasks.length,
                "recent": root.activityStore.recent,
                "snoozes": root.snoozes,
                "pausePet": root.pausePet,
                "onlyAttention": root.onlyAttention
            });
        }

        function cycleTask(direction: int) : string {
            root.cycleActivity(direction);
            return "ok";
        }

        function snooze(mode: string) : string {
            root.snoozeTask(root.selectedTask, mode);
            return "ok";
        }

        function resumeSnoozed() : string {
            root.snoozes = ({
            });
            root.save();
            return "ok";
        }

        function history() : string {
            root.toggleHistory(root.selectedTask);
            return "ok";
        }

        function dismissRecent() : string {
            root.dismissTask(root.selectedTask);
            return "ok";
        }

        function pinTask() : string {
            root.togglePin(root.selectedTask);
            return "ok";
        }

        function mini() : string {
            root.setMini(!root.miniMode);
            return "ok";
        }

        function activityTray() : string {
            root.activityExpanded = !root.activityExpanded;
            root.save();
            return "ok";
        }

        function show() : string {
            root.shown = true;
            root.save();
            return "ok";
        }

        function hide() : string {
            root.shown = false;
            root.menuOpen = false;
            root.save();
            return "ok";
        }

        function toggle() : string {
            root.shown = !root.shown;
            root.save();
            return "ok";
        }

        function animate(name: string) : string {
            return root.animate(name);
        }

        function configure(json: string) : string {
            try {
                root.apply(JSON.parse(json));
                root.save();
                return "ok";
            } catch (e) {
                return String(e);
            }
        }

        function menu() : string {
            root.menuOpen = !root.menuOpen;
            return "ok";
        }

        target: "spool"
    }

    PanelWindow {
        id: win

        screen: root.targetScreen
        visible: root.active
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "spool"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }

        Item {
            id: pet

            width: root.petSize
            height: width * 208 / 192
            x: Math.max(0, win.width - width - root.rightOffset)
            y: Math.max(0, win.height - height - root.bottomOffset)
            clip: true

            Image {
                id: sheet

                source: "assets/spool.png"
                width: pet.width * 8
                height: pet.height * 11
                x: -root.spriteFrame * pet.width
                y: -root.spriteRow * pet.height
                smooth: true
            }

            MouseArea {
                property point origin
                property real initialRight
                property real initialBottom
                property bool moved: false

                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
                onPressed: (mouse) => {
                    origin = mapToItem(win.contentItem, mouse.x, mouse.y);
                    initialRight = root.rightOffset;
                    initialBottom = root.bottomOffset;
                    moved = false;
                    if (mouse.button === Qt.LeftButton)
                        root.dragging = true;

                }
                onPositionChanged: (mouse) => {
                    if (!root.dragging)
                        return ;

                    var point = mapToItem(win.contentItem, mouse.x, mouse.y), dx = point.x - origin.x, dy = point.y - origin.y;
                    if (Math.abs(dx) + Math.abs(dy) > 4)
                        moved = true;

                    if (moved) {
                        root.rightOffset = Math.max(0, Math.min(win.width - pet.width, initialRight - dx));
                        root.bottomOffset = Math.max(0, Math.min(win.height - pet.height, initialBottom - dy));
                    }
                }
                onReleased: (mouse) => {
                    root.dragging = false;
                    if (mouse.button === Qt.RightButton) {
                        root.menuOpen = !root.menuOpen;
                    } else if (mouse.button === Qt.MiddleButton) {
                        root.animate("waving");
                    } else if (!moved) {
                        if (root.autoActivity && root.selectedTask)
                            root.openTask();
                        else
                            root.animate("jumping");
                    }
                    if (moved)
                        root.save();

                }
                onCanceled: root.dragging = false
            }

        }

        Rectangle {
            id: activityBadge

            property int count: root.orderedTasks.length
            property string progressText: root.selectedTask ? (root.selectedTask.progressText || "") : ""
            property string taskTitle: root.selectedTask ? (root.selectedTask.title || "Chat") : ""

            visible: root.autoActivity && (count > 0 || root.attentionTasks.length > 0 || Object.keys(root.snoozes).length > 0 || root.activityStore.recent.length > 0) && !root.menuOpen
            width: visible ? Math.min(root.miniMode ? 340 : 380, win.width - 16) : 0
            height: visible ? root.miniMode ? 38 : 62 + (root.activityExpanded ? Math.max(taskList.height, activityBadge.count ? 0 : 24) + 8 : badgeContent.implicitHeight + 16) : 0
            x: Math.max(8, Math.min(win.width - width - 8, pet.x + pet.width / 2 - width / 2))
            y: Math.max(8, pet.y - height - 8)
            radius: 10
            color: "#100b19"
            border.color: root.activityState === "failed" ? "#ff5f70" : root.activityState === "waiting" ? "#ffcc66" : "#00ff88"

            Rectangle {
                visible: !root.miniMode && !root.activityExpanded && activityBadge.count > 1
                x: 6
                y: -6
                width: parent.width - 12
                height: 12
                z: -1
                radius: 8
                color: "#24182f"
                border.color: "#65526d"
            }

            Rectangle {
                visible: !root.miniMode && !root.activityExpanded && activityBadge.count > 2
                x: 12
                y: -12
                width: parent.width - 24
                height: 12
                z: -2
                radius: 8
                color: "#1b1324"
                border.color: "#493754"
            }

            Item {
                anchors.fill: parent
                visible: root.miniMode

                MouseArea {
                    id: miniMouse

                    anchors.fill: parent
                    onClicked: root.openTask()
                    onWheel: (wheel) => {
                        root.cycleActivity(wheel.angleDelta.y > 0 ? -1 : 1);
                        wheel.accepted = true;
                    }
                }

                ProviderMark {
                    x: 10
                    anchors.verticalCenter: parent.verticalCenter
                    task: root.selectedTask || ({
                    })
                }

                Text {
                    x: 36
                    anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 72 - (root.attentionTasks.length ? 40 : 0)
                    color: "#f0ece4"
                    font.pixelSize: 11
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: root.selectedTask ? (root.hoveredSourceKey === root.selectedTaskKey ? ActivityStore.source(root.selectedTask) : (root.selectedTaskKey === root.pinnedTaskKey ? "◆ " : "") + root.activityLabel(root.selectedTask) + " · " + activityBadge.count + " · " + activityBadge.taskTitle) : "No activity in this view"
                }

                Rectangle {
                    anchors.right: miniExpand.left
                    anchors.rightMargin: 4
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34
                    height: 22
                    radius: 5
                    visible: root.attentionTasks.length > 0
                    color: "#5d4020"

                    Text {
                        anchors.centerIn: parent
                        text: "! " + root.attentionTasks.length
                        color: "#ffcc66"
                        font.pixelSize: 11
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.showAttention()
                    }

                }

                Rectangle {
                    id: miniExpand

                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    width: 26
                    height: 26
                    radius: 5
                    color: expandMouse.containsMouse ? "#382350" : "transparent"

                    Text {
                        anchors.centerIn: parent
                        text: "⌃"
                        color: "#f0ece4"
                        font.pixelSize: 18
                    }

                    MouseArea {
                        id: expandMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: root.setMini(false)
                    }

                }

            }

            Item {
                visible: !root.miniMode
                x: 10
                y: 3
                width: parent.width - 20
                height: 28

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Activity · " + activityBadge.count
                    color: "#f0ece4"
                    font.pixelSize: 12
                    font.bold: true
                }

                Rectangle {
                    x: 88
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34
                    height: 21
                    radius: 5
                    visible: root.attentionTasks.length > 0
                    color: "#5d4020"

                    Text {
                        anchors.centerIn: parent
                        text: "! " + root.attentionTasks.length
                        color: "#ffcc66"
                        font.pixelSize: 11
                    }

                    MouseArea {
                        anchors.fill: parent
                        onClicked: root.showAttention()
                    }

                }

                Row {
                    anchors.right: parent.right
                    height: 28
                    spacing: 2

                    Repeater {
                        model: ["‹", (root.selectedTaskIndex + 1) + " / " + activityBadge.count, "›", root.selectedTask && TaskQueue.key(root.selectedTask) === root.pinnedTaskKey ? "Unpin" : "Pin", root.activityExpanded ? "⌄" : "⌃", "−"]

                        delegate: Rectangle {
                            required property int index
                            required property string modelData

                            width: index === 1 ? 46 : index === 3 ? 42 : 26
                            height: 26
                            radius: 5
                            color: navMouse.containsMouse && index !== 1 ? "#382350" : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: modelData
                                color: "#f0ece4"
                                font.pixelSize: (index === 1 || index === 3) ? 11 : 18
                            }

                            MouseArea {
                                id: navMouse

                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: index !== 1
                                onClicked: root.navigationAction(index)
                            }

                        }

                    }

                }

            }

            Row {
                visible: !root.miniMode
                x: 10
                y: 34
                spacing: 14
                height: 24

                Repeater {
                    model: ["Recent (" + root.activityStore.recent.length + ") " + (root.recentExpanded ? "⌄" : "›"), "Snoozed (" + Object.keys(root.snoozes).length + ")", root.onlyAttention ? "Needs attention" : "All activity", root.showSnoozed ? "Resume all" : ""]

                    delegate: Text {
                        required property int index
                        required property string modelData

                        visible: modelData !== ""
                        text: modelData
                        color: index === 1 && root.showSnoozed ? "#ffcc66" : "#b999dd"
                        font.pixelSize: 11

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            onClicked: root.trayAction(index)
                        }

                    }

                }

            }

            MouseArea {
                visible: !root.miniMode && !root.activityExpanded
                x: 0
                y: 62
                width: parent.width
                height: parent.height - 62
                onClicked: root.openTask()
                onWheel: (wheel) => {
                    root.cycleActivity(wheel.angleDelta.y > 0 ? -1 : 1);
                    wheel.accepted = true;
                }
            }

            Column {
                id: badgeContent

                visible: !root.miniMode && !root.activityExpanded
                x: 10
                y: 68
                width: parent.width - 20
                spacing: 5

                Row {
                    spacing: 6

                    ProviderMark {
                        task: root.selectedTask || ({
                        })
                    }

                    Text {
                        color: "#f0ece4"
                        font.pixelSize: 12
                        text: root.activityLabel(root.selectedTask)
                        anchors.verticalCenter: parent.verticalCenter
                    }

                }

                Text {
                    width: parent.width
                    color: "#f0ece4"
                    font.pixelSize: 12
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    text: root.selectedTask ? activityBadge.taskTitle : "No activity in this view"
                }

                SourceDetails {
                    task: root.selectedTask || ({
                    })
                }

                ProgressView {
                    taskKey: root.selectedTaskKey
                    text: root.taskText(root.selectedTask)
                }

                CardActions {
                    visible: !!root.selectedTask
                    task: root.selectedTask || ({
                    })
                }

            }

            Text {
                visible: !root.miniMode && root.activityExpanded && activityBadge.count === 0
                x: 10
                y: 68
                color: "#a99bb8"
                font.pixelSize: 12
                text: "No activity in this view"
            }

            ListView {
                id: taskList

                visible: !root.miniMode && root.activityExpanded
                x: 8
                y: 62
                width: parent.width - 16
                height: visible ? Math.min(contentHeight, 320, win.height * 0.45) : 0
                clip: true
                spacing: 6
                model: root.orderedTasks
                boundsBehavior: Flickable.StopAtBounds

                Rectangle {
                    anchors.right: parent.right
                    width: 3
                    radius: 2
                    color: "#8b6ba4"
                    visible: taskList.contentHeight > taskList.height
                    height: Math.max(20, taskList.height * taskList.height / Math.max(1, taskList.contentHeight))
                    y: Math.max(0, taskList.contentY) * (taskList.height - height) / Math.max(1, taskList.contentHeight - taskList.height)
                }

                delegate: Rectangle {
                    required property var modelData
                    required property int index

                    width: taskList.width - 8
                    height: taskContent.implicitHeight + 16
                    radius: 7
                    color: taskMouse.containsMouse ? "#302039" : "#1e1429"
                    border.color: TaskQueue.key(modelData) === root.selectedTaskKey ? "#9c74d9" : "#3b2b46"

                    MouseArea {
                        id: taskMouse

                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: {
                            root.selectedTaskKey = TaskQueue.key(modelData);
                            root.taskManuallySelected = true;
                            root.openTask();
                        }
                        onWheel: (wheel) => {
                            taskList.contentY = Math.max(0, Math.min(Math.max(0, taskList.contentHeight - taskList.height), taskList.contentY - wheel.angleDelta.y / 3));
                            wheel.accepted = true;
                        }
                    }

                    Column {
                        id: taskContent

                        x: 10
                        y: 8
                        width: parent.width - 20
                        spacing: 4

                        Row {
                            spacing: 6

                            ProviderMark {
                                task: modelData
                            }

                            Text {
                                width: taskContent.width - 80
                                text: (modelData.recent ? "Recent · " : modelData.snoozed ? "Snoozed · " : "") + root.activityLabel(modelData)
                                color: modelData.state === "waiting" ? "#ffcc66" : modelData.state === "failed" ? "#ff5f70" : "#00ff88"
                                textFormat: Text.PlainText
                                font.pixelSize: 11
                                anchors.verticalCenter: parent.verticalCenter
                            }

                        }

                        Text {
                            width: parent.width
                            text: modelData.title || "Chat"
                            color: "#f0ece4"
                            font.pixelSize: 12
                            font.bold: true
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                        }

                        SourceDetails {
                            task: modelData
                        }

                        ProgressView {
                            taskKey: TaskQueue.key(modelData)
                            text: root.taskText(modelData)
                        }

                        CardActions {
                            task: modelData
                        }

                    }

                    Rectangle {
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.margins: 6
                        width: 42
                        height: 22
                        radius: 4
                        color: pinMouse.containsMouse ? "#382350" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            color: "#f0ece4"
                            font.pixelSize: 11
                            text: TaskQueue.key(modelData) === root.pinnedTaskKey ? "Unpin" : "Pin"
                        }

                        MouseArea {
                            id: pinMouse

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.togglePin(modelData)
                        }

                    }

                }

            }

        }

        Rectangle {
            id: menuPanel

            visible: root.menuOpen
            width: visible ? 224 : 0
            height: visible ? 460 : 0
            x: Math.max(8, Math.min(win.width - width - 8, pet.x + pet.width - width))
            y: Math.max(8, pet.y - height - 8)
            color: "#100b19"
            border.color: "#8b5cf6"
            border.width: 2
            radius: 12

            Column {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 4

                Text {
                    text: "SPOOL / SUBCULT"
                    color: "#00ff88"
                    font.bold: true
                    font.pixelSize: 15
                    height: 26
                }

                Repeater {
                    model: ["Wave", "Jump", "Size: " + root.petSize + " px (+32)", "Eyes: " + (root.followPointer ? "on" : "off"), "Wander: " + (root.wander ? "on" : "off"), "Reduced motion: " + (root.reducedMotion ? "on" : "off"), "Monitor: " + (root.targetScreen ? root.targetScreen.name : "none"), "Chat activity: " + (root.autoActivity ? "on" : "off"), "Source: " + ({
                        "t3": "T3 Code",
                        "desktop": "Desktop chats",
                        "all": "Both"
                    })[root.activitySource], "Pet motion: " + (root.pausePet ? "paused" : "on"), "View: " + (root.onlyAttention ? "needs attention" : "all activity"), "Mini mode: " + (root.miniMode ? "on" : "off"), "Hide Spool", "Close"]

                    delegate: Rectangle {
                        required property int index
                        required property string modelData

                        width: 200
                        height: 26
                        radius: 4
                        color: action.containsMouse ? "#382350" : "transparent"

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            x: 6
                            text: modelData
                            color: "#f0ece4"
                            font.pixelSize: 13
                        }

                        MouseArea {
                            id: action

                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: root.menuAction(index)
                        }

                    }

                }

            }

        }

        mask: Region {
            item: pet

            Region {
                item: menuPanel
                intersection: Intersection.Combine
            }

            Region {
                item: activityBadge
                intersection: Intersection.Combine
            }

        }

    }

    component CardActions: Column {
        property var task: ({
        })

        width: parent.width
        spacing: 4

        Row {
            spacing: 12

            Repeater {
                model: [root.historyExpanded[TaskQueue.key(task)] ? "Latest" : "History", task.snoozed ? "Resume" : "Snooze", task.recent ? "Dismiss" : ""]

                delegate: Text {
                    required property int index
                    required property string modelData

                    visible: modelData !== ""
                    text: modelData
                    color: actionMouse.containsMouse ? "#f0ece4" : "#b999dd"
                    font.pixelSize: 11

                    MouseArea {
                        id: actionMouse

                        anchors.fill: parent
                        anchors.margins: -3
                        hoverEnabled: true
                        onClicked: {
                            if (index === 0)
                                root.toggleHistory(task);
                            else if (index === 2)
                                root.dismissTask(task);
                            else if (task.snoozed)
                                root.resumeTask(task);
                            else
                                root.snoozeMenuKey = root.snoozeMenuKey === TaskQueue.key(task) ? "" : TaskQueue.key(task);
                        }
                    }

                }

            }

        }

        Row {
            visible: root.snoozeMenuKey === TaskQueue.key(task)
            spacing: 12

            Repeater {
                model: ["15m", "1h", "next"]

                delegate: Text {
                    required property string modelData

                    text: modelData === "next" ? "Until next run" : modelData
                    color: "#ffcc66"
                    font.pixelSize: 11

                    MouseArea {
                        anchors.fill: parent
                        anchors.margins: -3
                        onClicked: root.snoozeTask(task, modelData)
                    }

                }

            }

        }

    }

    component SourceDetails: Item {
        property var task: ({
        })
        property bool hovered: false

        width: parent.width
        height: details.implicitHeight

        Text {
            id: details

            width: parent.width
            text: (parent.hovered || root.hoveredSourceKey === TaskQueue.key(parent.task)) ? ActivityStore.source(parent.task) : ActivityStore.timing(parent.task, root.clockNow)
            color: "#a99bb8"
            font.pixelSize: 10
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onContainsMouseChanged: parent.hovered = containsMouse
        }

    }

    component ProgressView: Flickable {
        id: progressView

        property string text: ""
        property string taskKey: ""
        property bool initialized: false

        width: parent.width
        height: Math.min(progress.implicitHeight, 80)
        visible: text !== ""
        contentWidth: width
        contentHeight: progress.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        onTextChanged: {
            if (initialized) {
                var saved = root.progressOffsets[taskKey];
                contentY = saved && saved.text === text ? Math.max(0, Math.min(saved.y, Math.max(0, contentHeight - height))) : 0;
            }
        }
        onContentYChanged: {
            if (initialized && taskKey) {
                root.progressOffsets[taskKey] = {
                "text": text,
                "y": contentY
            };
            }
        }
        Component.onCompleted: {
            var saved = root.progressOffsets[taskKey];
            if (saved && saved.text === text)
                contentY = Math.max(0, Math.min(saved.y, Math.max(0, contentHeight - height)));

            initialized = true;
        }

        Text {
            id: progress

            width: progressView.width - 8
            text: progressView.text
            color: "#c9c1d4"
            font.pixelSize: 12
            lineHeight: 16
            lineHeightMode: Text.FixedHeight
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
        }

        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.NoButton
            onWheel: (wheel) => {
                if (progressView.contentHeight > progressView.height) {
                    progressView.contentY = Math.max(0, Math.min(progressView.contentHeight - progressView.height, progressView.contentY - wheel.angleDelta.y / 3));
                    wheel.accepted = true;
                } else {
                    wheel.accepted = false;
                }
            }
        }

        Rectangle {
            anchors.right: parent.right
            width: 3
            radius: 2
            color: "#8b6ba4"
            visible: progressView.contentHeight > progressView.height
            height: Math.max(10, progressView.height * progressView.height / Math.max(1, progressView.contentHeight))
            y: progressView.contentY * (progressView.height - height) / Math.max(1, progressView.contentHeight - progressView.height)
        }

    }

    component ProviderMark: Item {
        property var task: ({
        })
        property string logo: TaskQueue.logo(task)
        property bool hovered: false

        width: 18
        height: 18

        Image {
            anchors.fill: parent
            source: parent.logo ? "assets/providers/" + parent.logo + ".svg" : ""
            visible: parent.logo !== ""
            sourceSize.width: 36
            sourceSize.height: 36
        }

        MouseArea {
            anchors.fill: parent
            hoverEnabled: true
            acceptedButtons: Qt.NoButton
            onContainsMouseChanged: {
                var key = TaskQueue.key(parent.task);
                if (containsMouse)
                    root.hoveredSourceKey = key;
                else if (root.hoveredSourceKey === key)
                    root.hoveredSourceKey = "";
            }
        }

        Text {
            anchors.centerIn: parent
            visible: parent.logo === ""
            text: (parent.task.provider || "?").slice(0, 1).toUpperCase()
            color: "#f0ece4"
            font.pixelSize: 12
        }

    }

}
