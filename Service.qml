import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland

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
    property string originThread: ""
    property string activityState: "idle"
    property var activity: ({connected:false,counts:{},tasks:[]})
    property var savedPreferences: ({})
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
    property var rows: ({"idle":0,"running-right":1,"running-left":2,"waving":3,"jumping":4,"failed":5,"waiting":6,"running":7,"review":8})
    property var timings: [ [280,110,110,140,140,320], [120,120,120,120,120,120,120,220], [120,120,120,120,120,120,120,220], [140,140,140,280], [140,140,140,140,280], [140,140,140,140,140,140,140,240], [150,150,150,150,150,260], [120,120,120,120,120,220], [150,150,150,150,150,280] ]
    property var targetScreen: {
        var screens = Quickshell.screens;
        for (var i=0;i<screens.length;i++) if (screens[i].name===monitorName) return screens[i];
        return screens.length ? screens[0] : null;
    }
    property var targetMonitor: {
        var monitors=Hyprland.monitors.values;
        for(var i=0;i<monitors.length;i++) if(targetScreen && monitors[i].name===targetScreen.name) return monitors[i];
        return null;
    }
    property bool fullscreen: hideFullscreen && targetMonitor && targetMonitor.activeWorkspace ? targetMonitor.activeWorkspace.hasFullscreen : false
    property bool active: shown && !fullscreen && targetScreen !== null
    property int spriteRow: !reducedMotion && gaze>=0 && state==="idle" ? 9+Math.floor(gaze/8) : rows[state]
    property int spriteFrame: reducedMotion ? 0 : (!reducedMotion && gaze>=0 && state==="idle" ? gaze%8 : frame)

    function settings() { return {shown:shown,size:petSize,monitor:monitorName,right:rightOffset,bottom:bottomOffset,followPointer:followPointer,wander:wander,reducedMotion:reducedMotion,hideFullscreen:hideFullscreen,autoActivity:autoActivity,originThread:originThread}; }
    function apply(s) {
        if(s.shown!==undefined) shown=!!s.shown;
        if(s.size!==undefined) petSize=Math.max(64,Math.min(256,Number(s.size)||128));
        if(s.monitor!==undefined) monitorName=String(s.monitor);
        if(s.right!==undefined) rightOffset=Math.max(0,Number(s.right)||0);
        if(s.bottom!==undefined) bottomOffset=Math.max(0,Number(s.bottom)||0);
        if(s.originThread!==undefined) originThread=String(s.originThread);
        for(var key of ["followPointer","wander","reducedMotion","hideFullscreen","autoActivity"]) if(s[key]!==undefined) root[key]=!!s[key];
    }
    function save() {
        var value=settings();
        savedPreferences=value;
        var text=JSON.stringify(value);
        if(preferenceFile.text()!==text) preferenceFile.setText(text);
        if(shell) shell.updateEntryInline("onnwee.spool",value);
    }
    function readSettings() {
        try { if(!configFile.loaded) return; apply(savedPreferences); var config=JSON.parse(configFile.text()); for(var entry of (config.plugins||[])) if(entry.id==="onnwee.spool") { apply(entry); return; } } catch(e) { console.warn("Spool settings:",e); }
    }
    function animate(name) {
        if(rows[name]===undefined) return "unknown state";
        state=name; frame=0; gaze=-1; animation.restart(); return "ok";
    }
    function receiveActivity(data) {
        if(["idle","running","waiting","failed","review","waving"].indexOf(data.state)<0) return;
        activity=data; lastActivityAt=Date.now();
        var previous=activityState;
        activityState=autoActivity ? data.state : "idle";
        if(activityState!==previous && (state===previous || state==="idle" || ["running","waiting","failed","review"].indexOf(state)>=0)) animate(activityState);
    }
    function openTask() {
        if(!activity.tasks || !activity.tasks.length) return;
        var task=activity.tasks[0];
        Quickshell.execDetached(["python3",bridgeScript,"--origin-thread",originThread,"--open",task.id]);
    }
    onAutoActivityChanged: {
        if(!autoActivity) {
            activityBridge.running=false;
            receiveActivity({state:"idle",connected:false,counts:{},tasks:[]});
        }
    }
    onOriginThreadChanged: activityBridge.running=false
    Process {
        id: activityBridge
        command: ["python3",root.bridgeScript,"--origin-thread",root.originThread]
        running: root.autoActivity && root.originThread!==""
        stdout: SplitParser {
            onRead: data => { try { root.receiveActivity(JSON.parse(data)); } catch(e) { console.warn("Spool activity data invalid"); } }
        }
    }
    Timer {
        interval: 5000; repeat:true
        running: root.autoActivity && root.originThread!==""
        onTriggered: if(!activityBridge.running) activityBridge.running=true
    }
    Timer {
        interval: 1000; repeat:true; running: root.autoActivity
        onTriggered: if(root.lastActivityAt>0 && Date.now()-root.lastActivityAt>45000 && root.activity.connected) root.receiveActivity({state:"idle",connected:false,counts:{},tasks:[]})
    }
    function cycleMonitor() {
        var screens=Quickshell.screens;
        for(var i=0;i<screens.length;i++) if(targetScreen===screens[i]) { monitorName=screens[(i+1)%screens.length].name; break; }
        save();
    }
    FileView {
        id: preferenceFile
        path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME")+"/.local/state")+"/spool/preferences.json"
        atomicWrites: true
        printErrors: false
        onLoaded: {
            try { root.savedPreferences=JSON.parse(text()); root.readSettings(); }
            catch(e) { console.warn("Spool saved preferences invalid"); }
        }
    }
    FileView {
        id: configFile
        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME")+"/.config")+"/omarchy/shell.json"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.readSettings()
    }
    Timer {
        id: animation
        interval: root.timings[root.rows[root.state]][root.frame]
        running: root.active && !root.reducedMotion
        repeat: true
        onTriggered: {
            var count=root.timings[root.rows[root.state]].length;
            root.frame=(root.frame+1)%count;
            if(root.frame===0 && ["waving","jumping","failed","running-right","running-left"].indexOf(root.state)>=0 && !(root.state==="failed" && root.autoActivity && root.activityState==="failed")) {
                root.state=root.autoActivity && root.activityState!=="waving" ? root.activityState : "idle";
                root.frame=0; root.save();
            }
            if(root.gaze>=0 && Date.now()>root.gazeUntil) root.gaze=-1;
            if(root.wander && !root.dragging && !root.menuOpen && ["running-right","running-left"].indexOf(root.state)>=0) {
                root.rightOffset=Math.max(0,Math.min(win.width-root.petSize,root.rightOffset+(root.state==="running-left"?4:-4)));
            }
        }
    }
    Timer {
        interval: 12000; repeat: true
        running: root.active && root.wander && !root.reducedMotion && !root.dragging && !root.menuOpen
        onTriggered: if(root.state==="idle") root.animate(Math.random()>0.5?"running-left":"running-right")
    }
    Timer {
        interval: 250; repeat: true
        running: root.active && root.followPointer && !root.reducedMotion && !root.menuOpen && !root.dragging && root.state==="idle"
        onTriggered: if(!cursor.running) cursor.running=true
    }
    Process {
        id: cursor
        command: ["hyprctl","-j","cursorpos"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var pos=JSON.parse(text), monitor=root.targetMonitor;
                    if(!monitor) return;
                    if(pos.x===root.lastCursorX && pos.y===root.lastCursorY) return;
                    root.lastCursorX=pos.x; root.lastCursorY=pos.y;
                    var x=pos.x-monitor.x, y=pos.y-monitor.y;
                    if(x<0 || y<0 || x>win.width || y>win.height) { root.gaze=-1; return; }
                    var dx=x-(pet.x+pet.width/2), dy=y-(pet.y+pet.height/2);
                    if(Math.hypot(dx,dy)<root.petSize/2) { root.gaze=-1; return; }
                    root.gaze=Math.round(((Math.atan2(dx,-dy)*180/Math.PI+360)%360)/22.5)%16;
                    root.gazeUntil=Date.now()+1100;
                } catch(e) { console.warn("Spool cursor:",e); }
            }
        }
    }
    IpcHandler {
        target: "spool"
        function status(): string { return JSON.stringify({shown:root.shown,visible:win.visible,state:root.state,frame:root.frame,gaze:root.gaze,monitor:root.targetScreen?root.targetScreen.name:"",size:root.petSize,right:root.rightOffset,bottom:root.bottomOffset,imageReady:sheet.status===Image.Ready,fullscreen:root.fullscreen,menu:root.menuOpen,autoActivity:root.autoActivity,activityState:root.activityState,activity:root.activity}); }
        function show(): string { root.shown=true; root.save(); return "ok"; }
        function hide(): string { root.shown=false; root.menuOpen=false; root.save(); return "ok"; }
        function toggle(): string { root.shown=!root.shown; root.save(); return "ok"; }
        function animate(name: string): string { return root.animate(name); }
        function configure(json: string): string { try { root.apply(JSON.parse(json)); root.save(); return "ok"; } catch(e) { return String(e); } }
        function menu(): string { root.menuOpen=!root.menuOpen; return "ok"; }
    }
    PanelWindow {
        id: win
        screen: root.targetScreen
        visible: root.active
        anchors { top:true; bottom:true; left:true; right:true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "spool"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
        mask: Region {
            item: pet
            Region { item: menuPanel; intersection: Intersection.Combine }
            Region { item: activityBadge; intersection: Intersection.Combine }
        }
        Item {
            id: pet
            width: root.petSize; height: width*208/192
            x: Math.max(0,win.width-width-root.rightOffset)
            y: Math.max(0,win.height-height-root.bottomOffset)
            clip: true
            Image {
                id: sheet
                source: "assets/spool.png"
                width: pet.width*8; height: pet.height*11
                x: -root.spriteFrame*pet.width; y: -root.spriteRow*pet.height
                smooth: true
            }
            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.LeftButton|Qt.RightButton|Qt.MiddleButton
                property point origin
                property real initialRight
                property real initialBottom
                property bool moved: false
                onPressed: mouse => {
                    origin=mapToItem(win.contentItem,mouse.x,mouse.y);
                    initialRight=root.rightOffset; initialBottom=root.bottomOffset; moved=false;
                    if(mouse.button===Qt.LeftButton) root.dragging=true;
                }
                onPositionChanged: mouse => {
                    if(!root.dragging) return;
                    var point=mapToItem(win.contentItem,mouse.x,mouse.y), dx=point.x-origin.x, dy=point.y-origin.y;
                    if(Math.abs(dx)+Math.abs(dy)>4) moved=true;
                    if(moved) { root.rightOffset=Math.max(0,Math.min(win.width-pet.width,initialRight-dx)); root.bottomOffset=Math.max(0,Math.min(win.height-pet.height,initialBottom-dy)); }
                }
                onReleased: mouse => {
                    root.dragging=false;
                    if(mouse.button===Qt.RightButton) root.menuOpen=!root.menuOpen;
                    else if(mouse.button===Qt.MiddleButton) root.animate("waving");
                    else if(!moved) root.animate("jumping");
                    if(moved) root.save();
                }
                onCanceled: root.dragging=false
            }
        }
        Rectangle {
            id: activityBadge
            property int count: root.activity.tasks ? root.activity.tasks.length : 0
            visible: root.autoActivity && root.activity.connected && count>0 && !root.menuOpen
            width: visible ? 150 : 0; height: visible ? 30 : 0
            x: Math.max(8,Math.min(win.width-width-8,pet.x+pet.width/2-width/2))
            y: Math.max(8,pet.y-height-8)
            radius: 10; color: "#100b19"
            border.color: root.activityState==="failed"?"#ff5f70":root.activityState==="waiting"?"#ffcc66":"#00ff88"
            Text {
                anchors.centerIn: parent; color:"#f0ece4"; font.pixelSize:12
                text: ({running:"Thinking",waiting:"Needs you",failed:"Task failed",review:"Ready for review"})[root.activityState]+(activityBadge.count>1?" · "+activityBadge.count:"")
            }
            MouseArea { anchors.fill:parent; onClicked:root.openTask() }
        }
        Rectangle {
            id: menuPanel
            visible: root.menuOpen
            width: visible?224:0; height: visible?348:0
            x: Math.max(8,Math.min(win.width-width-8,pet.x+pet.width-width))
            y: Math.max(8,pet.y-height-8)
            color: "#100b19"; border.color: "#8b5cf6"; border.width: 2; radius: 12
            Column {
                anchors.fill: parent; anchors.margins: 12; spacing: 4
                Text { text:"SPOOL / SUBCULT"; color:"#00ff88"; font.bold:true; font.pixelSize:15; height:26 }
                Repeater {
                    model: ["Wave", "Jump", "Size: "+root.petSize+" px (+32)", "Eyes: "+(root.followPointer?"on":"off"), "Wander: "+(root.wander?"on":"off"), "Reduced motion: "+(root.reducedMotion?"on":"off"), "Monitor: "+(root.targetScreen?root.targetScreen.name:"none"), "Chat activity: "+(root.autoActivity?"on":"off"), "Hide Spool", "Close"]
                    delegate: Rectangle {
                        required property int index
                        required property string modelData
                        width: 200; height: 26; radius: 4
                        color: action.containsMouse?"#382350":"transparent"
                        Text { anchors.verticalCenter:parent.verticalCenter; x:6; text:modelData; color:"#f0ece4"; font.pixelSize:13 }
                        MouseArea {
                            id: action; anchors.fill:parent; hoverEnabled:true
                            onClicked: {
                                switch(index) {
                                case 0: root.animate("waving"); break;
                                case 1: root.animate("jumping"); break;
                                case 2: root.petSize=root.petSize>=192?64:root.petSize+32; break;
                                case 3: root.followPointer=!root.followPointer; root.gaze=-1; break;
                                case 4: root.wander=!root.wander; break;
                                case 5: root.reducedMotion=!root.reducedMotion; root.gaze=-1; break;
                                case 6: root.cycleMonitor(); break;
                                case 7: root.autoActivity=!root.autoActivity; break;
                                case 8: root.shown=false; root.menuOpen=false; break;
                                case 9: root.menuOpen=false; break;
                                }
                                root.save();
                            }
                        }
                    }
                }
            }
        }
    }
}
