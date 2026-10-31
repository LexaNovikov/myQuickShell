import QtQuick
import Quickshell
import QtQuick.Controls
import Quickshell.Io
import Quickshell.Services.Pipewire
import Quickshell.Services.Notifications
import Quickshell.Widgets
import Quickshell.Wayland

ShellRoot {
    id: shellRoot
    property string accentColor: "#25d8a3"
    property string selectedWallpaper: ""
    property bool smartPaletteEnabled: false
    property bool nightModeForced: false
    property bool nightModeScheduleEnabled: false
    property int nightModeTemperature: 5600
    property string nightModeFrom: "21:00:00"
    property string nightModeTo: "07:00:00"

    IdleMonitor {
        timeout: 300
        onIsIdleChanged: {
            if (isIdle) {
                if (!monitorsOffCommand.running)
                    monitorsOffCommand.running = true
            } else if (!monitorsOnCommand.running) {
                monitorsOnCommand.running = true
            }
        }
    }

    IdleMonitor {
        timeout: 600
        onIsIdleChanged: {
            if (isIdle && !idleSuspendCommand.running)
                idleSuspendCommand.running = true
        }
    }

    IdleMonitor {
        timeout: 900
        onIsIdleChanged: {
            if (isIdle && !idleLockCommand.running)
                idleLockCommand.running = true
        }
    }

    Process {
        id: monitorsOffCommand
        command: ["niri", "msg", "action", "power-off-monitors"]
    }

    Process {
        id: monitorsOnCommand
        command: ["niri", "msg", "action", "power-on-monitors"]
    }

    Process {
        id: idleSuspendCommand
        command: [Quickshell.shellPath("session-action.sh"), "lock-and-suspend"]
    }

    Process {
        id: idleLockCommand
        command: [Quickshell.shellPath("session-action.sh"), "lock"]
    }

    NotificationServer {
        id: notificationServer
        keepOnReload: false
        persistenceSupported: false
        bodySupported: true
        imageSupported: true
        actionsSupported: true
        inlineReplySupported: true

        onNotification: notification => {
            let panel = panelVariants.instances.length > 0 ? panelVariants.instances[0] : null
            if (panel) panel.presentNotification(notification)
        }
    }

    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink, Pipewire.defaultAudioSource]
    }

    Variants {
        id: panelVariants
        model: Quickshell.screens

        delegate: PanelWindow {
        property var modelData
        screen: modelData
        id: mainWindow
        anchors { top: true; left: true; right: true }
        focusable: island.notificationCanReply
            || (controlCenter.isOpen
                && (controlCenter.wifiMenuOpen || controlCenter.nightModeMenuOpen
                    || controlCenter.personalizationMenuOpen))

        function presentNotification(notification) {
            if (island.notificationReplyOpen) {
                console.info("Notification ignored while composing reply:", notification.appName)
                return
            }

            island.hideSystemOsd()

            let advertisedActions = []
            for (let index = 0; index < notification.actions.length; ++index) {
                let action = notification.actions[index]
                advertisedActions.push(action.identifier + ":" + action.text)
            }
            console.info("Notification actions:", notification.appName,
                         "inlineReply=" + notification.hasInlineReply,
                         advertisedActions.join(", "))

            let previous = island.activeNotification
            island.activeNotification = null
            if (previous) previous.expire()

            notification.tracked = true
            island.activeNotification = notification
            island.notificationReplyOpen = false
            notificationFocusDelay.stop()
            notificationReplyInput.text = ""
            island.expanded = false
            playerWidget.expanded = false
            controlCenter.isOpen = false
            notificationTimeout.restart()
        }

        property int playerSurfaceHeight: 32
        property int islandSurfaceHeight: 32
        property int controlSurfaceHeight: 32

        function reservePlayerHeight(target) {
            if (target >= playerSurfaceHeight) {
                playerSurfaceShrink.stop()
                playerSurfaceHeight = target
            } else {
                playerSurfaceShrink.targetHeight = target
                playerSurfaceShrink.restart()
            }
        }

        function reserveIslandHeight(target) {
            if (target >= islandSurfaceHeight) {
                islandSurfaceShrink.stop()
                islandSurfaceHeight = target
            } else {
                islandSurfaceShrink.targetHeight = target
                islandSurfaceShrink.restart()
            }
        }

        function reserveControlHeight(target) {
            if (target >= controlSurfaceHeight) {
                controlSurfaceShrink.stop()
                controlSurfaceHeight = target
            } else {
                controlSurfaceShrink.targetHeight = target
                controlSurfaceShrink.restart()
            }
        }

        Timer {
            id: playerSurfaceShrink
            property int targetHeight: 32
            interval: 300
            onTriggered: mainWindow.playerSurfaceHeight = targetHeight
        }

        Timer {
            id: islandSurfaceShrink
            property int targetHeight: 32
            interval: 320
            onTriggered: mainWindow.islandSurfaceHeight = targetHeight
        }

        Timer {
            id: controlSurfaceShrink
            property int targetHeight: 32
            interval: 320
            onTriggered: mainWindow.controlSurfaceHeight = targetHeight
        }

        implicitHeight: {
            let ctrlHeight = controlSurfaceHeight > 32 ? controlWidget.y + controlSurfaceHeight + 20 : 0
            let playerHeight = playerSurfaceHeight > 32 ? playerWidget.y + playerSurfaceHeight + 20 : 0
            return Math.max(islandSurfaceHeight + 20, Math.max(ctrlHeight, playerHeight))
        }
        color: "transparent"
        exclusiveZone: 38
        mask: Region {
            item: island
            radius: island.radius

            Region {
                item: playerWidget
                radius: playerWidget.radius
            }

            Region {
                item: controlWidget
                radius: controlWidget.radius
            }
        }

        // 1. Иконка плеера слева
        Rectangle {
            id: playerWidget
            property bool expanded: false
            readonly property int targetHeight: expanded ? 160 : 32

            // Внутренние переменные состояния
            property string trackTitle: "Тишина"
            property string trackArtist: ""
            property string trackAlbum: ""
            property string trackArt: ""
            property real trackPosition: 0
            property real trackLength: 0
            property string trackStatus: "Stopped"
            property var availablePlayers: []
            property string selectedPlayer: ""
            property bool sourceMenuOpen: false
            readonly property bool showCompactArtwork: trackStatus === "Playing" && trackArt !== ""
            readonly property var playerChoices: {
                let choices = [{ id: "", label: "Auto" }]
                for (let i = 0; i < availablePlayers.length; ++i) {
                    let player = availablePlayers[i]
                    choices.push({ id: player, label: friendlyPlayerName(player) })
                }
                return choices
            }
            readonly property string selectedPlayerLabel: selectedPlayer === ""
                ? "Auto" : friendlyPlayerName(selectedPlayer)

            function friendlyPlayerName(player) {
                let base = (player || "").split(".")[0]
                let knownNames = {
                    spotify: "Spotify",
                    firefox: "Firefox",
                    chromium: "Chromium",
                    chrome: "Chrome",
                    brave: "Brave",
                    vlc: "VLC",
                    mpv: "MPV"
                }
                let lower = base.toLowerCase()
                if (knownNames[lower]) return knownNames[lower]
                return base === "" ? "Auto" : base.charAt(0).toUpperCase() + base.slice(1)
            }

            function playerCommand(arguments) {
                let command = ["playerctl"]
                if (selectedPlayer !== "") command.push("--player", selectedPlayer)
                return command.concat(arguments)
            }

            function selectPlayer(player) {
                selectedPlayer = player
                sourceMenuOpen = false
                playerSourceFile.setText(player)
                trackPosition = 0
                refreshPlayerState()
                refreshPlayerPosition()
            }

            function refreshPlayerState() {
                if (!mprisMeta.running) mprisMeta.running = true
                if (!mprisStatus.running) mprisStatus.running = true
            }

            function refreshPlayerPosition() {
                if (!mprisPos.running) mprisPos.running = true
            }

            // Функция форматирования времени
            function formatTime(usec) {
                if (!usec || isNaN(usec) || usec <= 0) return "0:00"
                let secs = Math.floor(usec / 1000000)
                let m = Math.floor(secs / 60)
                let s = secs % 60
                return m + ":" + (s < 10 ? "0" : "") + s
            }

            FileView {
                id: playerSourceFile
                path: Quickshell.shellPath("player-source.txt")
                blockLoading: true
                atomicWrites: true
                printErrors: false
            }

            Process {
                id: mprisPlayers
                command: ["playerctl", "-l"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        let players = []
                        let seen = ({})
                        let lines = this.text.trim().split("\n")
                        for (let i = 0; i < lines.length; ++i) {
                            let player = lines[i].trim()
                            if (player !== "" && !seen[player]) {
                                seen[player] = true
                                players.push(player)
                            }
                        }
                        playerWidget.availablePlayers = players
                    }
                }
            }

            // 1. Метаданные (текст + обложка)
            Process {
                id: mprisMeta
                command: playerWidget.playerCommand(["metadata", "--format", "{{title}}|||{{artist}}|||{{album}}|||{{mpris:artUrl}}|||{{mpris:length}}"])
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        let out = this.text.trim()
                        if (out === "") {
                            playerWidget.trackTitle = "Тишина"
                            playerWidget.trackArtist = ""
                            playerWidget.trackAlbum = ""
                            playerWidget.trackArt = ""
                            playerWidget.trackLength = 0
                            return
                        }
                        let parts = out.split("|||")
                        if (parts.length >= 5) {
                            playerWidget.trackTitle = parts[0] || "Неизвестно"
                            playerWidget.trackArtist = parts[1] || ""
                            playerWidget.trackAlbum = parts[2] || ""
                            playerWidget.trackArt = parts[3] || ""
                            playerWidget.trackLength = parseFloat(parts[4]) || 0
                        }
                    }
                }
            }

            // 2. Независимо получаем статус (Играет/Пауза)
            Process {
                id: mprisStatus
                command: playerWidget.playerCommand(["status"])
                running: true
                stdout: StdioCollector {
                    onStreamFinished: playerWidget.trackStatus = this.text.trim() || "Stopped"
                }
            }

            // 3. Независимо получаем текущую позицию
            Process {
                id: mprisPos
                command: playerWidget.playerCommand(["position"])
                running: true
                stdout: StdioCollector {
                    onStreamFinished: playerWidget.trackPosition = (parseFloat(this.text.trim()) * 1000000) || 0
                }
            }

            // Процесс для отправки команд (пауза, переключение, перемотка)
            Process {
                id: mprisCmd
                onRunningChanged: {
                    if (!running) {
                        playerWidget.refreshPlayerState()
                        playerWidget.refreshPlayerPosition()
                    }
                }
            }

            // Название и статус не требуют опроса несколько раз за кадр.
            Timer {
                interval: 1000; running: true; repeat: true
                onTriggered: playerWidget.refreshPlayerState()
            }

            Timer {
                interval: 3000; running: true; repeat: true
                onTriggered: if (!mprisPlayers.running) mprisPlayers.running = true
            }

            // Позиция нужна часто только пока раскрыт играющий плеер.
            Timer {
                interval: 500
                running: playerWidget.expanded && playerWidget.trackStatus === "Playing"
                repeat: true
                triggeredOnStart: true
                onTriggered: playerWidget.refreshPlayerPosition()
            }

            onExpandedChanged: {
                if (expanded) refreshPlayerPosition()
                else sourceMenuOpen = false
            }
            onTargetHeightChanged: mainWindow.reservePlayerHeight(targetHeight)
            Component.onCompleted: {
                selectedPlayer = playerSourceFile.text().trim()
                mainWindow.reservePlayerHeight(targetHeight)
            }

            width: expanded ? 360 : 32
            height: targetHeight
            radius: expanded ? 24 : 16
            color: expanded ? "#0a0a0a" : "#000000"
            clip: true

            anchors.top: island.top
            anchors.right: island.left
            anchors.rightMargin: 6

            Behavior on width { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
            Behavior on radius { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }

            Rectangle {
                width: 32; height: 32; radius: 16; color: "transparent"
                anchors.top: parent.top; anchors.right: parent.right
                opacity: playerWidget.expanded ? 0 : 1
                Image {
                    anchors.centerIn: parent
                    width: 26; height: 26
                    source: Quickshell.shellPath("assets/music.png")
                    sourceSize.width: 26; sourceSize.height: 26
                    smooth: true
                    opacity: playerWidget.showCompactArtwork && compactArtwork.status === Image.Ready ? 0 : 1
                    Behavior on opacity { NumberAnimation { duration: 140 } }
                }
                ClippingRectangle {
                    anchors.centerIn: parent
                    width: 24; height: 24; radius: 12
                    color: "#161616"
                    opacity: playerWidget.showCompactArtwork && compactArtwork.status === Image.Ready ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 140 } }

                    Image {
                        id: compactArtwork
                        anchors.fill: parent
                        source: playerWidget.trackArt
                        sourceSize.width: 48; sourceSize.height: 48
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                    }
                }
                MouseArea {
                    cursorShape: Qt.PointingHandCursor
                    anchors.fill: parent
                    enabled: !playerWidget.expanded
                    onClicked: {
                        playerCloseDelay.stop()
                        island.expanded = false
                        controlCenter.isOpen = false
                        playerWidget.expanded = true
                    }
                }
            }

            HoverHandler {
                id: playerHoverHandler
                cursorShape: Qt.ArrowCursor
                onHoveredChanged: {
                    if (hovered && playerWidget.expanded) {
                        playerCloseDelay.stop()
                    } else if (!hovered && playerWidget.expanded) {
                        playerCloseDelay.restart()
                    }
                }
            }

            Timer {
                id: playerCloseDelay
                interval: 120
                onTriggered: {
                    if (!playerHoverHandler.hovered)
                        playerWidget.expanded = false
                }
            }

            Item {
                anchors.fill: parent
                opacity: playerWidget.expanded ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180 } }

                Row {
                    anchors.fill: parent; anchors.margins: 16; spacing: 16

                    ClippingRectangle {
                        width: 128; height: 128; radius: 12; color: "#1c1c1c"
                        Image {
                            anchors.fill: parent
                            source: playerWidget.trackArt
                            sourceSize.width: 256
                            sourceSize.height: 256
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            smooth: true
                        }
                    }

                    Column {
                        width: parent.width - 128 - 16; height: parent.height; spacing: 4

                        Text { text: playerWidget.trackTitle; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 16; elide: Text.ElideRight; width: parent.width }
                        Text { text: playerWidget.trackArtist; color: "#aaaaaa"; font.family: "SF Pro Rounded"; font.pixelSize: 14; elide: Text.ElideRight; width: parent.width }
                        Item {
                            width: parent.width; height: 15

                            Text {
                                anchors { left: parent.left; right: playerSourceLabel.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                text: playerWidget.trackAlbum
                                color: "#666666"; font.family: "SF Pro Rounded"; font.pixelSize: 12
                                elide: Text.ElideRight
                            }

                            Text {
                                id: playerSourceLabel
                                anchors { right: parent.right; verticalCenter: parent.verticalCenter }
                                text: playerWidget.selectedPlayerLabel + (playerWidget.sourceMenuOpen ? "  ⌃" : "  ⌄")
                                color: playerWidget.sourceMenuOpen ? "#888888" : shellRoot.accentColor
                                font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 12

                                Behavior on color { ColorAnimation { duration: 140 } }

                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    anchors.fill: parent
                                    anchors.margins: -5
                                    onClicked: playerWidget.sourceMenuOpen = !playerWidget.sourceMenuOpen
                                }
                            }
                        }

                        Item { height: 2; width: 1 }

                        Row {
                            width: parent.width; spacing: 8

                            // Исправлен вызов функции formatTime с префиксом
                            Text { text: playerWidget.formatTime(playerWidget.trackPosition); color: "#aaaaaa"; font.family: "SF Pro Rounded"; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }

                            Rectangle {
                                width: parent.width - 64; height: 6; radius: 3; color: "#333333"
                                anchors.verticalCenter: parent.verticalCenter

                                Rectangle {
                                    width: playerWidget.trackLength > 0 ? (playerWidget.trackPosition / playerWidget.trackLength) * parent.width : 0
                                    height: 6; radius: 3; color: "#aaaaaa"
                                }
                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    anchors.fill: parent
                                    onClicked: (mouse) => {
                                        if (playerWidget.trackLength > 0) {
                                            let targetSec = (mouse.x / width) * (playerWidget.trackLength / 1000000)
                                            mprisCmd.command = playerWidget.playerCommand(["position", targetSec.toString()])
                                            mprisCmd.running = true
                                        }
                                    }
                                }
                            }

                            // Исправлен вызов функции formatTime с префиксом
                            Text { text: playerWidget.formatTime(playerWidget.trackLength); color: "#aaaaaa"; font.family: "SF Pro Rounded"; font.pixelSize: 11; anchors.verticalCenter: parent.verticalCenter }
                        }

                        Item { height: 0; width: 1 }

                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 24
                            Item {
                                width: 40; height: 40
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 14; height: 14
                                    property color glyphColor: previousTrackMouse.containsMouse ? "#ffffff" : "#777777"
                                    onGlyphColorChanged: requestPaint()
                                    Behavior on glyphColor { ColorAnimation { duration: 160 } }
                                    onPaint: {
                                        let ctx = getContext("2d")
                                        ctx.reset()
                                        ctx.fillStyle = glyphColor.toString()
                                        ctx.beginPath()
                                        ctx.roundedRect(1, 2, 3, 10, 1.5, 1.5)
                                        ctx.fill()
                                        ctx.beginPath()
                                        ctx.moveTo(4, 7)
                                        ctx.lineTo(12, 2)
                                        ctx.lineTo(12, 12)
                                        ctx.closePath()
                                        ctx.fill()
                                    }
                                }
                                MouseArea { id: previousTrackMouse; cursorShape: Qt.PointingHandCursor; anchors.fill: parent; hoverEnabled: true; onClicked: { mprisCmd.command = playerWidget.playerCommand(["previous"]); mprisCmd.running = true } }
                            }
                            Rectangle {
                                width: 36; height: 36; radius: 18; color: "#222222"
                                anchors.verticalCenter: parent.verticalCenter
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 14; height: 14
                                    property bool playing: playerWidget.trackStatus === "Playing"
                                    onPlayingChanged: requestPaint()
                                    onPaint: {
                                        let ctx = getContext("2d")
                                        ctx.reset()
                                        ctx.fillStyle = "#ffffff"

                                        if (playing) {
                                            ctx.beginPath()
                                            ctx.roundedRect(2, 1, 4, 12, 2, 2)
                                            ctx.roundedRect(8, 1, 4, 12, 2, 2)
                                            ctx.fill()
                                        } else {
                                            ctx.beginPath()
                                            ctx.moveTo(3, 1)
                                            ctx.lineTo(12, 7)
                                            ctx.lineTo(3, 13)
                                            ctx.closePath()
                                            ctx.fill()
                                        }
                                    }
                                }
                                MouseArea { cursorShape: Qt.PointingHandCursor; anchors.fill: parent; onClicked: { mprisCmd.command = playerWidget.playerCommand(["play-pause"]); mprisCmd.running = true } }
                            }
                            Item {
                                width: 40; height: 40
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 14; height: 14
                                    property color glyphColor: nextTrackMouse.containsMouse ? "#ffffff" : "#777777"
                                    onGlyphColorChanged: requestPaint()
                                    Behavior on glyphColor { ColorAnimation { duration: 160 } }
                                    onPaint: {
                                        let ctx = getContext("2d")
                                        ctx.reset()
                                        ctx.fillStyle = glyphColor.toString()
                                        ctx.beginPath()
                                        ctx.moveTo(2, 2)
                                        ctx.lineTo(10, 7)
                                        ctx.lineTo(2, 12)
                                        ctx.closePath()
                                        ctx.fill()
                                        ctx.beginPath()
                                        ctx.roundedRect(10, 2, 3, 10, 1.5, 1.5)
                                        ctx.fill()
                                    }
                                }
                                MouseArea { id: nextTrackMouse; cursorShape: Qt.PointingHandCursor; anchors.fill: parent; hoverEnabled: true; onClicked: { mprisCmd.command = playerWidget.playerCommand(["next"]); mprisCmd.running = true } }
                            }
                        }
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    visible: playerWidget.sourceMenuOpen
                    z: 10
                    onClicked: playerWidget.sourceMenuOpen = false
                }

                Rectangle {
                    id: playerSourceMenu
                    readonly property int openHeight: Math.min(124, playerWidget.playerChoices.length * 28 + 8)
                    anchors { top: parent.top; right: parent.right; topMargin: 32; rightMargin: 8 }
                    width: 205
                    height: playerWidget.sourceMenuOpen ? openHeight : 0
                    radius: 18
                    color: "#050505"
                    border.width: 1
                    border.color: "#202020"
                    opacity: playerWidget.sourceMenuOpen ? 1 : 0
                    visible: height > 0
                    clip: true
                    z: 11

                    Behavior on height {
                        NumberAnimation { duration: 220; easing.type: Easing.OutCubic }
                    }
                    Behavior on opacity { NumberAnimation { duration: 140 } }

                    ListView {
                        anchors.fill: parent
                        anchors.margins: 4
                        model: playerWidget.playerChoices
                        spacing: 2
                        interactive: count > 4
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            width: ListView.view.width
                            height: 26
                            radius: 12
                            color: sourceMouse.containsMouse ? "#111111" : "transparent"
                            opacity: playerWidget.sourceMenuOpen ? 1 : 0
                            transform: Translate {
                                y: playerWidget.sourceMenuOpen ? 0 : -4
                                Behavior on y {
                                    NumberAnimation {
                                        duration: 180 + Math.min(3, index) * 25
                                        easing.type: Easing.OutCubic
                                    }
                                }
                            }

                            Behavior on opacity {
                                NumberAnimation {
                                    duration: 140 + Math.min(3, index) * 25
                                    easing.type: Easing.OutCubic
                                }
                            }

                            Text {
                                anchors { left: parent.left; right: sourceIndicator.left; leftMargin: 10; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                text: parent.modelData.label
                                color: parent.modelData.id === playerWidget.selectedPlayer ? "#ffffff" : "#777777"
                                font.family: "SF Pro Rounded"
                                font.bold: parent.modelData.id === playerWidget.selectedPlayer
                                font.pixelSize: 12
                                elide: Text.ElideRight

                                Behavior on color { ColorAnimation { duration: 140 } }
                            }

                            Rectangle {
                                id: sourceIndicator
                                anchors { right: parent.right; rightMargin: 9; verticalCenter: parent.verticalCenter }
                                width: 6; height: 6; radius: 3
                                color: shellRoot.accentColor
                                visible: parent.modelData.id === playerWidget.selectedPlayer
                            }

                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                id: sourceMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: playerWidget.selectPlayer(parent.modelData.id)
                            }
                        }
                    }
                }
            }
        }

        // 2. Главный островок по центру
        Rectangle {
            id: island
            anchors.top: parent.top
            anchors.topMargin: 10
            anchors.horizontalCenter: parent.horizontalCenter
            property bool expanded: false
            property date now: new Date()
            property var calendarEvents: []
            property bool calendarConfigured: false
            property string calendarError: ""
            property var activeNotification: null
            property bool notificationReplyOpen: false
            property bool calendarHoverArmed: true
            property bool systemOsdVisible: false
            property string systemOsdKind: "volume"
            property string systemOsdTitle: "Volume"
            property int systemOsdValue: 0
            property bool systemOsdMuted: false
            property string systemOsdDetail: ""
            readonly property var osdSinkAudio: Pipewire.defaultAudioSink
                ? Pipewire.defaultAudioSink.audio : null
            readonly property var osdSourceAudio: Pipewire.defaultAudioSource
                ? Pipewire.defaultAudioSource.audio : null
            property bool osdSinkInitialized: false
            property int osdLastSinkVolume: -1
            property bool osdLastSinkMuted: false
            property bool osdSourceInitialized: false
            property int osdLastSourceVolume: -1
            property bool osdLastSourceMuted: false
            property bool osdBrightnessInitialized: false
            property int osdLastBrightness: -1
            property bool osdLayoutInitialized: false
            property int osdLastLayoutIndex: -1
            property var osdLayoutNames: []
            readonly property bool notificationVisible: activeNotification !== null
            readonly property bool notificationCanReply: notificationVisible && activeNotification.hasInlineReply
            readonly property var notificationDefaultAction: {
                if (!activeNotification) return null
                let actions = activeNotification.actions
                for (let index = 0; index < actions.length; ++index) {
                    if (actions[index].identifier === "default") return actions[index]
                }
                return null
            }
            readonly property var notificationButtons: {
                let buttons = []
                if (!activeNotification) return buttons
                let actions = activeNotification.actions
                let limit = notificationCanReply ? 1 : 2
                for (let index = 0; index < actions.length && buttons.length < limit; ++index) {
                    if (actions[index].identifier !== "default" && actions[index].text !== "")
                        buttons.push(actions[index])
                }
                return buttons
            }
            readonly property bool notificationHasButtons: notificationButtons.length > 0 || notificationCanReply
            readonly property int targetHeight: expanded
                ? 320
                : (notificationVisible
                   ? Math.ceil(Math.max(56, notificationContentColumn.implicitHeight)
                               + 20
                               + ((notificationHasButtons || notificationReplyOpen) ? 38 : 0))
                   : (systemOsdVisible ? 58 : 32))
            readonly property var weekdayNames: ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
            readonly property string todayKey: dateKey(now.getFullYear(), now.getMonth() + 1, now.getDate())
            property string selectedDateKey: todayKey
            readonly property var eventDates: {
                let dates = ({})
                for (let index = 0; index < calendarEvents.length; ++index)
                    dates[calendarEvents[index].date] = true
                return dates
            }
            readonly property var calendarTasks: {
                let tasks = []
                for (let index = 0; index < calendarEvents.length; ++index) {
                    if (calendarEvents[index].date === selectedDateKey)
                        tasks.push(calendarEvents[index])
                }
                return tasks.slice(0, 5)
            }
            readonly property var calendarDays: {
                let year = now.getFullYear()
                let month = now.getMonth()
                let firstWeekday = (new Date(year, month, 1).getDay() + 6) % 7
                let daysInMonth = new Date(year, month + 1, 0).getDate()
                let cellCount = Math.ceil((firstWeekday + daysInMonth) / 7) * 7
                let days = []

                for (let index = 0; index < cellCount; ++index) {
                    let date = new Date(year, month, index - firstWeekday + 1)
                    let key = dateKey(date.getFullYear(), date.getMonth() + 1, date.getDate())
                    days.push({
                        number: date.getDate(),
                        key: key,
                        inCurrentMonth: date.getMonth() === month,
                        isToday: date.getFullYear() === now.getFullYear()
                                 && date.getMonth() === now.getMonth()
                                 && date.getDate() === now.getDate(),
                        hasEvents: eventDates[key] === true
                    })
                }
                return days
            }

            function dateKey(year, month, day) {
                return year.toString().padStart(4, "0") + "-"
                       + month.toString().padStart(2, "0") + "-"
                       + day.toString().padStart(2, "0")
            }

            function dateTitle() {
                let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
                let day = now.getDate().toString().padStart(2, "0")
                let month = (now.getMonth() + 1).toString().padStart(2, "0")
                return weekdays[now.getDay()] + " " + day + "." + month + "." + now.getFullYear()
            }

            function refreshCalendar() {
                if (!googleCalendarQuery.running) googleCalendarQuery.running = true
            }

            function notificationImageSource(notification) {
                if (!notification) return ""
                let source = notification.image || notification.appIcon || ""
                if (source === "") return ""
                if (source.indexOf("/") !== -1 || source.indexOf(":") !== -1)
                    return source
                return Quickshell.iconPath(source)
            }

            function truncatedNotificationText(value, limit) {
                let normalized = (value || "").replace(/\s+/g, " ").trim()
                if (normalized.length <= limit) return normalized
                return normalized.substring(0, Math.max(0, limit - 3)).trim() + "..."
            }

            function normalizedNotificationText(value) {
                return (value || "").replace(/\s+/g, " ").trim()
            }

            function revealSystemOsd(kind, title, value, muted) {
                if (notificationVisible || notificationReplyOpen || expanded) return
                systemOsdKind = kind
                systemOsdTitle = title
                systemOsdValue = Math.max(0, Math.min(100, Math.round(value)))
                systemOsdMuted = muted
                systemOsdDetail = ""
                systemOsdVisible = true
                systemOsdHideTimer.restart()
            }

            function updateBatteryWarning(present, percent, status) {
                if (!present || status !== "discharging" || isNaN(percent)) {
                    controlCenter.lastDischargingBatteryPercent = -1
                    return
                }
                let previous = controlCenter.lastDischargingBatteryPercent
                controlCenter.lastDischargingBatteryPercent = percent
                if (previous < 0 || percent >= previous) return
                if (previous > 5 && percent <= 5)
                    revealSystemOsd("battery", "Critical battery", percent, false)
                else if (previous > 20 && percent <= 20)
                    revealSystemOsd("battery", "Low battery", percent, false)
            }

            function revealKeyboardLayout(layoutName) {
                if (notificationVisible || notificationReplyOpen || expanded) return
                let normalized = (layoutName || "Unknown").trim()
                systemOsdKind = "language"
                systemOsdTitle = "Language"
                systemOsdDetail = normalized
                systemOsdMuted = false
                systemOsdVisible = true
                systemOsdHideTimer.restart()
                console.info("Keyboard layout OSD:", normalized)
            }

            function revealLockKey(key, enabled) {
                revealSystemOsd("keylock", key === "capslock" ? "Caps Lock" : "Num Lock", 0, !enabled)
            }

            function hideSystemOsd() {
                systemOsdHideTimer.stop()
                systemOsdVisible = false
            }

            function updateOsdSink() {
                if (!osdSinkAudio) {
                    osdSinkInitialized = false
                    return
                }
                let volume = Math.round(osdSinkAudio.volume * 100)
                let muted = osdSinkAudio.muted
                if (!osdSinkInitialized) {
                    osdSinkInitialized = true
                    osdLastSinkVolume = volume
                    osdLastSinkMuted = muted
                    return
                }
                if (volume === osdLastSinkVolume && muted === osdLastSinkMuted) return
                osdLastSinkVolume = volume
                osdLastSinkMuted = muted
                revealSystemOsd("volume", muted ? "Sound muted" : "Volume", volume, muted)
            }

            function updateOsdSource() {
                if (!osdSourceAudio) {
                    osdSourceInitialized = false
                    return
                }
                let volume = Math.round(osdSourceAudio.volume * 100)
                let muted = osdSourceAudio.muted
                if (!osdSourceInitialized) {
                    osdSourceInitialized = true
                    osdLastSourceVolume = volume
                    osdLastSourceMuted = muted
                    return
                }
                if (volume === osdLastSourceVolume && muted === osdLastSourceMuted) return
                osdLastSourceVolume = volume
                osdLastSourceMuted = muted
                revealSystemOsd("microphone", muted ? "Microphone muted" : "Microphone", volume, muted)
            }

            function openNotificationReply() {
                if (!notificationCanReply) return
                notificationReplyOpen = true
                notificationTimeout.stop()
                notificationFocusDelay.restart()
            }

            function cancelNotificationReply() {
                notificationReplyOpen = false
                notificationFocusDelay.stop()
                notificationReplyInput.text = ""
                notificationTimeout.restart()
            }

            function blockCalendarUntilPointerLeaves() {
                if (calendarHoverHandler.hovered)
                    calendarHoverArmed = false
            }

            function sendNotificationReply() {
                let reply = notificationReplyInput.text.trim()
                let notification = activeNotification
                if (!notification || !notification.hasInlineReply || reply === "") return

                notificationTimeout.stop()
                notificationReplyOpen = false
                notificationFocusDelay.stop()
                notificationReplyInput.text = ""
                blockCalendarUntilPointerLeaves()
                activeNotification = null
                notification.sendInlineReply(reply)
                Qt.callLater(() => {
                    try {
                        if (notification && notification.tracked)
                            notification.dismiss()
                    } catch (error) {
                        // The application already closed the notification after receiving the reply.
                    }
                })
            }

            function invokeNotificationAction(action) {
                if (!action || !activeNotification) return
                let notification = activeNotification
                notificationTimeout.stop()
                blockCalendarUntilPointerLeaves()
                activeNotification = null
                notificationReplyOpen = false
                notificationFocusDelay.stop()
                action.invoke()
                Qt.callLater(() => {
                    try {
                        if (notification && notification.tracked)
                            notification.dismiss()
                    } catch (error) {
                        // The application already closed the notification after the action.
                    }
                })
            }

            function dismissActiveNotification() {
                let notification = activeNotification
                if (!notification) return
                notificationTimeout.stop()
                blockCalendarUntilPointerLeaves()
                activeNotification = null
                notificationReplyOpen = false
                notificationFocusDelay.stop()
                notificationReplyInput.text = ""
                Qt.callLater(() => {
                    try {
                        if (notification && notification.tracked)
                            notification.dismiss()
                    } catch (error) {
                        // The application already closed the notification.
                    }
                })
            }

            width: expanded ? 650 : (notificationVisible ? 380 : (systemOsdVisible ? 290 : 68))
            height: targetHeight
            radius: expanded ? 34 : (notificationVisible ? 26 : (systemOsdVisible ? 26 : 16))
            color: "#000000"
            clip: true
            onTargetHeightChanged: mainWindow.reserveIslandHeight(targetHeight)
            Component.onCompleted: mainWindow.reserveIslandHeight(targetHeight)
            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on radius { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

            Timer {
                interval: 1000
                running: true
                repeat: true
                onTriggered: island.now = new Date()
            }

            Process {
                id: googleCalendarQuery
                command: [Quickshell.shellPath("google-calendar.pl")]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        try {
                            let response = JSON.parse(this.text.trim())
                            island.calendarConfigured = response.configured === true
                            island.calendarEvents = response.events || []
                            island.calendarError = response.error || ""
                        } catch (error) {
                            island.calendarEvents = []
                            island.calendarError = "Could not read calendar"
                        }
                    }
                }
            }

            Timer {
                interval: 300000
                running: true
                repeat: true
                onTriggered: island.refreshCalendar()
            }

            Timer {
                id: notificationTimeout
                interval: 5000
                onTriggered: {
                    let notification = island.activeNotification
                    island.blockCalendarUntilPointerLeaves()
                    island.activeNotification = null
                    island.notificationReplyOpen = false
                    notificationFocusDelay.stop()
                    notificationReplyInput.text = ""
                    if (notification) notification.expire()
                }
            }

            Timer {
                id: notificationFocusDelay
                interval: 50
                onTriggered: {
                    if (!island.notificationReplyOpen) return
                    notificationReplyInput.forceActiveFocus(Qt.MouseFocusReason)
                }
            }

            Timer {
                id: systemOsdHideTimer
                interval: island.systemOsdKind === "battery" ? 4000 : 1000
                onTriggered: island.systemOsdVisible = false
            }

            Connections {
                target: island.osdSinkAudio
                ignoreUnknownSignals: true
                function onVolumeChanged() { island.updateOsdSink() }
                function onMutedChanged() { island.updateOsdSink() }
            }

            Connections {
                target: island.osdSourceAudio
                ignoreUnknownSignals: true
                function onVolumeChanged() { island.updateOsdSource() }
                function onMutedChanged() { island.updateOsdSource() }
            }

            onOsdSinkAudioChanged: Qt.callLater(updateOsdSink)
            onOsdSourceAudioChanged: Qt.callLater(updateOsdSource)

            Process {
                command: ["perl", Quickshell.shellPath("brightness-monitor.pl")]
                running: true
                stdout: SplitParser {
                    onRead: data => {
                        let value = parseInt(data.trim())
                        if (isNaN(value)) return
                        if (!island.osdBrightnessInitialized) {
                            island.osdBrightnessInitialized = true
                            island.osdLastBrightness = value
                            return
                        }
                        if (value === island.osdLastBrightness) return
                        island.osdLastBrightness = value
                        island.revealSystemOsd("brightness", "Brightness", value, false)
                    }
                }
            }

            Process {
                command: ["perl", Quickshell.shellPath("lock-key-monitor.pl")]
                running: true
                stdout: SplitParser {
                    onRead: data => {
                        let match = data.trim().match(/^(capslock|numlock) ([01])$/)
                        if (match)
                            island.revealLockKey(match[1], match[2] === "1")
                    }
                }
            }

            Process {
                command: ["niri", "msg", "--json", "event-stream"]
                running: true
                stdout: SplitParser {
                    onRead: data => {
                        try {
                            let event = JSON.parse(data)
                            let changed = event.KeyboardLayoutsChanged
                            if (changed && changed.keyboard_layouts) {
                                let layouts = changed.keyboard_layouts
                                island.osdLayoutNames = layouts.names || []
                                island.osdLayoutInitialized = true
                                island.osdLastLayoutIndex = layouts.current_idx
                                return
                            }

                            let switched = event.KeyboardLayoutSwitched
                            if (!switched) return
                            let index = switched.idx
                            if (!island.osdLayoutInitialized) {
                                island.osdLayoutInitialized = true
                                island.osdLastLayoutIndex = index
                                return
                            }
                            if (index === island.osdLastLayoutIndex) return
                            island.osdLastLayoutIndex = index
                            let name = index >= 0 && index < island.osdLayoutNames.length
                                ? island.osdLayoutNames[index] : "Unknown"
                            island.revealKeyboardLayout(name)
                        } catch (error) {
                            // Ignore unrelated or partial IPC messages.
                        }
                    }
                }
            }

            Connections {
                target: island.activeNotification
                ignoreUnknownSignals: true
                function onClosed(reason) {
                    island.blockCalendarUntilPointerLeaves()
                    island.activeNotification = null
                    island.notificationReplyOpen = false
                    notificationFocusDelay.stop()
                    notificationReplyInput.text = ""
                    notificationTimeout.stop()
                }
            }

            Text {
                anchors.centerIn: parent
                color: "#ffffff"
                font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 16

                text: Qt.formatTime(island.now, "HH:mm")
                opacity: island.expanded || island.notificationVisible || island.systemOsdVisible ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 140 } }
            }

            Item {
                anchors.fill: parent
                opacity: island.systemOsdVisible && !island.expanded
                    && !island.notificationVisible ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 170; easing.type: Easing.OutCubic } }

                Text {
                    anchors { left: parent.left; leftMargin: 18 }
                    y: 8
                    text: island.systemOsdTitle
                    visible: island.systemOsdKind !== "language" && island.systemOsdKind !== "keylock"
                    color: "#ffffff"
                    font.family: "SF Pro Rounded"
                    font.bold: true
                    font.pixelSize: 14
                }

                Text {
                    anchors { right: parent.right; rightMargin: 18 }
                    y: 8
                    text: island.systemOsdMuted ? "Off" : island.systemOsdValue + "%"
                    visible: island.systemOsdKind !== "language" && island.systemOsdKind !== "keylock"
                    color: island.systemOsdMuted ? "#777777" : "#ffffff"
                    font.family: "SF Pro Rounded"
                    font.bold: true
                    font.pixelSize: 13
                }

                Text {
                    anchors {
                        fill: parent
                        leftMargin: 18
                        rightMargin: 18
                    }
                    visible: island.systemOsdKind === "language" || island.systemOsdKind === "keylock"
                    text: island.systemOsdKind === "keylock"
                        ? island.systemOsdTitle + (island.systemOsdMuted ? " Off" : " On")
                        : island.systemOsdDetail
                    color: island.systemOsdKind === "keylock" && island.systemOsdMuted
                        ? "#777777" : "#ffffff"
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    font.family: "SF Pro Rounded"
                    font.bold: true
                    font.pixelSize: 14
                }

                Rectangle {
                    anchors {
                        left: parent.left
                        right: parent.right
                        bottom: parent.bottom
                        leftMargin: 18
                        rightMargin: 18
                        bottomMargin: 11
                    }
                    height: 8
                    radius: 4
                    color: "#252525"
                    clip: true
                    visible: island.systemOsdKind !== "language" && island.systemOsdKind !== "keylock"

                    Rectangle {
                        width: island.systemOsdMuted ? 0
                            : parent.width * island.systemOsdValue / 100
                        height: parent.height
                        radius: parent.radius
                        color: island.systemOsdKind === "battery"
                            ? (island.systemOsdValue <= 5 ? "#ed414b" : "#f0c45e")
                            : shellRoot.accentColor
                    }
                }
            }

            Item {
                anchors.fill: parent
                opacity: island.notificationVisible && !island.expanded ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 180 } }

                MouseArea {
                    cursorShape: Qt.PointingHandCursor
                    anchors.fill: parent
                    enabled: !island.notificationReplyOpen && island.notificationDefaultAction !== null
                    onClicked: island.invokeNotificationAction(island.notificationDefaultAction)
                }

                ClippingRectangle {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 11 }
                    anchors.verticalCenterOffset: island.notificationHasButtons ? -19 : 0
                    width: 56; height: 56; radius: 28
                    color: "#dedede"

                    Text {
                        anchors.centerIn: parent
                        text: island.activeNotification && island.activeNotification.appName !== ""
                            ? island.activeNotification.appName.charAt(0).toUpperCase()
                            : "•"
                        color: "#303030"
                        font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 22
                        visible: notificationImage.status !== Image.Ready
                    }

                    Image {
                        id: notificationImage
                        anchors.fill: parent
                        source: island.notificationImageSource(island.activeNotification)
                        sourceSize.width: 112
                        sourceSize.height: 112
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        smooth: true
                    }
                }

                Column {
                    id: notificationContentColumn
                    anchors {
                        left: parent.left
                        verticalCenter: parent.verticalCenter
                        leftMargin: 79
                    }
                    width: 260
                    spacing: 2
                    anchors.verticalCenterOffset: island.notificationHasButtons ? -19 : 0

                    Text {
                        width: parent.width
                        text: island.activeNotification
                            ? island.truncatedNotificationText(island.activeNotification.appName, 24)
                            : ""
                        color: "#777777"
                        font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 12
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Text {
                        width: parent.width
                        text: island.activeNotification
                            ? island.normalizedNotificationText(island.activeNotification.summary)
                            : ""
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 16
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                    }
                    Text {
                        width: parent.width
                        text: island.activeNotification
                            ? island.normalizedNotificationText(island.activeNotification.body)
                            : ""
                        color: "#aaaaaa"
                        font.family: "SF Pro Rounded"; font.pixelSize: 14
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        maximumLineCount: 3
                        elide: Text.ElideRight
                        textFormat: Text.PlainText
                        visible: text !== ""
                    }
                }

                Rectangle {
                    anchors { top: parent.top; right: parent.right; topMargin: 8; rightMargin: 8 }
                    width: 24
                    height: 24
                    radius: 12
                    color: notificationCloseMouse.containsMouse ? "#242424" : "#161616"
                    z: 10

                    Behavior on color { ColorAnimation { duration: 120 } }

                    Canvas {
                        anchors.centerIn: parent
                        width: 10
                        height: 10
                        onPaint: {
                            let ctx = getContext("2d")
                            ctx.reset()
                            ctx.strokeStyle = "#8d8d8d"
                            ctx.lineWidth = 1.6
                            ctx.lineCap = "round"
                            ctx.beginPath()
                            ctx.moveTo(1, 1)
                            ctx.lineTo(9, 9)
                            ctx.moveTo(9, 1)
                            ctx.lineTo(1, 9)
                            ctx.stroke()
                        }
                    }

                    MouseArea {
                        cursorShape: Qt.PointingHandCursor
                        id: notificationCloseMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: island.dismissActiveNotification()
                    }
                }

                Row {
                    id: notificationActionRow
                    readonly property int buttonCount: island.notificationButtons.length + (island.notificationCanReply ? 1 : 0)
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 10; rightMargin: 10; bottomMargin: 10 }
                    height: 28
                    spacing: 6
                    visible: island.notificationHasButtons && !island.notificationReplyOpen

                    Repeater {
                        model: island.notificationButtons

                        Rectangle {
                            required property var modelData
                            width: (notificationActionRow.width
                                    - notificationActionRow.spacing * Math.max(0, notificationActionRow.buttonCount - 1))
                                   / Math.max(1, notificationActionRow.buttonCount)
                            height: notificationActionRow.height
                            radius: 14
                            color: "#161616"

                            Text {
                                anchors { fill: parent; leftMargin: 10; rightMargin: 10 }
                                verticalAlignment: Text.AlignVCenter
                                horizontalAlignment: Text.AlignHCenter
                                text: island.truncatedNotificationText(parent.modelData.text, 26)
                                color: "#d0d0d0"
                                font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 12
                                elide: Text.ElideRight
                                textFormat: Text.PlainText
                            }
                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                anchors.fill: parent
                                onClicked: island.invokeNotificationAction(parent.modelData)
                            }
                        }
                    }

                    Rectangle {
                        width: (notificationActionRow.width
                                - notificationActionRow.spacing * Math.max(0, notificationActionRow.buttonCount - 1))
                               / Math.max(1, notificationActionRow.buttonCount)
                        height: notificationActionRow.height
                        radius: 14
                        color: shellRoot.accentColor
                        visible: island.notificationCanReply

                        Text {
                            anchors.centerIn: parent
                            text: "Reply"
                            color: "#050505"
                            font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 12
                        }
                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors.fill: parent
                            onClicked: island.openNotificationReply()
                        }
                    }
                }

                Rectangle {
                    anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 10; rightMargin: 10; bottomMargin: 10 }
                    height: 28
                    radius: 14
                    color: "#161616"
                    visible: island.notificationReplyOpen

                    TextInput {
                        id: notificationReplyInput
                        anchors { left: parent.left; right: replySend.left; verticalCenter: parent.verticalCenter; leftMargin: 14; rightMargin: 10 }
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"; font.pixelSize: 13
                        clip: true
                        selectByMouse: true
                        enabled: island.notificationReplyOpen
                        focus: island.notificationReplyOpen

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                island.sendNotificationReply()
                                event.accepted = true
                            } else if (event.key === Qt.Key_Escape) {
                                island.cancelNotificationReply()
                                event.accepted = true
                            }
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: island.activeNotification
                                ? (island.activeNotification.inlineReplyPlaceholder || "Ответить")
                                : "Ответить"
                            color: "#666666"
                            font: notificationReplyInput.font
                            visible: notificationReplyInput.text === ""
                            elide: Text.ElideRight
                        }
                    }

                    Rectangle {
                        id: replySend
                        anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 3 }
                        width: 64; height: 22; radius: 11
                        color: notificationReplyInput.text.trim() === "" ? "#262626" : shellRoot.accentColor
                        Behavior on color { ColorAnimation { duration: 140 } }

                        Text {
                            anchors.centerIn: parent
                            text: "Send"
                            color: notificationReplyInput.text.trim() === "" ? "#777777" : "#050505"
                            font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 11
                        }
                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors.fill: parent
                            enabled: notificationReplyInput.text.trim() !== ""
                            onClicked: island.sendNotificationReply()
                        }
                    }
                }
            }

            MouseArea {
                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                anchors.fill: parent
                enabled: !island.expanded && !island.notificationVisible
                    && !island.systemOsdVisible && island.calendarHoverArmed
                onClicked: {
                    calendarCloseDelay.stop()
                    playerWidget.expanded = false
                    controlCenter.isOpen = false
                    island.selectedDateKey = island.todayKey
                    island.refreshCalendar()
                    island.expanded = true
                }
            }

            HoverHandler {
                id: calendarHoverHandler
                cursorShape: Qt.ArrowCursor
                onHoveredChanged: {
                    if (hovered && island.expanded) {
                        calendarCloseDelay.stop()
                    } else if (!hovered) {
                        island.calendarHoverArmed = true
                        if (island.expanded) calendarCloseDelay.restart()
                    }
                }
            }

            Timer {
                id: calendarCloseDelay
                interval: 120
                onTriggered: {
                    if (!calendarHoverHandler.hovered)
                        island.expanded = false
                }
            }

            Row {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12
                opacity: island.expanded ? 1 : 0
                visible: opacity > 0
                Behavior on opacity { NumberAnimation { duration: 220 } }

                Rectangle {
                    width: 386
                    height: parent.height
                    radius: 28
                    color: "#161616"

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 20; leftMargin: 20 }
                        text: island.dateTitle()
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 18
                    }

                    Text {
                        anchors { top: parent.top; right: parent.right; topMargin: 20; rightMargin: 20 }
                        text: Qt.formatTime(island.now, "HH:mm")
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 18
                    }

                    Row {
                        id: calendarWeekdays
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 66; leftMargin: 18; rightMargin: 18 }
                        spacing: 6

                        Repeater {
                            model: island.weekdayNames
                            Text {
                                required property string modelData
                                width: (calendarWeekdays.width - 36) / 7
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData
                                color: "#6f6f6f"
                                font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 15
                            }
                        }
                    }

                    Grid {
                        id: calendarGrid
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 96; leftMargin: 18; rightMargin: 18 }
                        columns: 7
                        columnSpacing: 6
                        rowSpacing: 4

                        Repeater {
                            model: island.calendarDays
                            Item {
                                id: calendarDay
                                required property var modelData
                                width: (calendarGrid.width - 36) / 7
                                height: 31

                                Rectangle {
                                    id: calendarDayCircle
                                    anchors.centerIn: parent
                                    width: 29; height: 29; radius: width / 2
                                    color: calendarDay.modelData.isToday
                                           ? shellRoot.accentColor
                                           : (calendarDay.modelData.key === island.selectedDateKey
                                              || calendarDayMouse.containsMouse ? "#303030" : "transparent")
                                }

                                Text {
                                    anchors.centerIn: calendarDayCircle
                                    text: calendarDay.modelData.number
                                    color: calendarDay.modelData.isToday
                                           ? "#050505"
                                           : (calendarDay.modelData.inCurrentMonth ? "#ffffff" : "#686868")
                                    font.family: "SF Pro Rounded"
                                    font.pixelSize: 16
                                }

                                Rectangle {
                                    visible: calendarDay.modelData.hasEvents
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: 24
                                    width: 4; height: 4; radius: 2
                                    color: calendarDay.modelData.isToday ? "#050505" : "#ffffff"
                                }

                                MouseArea {
                                    id: calendarDayMouse
                                    cursorShape: Qt.PointingHandCursor
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: calendarDay.modelData.inCurrentMonth
                                    onClicked: island.selectedDateKey = calendarDay.modelData.key
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: 220
                    height: parent.height
                    radius: 28
                    color: "#161616"

                    Text {
                        id: tasksTitle
                        anchors { top: parent.top; left: parent.left; topMargin: 20; leftMargin: 20 }
                        text: "Tasks"
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"; font.bold: true; font.pixelSize: 18
                    }

                    Column {
                        anchors { top: tasksTitle.bottom; left: parent.left; right: parent.right; topMargin: 14; leftMargin: 14; rightMargin: 14 }
                        spacing: 8

                        Repeater {
                            model: island.calendarTasks
                            Rectangle {
                                required property var modelData
                                width: 192; height: 38; radius: 19; color: "#000000"

                                Text {
                                    anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 14 }
                                    width: 120
                                    text: parent.modelData.title
                                    elide: Text.ElideRight
                                    color: "#ffffff"
                                    font.family: "SF Pro Rounded"; font.pixelSize: 14
                                }
                                Text {
                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 14 }
                                    text: parent.modelData.time
                                    color: "#ffffff"
                                    font.family: "SF Pro Rounded"; font.pixelSize: 14
                                }
                            }
                        }
                    }

                    Text {
                        anchors { top: tasksTitle.bottom; left: parent.left; topMargin: 18; leftMargin: 20 }
                        visible: island.calendarTasks.length === 0
                        text: island.calendarError === "" ? "No tasks" : "Calendar unavailable"
                        color: "#777777"
                        font.family: "SF Pro Rounded"; font.pixelSize: 14
                    }
                }
            }

        }

        // 3. Кружок настроек справа
        Rectangle {
            id: controlWidget
            readonly property int targetHeight: controlCenter.isOpen
                ? (controlCenter.personalizationMenuOpen
                    ? controlCenter.personalizationMenuHeight
                    : (controlCenter.powerMenuOpen
                    ? controlCenter.powerMenuHeight
                    : (controlCenter.wifiMenuOpen
                    ? controlCenter.wifiMenuHeight
                    : (controlCenter.bluetoothMenuOpen
                        ? controlCenter.bluetoothMenuHeight
                        : (controlCenter.nightModeMenuOpen ? controlCenter.nightModeMenuHeight : controlCenter.homeMenuHeight)))))
                : 32
            width: controlCenter.isOpen ? 408 : 32
            height: targetHeight
            radius: controlCenter.isOpen ? 32 : 16
            color: "#000000"
            clip: true

            onTargetHeightChanged: mainWindow.reserveControlHeight(targetHeight)
            Component.onCompleted: mainWindow.reserveControlHeight(targetHeight)

            anchors.left: island.right
            anchors.leftMargin: 6
            anchors.top: island.top

            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on radius { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
            Behavior on color { ColorAnimation { duration: 300 } }

            Image {
                anchors { top: parent.top; left: parent.left; topMargin: 3; leftMargin: 3 }
                width: 26; height: 26
                source: Quickshell.shellPath("assets/wifi.png")
                sourceSize.width: 26; sourceSize.height: 26
                smooth: true
                opacity: controlCenter.isOpen ? 0 : (controlCenter.wifiEnabled ? 1 : 0.4)
                Behavior on opacity { NumberAnimation { duration: 150 } }
            }
            MouseArea {
                cursorShape: Qt.PointingHandCursor
                anchors.fill: parent
                enabled: !controlCenter.isOpen
                onPressed: {
                    controlCenter.wifiToggleBlocked = true
                    wifiToggleReadyDelay.restart()
                }
                onClicked: {
                    controlCloseDelay.stop()
                    controlCenter.wifiMenuOpen = false
                    controlCenter.bluetoothMenuOpen = false
                    controlCenter.nightModeMenuOpen = false
                    controlCenter.powerMenuOpen = false
                    controlCenter.personalizationMenuOpen = false
                    island.expanded = false
                    playerWidget.expanded = false
                    controlCenter.isOpen = true
                }
            }
            HoverHandler {
                id: controlHoverHandler
                cursorShape: Qt.ArrowCursor
                onHoveredChanged: {
                    if (hovered && controlCenter.isOpen) {
                        controlCloseDelay.stop()
                    } else if (!hovered && controlCenter.isOpen) {
                        controlCloseDelay.restart()
                    }
                }
            }

            Timer {
                id: wifiToggleReadyDelay
                interval: 400
                onTriggered: {
                    if (!wifiPowerHover.hovered)
                        controlCenter.wifiToggleBlocked = false
                }
            }

            Timer {
                id: controlCloseDelay
                interval: 120
                onTriggered: {
                    if (!controlHoverHandler.hovered
                            && controlCenter.pointerHoldCount === 0
                            && !controlCenter.controlCloseSuppressed
                            && !controlCenter.wifiPasswordPromptOpen)
                        controlCenter.isOpen = false
                }
            }

        }

        // 4. Панель управления
        Rectangle {
            id: controlCenter
            property bool isOpen: false
            property bool wifiMenuOpen: false
            property bool bluetoothMenuOpen: false
            property bool nightModeMenuOpen: false
            property bool powerMenuOpen: false
            property bool personalizationMenuOpen: false
            property int pointerHoldCount: 0
            property bool controlCloseSuppressed: false
            property bool wifiEnabled: false
            property bool wifiToggleBlocked: false
            readonly property bool wifiPowerReady: isOpen
                && controlWidget.width >= 407
                && controlWidget.height >= homeMenuHeight
                && !wifiToggleBlocked
            property string wifiDevice: "wlan0"
            property string wifiConnection: ""
            property string wifiSsid: ""
            property string wifiIp: "—"
            property int wifiSignal: 0
            property string wifiBand: "—"
            property string wifiLastConnection: ""
            property string wifiPendingSsid: ""
            property string wifiConnectingSsid: ""
            property string wifiActionMessage: ""
            property bool wifiPasswordPromptOpen: false
            property var wifiSavedNetworks: []
            property var wifiVisibleNetworks: []
            readonly property var wifiAvailableSavedNetworks: {
                let visible = ({})
                for (let i = 0; i < wifiVisibleNetworks.length; ++i)
                    visible[wifiVisibleNetworks[i].ssid] = true

                let networks = []
                for (let j = 0; j < wifiSavedNetworks.length; ++j) {
                    let saved = wifiSavedNetworks[j]
                    if (visible[saved.name] || saved.name === wifiConnection || saved.name === wifiSsid)
                        networks.push(saved)
                }
                return networks
            }
            readonly property int wifiSavedBlockHeight: Math.min(170, 43 + Math.max(1, wifiAvailableSavedNetworks.length) * 28)
            readonly property int wifiNewBlockHeight: Math.min(190, 43 + Math.max(1, wifiNewNetworks.length) * 28)
            readonly property int wifiMenuHeight: 32 + 52 + 8 + wifiSavedBlockHeight + 8 + wifiNewBlockHeight
            readonly property var wifiNewNetworks: {
                let saved = ({})
                for (let i = 0; i < wifiSavedNetworks.length; ++i)
                    saved[wifiSavedNetworks[i].name] = true

                let networks = []
                for (let j = 0; j < wifiVisibleNetworks.length; ++j) {
                    let network = wifiVisibleNetworks[j]
                    if (!saved[network.ssid] && network.ssid !== wifiSsid)
                        networks.push(network)
                }
                return networks
            }

            property bool bluetoothEnabled: false
            property string bluetoothCurrentAddress: ""
            property string bluetoothCurrentName: ""
            property string bluetoothCurrentType: "Device"
            property int bluetoothCurrentBattery: -1
            property string bluetoothLastAddress: ""
            property string bluetoothPendingAddress: ""
            property string bluetoothActionMessage: ""
            property var bluetoothSavedDevices: []
            property var bluetoothVisibleDevices: []
            property var bluetoothConnectedAddresses: []
            readonly property var bluetoothNewDevices: {
                let saved = ({})
                for (let i = 0; i < bluetoothSavedDevices.length; ++i)
                    saved[bluetoothSavedDevices[i].address] = true

                let devices = []
                for (let j = 0; j < bluetoothVisibleDevices.length; ++j) {
                    let device = bluetoothVisibleDevices[j]
                    if (!saved[device.address]) devices.push(device)
                }
                return devices
            }
            readonly property int bluetoothSavedBlockHeight: Math.min(170, 43 + Math.max(1, bluetoothSavedDevices.length) * 28)
            readonly property int bluetoothNewBlockHeight: Math.min(190, 43 + Math.max(1, bluetoothNewDevices.length) * 28)
            readonly property int bluetoothMenuHeight: 32 + 52 + 8 + bluetoothSavedBlockHeight + 8 + bluetoothNewBlockHeight
            readonly property int nightModeMenuHeight: 210
            readonly property int powerMenuHeight: 368
            readonly property int personalizationMenuHeight: customAccentOpen ? 504 : 448
            property var wallpapers: []
            property string wallpaperDirectory: ""
            property string selectedWallpaper: shellRoot.selectedWallpaper
            property string personalizationMessage: ""
            property string customAccentText: shellRoot.accentColor
            property int wallpaperCarouselIndex: 0
            property bool smartPaletteEnabled: shellRoot.smartPaletteEnabled
            property bool customAccentOpen: false
            onSelectedWallpaperChanged: {
                if (shellRoot.selectedWallpaper !== selectedWallpaper) {
                    shellRoot.selectedWallpaper = selectedWallpaper
                    return
                }
                let index = wallpapers.indexOf(selectedWallpaper)
                if (index < 0) return
                wallpaperSlide.stop()
                wallpaperCarouselIndex = index
                wallpaperCarousel.position = index
            }
            onSmartPaletteEnabledChanged: {
                if (shellRoot.smartPaletteEnabled !== smartPaletteEnabled)
                    shellRoot.smartPaletteEnabled = smartPaletteEnabled
            }
            Connections {
                target: shellRoot
                function onSelectedWallpaperChanged() {
                    if (controlCenter.selectedWallpaper === shellRoot.selectedWallpaper) return
                    controlCenter.selectedWallpaper = shellRoot.selectedWallpaper
                }
                function onSmartPaletteEnabledChanged() {
                    if (controlCenter.smartPaletteEnabled !== shellRoot.smartPaletteEnabled)
                        controlCenter.smartPaletteEnabled = shellRoot.smartPaletteEnabled
                }
            }
            readonly property var accentPalette: ["#25d8a3", "#e993dc", "#e2aa76", "#ed414b"]
            property bool nightModeForced: shellRoot.nightModeForced
            property bool nightModeScheduleEnabled: shellRoot.nightModeScheduleEnabled
            property bool nightModeActive: false
            property int nightModeTemperature: shellRoot.nightModeTemperature
            property string nightModeFrom: shellRoot.nightModeFrom
            property string nightModeTo: shellRoot.nightModeTo
            onNightModeForcedChanged: {
                if (shellRoot.nightModeForced !== nightModeForced)
                    shellRoot.nightModeForced = nightModeForced
                refreshNightModeActive()
            }
            onNightModeScheduleEnabledChanged: {
                if (shellRoot.nightModeScheduleEnabled !== nightModeScheduleEnabled)
                    shellRoot.nightModeScheduleEnabled = nightModeScheduleEnabled
                refreshNightModeActive()
            }
            onNightModeTemperatureChanged: {
                if (shellRoot.nightModeTemperature !== nightModeTemperature)
                    shellRoot.nightModeTemperature = nightModeTemperature
            }
            onNightModeFromChanged: {
                if (shellRoot.nightModeFrom !== nightModeFrom)
                    shellRoot.nightModeFrom = nightModeFrom
                refreshNightModeActive()
            }
            onNightModeToChanged: {
                if (shellRoot.nightModeTo !== nightModeTo)
                    shellRoot.nightModeTo = nightModeTo
                refreshNightModeActive()
            }
            Connections {
                target: shellRoot
                function onNightModeForcedChanged() {
                    if (controlCenter.nightModeForced !== shellRoot.nightModeForced)
                        controlCenter.nightModeForced = shellRoot.nightModeForced
                }
                function onNightModeScheduleEnabledChanged() {
                    if (controlCenter.nightModeScheduleEnabled !== shellRoot.nightModeScheduleEnabled)
                        controlCenter.nightModeScheduleEnabled = shellRoot.nightModeScheduleEnabled
                }
                function onNightModeTemperatureChanged() {
                    if (controlCenter.nightModeTemperature !== shellRoot.nightModeTemperature)
                        controlCenter.nightModeTemperature = shellRoot.nightModeTemperature
                }
                function onNightModeFromChanged() {
                    if (controlCenter.nightModeFrom !== shellRoot.nightModeFrom)
                        controlCenter.nightModeFrom = shellRoot.nightModeFrom
                }
                function onNightModeToChanged() {
                    if (controlCenter.nightModeTo !== shellRoot.nightModeTo)
                        controlCenter.nightModeTo = shellRoot.nightModeTo
                }
            }
            property string nightModeError: ""
            property bool nightModeApplyPending: false
            property real memoryUsedGiB: 0
            property int processorUsage: 0
            property bool batteryPresent: false
            property int batteryPercent: 0
            property int lastDischargingBatteryPercent: -1
            property string batteryStatus: "unknown"
            property int batteryMinutes: -1
            property int batteryHealth: 0
            property string powerProfile: "balanced"
            readonly property var audioSink: Pipewire.defaultAudioSink
            readonly property var audioSource: Pipewire.defaultAudioSource
            readonly property string audioOutputName: audioSink
                ? (audioSink.description || audioSink.nickname || audioSink.name || "No output")
                : "No output"
            readonly property int audioOutputVolume: audioSink && audioSink.audio
                ? Math.round(audioSink.audio.volume * 100)
                : 0
            readonly property string audioInputName: audioSource
                ? (audioSource.description || audioSource.nickname || audioSource.name || "No microphone")
                : "No microphone"
            readonly property int audioInputVolume: audioSource && audioSource.audio
                ? Math.round(audioSource.audio.volume * 100)
                : 0
            property var audioApps: []
            property var audioOutputs: []
            property var audioInputs: []
            property bool audioOutputMenuOpen: false
            property bool audioInputMenuOpen: false
            property bool audioAdjustmentActive: false
            readonly property int primaryFontSize: 16
            readonly property int secondaryFontSize: 13
            readonly property int smallFontSize: 11
            readonly property int wideTileWidth: 154
            readonly property int audioRowCount: Math.max(1, Math.min(3, audioApps.length))
            readonly property int audioBlockHeight: 154 + audioRowCount * 24
            readonly property int homeMenuHeight: 234 + audioBlockHeight

            function compactAudioDeviceName(value) {
                let name = (value || "").replace(/\s+/g, " ").trim()
                name = name.replace(/\s+(analog|digital|stereo|mono|аналоговый|аналоговое|цифровой|цифровое|стерео|моно).*$/i, "")
                if (name.length <= 20) return name
                return name.substring(0, 17).trim() + "..."
            }

            function wallpaperName(path) {
                let parts = (path || "").split("/")
                return parts.length > 0 ? parts[parts.length - 1] : ""
            }

            function wallpaperOffset(index, position) {
                let count = wallpapers.length
                if (count < 2) return index - position
                let offset = index - position
                while (offset > count / 2) offset -= count
                while (offset < -count / 2) offset += count
                return offset
            }

            function toggleCustomAccent() {
                customAccentOpen = !customAccentOpen
                if (customAccentOpen)
                    Qt.callLater(() => customAccentField.forceActiveFocus(Qt.MouseFocusReason))
            }

            function selectWallpaper(index, path) {
                if (!path || wallpaperApplyCommand.running) return
                let offset = wallpaperOffset(index, wallpaperCarousel.position)
                wallpaperCarouselIndex = index
                wallpaperSlide.stop()
                wallpaperSlide.from = wallpaperCarousel.position
                wallpaperSlide.to = wallpaperCarousel.position + offset
                wallpaperSlide.start()
                selectedWallpaper = path
                savePersonalizationSettings()
                applyWallpaper(path)
            }

            function validAccent(value) {
                return /^#[0-9a-fA-F]{6}$/.test((value || "").trim())
            }

            function savePersonalizationSettings() {
                personalizationSettingsFile.setText(JSON.stringify({
                    accent: shellRoot.accentColor,
                    wallpaper: selectedWallpaper,
                    smartPalette: smartPaletteEnabled
                }, null, 2))
            }

            function loadPersonalizationSettings() {
                let contents = personalizationSettingsFile.text().trim()
                if (contents === "") return
                try {
                    let settings = JSON.parse(contents)
                    if (validAccent(settings.accent || "")) {
                        shellRoot.accentColor = settings.accent.toLowerCase()
                        customAccentText = shellRoot.accentColor
                    }
                    selectedWallpaper = settings.wallpaper || ""
                    smartPaletteEnabled = settings.smartPalette === true
                    if (selectedWallpaper !== "")
                        wallpaperRestoreDelay.restart()
                } catch (error) {
                    personalizationMessage = "Could not read personalization settings"
                }
            }

            function setAccent(value) {
                let accent = (value || "").trim()
                if (!validAccent(accent)) {
                    personalizationMessage = "Use a color like #25d8a3"
                    return
                }
                shellRoot.accentColor = accent.toLowerCase()
                smartPaletteEnabled = false
                customAccentOpen = false
                customAccentText = shellRoot.accentColor
                personalizationMessage = "Accent updated"
                savePersonalizationSettings()
            }

            function refreshWallpapers() {
                if (!wallpaperDirectoryQuery.running) wallpaperDirectoryQuery.running = true
                if (!wallpaperListQuery.running) wallpaperListQuery.running = true
            }

            function applyWallpaper(path) {
                if (!path || wallpaperApplyCommand.running) return
                personalizationMessage = "Applying wallpaper…"
                wallpaperApplyCommand.targetPath = path
                wallpaperApplyCommand.command = [Quickshell.shellPath("wallpaper-helper.sh"), "set", path]
                wallpaperApplyCommand.running = true
            }

            function toggleSmartPalette() {
                smartPaletteEnabled = !smartPaletteEnabled
                savePersonalizationSettings()
                if (smartPaletteEnabled && selectedWallpaper !== "")
                    updateAccentFromWallpaper(selectedWallpaper)
            }

            function updateAccentFromWallpaper(path) {
                if (!path || wallpaperAccentQuery.running) return
                wallpaperAccentQuery.command = [Quickshell.shellPath("wallpaper-helper.sh"), "accent", path]
                wallpaperAccentQuery.running = true
            }

            function openPersonalizationMenu() {
                closeAudioDeviceMenus()
                wifiMenuOpen = false
                bluetoothMenuOpen = false
                nightModeMenuOpen = false
                powerMenuOpen = false
                personalizationMenuOpen = true
                customAccentOpen = false
                refreshWallpapers()
            }

            function splitNmcli(line) {
                let fields = []
                let field = ""
                let escaped = false

                for (let i = 0; i < line.length; ++i) {
                    let character = line[i]
                    if (escaped) {
                        field += character
                        escaped = false
                    } else if (character === "\\") {
                        escaped = true
                    } else if (character === ":") {
                        fields.push(field)
                        field = ""
                    } else {
                        field += character
                    }
                }
                fields.push(field)
                return fields
            }

            function bandFromFrequency(frequency) {
                let mhz = parseFloat(frequency)
                if (isNaN(mhz)) return "—"
                if (mhz >= 5925) return "6 GHz"
                if (mhz >= 4900) return "5 GHz"
                return "2.4 GHz"
            }

            function refreshWifi() {
                if (!wifiRadioQuery.running) wifiRadioQuery.running = true
                if (!wifiStatusQuery.running) wifiStatusQuery.running = true
                if (!wifiAccessPointsQuery.running) wifiAccessPointsQuery.running = true
                if (!wifiSavedQuery.running) wifiSavedQuery.running = true
                if (!wifiIpQuery.running) wifiIpQuery.running = true
            }

            function refreshConnectivitySummary() {
                if (!wifiRadioQuery.running) wifiRadioQuery.running = true
                if (!wifiStatusQuery.running) wifiStatusQuery.running = true
                if (!bluetoothPowerQuery.running) bluetoothPowerQuery.running = true
                if (!bluetoothConnectedQuery.running) bluetoothConnectedQuery.running = true
            }

            function closeAudioDeviceMenus() {
                audioOutputMenuOpen = false
                audioInputMenuOpen = false
            }

            function openWifiMenu() {
                closeAudioDeviceMenus()
                bluetoothMenuOpen = false
                nightModeMenuOpen = false
                powerMenuOpen = false
                personalizationMenuOpen = false
                wifiMenuOpen = true
                refreshWifi()
                if (wifiEnabled && !wifiRescanCommand.running)
                    wifiRescanCommand.running = true
            }

            function holdPanelOpen(hold) {
                pointerHoldCount = Math.max(0, pointerHoldCount + (hold ? 1 : -1))
                if (pointerHoldCount > 0)
                    controlCloseDelay.stop()
                else if (!controlHoverHandler.hovered && !controlCloseSuppressed)
                    controlCloseDelay.restart()
            }

            function toggleWifi() {
                if (wifiToggleBlocked || wifiRadioCommand.running) return

                if (wifiEnabled) {
                    if (wifiConnection !== "") wifiLastConnection = wifiConnection
                    wifiRadioCommand.reconnectAfterEnable = false
                    wifiRadioCommand.command = ["nmcli", "radio", "wifi", "off"]
                } else {
                    wifiRadioCommand.reconnectAfterEnable = true
                    wifiRadioCommand.command = ["nmcli", "radio", "wifi", "on"]
                }
                wifiRadioCommand.running = true
            }

            function connectSavedNetwork(name) {
                if (name === "" || wifiConnectCommand.running) return
                wifiLastConnection = name
                wifiConnectingSsid = name
                wifiActionMessage = "Connecting…"

                if (!wifiEnabled) {
                    if (wifiRadioCommand.running) return
                    wifiRadioCommand.reconnectAfterEnable = true
                    wifiRadioCommand.command = ["nmcli", "radio", "wifi", "on"]
                    wifiRadioCommand.running = true
                    return
                }

                wifiConnectCommand.command = ["nmcli", "--wait", "10", "connection", "up", "id", name]
                wifiConnectCommand.running = true
            }

            function savedNetworkIsActive(name) {
                return name === wifiConnection || name === wifiSsid
            }

            function activateSavedNetwork(name) {
                if (savedNetworkIsActive(name)) disconnectCurrentNetwork()
                else connectSavedNetwork(name)
            }

            function disconnectCurrentNetwork() {
                if (wifiConnectCommand.running || wifiDevice === "") return
                wifiConnectingSsid = ""
                wifiActionMessage = "Disconnecting…"
                wifiConnectCommand.command = ["nmcli", "device", "disconnect", wifiDevice]
                wifiConnectCommand.running = true
            }

            function requestVisibleNetwork(network) {
                let security = network.security.trim()
                if (security !== "" && security !== "--") {
                    wifiPendingSsid = network.ssid
                    wifiPasswordPromptOpen = true
                    return
                }
                connectVisibleNetwork(network.ssid, "")
            }

            function connectVisibleNetwork(ssid, password) {
                if (ssid === "" || wifiConnectCommand.running) return
                let connectCommand = ["nmcli", "--wait", "15", "device", "wifi", "connect", ssid]
                if (password !== "") connectCommand.push("password", password)
                wifiConnectingSsid = ssid
                wifiActionMessage = "Connecting…"
                wifiConnectCommand.command = connectCommand
                wifiConnectCommand.running = true
                wifiPasswordPromptOpen = false
            }

            function parseBluetoothDevices(output) {
                let devices = []
                let seen = ({})
                let lines = output.trim().split("\n")
                for (let i = 0; i < lines.length; ++i) {
                    let match = lines[i].match(/^Device\s+([0-9A-Fa-f:]{17})\s+(.+)$/)
                    if (!match || seen[match[1]]) continue
                    seen[match[1]] = true
                    devices.push({ address: match[1], name: match[2].trim() })
                }
                return devices
            }

            function bluetoothIsConnected(address) {
                for (let i = 0; i < bluetoothConnectedAddresses.length; ++i) {
                    if (bluetoothConnectedAddresses[i] === address) return true
                }
                return false
            }

            function refreshBluetooth() {
                if (!bluetoothPowerQuery.running) bluetoothPowerQuery.running = true
                if (!bluetoothSavedQuery.running) bluetoothSavedQuery.running = true
                if (!bluetoothConnectedQuery.running) bluetoothConnectedQuery.running = true
                if (!bluetoothDevicesQuery.running) bluetoothDevicesQuery.running = true
            }

            function openBluetoothMenu() {
                closeAudioDeviceMenus()
                wifiMenuOpen = false
                nightModeMenuOpen = false
                powerMenuOpen = false
                personalizationMenuOpen = false
                bluetoothMenuOpen = true
                refreshBluetooth()
                if (bluetoothEnabled && !bluetoothScanCommand.running)
                    bluetoothScanCommand.running = true
            }

            function toggleBluetooth() {
                if (bluetoothPowerCommand.running) return
                if (bluetoothEnabled && bluetoothCurrentAddress !== "")
                    bluetoothLastAddress = bluetoothCurrentAddress
                bluetoothPowerCommand.reconnectAfterEnable = !bluetoothEnabled
                bluetoothPowerCommand.command = ["bluetoothctl", "power", bluetoothEnabled ? "off" : "on"]
                bluetoothPowerCommand.running = true
            }

            function activateBluetoothDevice(device) {
                if (!device || device.address === "" || bluetoothDeviceCommand.running || bluetoothPairCommand.running) return
                bluetoothPendingAddress = device.address
                bluetoothActionMessage = bluetoothIsConnected(device.address) ? "Disconnecting…" : "Connecting…"
                bluetoothDeviceCommand.command = ["bluetoothctl", bluetoothIsConnected(device.address) ? "disconnect" : "connect", device.address]
                bluetoothDeviceCommand.running = true
            }

            function pairBluetoothDevice(device) {
                if (!device || device.address === "" || bluetoothPairCommand.running || bluetoothDeviceCommand.running) return
                bluetoothPendingAddress = device.address
                bluetoothActionMessage = "Pairing…"
                bluetoothPairCommand.command = ["bluetoothctl", "--agent", "NoInputNoOutput", "--timeout", "30", "pair", device.address]
                bluetoothPairCommand.running = true
            }

            function validNightTime(value) {
                let match = value.match(/^([01][0-9]|2[0-3]):([0-5][0-9]):([0-5][0-9])$/)
                return match !== null
            }

            function nightMinutes(value) {
                let parts = value.split(":")
                if (parts.length < 2) return 0
                return (parseInt(parts[0]) || 0) * 60 + (parseInt(parts[1]) || 0)
            }

            function refreshNightModeActive() {
                if (nightModeForced) {
                    nightModeActive = true
                    return
                }
                if (!nightModeScheduleEnabled) {
                    nightModeActive = false
                    return
                }

                let now = new Date()
                let current = now.getHours() * 60 + now.getMinutes()
                let from = nightMinutes(nightModeFrom)
                let to = nightMinutes(nightModeTo)
                nightModeActive = from <= to
                    ? current >= from && current < to
                    : current >= from || current < to
            }

            function saveNightModeSettings() {
                nightModeSettingsFile.setText(JSON.stringify({
                    forced: nightModeForced,
                    schedule: nightModeScheduleEnabled,
                    temperature: nightModeTemperature,
                    from: nightModeFrom,
                    to: nightModeTo
                }, null, 2))
            }

            function loadNightModeSettings() {
                let contents = nightModeSettingsFile.text().trim()
                if (contents !== "") {
                    try {
                        let settings = JSON.parse(contents)
                        nightModeForced = settings.forced === true
                        nightModeScheduleEnabled = settings.schedule === true
                        if (settings.temperature >= 3000 && settings.temperature <= 6500)
                            nightModeTemperature = Math.round(settings.temperature / 100) * 100
                        if (validNightTime(settings.from || "")) nightModeFrom = settings.from
                        if (validNightTime(settings.to || "")) nightModeTo = settings.to
                    } catch (error) {
                        nightModeError = "Could not read schedule"
                    }
                    refreshNightModeActive()
                    restartNightMode()
                    return
                }
                refreshNightModeActive()
            }

            function restartNightMode() {
                nightModeRestartDelay.restart()
                refreshNightModeActive()
            }

            function applyNightModeSettings() {
                if (nightModeApplyProcess.running) {
                    nightModeApplyPending = true
                    return
                }
                nightModeError = ""
                nightModeApplyProcess.command = [
                    Quickshell.shellPath("night-mode-helper.sh"),
                    nightModeForced ? "true" : "false",
                    nightModeScheduleEnabled ? "true" : "false",
                    nightModeTemperature.toString(),
                    nightModeFrom,
                    nightModeTo,
                    nightModeActive ? "true" : "false"
                ]
                nightModeApplyProcess.running = true
            }

            function setNightModeForced(enabled) {
                nightModeForced = enabled
                saveNightModeSettings()
                restartNightMode()
            }

            function setNightModeSchedule(enabled) {
                nightModeScheduleEnabled = enabled
                if (enabled) nightModeForced = false
                saveNightModeSettings()
                restartNightMode()
            }

            function openNightModeMenu() {
                closeAudioDeviceMenus()
                wifiMenuOpen = false
                bluetoothMenuOpen = false
                powerMenuOpen = false
                personalizationMenuOpen = false
                nightModeMenuOpen = true
            }

            function openPowerMenu() {
                closeAudioDeviceMenus()
                wifiMenuOpen = false
                bluetoothMenuOpen = false
                nightModeMenuOpen = false
                personalizationMenuOpen = false
                powerMenuOpen = true
                refreshSystemPanels()
            }

            function setPowerProfile(profile) {
                if (powerProfileCommand.running || profile === powerProfile) return
                powerProfileCommand.command = [
                    "busctl", "--system", "set-property",
                    "net.hadess.PowerProfiles", "/net/hadess/PowerProfiles",
                    "net.hadess.PowerProfiles", "ActiveProfile", "s", profile
                ]
                powerProfileCommand.running = true
            }

            function batteryTimeText() {
                if (!batteryPresent) return "No battery detected"
                if (batteryStatus === "full") return "Fully charged"
                if (batteryMinutes < 0)
                    return batteryStatus === "charging" ? "Charging" : "Running on battery"
                let hours = Math.floor(batteryMinutes / 60)
                let minutes = batteryMinutes % 60
                if (batteryStatus === "charging")
                    return "Full charge after  " + hours + "H " + minutes + "M"
                if (batteryStatus === "discharging")
                    return "Battery empty after  " + hours + "H " + minutes + "M"
                return "Running on battery"
            }

            function runSessionAction(action) {
                if (sessionActionCommand.running) return
                sessionActionCommand.command = [Quickshell.shellPath("session-action.sh"), action]
                sessionActionCommand.running = true
            }

            function refreshSystemPanels() {
                if (!systemStatsQuery.running) systemStatsQuery.running = true
                if (!audioStatusQuery.running && !audioAdjustmentActive) audioStatusQuery.running = true
            }

            function setAudioVolume(command) {
                audioSetCommand.running = false
                audioSetCommand.command = command
                audioSetCommand.running = true
                audioRefreshDelay.restart()
            }

            function keepOpenAfterAudioDeviceSelection() {
                controlCloseSuppressed = true
                controlCloseDelay.stop()
                audioDeviceSelectionRelease.restart()
            }

            function setAudioDevice(kind, deviceId) {
                if (audioDeviceCommand.running || !deviceId) return
                keepOpenAfterAudioDeviceSelection()
                closeAudioDeviceMenus()
                audioDeviceCommand.command = [
                    Quickshell.shellPath("audio-status.pl"),
                    kind === "output" ? "set-default-output" : "set-default-input",
                    deviceId
                ]
                audioDeviceCommand.running = true
            }

            onIsOpenChanged: {
                if (isOpen) {
                    refreshSystemPanels()
                } else {
                    audioDeviceSelectionRelease.stop()
                    controlCloseSuppressed = false
                    closeAudioDeviceMenus()
                }
            }

            Process {
                id: wifiRadioQuery
                command: ["nmcli", "radio", "wifi"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: controlCenter.wifiEnabled = this.text.trim() === "enabled"
                }
            }

            Process {
                id: wifiStatusQuery
                command: ["nmcli", "-t", "--escape", "yes", "-f", "DEVICE,TYPE,STATE,CONNECTION", "device", "status"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        let device = controlCenter.wifiDevice
                        let connection = ""
                        let lines = this.text.trim().split("\n")
                        for (let i = 0; i < lines.length; ++i) {
                            let fields = controlCenter.splitNmcli(lines[i])
                            if (fields.length >= 4 && fields[1] === "wifi") {
                                device = fields[0]
                                if (fields[2] === "connected") connection = fields[3]
                                break
                            }
                        }
                        controlCenter.wifiDevice = device
                        controlCenter.wifiConnection = connection
                        if (connection !== "") controlCenter.wifiConnectingSsid = ""
                    }
                }
            }

            Process {
                id: wifiAccessPointsQuery
                command: ["nmcli", "-t", "--escape", "yes", "-f", "IN-USE,SSID,SIGNAL,FREQ,SECURITY", "device", "wifi", "list", "--rescan", "no"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        let networks = []
                        let seen = ({})
                        let activeSsid = ""
                        let activeSignal = 0
                        let activeBand = "—"
                        let lines = this.text.trim().split("\n")

                        for (let i = 0; i < lines.length; ++i) {
                            if (lines[i] === "") continue
                            let fields = controlCenter.splitNmcli(lines[i])
                            if (fields.length < 5 || fields[1] === "") continue

                            let network = {
                                ssid: fields[1],
                                signal: parseInt(fields[2]) || 0,
                                frequency: fields[3],
                                security: fields[4]
                            }

                            if (!seen[network.ssid]) {
                                seen[network.ssid] = true
                                networks.push(network)
                            }

                            if (fields[0] === "*") {
                                activeSsid = network.ssid
                                activeSignal = network.signal
                                activeBand = controlCenter.bandFromFrequency(network.frequency)
                            }
                        }

                        networks.sort((left, right) => right.signal - left.signal)
                        controlCenter.wifiVisibleNetworks = networks
                        controlCenter.wifiSsid = activeSsid
                        controlCenter.wifiSignal = activeSignal
                        controlCenter.wifiBand = activeBand
                    }
                }
            }

            Process {
                id: wifiSavedQuery
                command: ["nmcli", "-t", "--escape", "yes", "-f", "NAME,TYPE,TIMESTAMP", "connection", "show"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        let networks = []
                        let lines = this.text.trim().split("\n")
                        for (let i = 0; i < lines.length; ++i) {
                            let fields = controlCenter.splitNmcli(lines[i])
                            if (fields.length >= 3 && fields[1] === "802-11-wireless") {
                                networks.push({ name: fields[0], timestamp: parseInt(fields[2]) || 0 })
                            }
                        }
                        networks.sort((left, right) => right.timestamp - left.timestamp)
                        controlCenter.wifiSavedNetworks = networks
                        if (controlCenter.wifiLastConnection === "" && networks.length > 0)
                            controlCenter.wifiLastConnection = networks[0].name
                    }
                }
            }

            Process {
                id: wifiIpQuery
                command: ["nmcli", "-g", "IP4.ADDRESS", "device", "show", controlCenter.wifiDevice]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        let address = this.text.trim().split("\n")[0]
                        controlCenter.wifiIp = address ? address.split("/")[0] : "—"
                    }
                }
            }

            Process {
                id: wifiRescanCommand
                command: ["nmcli", "device", "wifi", "rescan"]
                onRunningChanged: if (!running) wifiRefreshDelay.restart()
            }

            Process {
                id: wifiRadioCommand
                property bool reconnectAfterEnable: false
                onRunningChanged: {
                    if (running) return
                    if (reconnectAfterEnable && controlCenter.wifiLastConnection !== "") {
                        reconnectAfterEnable = false
                        wifiConnectCommand.command = ["nmcli", "--wait", "10", "connection", "up", "id", controlCenter.wifiLastConnection]
                        wifiConnectCommand.running = true
                    }
                    wifiRefreshDelay.restart()
                }
            }

            Process {
                id: wifiConnectCommand
                stderr: StdioCollector {
                    onStreamFinished: {
                        let error = this.text.trim()
                        if (error !== "") controlCenter.wifiActionMessage = error
                    }
                }
                onRunningChanged: {
                    if (running) return
                    wifiRefreshDelay.restart()
                    wifiActionClearDelay.restart()
                }
            }

            Timer {
                id: wifiRefreshDelay
                interval: 1000
                repeat: false
                onTriggered: controlCenter.refreshWifi()
            }

            Timer {
                id: wifiActionClearDelay
                interval: 3500
                repeat: false
                onTriggered: {
                    controlCenter.wifiActionMessage = ""
                    controlCenter.wifiConnectingSsid = ""
                }
            }

            Timer {
                interval: controlCenter.isOpen ? 5000 : 10000
                running: true
                repeat: true
                onTriggered: {
                    if (controlCenter.wifiMenuOpen)
                        controlCenter.refreshWifi()
                    else if (controlCenter.bluetoothMenuOpen)
                        controlCenter.refreshBluetooth()
                    else
                        controlCenter.refreshConnectivitySummary()
                }
            }

            Process {
                id: bluetoothPowerQuery
                command: ["bluetoothctl", "show"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: controlCenter.bluetoothEnabled = /Powered:\s+yes/.test(this.text)
                }
            }

            Process {
                id: bluetoothSavedQuery
                command: ["bluetoothctl", "devices", "Paired"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: controlCenter.bluetoothSavedDevices = controlCenter.parseBluetoothDevices(this.text)
                }
            }

            Process {
                id: bluetoothDevicesQuery
                command: ["bluetoothctl", "devices"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: controlCenter.bluetoothVisibleDevices = controlCenter.parseBluetoothDevices(this.text)
                }
            }

            Process {
                id: bluetoothConnectedQuery
                command: ["bluetoothctl", "devices", "Connected"]
                running: true
                stdout: StdioCollector {
                    onStreamFinished: {
                        let devices = controlCenter.parseBluetoothDevices(this.text)
                        let addresses = []
                        for (let i = 0; i < devices.length; ++i) addresses.push(devices[i].address)
                        controlCenter.bluetoothConnectedAddresses = addresses

                        if (devices.length > 0) {
                            controlCenter.bluetoothCurrentAddress = devices[0].address
                            controlCenter.bluetoothCurrentName = devices[0].name
                            controlCenter.bluetoothLastAddress = devices[0].address
                            controlCenter.bluetoothPendingAddress = ""
                            bluetoothInfoQuery.command = ["bluetoothctl", "info", devices[0].address]
                            if (!bluetoothInfoQuery.running) bluetoothInfoQuery.running = true
                        } else {
                            controlCenter.bluetoothCurrentAddress = ""
                            controlCenter.bluetoothCurrentName = ""
                            controlCenter.bluetoothCurrentType = "Device"
                            controlCenter.bluetoothCurrentBattery = -1
                        }
                    }
                }
            }

            Process {
                id: bluetoothInfoQuery
                stdout: StdioCollector {
                    onStreamFinished: {
                        let output = this.text
                        let iconMatch = output.match(/Icon:\s+([^\n]+)/)
                        let icon = iconMatch ? iconMatch[1].trim().toLowerCase() : ""
                        if (icon.indexOf("audio") !== -1 || /Audio Sink|Headset|Headphones/i.test(output))
                            controlCenter.bluetoothCurrentType = "Sound device"
                        else if (icon.indexOf("phone") !== -1)
                            controlCenter.bluetoothCurrentType = "Phone"
                        else if (icon.indexOf("input") !== -1 || /Human Interface Device/i.test(output))
                            controlCenter.bluetoothCurrentType = "Input device"
                        else
                            controlCenter.bluetoothCurrentType = "Device"

                        let batteryMatch = output.match(/Battery Percentage:\s+(?:0x[0-9a-f]+\s+)?\(([0-9]+)\)/i)
                        controlCenter.bluetoothCurrentBattery = batteryMatch ? parseInt(batteryMatch[1]) : -1
                    }
                }
            }

            Process {
                id: bluetoothScanCommand
                command: ["bluetoothctl", "--timeout", "4", "scan", "on"]
                onRunningChanged: if (!running) bluetoothRefreshDelay.restart()
            }

            Process {
                id: bluetoothPowerCommand
                property bool reconnectAfterEnable: false
                stdout: StdioCollector {
                    onStreamFinished: {
                        let output = this.text.trim()
                        if (/Failed|No default controller/i.test(output)) controlCenter.bluetoothActionMessage = output.split("\n").pop()
                    }
                }
                stderr: StdioCollector {
                    onStreamFinished: {
                        let error = this.text.trim()
                        if (error !== "") controlCenter.bluetoothActionMessage = error
                    }
                }
                onRunningChanged: {
                    if (running) return
                    if (reconnectAfterEnable && controlCenter.bluetoothLastAddress !== "") {
                        reconnectAfterEnable = false
                        controlCenter.bluetoothPendingAddress = controlCenter.bluetoothLastAddress
                        controlCenter.bluetoothActionMessage = "Connecting…"
                        bluetoothDeviceCommand.command = ["bluetoothctl", "connect", controlCenter.bluetoothLastAddress]
                        bluetoothDeviceCommand.running = true
                    }
                    bluetoothRefreshDelay.restart()
                    bluetoothActionClearDelay.restart()
                }
            }

            Process {
                id: bluetoothDeviceCommand
                stdout: StdioCollector {
                    onStreamFinished: {
                        let output = this.text.trim()
                        if (/Failed|not available|No default controller/i.test(output)) controlCenter.bluetoothActionMessage = output.split("\n").pop()
                    }
                }
                stderr: StdioCollector {
                    onStreamFinished: {
                        let error = this.text.trim()
                        if (error !== "") controlCenter.bluetoothActionMessage = error
                    }
                }
                onRunningChanged: {
                    if (running) return
                    bluetoothRefreshDelay.restart()
                    bluetoothActionClearDelay.restart()
                }
            }

            Process {
                id: bluetoothPairCommand
                stdout: StdioCollector {
                    onStreamFinished: {
                        let output = this.text.trim()
                        if (/Failed|Authentication|not available|No default controller/i.test(output)) controlCenter.bluetoothActionMessage = output.split("\n").pop()
                    }
                }
                stderr: StdioCollector {
                    onStreamFinished: {
                        let error = this.text.trim()
                        if (error !== "") controlCenter.bluetoothActionMessage = error
                    }
                }
                onRunningChanged: {
                    if (running || controlCenter.bluetoothPendingAddress === "") return
                    bluetoothTrustCommand.command = ["bluetoothctl", "trust", controlCenter.bluetoothPendingAddress]
                    bluetoothTrustCommand.running = true
                }
            }

            Process {
                id: bluetoothTrustCommand
                onRunningChanged: {
                    if (running || controlCenter.bluetoothPendingAddress === "") return
                    controlCenter.bluetoothActionMessage = "Connecting…"
                    bluetoothDeviceCommand.command = ["bluetoothctl", "connect", controlCenter.bluetoothPendingAddress]
                    bluetoothDeviceCommand.running = true
                }
            }

            Timer {
                id: bluetoothRefreshDelay
                interval: 900
                repeat: false
                onTriggered: controlCenter.refreshBluetooth()
            }

            Timer {
                id: bluetoothActionClearDelay
                interval: 4000
                repeat: false
                onTriggered: {
                    controlCenter.bluetoothActionMessage = ""
                    controlCenter.bluetoothPendingAddress = ""
                }
            }

            Timer {
                interval: 12000
                running: controlCenter.bluetoothMenuOpen && controlCenter.bluetoothEnabled
                repeat: true
                triggeredOnStart: true
                onTriggered: if (!bluetoothScanCommand.running) bluetoothScanCommand.running = true
            }

            FileView {
                id: personalizationSettingsFile
                path: Quickshell.shellPath("personalization.json")
                blockLoading: true
                atomicWrites: true
                printErrors: false
            }

            Process {
                id: wallpaperDirectoryQuery
                command: [Quickshell.shellPath("wallpaper-helper.sh"), "directory"]
                stdout: StdioCollector {
                    onStreamFinished: controlCenter.wallpaperDirectory = this.text.trim()
                }
            }

            Process {
                id: wallpaperListQuery
                command: [Quickshell.shellPath("wallpaper-helper.sh"), "list"]
                stdout: StdioCollector {
                    onStreamFinished: {
                        let paths = []
                        let lines = this.text.trim().split("\n")
                        for (let i = 0; i < lines.length; ++i) {
                            let path = lines[i].trim()
                            if (path !== "") paths.push(path)
                        }
                        let previous = controlCenter.wallpapers
                        let changed = paths.length !== previous.length
                        for (let i = 0; !changed && i < paths.length; ++i)
                            changed = paths[i] !== previous[i]
                        if (!changed) return
                        controlCenter.wallpapers = paths
                        let selectedIndex = paths.indexOf(controlCenter.selectedWallpaper)
                        controlCenter.wallpaperCarouselIndex = selectedIndex >= 0 ? selectedIndex : 0
                        wallpaperSlide.stop()
                        wallpaperCarousel.position = controlCenter.wallpaperCarouselIndex
                    }
                }
            }

            Process {
                id: wallpaperAccentQuery
                stdout: StdioCollector {
                    onStreamFinished: {
                        let accent = this.text.trim()
                        if (!controlCenter.validAccent(accent)) return
                        shellRoot.accentColor = accent.toLowerCase()
                        controlCenter.customAccentText = shellRoot.accentColor
                        controlCenter.personalizationMessage = "Palette updated from wallpaper"
                        controlCenter.savePersonalizationSettings()
                    }
                }
            }

            Timer {
                id: wallpaperRestoreDelay
                interval: 700
                onTriggered: {
                    if (controlCenter.selectedWallpaper === "" || !mainWindow.modelData)
                        return
                    wallpaperRestoreCommand.command = [
                        Quickshell.shellPath("wallpaper-helper.sh"), "set",
                        controlCenter.selectedWallpaper, mainWindow.modelData.name
                    ]
                    wallpaperRestoreCommand.running = true
                }
            }

            Process { id: wallpaperRestoreCommand }

            Process {
                id: wallpaperApplyCommand
                property string targetPath: ""
                property string errorText: ""
                stderr: StdioCollector {
                    onStreamFinished: wallpaperApplyCommand.errorText = this.text.trim()
                }
                onRunningChanged: {
                    if (running) errorText = ""
                }
                onExited: (exitCode, exitStatus) => {
                    if (targetPath === "") return
                    if (exitCode === 0) {
                        controlCenter.selectedWallpaper = targetPath
                        controlCenter.personalizationMessage = "Wallpaper applied"
                        controlCenter.savePersonalizationSettings()
                        if (controlCenter.smartPaletteEnabled)
                            controlCenter.updateAccentFromWallpaper(targetPath)
                    } else {
                        controlCenter.personalizationMessage = errorText !== ""
                            ? errorText.split("\n").pop()
                            : "Could not apply wallpaper"
                    }
                    targetPath = ""
                }
            }

            FileView {
                id: nightModeSettingsFile
                path: Quickshell.shellPath("night-mode.json")
                blockLoading: true
                atomicWrites: true
                printErrors: false
            }

            Process {
                id: nightModeApplyProcess
                stderr: StdioCollector {
                    onStreamFinished: {
                        let error = this.text.trim()
                        if (error !== "") controlCenter.nightModeError = error.split("\n").pop()
                    }
                }
                onRunningChanged: {
                    if (running || !controlCenter.nightModeApplyPending) return
                    controlCenter.nightModeApplyPending = false
                    nightModeRestartDelay.restart()
                }
            }

            Process { id: sessionActionCommand }

            Process {
                id: systemStatsQuery
                command: [Quickshell.shellPath("system-stats.sh")]
                stdout: StdioCollector {
                    onStreamFinished: {
                        let values = this.text.trim().split("|")
                        if (values.length < 2) return
                        let memory = parseFloat(values[0])
                        let processor = parseInt(values[1])
                        if (!isNaN(memory)) controlCenter.memoryUsedGiB = memory
                        if (!isNaN(processor)) controlCenter.processorUsage = processor
                        if (values.length >= 8) {
                            let present = values[2] === "1"
                            let percent = parseInt(values[3])
                            let status = values[4] || "unknown"
                            controlCenter.batteryPresent = present
                            controlCenter.batteryPercent = isNaN(percent) ? 0 : percent
                            controlCenter.batteryStatus = status
                            island.updateBatteryWarning(present, percent, status)
                            controlCenter.batteryMinutes = parseInt(values[5])
                            controlCenter.batteryHealth = parseInt(values[6]) || 0
                            controlCenter.powerProfile = values[7] || "balanced"
                        }
                    }
                }
            }

            Timer {
                interval: 30000
                running: true
                repeat: true
                triggeredOnStart: true
                onTriggered: if (!systemStatsQuery.running) systemStatsQuery.running = true
            }

            Process {
                id: powerProfileCommand
                stderr: StdioCollector {
                    onStreamFinished: {
                        let error = this.text.trim()
                        if (error !== "") console.warn("Could not change power profile:", error)
                    }
                }
                onRunningChanged: {
                    if (!running && !systemStatsQuery.running)
                        systemStatsQuery.running = true
                }
            }

            Process {
                id: audioStatusQuery
                command: [Quickshell.shellPath("audio-status.pl")]
                stdout: StdioCollector {
                    onStreamFinished: {
                        try {
                            let status = JSON.parse(this.text.trim())
                            controlCenter.audioOutputs = status.outputs || []
                            controlCenter.audioInputs = status.inputs || []
                            if (!controlCenter.audioAdjustmentActive)
                                controlCenter.audioApps = status.apps || []
                        } catch (error) {
                            // Keep the most recent values while PipeWire is restarting.
                        }
                    }
                }
            }

            Process { id: audioSetCommand }

            Process {
                id: audioDeviceCommand
                stderr: StdioCollector {
                    onStreamFinished: {
                        let error = this.text.trim()
                        if (error !== "") console.warn("Could not change audio device:", error)
                    }
                }
                onRunningChanged: {
                    if (!running && !audioStatusQuery.running)
                        audioStatusQuery.running = true
                }
            }

            Timer {
                interval: 2000
                running: controlCenter.isOpen
                    && !controlCenter.wifiMenuOpen
                    && !controlCenter.bluetoothMenuOpen
                    && !controlCenter.nightModeMenuOpen
                    && !controlCenter.personalizationMenuOpen
                repeat: true
                triggeredOnStart: true
                onTriggered: controlCenter.refreshSystemPanels()
            }

            Timer {
                id: audioRefreshDelay
                interval: 250
                repeat: false
                onTriggered: {
                    controlCenter.audioAdjustmentActive = false
                    if (!audioStatusQuery.running) audioStatusQuery.running = true
                }
            }

            Timer {
                id: audioDeviceSelectionRelease
                interval: 400
                repeat: false
                onTriggered: {
                    controlCenter.controlCloseSuppressed = false
                    if (!controlHoverHandler.hovered && controlCenter.pointerHoldCount === 0)
                        controlCloseDelay.restart()
                }
            }

            Timer {
                id: nightModeRestartDelay
                interval: 120
                repeat: false
                onTriggered: controlCenter.applyNightModeSettings()
            }

            Timer {
                interval: 30000
                running: true
                repeat: true
                triggeredOnStart: true
                onTriggered: {
                    const wasActive = controlCenter.nightModeActive
                    controlCenter.refreshNightModeActive()
                    if (wasActive !== controlCenter.nightModeActive)
                        controlCenter.restartNightMode()
                }
            }

            Component.onCompleted: {
                loadNightModeSettings()
                loadPersonalizationSettings()
                refreshWallpapers()
            }

            anchors.fill: controlWidget
            opacity: isOpen ? 1 : 0
            color: "transparent"
            clip: true

            HoverHandler {
                enabled: controlCenter.isOpen
                cursorShape: Qt.ArrowCursor
                onHoveredChanged: controlCenter.holdPanelOpen(hovered)
                Component.onDestruction: {
                    if (hovered) controlCenter.holdPanelOpen(false)
                }
            }

            Behavior on opacity { NumberAnimation { duration: 180 } }

            Column {
                id: settingsHome
                anchors.fill: parent; anchors.margins: 16; spacing: 8
                visible: !controlCenter.wifiMenuOpen
                    && !controlCenter.bluetoothMenuOpen
                    && !controlCenter.nightModeMenuOpen
                    && !controlCenter.powerMenuOpen
                    && !controlCenter.personalizationMenuOpen

                // --- РЯД 1: Wi-Fi, Night mode ---
                Row {
                    spacing: 8
                    Rectangle {
                        id: wifiTile
                        width: controlCenter.wideTileWidth; height: 52; radius: 24; color: "#161616"
                        Row {
                            anchors.fill: parent; anchors.margins: 6; spacing: 8
                            Rectangle {
                                width: 40; height: 40; radius: 20
                                color: controlCenter.wifiEnabled ? shellRoot.accentColor : "#262626"
                                Behavior on color { ColorAnimation { duration: 180 } }
                                HoverHandler {
                                    id: wifiPowerHover
                                    onHoveredChanged: {
                                        if (!hovered && !wifiToggleReadyDelay.running)
                                            controlCenter.wifiToggleBlocked = false
                                    }
                                }
                                Image {
                                    anchors.centerIn: parent
                                    width: 21; height: 16
                                    source: Quickshell.shellPath(controlCenter.wifiEnabled
                                        ? "assets/wifi-glyph-on.png" : "assets/wifi-glyph-off.png")
                                    sourceSize.width: 21; sourceSize.height: 16
                                    smooth: true
                                }
                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    anchors.fill: parent
                                    enabled: controlCenter.wifiPowerReady
                                    property bool pressStartedReady: false
                                    onPressed: pressStartedReady = controlCenter.wifiPowerReady
                                    onCanceled: pressStartedReady = false
                                    onClicked: {
                                        if (pressStartedReady && controlCenter.wifiPowerReady)
                                            controlCenter.toggleWifi()
                                        pressStartedReady = false
                                    }
                                }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                Text { text: "Wi-Fi"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize }
                                Text {
                                    width: 94
                                    text: controlCenter.wifiEnabled
                                        ? (controlCenter.wifiSsid || controlCenter.wifiConnection || "Not connected")
                                        : "Off"
                                    color: "#888888"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors { top: parent.top; right: parent.right; bottom: parent.bottom }
                            width: parent.width - 52
                            onClicked: controlCenter.openWifiMenu()
                        }
                    }
                    Rectangle {
                        id: nightModeTile
                        width: controlCenter.wideTileWidth; height: 52; radius: 24; color: "#161616"
                        Row {
                            anchors.fill: parent; anchors.margins: 6; spacing: 8
                            Rectangle {
                                width: 40; height: 40; radius: 20
                                color: controlCenter.nightModeActive ? shellRoot.accentColor : "#262626"
                                Behavior on color { ColorAnimation { duration: 180 } }
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 22; height: 22
                                    property bool activeState: controlCenter.nightModeActive
                                    property string accentColor: shellRoot.accentColor
                                    onActiveStateChanged: requestPaint()
                                    onAccentColorChanged: requestPaint()
                                    onPaint: {
                                        let ctx = getContext("2d")
                                        ctx.reset()
                                        ctx.fillStyle = activeState ? "#050505" : "#888888"
                                        ctx.beginPath()
                                        ctx.arc(10, 11, 7, 0, Math.PI * 2)
                                        ctx.fill()
                                        ctx.fillStyle = activeState ? accentColor : "#262626"
                                        ctx.beginPath()
                                        ctx.arc(13.5, 8.5, 7, 0, Math.PI * 2)
                                        ctx.fill()
                                    }
                                }
                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    anchors.fill: parent
                                    onClicked: controlCenter.setNightModeForced(!controlCenter.nightModeForced)
                                }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                Text { text: "Night mode"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize }
                                Text {
                                    text: controlCenter.nightModeForced
                                        ? "On"
                                        : (controlCenter.nightModeScheduleEnabled ? "Scheduled" : "Off")
                                    color: "#888888"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                }
                            }
                        }
                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors { top: parent.top; right: parent.right; bottom: parent.bottom }
                            width: parent.width - 52
                            onClicked: controlCenter.openNightModeMenu()
                        }
                    }
                    Rectangle {
                        width: 52; height: 52; radius: 26; color: "#161616"

                        Canvas {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = "#ffffff"
                                ctx.fillStyle = "#ffffff"
                                ctx.lineWidth = 3.4
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"

                                ctx.beginPath()
                                ctx.moveTo(17.5, 3.5)
                                ctx.lineTo(9.5, 11.5)
                                ctx.stroke()

                                ctx.beginPath()
                                ctx.moveTo(10.5, 10.5)
                                ctx.quadraticCurveTo(12.5, 13.5, 10.5, 16.5)
                                ctx.quadraticCurveTo(8, 20, 3, 18.5)
                                ctx.quadraticCurveTo(6, 16.5, 5.5, 13.5)
                                ctx.quadraticCurveTo(7.5, 10.5, 10.5, 10.5)
                                ctx.fill()
                            }
                        }

                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors.fill: parent
                            onClicked: controlCenter.openPersonalizationMenu()
                        }
                    }
                }

                // --- РЯД 2: Bluetooth, Usage ---
                Row {
                    spacing: 8
                    Rectangle {
                        id: bluetoothTile
                        width: controlCenter.wideTileWidth; height: 52; radius: 24; color: "#161616"
                        Row {
                            anchors.fill: parent; anchors.margins: 6; spacing: 8
                            Rectangle {
                                width: 40; height: 40; radius: 20
                                color: controlCenter.bluetoothEnabled ? shellRoot.accentColor : "#262626"
                                Behavior on color { ColorAnimation { duration: 180 } }
                                Canvas {
                                    anchors.centerIn: parent
                                    width: 22; height: 22
                                    property bool enabledState: controlCenter.bluetoothEnabled
                                    onEnabledStateChanged: requestPaint()
                                    onPaint: {
                                        let ctx = getContext("2d")
                                        ctx.reset()
                                        ctx.strokeStyle = enabledState ? "#050505" : "#888888"
                                        ctx.lineWidth = 2.2
                                        ctx.lineCap = "round"
                                        ctx.lineJoin = "round"
                                        ctx.beginPath()
                                        ctx.moveTo(10, 2)
                                        ctx.lineTo(10, 20)
                                        ctx.moveTo(10, 2)
                                        ctx.lineTo(16, 7)
                                        ctx.lineTo(5, 15)
                                        ctx.moveTo(10, 20)
                                        ctx.lineTo(16, 15)
                                        ctx.lineTo(5, 7)
                                        ctx.stroke()
                                    }
                                }
                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    anchors.fill: parent
                                    onClicked: controlCenter.toggleBluetooth()
                                }
                            }
                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                Text { text: "Bluetooth"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize }
                                Text {
                                    width: 94
                                    text: controlCenter.bluetoothEnabled
                                        ? (controlCenter.bluetoothCurrentName || "Not connected")
                                        : "Off"
                                    color: "#888888"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                    elide: Text.ElideRight
                                }
                            }
                        }
                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors { top: parent.top; right: parent.right; bottom: parent.bottom }
                            width: parent.width - 52
                            onClicked: controlCenter.openBluetoothMenu()
                        }
                    }
                    Rectangle {
                        id: usageTile
                        width: controlCenter.wideTileWidth; height: 52; radius: 24; color: "#161616"
                        Row {
                            anchors { fill: parent; leftMargin: 8; rightMargin: 8 }
                            spacing: 1

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: (parent.width - 2) / 3; spacing: 0
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "Mem"; color: "#ffffff"
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: controlCenter.memoryUsedGiB.toFixed(1) + " Gib"
                                    color: "#e8d79a"
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: (parent.width - 2) / 3; spacing: 0
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "Proc"; color: "#ffffff"
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: controlCenter.processorUsage
                                    color: controlCenter.processorUsage >= 85
                                        ? "#ff3048"
                                        : (controlCenter.processorUsage >= 60 ? "#f0c45e" : shellRoot.accentColor)
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                                }
                            }

                            Column {
                                anchors.verticalCenter: parent.verticalCenter
                                width: (parent.width - 2) / 3; spacing: 0
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: "Bat"; color: "#ffffff"
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                }
                                Text {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: controlCenter.batteryPresent ? controlCenter.batteryPercent : "—"
                                    color: "#ffffff"
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                                }
                            }
                        }

                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors.fill: parent
                            onClicked: controlCenter.openPowerMenu()
                        }
                    }
                    Rectangle {
                        width: 52; height: 52; radius: 26; color: "#161616"

                        Canvas {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.fillStyle = "#ffffff"
                                ctx.beginPath()
                                ctx.arc(10, 11, 8, 0, Math.PI * 2)
                                ctx.fill()
                                ctx.fillStyle = "#161616"
                                ctx.beginPath()
                                ctx.arc(14, 7.5, 8, 0, Math.PI * 2)
                                ctx.fill()
                            }
                        }

                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors.fill: parent
                            onClicked: controlCenter.runSessionAction("lock-and-suspend")
                        }
                    }
                }

                // --- ПОЛЗУНОК ЗВУКА ---
                Rectangle {
                    id: audioBlock
                    width: parent.width; height: controlCenter.audioBlockHeight; radius: 24; color: "#161616"
                    z: controlCenter.audioOutputMenuOpen || controlCenter.audioInputMenuOpen ? 10 : 0
                    Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    HoverHandler {
                        cursorShape: Qt.ArrowCursor
                        onHoveredChanged: controlCenter.holdPanelOpen(hovered)
                        Component.onDestruction: {
                            if (hovered) controlCenter.holdPanelOpen(false)
                        }
                    }

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 16 }
                        width: 96
                        text: "Sound"; color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }
                    Item {
                        id: outputDeviceSelector
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 14; leftMargin: 120; rightMargin: 66 }
                        height: 18

                        Text {
                            id: outputDeviceName
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitWidth, parent.width - 17)
                            text: controlCenter.compactAudioDeviceName(controlCenter.audioOutputName)
                            color: "#777777"; elide: Text.ElideRight
                            font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                            maximumLineCount: 1
                        }

                        Canvas {
                            anchors { left: outputDeviceName.right; verticalCenter: parent.verticalCenter; leftMargin: 5 }
                            width: 10; height: 6
                            property bool expanded: controlCenter.audioOutputMenuOpen
                            onExpandedChanged: requestPaint()
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = "#777777"
                                ctx.lineWidth = 1.5
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                if (expanded) {
                                    ctx.moveTo(1, 5)
                                    ctx.lineTo(5, 1)
                                    ctx.lineTo(9, 5)
                                } else {
                                    ctx.moveTo(1, 1)
                                    ctx.lineTo(5, 5)
                                    ctx.lineTo(9, 1)
                                }
                                ctx.stroke()
                            }
                        }

                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            id: outputDeviceSelectorMouse
                            anchors.fill: parent
                            property bool keepsPanelOpen: containsMouse || pressed
                            hoverEnabled: true
                            onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                            Component.onDestruction: {
                                if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                            }
                            onClicked: {
                                controlCenter.audioInputMenuOpen = false
                                controlCenter.audioOutputMenuOpen = controlCenter.audioOutputs.length > 0
                                    && !controlCenter.audioOutputMenuOpen
                            }
                        }
                    }
                    Text {
                        anchors { top: parent.top; right: parent.right; topMargin: 14; rightMargin: 16 }
                        width: 42
                        horizontalAlignment: Text.AlignRight
                        text: controlCenter.audioOutputVolume + "%"
                        color: "#777777"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }

                    Slider {
                        id: outputVolumeSlider
                        property bool keepsPanelOpen: hovered || pressed
                        hoverEnabled: true
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 34; leftMargin: 14; rightMargin: 14 }
                        height: 22; from: 0.0; to: 1.0; value: 0
                        onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                        Component.onDestruction: {
                            if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                        }

                        Binding {
                            target: outputVolumeSlider
                            property: "value"
                            value: controlCenter.audioSink && controlCenter.audioSink.audio
                                ? controlCenter.audioSink.audio.volume
                                : 0
                            when: !outputVolumeSlider.pressed
                            restoreMode: Binding.RestoreNone
                        }

                        background: Rectangle {
                            x: outputVolumeSlider.leftPadding
                            y: outputVolumeSlider.topPadding + (outputVolumeSlider.availableHeight - height) / 2
                            width: outputVolumeSlider.availableWidth; height: 22; radius: 11; color: "#050505"; clip: true
                            Rectangle {
                                width: outputVolumeSlider.visualPosition * (outputVolumeSlider.availableWidth - outputVolumeSlider.handle.width)
                                       + outputVolumeSlider.handle.width / 2
                                height: parent.height
                                radius: 0
                                topLeftRadius: parent.radius
                                bottomLeftRadius: parent.radius
                                color: shellRoot.accentColor
                            }
                        }
                        handle: Rectangle {
                            x: outputVolumeSlider.leftPadding + outputVolumeSlider.visualPosition * (outputVolumeSlider.availableWidth - width)
                            y: outputVolumeSlider.topPadding + (outputVolumeSlider.availableHeight - height) / 2
                            width: 22; height: 22; radius: 11; color: "#ffffff"
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                        }
                        onPressedChanged: controlCenter.audioAdjustmentActive = pressed
                        onMoved: {
                            if (controlCenter.audioSink && controlCenter.audioSink.audio)
                                controlCenter.audioSink.audio.volume = value
                        }
                    }

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 70; leftMargin: 16 }
                        width: 96
                        text: "Microphone"; color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }
                    Item {
                        id: inputDeviceSelector
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 72; leftMargin: 120; rightMargin: 66 }
                        height: 18

                        Text {
                            id: inputDeviceName
                            anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                            width: Math.min(implicitWidth, parent.width - 17)
                            text: controlCenter.compactAudioDeviceName(controlCenter.audioInputName)
                            color: "#777777"; elide: Text.ElideRight
                            font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                            maximumLineCount: 1
                        }

                        Canvas {
                            anchors { left: inputDeviceName.right; verticalCenter: parent.verticalCenter; leftMargin: 5 }
                            width: 10; height: 6
                            property bool expanded: controlCenter.audioInputMenuOpen
                            onExpandedChanged: requestPaint()
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = "#777777"
                                ctx.lineWidth = 1.5
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                if (expanded) {
                                    ctx.moveTo(1, 5)
                                    ctx.lineTo(5, 1)
                                    ctx.lineTo(9, 5)
                                } else {
                                    ctx.moveTo(1, 1)
                                    ctx.lineTo(5, 5)
                                    ctx.lineTo(9, 1)
                                }
                                ctx.stroke()
                            }
                        }

                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            id: inputDeviceSelectorMouse
                            anchors.fill: parent
                            property bool keepsPanelOpen: containsMouse || pressed
                            hoverEnabled: true
                            onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                            Component.onDestruction: {
                                if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                            }
                            onClicked: {
                                controlCenter.audioOutputMenuOpen = false
                                controlCenter.audioInputMenuOpen = controlCenter.audioInputs.length > 0
                                    && !controlCenter.audioInputMenuOpen
                            }
                        }
                    }
                    Text {
                        anchors { top: parent.top; right: parent.right; topMargin: 72; rightMargin: 16 }
                        width: 42
                        horizontalAlignment: Text.AlignRight
                        text: controlCenter.audioInputVolume + "%"
                        color: "#777777"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }

                    Slider {
                        id: inputVolumeSlider
                        property bool keepsPanelOpen: hovered || pressed
                        hoverEnabled: true
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 92; leftMargin: 14; rightMargin: 14 }
                        height: 22; from: 0.0; to: 1.0; value: 0
                        onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                        Component.onDestruction: {
                            if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                        }

                        Binding {
                            target: inputVolumeSlider
                            property: "value"
                            value: controlCenter.audioSource && controlCenter.audioSource.audio
                                ? controlCenter.audioSource.audio.volume
                                : 0
                            when: !inputVolumeSlider.pressed
                            restoreMode: Binding.RestoreNone
                        }

                        background: Rectangle {
                            x: inputVolumeSlider.leftPadding
                            y: inputVolumeSlider.topPadding + (inputVolumeSlider.availableHeight - height) / 2
                            width: inputVolumeSlider.availableWidth; height: 22; radius: 11; color: "#050505"; clip: true
                            Rectangle {
                                width: inputVolumeSlider.visualPosition * (inputVolumeSlider.availableWidth - inputVolumeSlider.handle.width)
                                       + inputVolumeSlider.handle.width / 2
                                height: parent.height
                                radius: 0
                                topLeftRadius: parent.radius
                                bottomLeftRadius: parent.radius
                                color: shellRoot.accentColor
                            }
                        }
                        handle: Rectangle {
                            x: inputVolumeSlider.leftPadding + inputVolumeSlider.visualPosition * (inputVolumeSlider.availableWidth - width)
                            y: inputVolumeSlider.topPadding + (inputVolumeSlider.availableHeight - height) / 2
                            width: 22; height: 22; radius: 11; color: "#ffffff"
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                        }
                        onPressedChanged: controlCenter.audioAdjustmentActive = pressed
                        onMoved: {
                            if (controlCenter.audioSource && controlCenter.audioSource.audio)
                                controlCenter.audioSource.audio.volume = value
                        }
                    }

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 128; leftMargin: 16 }
                        text: "Apps"; color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }

                    Column {
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 150; leftMargin: 16; rightMargin: 14 }
                        spacing: 2

                        Repeater {
                            model: controlCenter.audioApps
                            Item {
                                id: audioAppRow
                                required property var modelData
                                width: parent.width; height: 22

                                Text {
                                    anchors { left: parent.left; verticalCenter: parent.verticalCenter }
                                    width: 120
                                    text: audioAppRow.modelData.name
                                    color: "#d0d0d0"; elide: Text.ElideRight
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                }
                                Slider {
                                    id: appVolumeSlider
                                    property bool keepsPanelOpen: hovered || pressed
                                    hoverEnabled: true
                                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter; leftMargin: 128 }
                                    height: 12; from: 0.0; to: 1.0
                                    value: Math.min(1, audioAppRow.modelData.volume / 100)
                                    onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                                    Component.onDestruction: {
                                        if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                                    }

                                    background: Rectangle {
                                        x: appVolumeSlider.leftPadding
                                        y: appVolumeSlider.topPadding + (appVolumeSlider.availableHeight - height) / 2
                                        width: appVolumeSlider.availableWidth; height: 10; radius: 5; color: "#050505"; clip: true
                                        Rectangle {
                                            width: appVolumeSlider.visualPosition * (appVolumeSlider.availableWidth - appVolumeSlider.handle.width)
                                                   + appVolumeSlider.handle.width / 2
                                            height: parent.height
                                            radius: 0
                                            topLeftRadius: parent.radius
                                            bottomLeftRadius: parent.radius
                                            color: shellRoot.accentColor
                                        }
                                    }
                                    handle: Rectangle {
                                        x: appVolumeSlider.leftPadding + appVolumeSlider.visualPosition * (appVolumeSlider.availableWidth - width)
                                        y: appVolumeSlider.topPadding + (appVolumeSlider.availableHeight - height) / 2
                                        width: 10; height: 10; radius: 5; color: "#ffffff"
                                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                                    }
                                    onPressedChanged: controlCenter.audioAdjustmentActive = pressed
                                    onMoved: {
                                        let percent = Math.round(value * 100)
                                        controlCenter.setAudioVolume(["pactl", "set-sink-input-volume", audioAppRow.modelData.id.toString(), percent + "%"])
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 153; leftMargin: 16 }
                        visible: controlCenter.audioApps.length === 0
                        text: "No active apps"
                        color: "#666666"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }

                    Rectangle {
                        id: outputDeviceMenu
                        x: 112; y: 32
                        width: 206
                        height: Math.min(4, controlCenter.audioOutputs.length) * 30 + 8
                        radius: 18
                        color: "#080808"
                        border.color: "#202020"
                        border.width: 1
                        clip: true
                        z: 30
                        property bool keepsPanelOpen: enabled && outputDeviceMenuHover.hovered
                        enabled: controlCenter.audioOutputMenuOpen && controlCenter.audioOutputs.length > 0
                        visible: enabled || opacity > 0
                        opacity: enabled ? 1 : 0
                        scale: enabled ? 1 : 0.94
                        transformOrigin: Item.Top
                        onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                        Component.onDestruction: {
                            if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                        }
                        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }

                        HoverHandler { id: outputDeviceMenuHover }

                        ListView {
                            id: outputDeviceList
                            anchors.fill: parent
                            anchors.margins: 4
                            model: controlCenter.audioOutputs
                            interactive: count > 4
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                required property var modelData
                                width: outputDeviceList.width
                                height: 30
                                radius: 14
                                color: modelData.active
                                    ? "#181818"
                                    : (outputDeviceMouse.containsMouse ? "#121212" : "transparent")

                                Text {
                                    anchors { left: parent.left; right: activeOutputDot.left; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 8 }
                                    text: parent.modelData.name
                                    color: parent.modelData.active ? "#ffffff" : "#999999"
                                    elide: Text.ElideRight
                                    font.bold: true
                                    font.family: "SF Pro Rounded"
                                    font.pixelSize: controlCenter.secondaryFontSize
                                }

                                Rectangle {
                                    id: activeOutputDot
                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 10 }
                                    width: 6; height: 6; radius: 3
                                    color: shellRoot.accentColor
                                    visible: parent.modelData.active
                                }

                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    id: outputDeviceMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        if (parent.modelData.active) {
                                            controlCenter.keepOpenAfterAudioDeviceSelection()
                                            controlCenter.closeAudioDeviceMenus()
                                        } else {
                                            controlCenter.setAudioDevice("output", parent.modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Rectangle {
                        id: inputDeviceMenu
                        x: 112; y: 90
                        width: 206
                        height: Math.min(4, controlCenter.audioInputs.length) * 30 + 8
                        radius: 18
                        color: "#080808"
                        border.color: "#202020"
                        border.width: 1
                        clip: true
                        z: 30
                        property bool keepsPanelOpen: enabled && inputDeviceMenuHover.hovered
                        enabled: controlCenter.audioInputMenuOpen && controlCenter.audioInputs.length > 0
                        visible: enabled || opacity > 0
                        opacity: enabled ? 1 : 0
                        scale: enabled ? 1 : 0.94
                        transformOrigin: Item.Top
                        onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                        Component.onDestruction: {
                            if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                        }
                        Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                        Behavior on scale { NumberAnimation { duration: 180; easing.type: Easing.OutBack } }

                        HoverHandler { id: inputDeviceMenuHover }

                        ListView {
                            id: inputDeviceList
                            anchors.fill: parent
                            anchors.margins: 4
                            model: controlCenter.audioInputs
                            interactive: count > 4
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                required property var modelData
                                width: inputDeviceList.width
                                height: 30
                                radius: 14
                                color: modelData.active
                                    ? "#181818"
                                    : (inputDeviceMouse.containsMouse ? "#121212" : "transparent")

                                Text {
                                    anchors { left: parent.left; right: activeInputDot.left; verticalCenter: parent.verticalCenter; leftMargin: 12; rightMargin: 8 }
                                    text: parent.modelData.name
                                    color: parent.modelData.active ? "#ffffff" : "#999999"
                                    elide: Text.ElideRight
                                    font.bold: true
                                    font.family: "SF Pro Rounded"
                                    font.pixelSize: controlCenter.secondaryFontSize
                                }

                                Rectangle {
                                    id: activeInputDot
                                    anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 10 }
                                    width: 6; height: 6; radius: 3
                                    color: shellRoot.accentColor
                                    visible: parent.modelData.active
                                }

                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    id: inputDeviceMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        if (parent.modelData.active) {
                                            controlCenter.keepOpenAfterAudioDeviceSelection()
                                            controlCenter.closeAudioDeviceMenus()
                                        } else {
                                            controlCenter.setAudioDevice("input", parent.modelData.id)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // --- ПОЛЗУНОК ДИСПЛЕЯ ---
                Rectangle {
                    width: parent.width; height: 74; radius: 24; color: "#161616"
                    HoverHandler {
                        cursorShape: Qt.ArrowCursor
                        onHoveredChanged: controlCenter.holdPanelOpen(hovered)
                        Component.onDestruction: {
                            if (hovered) controlCenter.holdPanelOpen(false)
                        }
                    }

                    Process { id: brightnessSet }
                    Process {
                        id: brightnessGet
                        command: ["brightnessctl", "-m"]
                        onStdoutChanged: {
                            let output = stdout.trim()
                            if (output !== "") {
                                let parts = output.split(",")
                                if (parts.length >= 4) {
                                    let percent = parseFloat(parts[3].replace("%", "")) / 100.0
                                    if (!isNaN(percent) && !displaySlider.pressed) {
                                        displaySlider.value = percent
                                    }
                                }
                            }
                        }
                    }

                    Timer {
                        interval: 1500
                        running: controlCenter.isOpen
                            && !controlCenter.wifiMenuOpen
                            && !controlCenter.bluetoothMenuOpen
                            && !controlCenter.nightModeMenuOpen
                            && !controlCenter.powerMenuOpen
                            && !controlCenter.personalizationMenuOpen
                        repeat: true
                        triggeredOnStart: true
                        onTriggered: if (!brightnessGet.running) brightnessGet.running = true
                    }

                    Item {
                        anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 12; leftMargin: 16; rightMargin: 16 }
                        height: 20
                        Text { text: "Brightness"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize; anchors.left: parent.left }
                    }

                    Slider {
                        id: displaySlider
                        property bool keepsPanelOpen: hovered || pressed
                        hoverEnabled: true
                        anchors { bottom: parent.bottom; bottomMargin: 14; horizontalCenter: parent.horizontalCenter }
                        width: parent.width - 28; height: 22
                        from: 0.01; to: 1.0; value: 0.5
                        onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                        Component.onDestruction: {
                            if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                        }

                        background: Rectangle {
                            x: displaySlider.leftPadding
                            y: displaySlider.topPadding + (displaySlider.availableHeight - height) / 2
                            width: displaySlider.availableWidth; height: 22; radius: 11; color: "#050505"
                            clip: true

                            Rectangle {
                                width: displaySlider.visualPosition * (displaySlider.availableWidth - displaySlider.handle.width)
                                       + displaySlider.handle.width / 2
                                height: parent.height
                                radius: 0
                                topLeftRadius: parent.radius
                                bottomLeftRadius: parent.radius
                                color: shellRoot.accentColor
                            }
                        }
                        handle: Rectangle {
                            x: displaySlider.leftPadding + displaySlider.visualPosition * (displaySlider.availableWidth - width)
                            y: displaySlider.topPadding + (displaySlider.availableHeight - height) / 2
                            width: 22; height: 22; radius: 11; color: "#ffffff"
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                        }
                        onMoved: {
                            let percent = Math.round(value * 100)
                            brightnessSet.command = ["brightnessctl", "set", percent + "%"]
                            brightnessSet.running = true
                        }
                    }
                }

            }

            Column {
                id: personalizationMenu
                anchors.fill: parent
                anchors.margins: 16
                spacing: 8
                visible: controlCenter.personalizationMenuOpen

                Item {
                    width: parent.width; height: 108

                    Rectangle {
                        anchors { top: parent.top; left: parent.left; right: parent.right }
                        height: 52; radius: 26; color: "#161616"

                        Rectangle {
                            anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                            width: 40; height: 40; radius: 20
                            color: shellRoot.accentColor

                            Canvas {
                                anchors.centerIn: parent
                                width: 22; height: 22
                                onPaint: {
                                    let ctx = getContext("2d")
                                    ctx.reset()
                                    ctx.strokeStyle = "#050505"
                                    ctx.lineWidth = 2.4
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.beginPath()
                                    ctx.moveTo(9, 5)
                                    ctx.lineTo(3, 11)
                                    ctx.lineTo(9, 17)
                                    ctx.moveTo(3, 11)
                                    ctx.lineTo(18, 11)
                                    ctx.stroke()
                                }
                            }

                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                anchors.fill: parent
                                onClicked: controlCenter.personalizationMenuOpen = false
                            }
                        }

                        Column {
                            anchors.centerIn: parent
                            spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Palette"; color: "#ffffff"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Path/To/Palette"; color: "#666666"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                            }
                        }
                    }

                    Row {
                        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 6 }
                        spacing: 18

                        Repeater {
                            model: controlCenter.accentPalette
                            Rectangle {
                                required property string modelData
                                width: 40; height: 40; radius: 20
                                color: modelData
                                border.width: shellRoot.accentColor.toLowerCase() === modelData.toLowerCase() ? 2 : 0
                                border.color: "#ffffff"
                                scale: accentMouse.pressed ? 0.88 : 1

                                Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    id: accentMouse
                                    anchors.fill: parent
                                    onClicked: {
                                        controlCenter.customAccentOpen = false
                                        controlCenter.setAccent(parent.modelData)
                                    }
                                }
                            }
                        }

                        Rectangle {
                            width: 40; height: 40; radius: 20; color: "#161616"
                            Text {
                                anchors.centerIn: parent
                                text: "+"; color: "#050505"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 34
                            }
                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                anchors.fill: parent
                                onClicked: controlCenter.toggleCustomAccent()
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: controlCenter.customAccentOpen ? 48 : 0
                    radius: 22; color: "#161616"
                    opacity: controlCenter.customAccentOpen ? 1 : 0
                    visible: height > 0
                    clip: true

                    Behavior on height { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 150 } }

                    HoverHandler {
                        onHoveredChanged: controlCenter.holdPanelOpen(hovered)
                        Component.onDestruction: {
                            if (hovered) controlCenter.holdPanelOpen(false)
                        }
                    }

                    Text {
                        anchors { left: parent.left; leftMargin: 14; verticalCenter: parent.verticalCenter }
                        text: "Custom color"
                        color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }

                    TextField {
                        id: customAccentField
                        anchors { right: applyAccentButton.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        width: 104; height: 30
                        text: controlCenter.customAccentText
                        color: "#ffffff"; placeholderText: "#25d8a3"; placeholderTextColor: "#666666"
                        font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                        horizontalAlignment: TextInput.AlignHCenter
                        selectByMouse: true; padding: 0
                        validator: RegularExpressionValidator { regularExpression: /^#[0-9a-fA-F]{6}$/ }
                        background: Rectangle { radius: 15; color: "#090909"; border.width: 1; border.color: customAccentField.activeFocus ? shellRoot.accentColor : "#303030" }
                        onTextEdited: controlCenter.customAccentText = text
                        onAccepted: controlCenter.setAccent(text)
                    }

                    Rectangle {
                        id: applyAccentButton
                        anchors { right: parent.right; rightMargin: 8; verticalCenter: parent.verticalCenter }
                        width: 58; height: 30; radius: 15
                        color: customAccentField.acceptableInput ? shellRoot.accentColor : "#262626"

                        Text {
                            anchors.centerIn: parent
                            text: "Apply"
                            color: customAccentField.acceptableInput ? "#050505" : "#777777"
                            font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                        }

                        MouseArea {
                            cursorShape: Qt.PointingHandCursor
                            anchors.fill: parent
                            enabled: customAccentField.acceptableInput
                            onClicked: controlCenter.setAccent(customAccentField.text)
                        }
                    }
                }

                Rectangle {
                    width: parent.width; height: 52; radius: 26; color: "#161616"

                    Column {
                        anchors.centerIn: parent
                        width: parent.width - 28
                        spacing: 0
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "Wallpaper"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                        }
                        Text {
                            width: parent.width
                            text: controlCenter.wallpaperDirectory || "Wallpaper directory"
                            color: "#666666"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideMiddle
                        }
                    }
                }

                Item {
                    id: wallpaperCarousel
                    property real position: 0
                    width: parent.width; height: 152
                    clip: true

                    NumberAnimation {
                        id: wallpaperSlide
                        target: wallpaperCarousel
                        property: "position"
                        duration: 380
                        easing.type: Easing.OutCubic
                    }

                    Repeater {
                        model: controlCenter.wallpapers

                        delegate: Rectangle {
                            id: wallpaperCard
                            required property string modelData
                            required property int index
                            readonly property real offset: controlCenter.wallpaperOffset(index, wallpaperCarousel.position)
                            readonly property real distance: Math.abs(offset)
                            readonly property real sizeFactor: Math.max(0, 1 - distance)
                            width: 270
                            height: 152
                            x: (wallpaperCarousel.width - width) / 2
                                + offset * 261
                            y: 0
                            z: 100 - distance
                            visible: x < wallpaperCarousel.width && x + width > 0
                            radius: 22
                            color: "#161616"
                            border.width: controlCenter.selectedWallpaper === modelData ? 2 : 0
                            border.color: shellRoot.accentColor
                            clip: true
                            scale: (0.82 + 0.18 * sizeFactor)
                                * (wallpaperMouse.pressed ? 0.97 : 1)

                            Behavior on border.width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            Behavior on border.color { ColorAnimation { duration: 180 } }

                            ClippingRectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                color: "#161616"

                                Image {
                                    anchors.fill: parent
                                    source: wallpaperCard.modelData
                                    sourceSize.width: 540
                                    sourceSize.height: 304
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    smooth: true
                                }
                            }

                            Rectangle {
                                anchors.fill: parent
                                radius: parent.radius
                                color: "transparent"
                                border.width: controlCenter.selectedWallpaper === parent.modelData ? 2 : 0
                                border.color: shellRoot.accentColor
                                z: 3

                                Behavior on border.width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                            }

                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                id: wallpaperMouse
                                anchors.fill: parent
                                z: 4
                                onClicked: controlCenter.selectWallpaper(parent.index, parent.modelData)
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: controlCenter.wallpapers.length === 0
                        text: "No images in the wallpaper folder"
                        color: "#777777"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                }

                Rectangle {
                    width: parent.width; height: 36; radius: 18; color: "#161616"

                    Text {
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        text: "Smart Palette"
                        color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }

                    Rectangle {
                        anchors { right: parent.right; rightMargin: 4; verticalCenter: parent.verticalCenter }
                        width: 48; height: 28; radius: 14
                        color: controlCenter.smartPaletteEnabled ? shellRoot.accentColor : "#303030"
                        Behavior on color { ColorAnimation { duration: 180 } }

                        Rectangle {
                            width: 24; height: 24; radius: 12; color: "#ffffff"
                            x: controlCenter.smartPaletteEnabled ? parent.width - width - 2 : 2
                            anchors.verticalCenter: parent.verticalCenter
                            Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                        }

                        MouseArea { cursorShape: Qt.PointingHandCursor; anchors.fill: parent; onClicked: controlCenter.toggleSmartPalette() }
                    }
                }

                Rectangle {
                    width: parent.width; height: 36; radius: 18; color: "#161616"
                    Text {
                        anchors { left: parent.left; leftMargin: 12; verticalCenter: parent.verticalCenter }
                        text: "Font"
                        color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                    Text {
                        anchors { right: parent.right; rightMargin: 12; verticalCenter: parent.verticalCenter }
                        text: "SF Pro Rounded"
                        color: "#777777"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                }

            }

            Column {
                id: powerMenu
                anchors.fill: parent
                anchors.margins: 16
                spacing: 8
                visible: controlCenter.powerMenuOpen

                Rectangle {
                    width: parent.width; height: 52; radius: 24; color: "#161616"

                    Rectangle {
                        width: 40; height: 40; radius: 20
                        anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                        color: shellRoot.accentColor

                        Canvas {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = "#050505"
                                ctx.lineWidth = 2.4
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.moveTo(9, 5)
                                ctx.lineTo(3, 11)
                                ctx.lineTo(9, 17)
                                ctx.moveTo(3, 11)
                                ctx.lineTo(18, 11)
                                ctx.stroke()
                            }
                        }

                        MouseArea { cursorShape: Qt.PointingHandCursor; anchors.fill: parent; onClicked: controlCenter.powerMenuOpen = false }
                    }

                    Row {
                        anchors { left: parent.left; right: parent.right; top: parent.top; bottom: parent.bottom; leftMargin: 46; rightMargin: 26 }
                        spacing: 1

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: (parent.width - 2) / 3; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Memory"; color: "#ffffff"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: controlCenter.memoryUsedGiB.toFixed(1) + " Gib"
                                color: "#e8d79a"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: (parent.width - 2) / 3; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Battery"; color: "#ffffff"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: controlCenter.batteryPresent ? controlCenter.batteryPercent + " %" : "—"
                                color: "#777777"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                            }
                        }

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            width: (parent.width - 2) / 3; spacing: 0
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Processor"; color: "#ffffff"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: controlCenter.processorUsage + "%"
                                color: controlCenter.processorUsage >= 85
                                    ? "#ff3048"
                                    : (controlCenter.processorUsage >= 60 ? "#f0c45e" : shellRoot.accentColor)
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width; height: 80; radius: 24; color: "#161616"

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 16 }
                        text: "Power mode"; color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }

                    Row {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 14; rightMargin: 14; bottomMargin: 14 }
                        height: 25; spacing: 4

                        Repeater {
                            model: [
                                { label: "Eco", profile: "power-saver" },
                                { label: "Balance", profile: "balanced" },
                                { label: "Turbo", profile: "performance" }
                            ]

                            Rectangle {
                                required property var modelData
                                readonly property bool selected: controlCenter.powerProfile === modelData.profile
                                width: (parent.width - 8) / 3; height: 25; radius: 13
                                color: selected ? shellRoot.accentColor : "#050505"
                                Behavior on color { ColorAnimation { duration: 160 } }

                                Text {
                                    anchors.centerIn: parent
                                    text: parent.modelData.label
                                    color: parent.selected ? "#050505" : "#8a8a8a"
                                    font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                }

                                MouseArea {
                                    cursorShape: Qt.PointingHandCursor
                                    anchors.fill: parent
                                    onClicked: controlCenter.setPowerProfile(parent.modelData.profile)
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width; height: 106; radius: 24; color: "#161616"

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 13; leftMargin: 16 }
                        text: controlCenter.batteryStatus === "charging"
                            ? "Charging"
                            : (controlCenter.batteryStatus === "full" ? "Fully charged" : "Battery")
                        color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }
                    Text {
                        anchors { top: parent.top; right: parent.right; topMargin: 13; rightMargin: 16 }
                        text: controlCenter.batteryPresent ? controlCenter.batteryPercent + "%" : "—"
                        color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }

                    Rectangle {
                        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 42 }
                        height: 22; radius: 11; color: "#050505"; clip: true
                        Rectangle {
                            width: controlCenter.batteryPresent ? parent.width * Math.min(100, controlCenter.batteryPercent) / 100 : 0
                            height: parent.height; radius: 11; color: shellRoot.accentColor
                            Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        }
                    }

                    Text {
                        anchors { left: parent.left; bottom: parent.bottom; leftMargin: 16; bottomMargin: 12 }
                        text: controlCenter.batteryTimeText()
                        color: "#777777"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                }

                Rectangle {
                    width: parent.width; height: 74; radius: 24; color: "#161616"

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 16 }
                        text: "Battery draining"; color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }
                    Text {
                        anchors { top: parent.top; right: parent.right; topMargin: 12; rightMargin: 16 }
                        text: controlCenter.batteryPresent ? controlCenter.batteryHealth + "%" : "—"
                        color: "#ffffff"
                        font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }

                    Rectangle {
                        anchors { left: parent.left; right: parent.right; bottom: parent.bottom; leftMargin: 14; rightMargin: 14; bottomMargin: 14 }
                        height: 22; radius: 11; color: "#050505"; clip: true
                        Rectangle {
                            width: controlCenter.batteryPresent ? parent.width * Math.min(100, controlCenter.batteryHealth) / 100 : 0
                            height: parent.height; radius: 11; color: shellRoot.accentColor
                            Behavior on width { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                        }
                    }
                }
            }

            Column {
                id: wifiMenu
                anchors.fill: parent; anchors.margins: 16; spacing: 8
                visible: controlCenter.wifiMenuOpen

                Rectangle {
                    width: parent.width; height: 52; radius: 24; color: "#161616"

                    Rectangle {
                        width: 40; height: 40; radius: 20
                        anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                        color: shellRoot.accentColor

                        Canvas {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = "#050505"
                                ctx.lineWidth = 2.4
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.moveTo(9, 5)
                                ctx.lineTo(3, 11)
                                ctx.lineTo(9, 17)
                                ctx.moveTo(3, 11)
                                ctx.lineTo(18, 11)
                                ctx.stroke()
                            }
                        }

                        MouseArea { cursorShape: Qt.PointingHandCursor; anchors.fill: parent; onClicked: controlCenter.wifiMenuOpen = false }
                    }

                    Column {
                        anchors.centerIn: parent; spacing: 2
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: controlCenter.wifiEnabled
                                ? (controlCenter.wifiSsid || controlCenter.wifiConnection || "Not connected")
                                : "Wi-Fi is off"
                            color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                        }
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 22
                            visible: controlCenter.wifiActionMessage === ""
                                && controlCenter.wifiEnabled
                                && (controlCenter.wifiSsid !== "" || controlCenter.wifiConnection !== "")
                            Text { text: "Ip : " + controlCenter.wifiIp; color: "#707070"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize }
                            Text { text: controlCenter.wifiSignal + " %"; color: "#707070"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize }
                            Text { text: controlCenter.wifiBand; color: "#707070"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: controlCenter.wifiActionMessage !== ""
                            width: 300
                            text: controlCenter.wifiActionMessage
                            color: "#707070"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors { top: parent.top; right: parent.right; bottom: parent.bottom }
                        width: parent.width - 52
                        onClicked: controlCenter.wifiMenuOpen = false
                    }
                }

                Rectangle {
                    width: parent.width; height: controlCenter.wifiSavedBlockHeight; radius: 24; color: "#161616"
                    Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                    Text {
                        id: savedNetworksTitle
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 16 }
                        text: "Saved"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }

                    ListView {
                        anchors { top: savedNetworksTitle.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; topMargin: 5; leftMargin: 16; rightMargin: 16; bottomMargin: 10 }
                        clip: true
                        model: controlCenter.wifiAvailableSavedNetworks
                        spacing: 4
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            id: savedNetworkRow
                            required property var modelData
                            readonly property bool activeNetwork: controlCenter.savedNetworkIsActive(modelData.name)
                            readonly property bool connectingNetwork: modelData.name === controlCenter.wifiConnectingSsid
                            width: ListView.view.width; height: 24; radius: 12
                            color: savedNetworkMouse.containsMouse ? "#080808" : "#000000"

                            Text {
                                anchors { left: parent.left; leftMargin: 10; right: savedNetworkStatus.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                text: savedNetworkRow.modelData.name
                                color: "#aaaaaa"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                elide: Text.ElideRight
                            }

                            Text {
                                id: savedNetworkStatus
                                anchors { right: savedNetworkSwitch.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                width: 92
                                text: savedNetworkRow.connectingNetwork ? "Connecting…" : (savedNetworkRow.activeNetwork ? "Connected" : "")
                                color: "#3f3f3f"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 11
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                id: savedNetworkSwitch
                                anchors { right: parent.right; rightMargin: 3; verticalCenter: parent.verticalCenter }
                                width: 36; height: 18; radius: 9
                                color: savedNetworkRow.activeNetwork || savedNetworkRow.connectingNetwork ? shellRoot.accentColor : "#262626"
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }

                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                id: savedNetworkMouse
                                property bool keepsPanelOpen: containsMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                                Component.onDestruction: {
                                    if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                                }
                                onClicked: controlCenter.activateSavedNetwork(savedNetworkRow.modelData.name)
                            }
                        }
                    }

                    Text {
                        anchors { top: savedNetworksTitle.bottom; left: parent.left; topMargin: 8; leftMargin: 16 }
                        visible: controlCenter.wifiAvailableSavedNetworks.length === 0
                        text: "No saved networks nearby"; color: "#777777"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                }

                Rectangle {
                    width: parent.width; height: controlCenter.wifiNewBlockHeight; radius: 24; color: "#161616"
                    Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                    Text {
                        id: newNetworksTitle
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 16 }
                        text: "New connection"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }

                    ListView {
                        anchors { top: newNetworksTitle.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; topMargin: 5; leftMargin: 16; rightMargin: 16; bottomMargin: 10 }
                        clip: true
                        model: controlCenter.wifiNewNetworks
                        spacing: 4
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            id: newNetworkRow
                            required property var modelData
                            readonly property bool connectingNetwork: modelData.ssid === controlCenter.wifiConnectingSsid
                            width: ListView.view.width; height: 24; radius: 12
                            color: newNetworkMouse.containsMouse ? "#080808" : "#000000"

                            Text {
                                anchors { left: parent.left; leftMargin: 10; right: newNetworkStatus.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                text: newNetworkRow.modelData.ssid
                                color: "#aaaaaa"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                elide: Text.ElideRight
                            }

                            Text {
                                id: newNetworkStatus
                                anchors { right: newNetworkSwitch.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                width: 92
                                text: newNetworkRow.connectingNetwork ? "Connecting…" : ""
                                color: "#3f3f3f"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 11
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                id: newNetworkSwitch
                                anchors { right: parent.right; rightMargin: 3; verticalCenter: parent.verticalCenter }
                                width: 36; height: 18; radius: 9
                                color: newNetworkRow.connectingNetwork ? shellRoot.accentColor : "#262626"
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }

                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                id: newNetworkMouse
                                property bool keepsPanelOpen: containsMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                                Component.onDestruction: {
                                    if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                                }
                                onClicked: controlCenter.requestVisibleNetwork(newNetworkRow.modelData)
                            }
                        }
                    }

                    Text {
                        anchors { top: newNetworksTitle.bottom; left: parent.left; topMargin: 8; leftMargin: 16 }
                        visible: controlCenter.wifiNewNetworks.length === 0
                        text: controlCenter.wifiEnabled ? "No new networks" : "Turn Wi-Fi on to scan"
                        color: "#777777"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                }
            }

            Column {
                id: bluetoothMenu
                anchors.fill: parent; anchors.margins: 16; spacing: 8
                visible: controlCenter.bluetoothMenuOpen

                Rectangle {
                    width: parent.width; height: 52; radius: 24; color: "#161616"

                    Rectangle {
                        width: 40; height: 40; radius: 20
                        anchors { left: parent.left; leftMargin: 6; verticalCenter: parent.verticalCenter }
                        color: shellRoot.accentColor

                        Canvas {
                            anchors.centerIn: parent
                            width: 22; height: 22
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = "#050505"
                                ctx.lineWidth = 2.4
                                ctx.lineCap = "round"
                                ctx.lineJoin = "round"
                                ctx.beginPath()
                                ctx.moveTo(9, 5)
                                ctx.lineTo(3, 11)
                                ctx.lineTo(9, 17)
                                ctx.moveTo(3, 11)
                                ctx.lineTo(18, 11)
                                ctx.stroke()
                            }
                        }

                        MouseArea { cursorShape: Qt.PointingHandCursor; anchors.fill: parent; onClicked: controlCenter.bluetoothMenuOpen = false }
                    }

                    Column {
                        anchors.centerIn: parent; spacing: 2
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: controlCenter.bluetoothEnabled
                                ? (controlCenter.bluetoothCurrentName || "Not connected")
                                : "Bluetooth is off"
                            color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                        }
                        Row {
                            anchors.horizontalCenter: parent.horizontalCenter; spacing: 22
                            visible: controlCenter.bluetoothActionMessage === ""
                                && controlCenter.bluetoothCurrentAddress !== ""
                            Text {
                                text: controlCenter.bluetoothCurrentType
                                color: "#707070"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                            }
                            Text {
                                visible: controlCenter.bluetoothCurrentBattery >= 0
                                text: controlCenter.bluetoothCurrentBattery + " %"
                                color: "#707070"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                            }
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            visible: controlCenter.bluetoothActionMessage !== ""
                            width: 280
                            text: controlCenter.bluetoothActionMessage
                            color: "#707070"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                            horizontalAlignment: Text.AlignHCenter
                            elide: Text.ElideRight
                        }
                    }

                    MouseArea {
                        anchors { top: parent.top; right: parent.right; bottom: parent.bottom }
                        width: parent.width - 52
                        onClicked: controlCenter.bluetoothMenuOpen = false
                    }
                }

                Rectangle {
                    width: parent.width; height: controlCenter.bluetoothSavedBlockHeight; radius: 24; color: "#161616"
                    Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                    Text {
                        id: savedBluetoothTitle
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 16 }
                        text: "Saved"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }

                    ListView {
                        anchors { top: savedBluetoothTitle.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; topMargin: 5; leftMargin: 16; rightMargin: 16; bottomMargin: 10 }
                        clip: true
                        model: controlCenter.bluetoothSavedDevices
                        spacing: 4
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            id: savedBluetoothRow
                            required property var modelData
                            readonly property bool connectedDevice: controlCenter.bluetoothIsConnected(modelData.address)
                            readonly property bool pendingDevice: modelData.address === controlCenter.bluetoothPendingAddress
                            width: ListView.view.width; height: 24; radius: 12
                            color: savedBluetoothMouse.containsMouse ? "#080808" : "#000000"

                            Text {
                                anchors { left: parent.left; leftMargin: 10; right: savedBluetoothStatus.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                text: savedBluetoothRow.modelData.name
                                color: "#aaaaaa"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                elide: Text.ElideRight
                            }

                            Text {
                                id: savedBluetoothStatus
                                anchors { right: savedBluetoothSwitch.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                width: 92
                                text: savedBluetoothRow.pendingDevice
                                    ? (savedBluetoothRow.connectedDevice ? "Disconnecting…" : "Connecting…")
                                    : (savedBluetoothRow.connectedDevice ? "Connected" : "")
                                color: "#3f3f3f"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 11
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                id: savedBluetoothSwitch
                                anchors { right: parent.right; rightMargin: 3; verticalCenter: parent.verticalCenter }
                                width: 36; height: 18; radius: 9
                                color: savedBluetoothRow.connectedDevice || savedBluetoothRow.pendingDevice ? shellRoot.accentColor : "#262626"
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }

                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                id: savedBluetoothMouse
                                property bool keepsPanelOpen: containsMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                                Component.onDestruction: {
                                    if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                                }
                                onClicked: controlCenter.activateBluetoothDevice(savedBluetoothRow.modelData)
                            }
                        }
                    }

                    Text {
                        anchors { top: savedBluetoothTitle.bottom; left: parent.left; topMargin: 8; leftMargin: 16 }
                        visible: controlCenter.bluetoothSavedDevices.length === 0
                        text: "No saved devices"
                        color: "#777777"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                }

                Rectangle {
                    width: parent.width; height: controlCenter.bluetoothNewBlockHeight; radius: 24; color: "#161616"
                    Behavior on height { NumberAnimation { duration: 250; easing.type: Easing.OutCubic } }

                    Text {
                        id: newBluetoothTitle
                        anchors { top: parent.top; left: parent.left; topMargin: 12; leftMargin: 16 }
                        text: "New pair"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                    }

                    ListView {
                        anchors { top: newBluetoothTitle.bottom; left: parent.left; right: parent.right; bottom: parent.bottom; topMargin: 5; leftMargin: 16; rightMargin: 16; bottomMargin: 10 }
                        clip: true
                        model: controlCenter.bluetoothNewDevices
                        spacing: 4
                        boundsBehavior: Flickable.StopAtBounds

                        delegate: Rectangle {
                            id: newBluetoothRow
                            required property var modelData
                            readonly property bool pairingDevice: modelData.address === controlCenter.bluetoothPendingAddress
                            width: ListView.view.width; height: 24; radius: 12
                            color: newBluetoothMouse.containsMouse ? "#080808" : "#000000"

                            Text {
                                anchors { left: parent.left; leftMargin: 10; right: newBluetoothStatus.left; rightMargin: 6; verticalCenter: parent.verticalCenter }
                                text: newBluetoothRow.modelData.name
                                color: "#aaaaaa"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                                elide: Text.ElideRight
                            }

                            Text {
                                id: newBluetoothStatus
                                anchors { right: newBluetoothSwitch.left; rightMargin: 8; verticalCenter: parent.verticalCenter }
                                width: 92
                                text: newBluetoothRow.pairingDevice ? "Pairing…" : ""
                                color: "#3f3f3f"
                                font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 11
                                horizontalAlignment: Text.AlignHCenter
                                elide: Text.ElideRight
                            }

                            Rectangle {
                                id: newBluetoothSwitch
                                anchors { right: parent.right; rightMargin: 3; verticalCenter: parent.verticalCenter }
                                width: 36; height: 18; radius: 9
                                color: newBluetoothRow.pairingDevice ? shellRoot.accentColor : "#262626"
                                Behavior on color { ColorAnimation { duration: 180 } }
                            }

                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                id: newBluetoothMouse
                                property bool keepsPanelOpen: containsMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                                Component.onDestruction: {
                                    if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                                }
                                onClicked: controlCenter.pairBluetoothDevice(newBluetoothRow.modelData)
                            }
                        }
                    }

                    Text {
                        anchors { top: newBluetoothTitle.bottom; left: parent.left; topMargin: 8; leftMargin: 16 }
                        visible: controlCenter.bluetoothNewDevices.length === 0
                        text: controlCenter.bluetoothEnabled ? "No new devices" : "Turn Bluetooth on to scan"
                        color: "#777777"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                    }
                }
            }

            Rectangle {
                id: nightModeMenu
                anchors.fill: parent
                anchors.margins: 8
                visible: controlCenter.nightModeMenuOpen
                color: "#000000"
                radius: 28

                MouseArea {
                    anchors.fill: parent
                    onClicked: controlCenter.nightModeMenuOpen = false
                }

                Text {
                    anchors { top: parent.top; horizontalCenter: parent.horizontalCenter; topMargin: 13 }
                    text: "Warmness: " + controlCenter.nightModeTemperature
                    color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 16
                }

                Slider {
                    id: nightWarmthSlider
                    property bool keepsPanelOpen: hovered || pressed
                    hoverEnabled: true
                    anchors { top: parent.top; left: parent.left; right: parent.right; topMargin: 46; leftMargin: 6; rightMargin: 6 }
                    height: 44
                    from: 3000; to: 6500; stepSize: 100
                    value: controlCenter.nightModeTemperature
                    onKeepsPanelOpenChanged: controlCenter.holdPanelOpen(keepsPanelOpen)
                    Component.onDestruction: {
                        if (keepsPanelOpen) controlCenter.holdPanelOpen(false)
                    }

                    background: Rectangle {
                        x: nightWarmthSlider.leftPadding
                        y: nightWarmthSlider.topPadding + nightWarmthSlider.availableHeight / 2 - height / 2
                        width: nightWarmthSlider.availableWidth; height: 44; radius: 22
                        color: "#161616"
                        clip: true

                        Rectangle {
                            width: nightWarmthSlider.visualPosition * (nightWarmthSlider.availableWidth - nightWarmthSlider.handle.width)
                                   + nightWarmthSlider.handle.width / 2
                            height: parent.height
                            radius: 0
                            topLeftRadius: parent.radius
                            bottomLeftRadius: parent.radius
                            color: shellRoot.accentColor
                        }
                    }

                    handle: Rectangle {
                        x: nightWarmthSlider.leftPadding + nightWarmthSlider.visualPosition * (nightWarmthSlider.availableWidth - width)
                        y: nightWarmthSlider.topPadding + nightWarmthSlider.availableHeight / 2 - height / 2
                        width: 44; height: 44; radius: 22; color: "#ffffff"
                        HoverHandler { cursorShape: Qt.PointingHandCursor }
                    }

                    onMoved: controlCenter.nightModeTemperature = Math.round(value / 100) * 100
                    onPressedChanged: {
                        if (!pressed) {
                            controlCenter.saveNightModeSettings()
                            controlCenter.restartNightMode()
                        }
                    }
                }

                Rectangle {
                    id: nightScheduleSwitch
                    anchors { left: parent.left; bottom: parent.bottom; leftMargin: 14; bottomMargin: 13 }
                    width: 76; height: 40; radius: 20
                    color: controlCenter.nightModeScheduleEnabled ? shellRoot.accentColor : "#262626"
                    Behavior on color { ColorAnimation { duration: 180 } }

                    Rectangle {
                        width: 40; height: 40; radius: 20; color: "#ffffff"
                        x: controlCenter.nightModeScheduleEnabled ? parent.width - width : 0
                        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                    }

                    MouseArea {
                        cursorShape: Qt.PointingHandCursor
                        anchors.fill: parent
                        onClicked: controlCenter.setNightModeSchedule(!controlCenter.nightModeScheduleEnabled)
                    }
                }

                Column {
                    anchors { left: nightScheduleSwitch.right; leftMargin: 52; verticalCenter: nightScheduleSwitch.verticalCenter }
                    spacing: 1
                    Text { text: "From"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 15 }
                    Text { text: "To"; color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 15 }
                }

                Column {
                    anchors { right: parent.right; rightMargin: 12; verticalCenter: nightScheduleSwitch.verticalCenter }
                    spacing: 1

                    TextField {
                        id: nightFromField
                        width: 88; height: 22
                        text: controlCenter.nightModeFrom.slice(0, 5)
                        color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 15
                        horizontalAlignment: TextInput.AlignHCenter
                        selectByMouse: true; padding: 0
                        inputMethodHints: Qt.ImhPreferNumbers
                        validator: RegularExpressionValidator { regularExpression: /^([01][0-9]|2[0-3]):[0-5][0-9]$/ }
                        background: Rectangle {
                            color: "#161616"; radius: 8
                            border.width: 1
                            border.color: nightFromField.activeFocus ? shellRoot.accentColor : "#303030"
                        }
                        onEditingFinished: {
                            if (acceptableInput) {
                                controlCenter.nightModeFrom = text + ":00"
                                controlCenter.saveNightModeSettings()
                                controlCenter.restartNightMode()
                            } else {
                                text = controlCenter.nightModeFrom.slice(0, 5)
                            }
                        }
                    }

                    TextField {
                        id: nightToField
                        width: 88; height: 22
                        text: controlCenter.nightModeTo.slice(0, 5)
                        color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: 15
                        horizontalAlignment: TextInput.AlignHCenter
                        selectByMouse: true; padding: 0
                        inputMethodHints: Qt.ImhPreferNumbers
                        validator: RegularExpressionValidator { regularExpression: /^([01][0-9]|2[0-3]):[0-5][0-9]$/ }
                        background: Rectangle {
                            color: "#161616"; radius: 8
                            border.width: 1
                            border.color: nightToField.activeFocus ? shellRoot.accentColor : "#303030"
                        }
                        onEditingFinished: {
                            if (acceptableInput) {
                                controlCenter.nightModeTo = text + ":00"
                                controlCenter.saveNightModeSettings()
                                controlCenter.restartNightMode()
                            } else {
                                text = controlCenter.nightModeTo.slice(0, 5)
                            }
                        }
                    }
                }

                Text {
                    anchors { bottom: parent.bottom; horizontalCenter: parent.horizontalCenter; bottomMargin: 2 }
                    visible: controlCenter.nightModeError !== ""
                    width: parent.width - 24
                    text: controlCenter.nightModeError
                    color: "#777777"; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize
                    horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                }
            }

            Rectangle {
                anchors.fill: parent
                visible: controlCenter.wifiPasswordPromptOpen
                color: "#cc000000"
                radius: controlWidget.radius
                z: 20

                onVisibleChanged: {
                    if (visible) {
                        controlCloseDelay.stop()
                        Qt.callLater(() => {
                            if (!controlCenter.wifiPasswordPromptOpen) return
                            let window = mainWindow.contentItem.window
                            if (window) window.requestActivate()
                            wifiPasswordFocusDelay.restart()
                        })
                    } else {
                        wifiPasswordFocusDelay.stop()
                        wifiPasswordField.text = ""
                        if (!controlHoverHandler.hovered)
                            controlCloseDelay.restart()
                    }
                }

                Timer {
                    id: wifiPasswordFocusDelay
                    interval: 50
                    onTriggered: {
                        if (controlCenter.wifiPasswordPromptOpen)
                            wifiPasswordField.forceActiveFocus(Qt.MouseFocusReason)
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    onClicked: controlCenter.wifiPasswordPromptOpen = false
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: 304; height: 132; radius: 24; color: "#161616"
                    border.width: 1; border.color: "#303030"

                    MouseArea { anchors.fill: parent }

                    Text {
                        anchors { top: parent.top; left: parent.left; topMargin: 14; leftMargin: 16 }
                        width: parent.width - 32
                        text: "Connect to " + controlCenter.wifiPendingSsid
                        color: "#ffffff"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.primaryFontSize
                        elide: Text.ElideRight
                    }

                    TextField {
                        id: wifiPasswordField
                        anchors { left: parent.left; right: parent.right; top: parent.top; leftMargin: 16; rightMargin: 16; topMargin: 42 }
                        height: 34
                        placeholderText: "Password"
                        echoMode: TextInput.Password
                        color: "#ffffff"
                        placeholderTextColor: "#666666"
                        font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.secondaryFontSize
                        enabled: controlCenter.wifiPasswordPromptOpen
                        focus: controlCenter.wifiPasswordPromptOpen
                        selectByMouse: true
                        leftPadding: 12; rightPadding: 12
                        background: Rectangle { radius: 17; color: "#090909"; border.width: 1; border.color: wifiPasswordField.activeFocus ? shellRoot.accentColor : "#303030" }
                        onAccepted: controlCenter.connectVisibleNetwork(controlCenter.wifiPendingSsid, text)
                        Keys.onEscapePressed: controlCenter.wifiPasswordPromptOpen = false
                    }

                    Row {
                        anchors { right: parent.right; bottom: parent.bottom; rightMargin: 16; bottomMargin: 12 }
                        spacing: 8

                        Rectangle {
                            width: 58; height: 26; radius: 13; color: "transparent"
                            border.width: 1; border.color: "#404040"
                            Text { anchors.centerIn: parent; text: "Cancel"; color: "#aaaaaa"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize }
                            MouseArea { cursorShape: Qt.PointingHandCursor; anchors.fill: parent; onClicked: controlCenter.wifiPasswordPromptOpen = false }
                        }

                        Rectangle {
                            width: 66; height: 26; radius: 13; color: shellRoot.accentColor
                            Text { anchors.centerIn: parent; text: "Connect"; color: "#050505"; font.bold: true; font.family: "SF Pro Rounded"; font.pixelSize: controlCenter.smallFontSize }
                            MouseArea {
                                cursorShape: Qt.PointingHandCursor
                                anchors.fill: parent
                                onClicked: controlCenter.connectVisibleNetwork(controlCenter.wifiPendingSsid, wifiPasswordField.text)
                            }
                        }
                    }
                }
            }
        }
    }
    }
}
