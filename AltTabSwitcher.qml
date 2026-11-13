import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets

PanelWindow {
    id: switcher
    property color accentColor: "#25d8a3"
    property var windows: []
    property int selectedIndex: 0
    property int pendingSteps: 0
    property bool commitWhenLoaded: false
    property bool shown: false
    property bool displaying: false
    property bool cardsReady: false
    property bool hadKeyboardFocus: false
    property bool altMonitorReady: false
    property bool altHeld: false
    property double lastAltReleaseAt: 0
    property bool releasePending: false
    property bool initializingSelection: false
    property var pendingFocusId: null
    property real reveal: shown ? 1 : 0
    readonly property int tileSize: 88
    readonly property int tileStep: 100
    readonly property int panelPadding: 18
    readonly property var usableScreen: findUsableScreen()

    function findUsableScreen() {
        const screens = Quickshell.screens
        for (let i = 0; i < screens.length; ++i) {
            const candidate = screens[i]
            if (candidate.name && candidate.width > 0 && candidate.height > 0)
                return candidate
        }
        return null
    }

    screen: usableScreen
    implicitWidth: Math.min((screen ? screen.width : 1920) - 32, 712)
    implicitHeight: 190
    color: "transparent"
    visible: usableScreen !== null
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-alt-tab"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    mask: Region {
        x: panelBackground.x
        y: panelBackground.y
        width: switcher.displaying ? panelBackground.width : 0
        height: switcher.displaying ? panelBackground.height : 0
        radius: panelBackground.radius
    }
    BackgroundEffect.blurRegion: Region {
        x: panelBackground.x
        y: panelBackground.y
        width: switcher.displaying && switcher.cardsReady ? panelBackground.width : 0
        height: switcher.displaying && switcher.cardsReady ? panelBackground.height : 0
        radius: panelBackground.radius
    }

    Behavior on reveal {
        NumberAnimation { duration: 130; easing.type: Easing.OutCubic }
    }

    function timestamp(windowData) {
        const value = windowData.focus_timestamp
        return value ? (value.secs || 0) * 1000000000 + (value.nanos || 0) : 0
    }

    function iconSource(appId) {
        if (appId === "jetbrains-pycharm")
            return "file:///opt/pycharm/bin/pycharm.svg"
        return Quickshell.iconPath(appId || "", "application-x-executable")
    }

    function appName(windowData) {
        const appId = windowData.app_id || ""
        if (appId === "jetbrains-pycharm") return "PyCharm"
        const name = appId ? appId.split(".").pop().replace(/[-_]/g, " ")
                           : (windowData.title || "Window")
        return name.charAt(0).toUpperCase() + name.slice(1)
    }

    function open(direction) {
        if (shown && windows.length > 0) {
            advance(direction)
            return
        }

        pendingSteps += direction
        if (!shown) {
            hideAfterClose.stop()
            showCards.stop()
            cardsReady = false
            windows = []
            selectedIndex = 0
            commitWhenLoaded = false
            rail.contentX = 0
            hadKeyboardFocus = false
            displaying = true
            shown = true
            focusDelay.restart()
            focusWatchdog.restart()
            if (Date.now() - lastAltReleaseAt < 350 && !altHeld)
                requestCommit()
            windowQuery.running = true
        }
    }

    function advance(direction) {
        if (windows.length === 0) return
        selectedIndex = (selectedIndex + direction + windows.length) % windows.length
        const cardX = selectedIndex * tileStep
        const target = Math.max(0, Math.min(cardX - (rail.width - tileSize) / 2,
                                             rail.contentWidth - rail.width))
        rail.contentX = target
    }

    function commit() {
        if (!shown) return
        if (windows.length === 0) {
            commitWhenLoaded = true
            return
        }
        const selected = windows[selectedIndex]
        pendingFocusId = selected.id
        if (!focusCommand.running) sendFocus()
        close()
    }

    function requestCommit() {
        if (!shown) return
        if (cardsReady) {
            commit()
            return
        }
        releasePending = true
    }

    function sendFocus() {
        if (pendingFocusId === null) return
        focusCommand.command = ["niri", "msg", "action", "focus-window", "--id", String(pendingFocusId)]
        pendingFocusId = null
        focusCommand.running = true
    }

    function close() {
        if (!shown) return
        shown = false
        pendingSteps = 0
        commitWhenLoaded = false
        focusWatchdog.stop()
        finishRelease.stop()
        releasePending = false
        showCards.stop()
        hideAfterClose.restart()
    }

    IpcHandler {
        target: "altTab"
        function next(): bool { switcher.open(1); return true }
        function previous(): bool { switcher.open(-1); return true }
    }

    Process {
        id: windowQuery
        command: ["niri", "msg", "-j", "windows"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (!switcher.shown) return
                try {
                    const parsed = JSON.parse(this.text)
                    if (!Array.isArray(parsed)) throw new Error("invalid window list")
                    parsed.sort((a, b) => {
                        if (a.is_focused !== b.is_focused) return a.is_focused ? -1 : 1
                        return switcher.timestamp(b) - switcher.timestamp(a)
                    })
                    const steps = switcher.pendingSteps
                    switcher.pendingSteps = 0
                    if (parsed.length === 0) switcher.close()
                    else {
                        switcher.initializingSelection = true
                        switcher.selectedIndex = ((steps % parsed.length) + parsed.length) % parsed.length
                        switcher.windows = parsed
                        const cardX = switcher.selectedIndex * switcher.tileStep
                        rail.contentX = Math.max(0, Math.min(cardX - (rail.width - switcher.tileSize) / 2,
                                                              rail.contentWidth - rail.width))
                        switcher.initializingSelection = false
                        if (switcher.commitWhenLoaded) switcher.commit()
                        else showCards.restart()
                    }
                } catch (error) {
                    console.warn("Alt+Tab: unable to read niri windows:", error)
                    switcher.close()
                }
            }
        }
    }

    Process {
        id: focusCommand
        onExited: Qt.callLater(() => switcher.sendFocus())
    }

    Process {
        id: altKeyMonitor
        command: ["/usr/bin/python3", Quickshell.shellPath("alt-tab-key-monitor.py")]
        running: true
        onExited: {
            switcher.altMonitorReady = false
            switcher.altHeld = false
        }
        stdout: SplitParser {
            onRead: data => {
                const state = data.trim()
                if (state === "ready") switcher.altMonitorReady = true
                else if (state === "down") {
                    switcher.altHeld = true
                    switcher.releasePending = false
                    finishRelease.stop()
                }
                else if (state === "up") {
                    switcher.altHeld = false
                    switcher.lastAltReleaseAt = Date.now()
                    switcher.requestCommit()
                }
            }
        }
    }

    Timer {
        id: finishRelease
        interval: 35
        onTriggered: {
            if (switcher.shown && switcher.releasePending && !switcher.altHeld)
                switcher.commit()
        }
    }

    Timer {
        id: focusDelay
        interval: 1
        onTriggered: keySurface.forceActiveFocus()
    }

    Timer {
        id: focusWatchdog
        interval: 220
        onTriggered: {
            // A very quick Alt+Tab can release Alt before Wayland grants focus.
            if (switcher.shown && !switcher.hadKeyboardFocus)
                switcher.requestCommit()
        }
    }

    Timer {
        id: showCards
        interval: 1
        onTriggered: {
            if (switcher.shown && switcher.windows.length > 0)
                switcher.cardsReady = true
            if (switcher.cardsReady && switcher.releasePending)
                finishRelease.restart()
        }
    }

    Timer {
        id: hideAfterClose
        interval: 150
        onTriggered: {
            switcher.displaying = false
            switcher.cardsReady = false
        }
    }

    FocusScope {
        id: keySurface
        anchors.fill: parent
        focus: switcher.shown
        onActiveFocusChanged: {
            if (activeFocus) switcher.hadKeyboardFocus = true
            else if (switcher.shown && switcher.hadKeyboardFocus) switcher.close()
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Escape) switcher.close()
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                switcher.commit()
            else if (event.key === Qt.Key_Left) switcher.advance(-1)
            else if (event.key === Qt.Key_Right) switcher.advance(1)
            else if (event.key === Qt.Key_Tab)
                switcher.advance(event.modifiers & Qt.ShiftModifier ? -1 : 1)
            else return
            event.accepted = true
        }

        Keys.onReleased: event => {
            if (event.key === Qt.Key_Alt && !event.isAutoRepeat) {
                switcher.requestCommit()
                event.accepted = true
            }
        }

        Rectangle {
            id: panelBackground
            x: rail.x - switcher.panelPadding
            y: rail.y - switcher.panelPadding
            width: rail.width + switcher.panelPadding * 2
            height: rail.height + switcher.panelPadding * 2
            radius: 18
            color: "#800b0e0d"
            opacity: switcher.reveal
            visible: switcher.cardsReady
        }

        Rectangle {
            anchors.fill: panelBackground
            radius: panelBackground.radius
            color: "transparent"
            border.width: 1
            border.color: "#66ffffff"
            opacity: panelBackground.opacity
            visible: panelBackground.visible
            layer.enabled: true
            layer.effect: MultiEffect {
                shadowEnabled: true
                shadowColor: "#66ffffff"
                shadowBlur: 0.65
                blurMax: 8
                shadowVerticalOffset: 0
                shadowHorizontalOffset: 0
            }
        }

        Flickable {
            id: rail
            width: Math.min(keySurface.width - switcher.panelPadding * 2,
                            Math.max(0, switcher.windows.length * switcher.tileStep - 12))
            height: switcher.tileSize
            x: (keySurface.width - width) / 2
            y: (keySurface.height - height) / 2
            opacity: switcher.reveal
            visible: switcher.cardsReady
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            interactive: false
            contentWidth: Math.max(width, switcher.windows.length * switcher.tileStep - 12)
            Behavior on contentX {
                enabled: !switcher.initializingSelection
                NumberAnimation { duration: 80; easing.type: Easing.OutCubic }
            }

            Row {
                spacing: 12
                Repeater {
                    model: switcher.windows
                    delegate: Item {
                        required property var modelData
                        required property int index
                        readonly property bool selected: index === switcher.selectedIndex
                        width: switcher.tileSize
                        height: rail.height

                        Rectangle {
                            id: iconTile
                            width: parent.width
                            height: switcher.tileSize
                            radius: 14
                            color: parent.selected ? "#a0294b40"
                                   : (iconMouse.containsMouse ? "#7526302c" : "transparent")
                            border.width: parent.selected ? 2 : 0
                            border.color: switcher.accentColor

                            IconImage {
                                anchors.centerIn: parent
                                width: 72
                                height: 72
                                source: switcher.iconSource(modelData.app_id)
                            }
                        }

                        MouseArea {
                            id: iconMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                switcher.selectedIndex = index
                                switcher.commit()
                            }
                        }
                    }
                }
            }
        }

        Text {
            x: rail.x + rail.width / 2
               + rail.scale * (switcher.selectedIndex * switcher.tileStep
                   - rail.contentX + switcher.tileSize / 2 - rail.width / 2)
               - switcher.tileSize / 2
            y: rail.y + rail.height / 2
               + rail.scale * (switcher.tileSize / 2 + 2)
            width: switcher.tileSize
            text: switcher.windows.length > 0
                ? switcher.appName(switcher.windows[switcher.selectedIndex]) : ""
            visible: switcher.cardsReady
            opacity: switcher.reveal
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            color: "#e8f7f0"
            font.family: "SF Pro Rounded"
            font.pixelSize: 11
            font.weight: Font.Medium
        }
    }
}
