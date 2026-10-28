//@ pragma ShellId quickshell-greeter

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd

ShellRoot {
    id: greeterRoot

    property string userName: "lexa"
    property string passwordText: ""
    property string pendingPassword: ""
    property string statusText: Greetd.available
        ? "Touch the fingerprint sensor or enter your password"
        : "Preview mode — authentication is disabled"
    property bool statusIsError: false
    property bool authenticating: false
    property bool passwordSubmitting: false
    property bool responsePending: false
    property bool restartWithPassword: false
    property int resetGeneration: 0
    property int exitAnimationGeneration: 0
    property int restoreAnimationGeneration: 0
    property bool launching: false

    function startFingerprintAuthentication() {
        if (!Greetd.available || Greetd.state !== GreetdState.Inactive) return

        pendingPassword = ""
        responsePending = false
        passwordSubmitting = false
        authenticating = true
        statusIsError = false
        statusText = "Touch the fingerprint sensor or enter your password"
        Greetd.createSession(userName)
    }

    function startPasswordAuthentication() {
        if (!Greetd.available) return
        if (Greetd.state !== GreetdState.Inactive) {
            restartWithPassword = true
            Greetd.cancelSession()
            return
        }

        restartWithPassword = false
        responsePending = false
        authenticating = true
        passwordSubmitting = true
        statusIsError = false
        statusText = "Checking password…"
        Greetd.createSession(userName)
    }

    function submit() {
        if (!Greetd.available) {
            statusIsError = false
            statusText = "Preview mode — authentication is disabled"
            return
        }
        if (passwordSubmitting || userName === "" || passwordText === "") return

        pendingPassword = passwordText
        passwordText = ""
        passwordSubmitting = true
        statusIsError = false
        statusText = "Checking password…"

        if (responsePending) {
            responsePending = false
            Greetd.respond(pendingPassword)
            pendingPassword = ""
            return
        }

        let markerPath = Quickshell.env("QS_GREETER_PASSWORD_MODE_FILE")
        if (!markerPath) {
            resetAuthentication("Password mode is not configured", true)
            return
        }
        passwordModeMarker.command = ["touch", markerPath]
        passwordModeMarker.running = true
    }

    function resetAuthentication(message, error) {
        pendingPassword = ""
        passwordText = ""
        authenticating = false
        passwordSubmitting = false
        responsePending = false
        statusIsError = error
        statusText = message
        resetGeneration++
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    FileView {
        path: Quickshell.shellPath("default-user")
        blockLoading: true
        printErrors: false
        onLoaded: {
            let value = text.trim()
            if (value !== "") greeterRoot.userName = value
        }
    }

    Connections {
        target: Greetd

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (message !== "") {
                greeterRoot.statusText = message
                greeterRoot.statusIsError = error
            }
            if (responseRequired) {
                greeterRoot.responsePending = true
                if (greeterRoot.pendingPassword !== "") {
                    greeterRoot.responsePending = false
                    Greetd.respond(greeterRoot.pendingPassword)
                    greeterRoot.pendingPassword = ""
                }
            }
        }

        function onAuthFailure(message) {
            if (greeterRoot.restartWithPassword) {
                passwordSessionRestart.restart()
                return
            }
            let passwordFailed = greeterRoot.passwordSubmitting
            greeterRoot.resetAuthentication(
                passwordFailed
                    ? (message !== "" ? message : "Incorrect password")
                    : "Fingerprint was not recognized — try again",
                passwordFailed)
            fingerprintRetry.restart()
        }

        function onReadyToLaunch() {
            if (greeterRoot.launching) return
            greeterRoot.responsePending = false
            greeterRoot.restartWithPassword = false
            greeterRoot.statusIsError = false
            greeterRoot.statusText = "Starting Niri…"
            greeterRoot.launching = true
            greeterRoot.exitAnimationGeneration++
            launchAfterAnimation.restart()
        }

        function onError(error) {
            let wasLaunching = greeterRoot.launching
            greeterRoot.launching = false
            launchAfterAnimation.stop()
            if (wasLaunching)
                greeterRoot.restoreAnimationGeneration++
            if (greeterRoot.restartWithPassword) {
                passwordSessionRestart.restart()
                return
            }
            greeterRoot.resetAuthentication(
                error !== "" ? error : "greetd connection error", true)
        }

        function onStateChanged() {
            if (Greetd.state === GreetdState.Inactive
                    && greeterRoot.restartWithPassword)
                passwordSessionRestart.restart()
        }
    }

    Timer {
        id: launchAfterAnimation
        interval: 480
        onTriggered: {
            Greetd.launch(
                ["/usr/bin/niri-session"],
                [
                    "XDG_SESSION_TYPE=wayland",
                    "XDG_CURRENT_DESKTOP=niri",
                    "XDG_SESSION_DESKTOP=niri"
                ]
            )
        }
    }

    Timer {
        id: initialFingerprintStart
        interval: 150
        repeat: true
        running: true
        onTriggered: {
            if (Greetd.available && Greetd.state === GreetdState.Inactive) {
                stop()
                greeterRoot.startFingerprintAuthentication()
            }
        }
    }

    Timer {
        id: passwordSessionRestart
        interval: 80
        onTriggered: {
            if (Greetd.state === GreetdState.Inactive)
                greeterRoot.startPasswordAuthentication()
            else
                restart()
        }
    }

    Timer {
        id: fingerprintRetry
        interval: 700
        onTriggered: {
            if (Greetd.state === GreetdState.Inactive)
                greeterRoot.startFingerprintAuthentication()
            else
                restart()
        }
    }

    Process {
        id: passwordModeMarker
        onExited: (exitCode, exitStatus) => {
            if (exitCode !== 0) {
                greeterRoot.resetAuthentication(
                    "Could not switch to password authentication", true)
                return
            }
            greeterRoot.startPasswordAuthentication()
        }
    }

    Process { id: powerCommand }

    FloatingWindow {
        id: greeterWindow
        visible: true
        implicitWidth: 1920
        implicitHeight: 1080
        color: "#030504"
        title: "Quickshell Greeter"

        Shortcut {
            sequence: "Escape"
            enabled: !Greetd.available
            onActivated: Qt.quit()
        }

        Rectangle {
            anchors.fill: parent
            color: "#030504"
            focus: true

            Canvas {
                id: backgroundCanvas
                anchors.fill: parent
                opacity: 0

                NumberAnimation on opacity {
                    from: 0
                    to: 1
                    duration: 700
                    easing.type: Easing.OutCubic
                }

                onWidthChanged: requestPaint()
                onHeightChanged: requestPaint()

                onPaint: {
                    let ctx = getContext("2d")
                    let w = width
                    let h = height
                    ctx.reset()

                    ctx.fillStyle = "#030504"
                    ctx.fillRect(0, 0, w, h)

                    let topGlow = ctx.createLinearGradient(0, 0, w * 0.42, h * 0.45)
                    topGlow.addColorStop(0, "#020707")
                    topGlow.addColorStop(0.48, "#003a32")
                    topGlow.addColorStop(0.78, "#006d59")
                    topGlow.addColorStop(1, "#00b894")
                    ctx.beginPath()
                    ctx.moveTo(0, 0)
                    ctx.lineTo(w * 0.39, 0)
                    ctx.bezierCurveTo(w * 0.35, h * 0.20, w * 0.20, h * 0.25, 0, h * 0.53)
                    ctx.closePath()
                    ctx.fillStyle = topGlow
                    ctx.fill()
                    ctx.strokeStyle = "#00b894"
                    ctx.lineWidth = 1.5
                    ctx.stroke()

                    let upperRibbon = ctx.createLinearGradient(0, h * 0.28, w, h * 0.62)
                    upperRibbon.addColorStop(0, "#020303")
                    upperRibbon.addColorStop(0.52, "#050807")
                    upperRibbon.addColorStop(1, "#002b25")
                    ctx.beginPath()
                    ctx.moveTo(-w * 0.03, h * 0.52)
                    ctx.bezierCurveTo(w * 0.27, h * 0.20, w * 0.43, h * 0.47, w * 0.77, h * 0.24)
                    ctx.bezierCurveTo(w * 0.89, h * 0.16, w * 0.97, h * 0.14, w * 1.04, h * 0.16)
                    ctx.lineTo(w * 1.04, h * 0.30)
                    ctx.bezierCurveTo(w * 0.84, h * 0.27, w * 0.75, h * 0.48, w * 0.58, h * 0.67)
                    ctx.bezierCurveTo(w * 0.31, h * 0.96, w * 0.09, h * 0.77, -w * 0.03, h * 0.64)
                    ctx.closePath()
                    ctx.fillStyle = upperRibbon
                    ctx.fill()
                    ctx.strokeStyle = "#007f6d"
                    ctx.lineWidth = 1.2
                    ctx.stroke()

                    let lowerRibbon = ctx.createLinearGradient(w * 0.50, h, w, h * 0.46)
                    lowerRibbon.addColorStop(0, "#080909")
                    lowerRibbon.addColorStop(0.62, "#061411")
                    lowerRibbon.addColorStop(1, "#00634f")
                    ctx.beginPath()
                    ctx.moveTo(w * 0.55, h * 1.08)
                    ctx.bezierCurveTo(w * 0.65, h * 0.70, w * 0.72, h * 0.75, w * 0.83, h * 0.57)
                    ctx.bezierCurveTo(w * 0.90, h * 0.46, w * 0.99, h * 0.48, w * 1.06, h * 0.52)
                    ctx.lineTo(w * 1.06, h * 1.08)
                    ctx.closePath()
                    ctx.fillStyle = lowerRibbon
                    ctx.fill()
                    ctx.strokeStyle = "#009e83"
                    ctx.lineWidth = 1.4
                    ctx.stroke()
                }
            }

            Column {
                id: clockBlock
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: parent.top
                    topMargin: parent.height * 0.155
                }
                spacing: 4
                opacity: 0
                transform: Translate { id: clockEnterOffset; y: -18 }

                SequentialAnimation {
                    running: true
                    PauseAnimation { duration: 90 }
                    ParallelAnimation {
                        NumberAnimation {
                            target: clockBlock
                            property: "opacity"
                            from: 0
                            to: 1
                            duration: 280
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: clockEnterOffset
                            property: "y"
                            from: -18
                            to: 0
                            duration: 420
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatTime(clock.date, "HH:mm")
                    color: "#ffffff"
                    font.family: "SF Pro Rounded"
                    font.weight: Font.Bold
                    font.pixelSize: Math.min(112, Math.max(74, greeterWindow.height * 0.104))
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Qt.formatDate(clock.date, "dddd, d MMMM")
                    color: "#8d8d8d"
                    font.family: "SF Pro Rounded"
                    font.pixelSize: Math.min(20, Math.max(15, greeterWindow.height * 0.018))
                }
            }

            Column {
                id: loginCard
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    top: parent.top
                    topMargin: parent.height * 0.405
                }
                width: Math.min(380, parent.width - 48)
                spacing: 10
                opacity: 0
                scale: 0.94

                SequentialAnimation {
                    running: true
                    PauseAnimation { duration: 190 }
                    ParallelAnimation {
                        NumberAnimation {
                            target: loginCard
                            property: "opacity"
                            from: 0
                            to: 1
                            duration: 300
                            easing.type: Easing.OutCubic
                        }
                        NumberAnimation {
                            target: loginCard
                            property: "scale"
                            from: 0.94
                            to: 1
                            duration: 480
                            easing.type: Easing.OutBack
                        }
                    }
                }

                Rectangle {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Math.min(116, greeterWindow.height * 0.108)
                    height: width
                    radius: width / 2
                    color: "#28a98a"
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: greeterRoot.userName === "lexa" ? "Lexa" : greeterRoot.userName
                    color: "#ffffff"
                    font.family: "SF Pro Rounded"
                    font.weight: Font.Bold
                    font.pixelSize: 24
                }

                Item { width: 1; height: 2 }

                Rectangle {
                    width: parent.width
                    height: 56
                    radius: height / 2
                    color: "#171717"
                    border.width: 2
                    border.color: greeterRoot.statusIsError ? "#ff4d5e" : "#00d6a4"

                    Behavior on border.color { ColorAnimation { duration: 160 } }

                    TextInput {
                        id: passwordInput
                        anchors {
                            left: parent.left
                            right: loginButton.left
                            top: parent.top
                            bottom: parent.bottom
                            leftMargin: 21
                            rightMargin: 10
                        }
                        text: greeterRoot.passwordText
                        onTextEdited: greeterRoot.passwordText = text
                        color: "transparent"
                        selectionColor: "transparent"
                        selectedTextColor: "transparent"
                        font.family: "SF Pro Rounded"
                        font.pixelSize: 15
                        echoMode: TextInput.Password
                        passwordCharacter: "•"
                        verticalAlignment: TextInput.AlignVCenter
                        enabled: !greeterRoot.passwordSubmitting
                        focus: true
                        cursorDelegate: Item { width: 0; height: 0 }

                        Keys.onPressed: event => {
                            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                greeterRoot.submit()
                                event.accepted = true
                            }
                        }

                        Text {
                            anchors.fill: parent
                            verticalAlignment: Text.AlignVCenter
                            text: greeterRoot.passwordSubmitting ? "Checking password…" : "Password"
                            color: "#666666"
                            font: passwordInput.font
                            visible: passwordInput.text.length === 0
                        }
                    }

                    Item {
                        id: passwordDotsArea
                        anchors {
                            left: parent.left
                            right: loginButton.left
                            top: parent.top
                            bottom: parent.bottom
                            leftMargin: 21
                            rightMargin: 10
                        }
                        clip: true

                        function syncDots() {
                            const wantedCount = greeterRoot.passwordText.length
                            while (passwordDotsModel.count < wantedCount)
                                passwordDotsModel.append({})
                            while (passwordDotsModel.count > wantedCount)
                                passwordDotsModel.remove(passwordDotsModel.count - 1)
                        }

                        ListModel {
                            id: passwordDotsModel
                        }

                        ListView {
                            anchors {
                                left: parent.left
                                right: parent.right
                                verticalCenter: parent.verticalCenter
                            }
                            height: 14
                            orientation: ListView.Horizontal
                            spacing: 8
                            interactive: false
                            model: passwordDotsModel

                            delegate: Rectangle {
                                required property int index
                                width: 14
                                height: 14
                                radius: 7
                                color: "#f2f2f2"
                            }

                            add: Transition {
                                ParallelAnimation {
                                    NumberAnimation {
                                        property: "opacity"
                                        from: 0
                                        to: 1
                                        duration: 90
                                        easing.type: Easing.OutCubic
                                    }
                                    NumberAnimation {
                                        property: "scale"
                                        from: 0.25
                                        to: 1
                                        duration: 180
                                        easing.type: Easing.OutBack
                                    }
                                }
                            }

                            remove: Transition {
                                ParallelAnimation {
                                    NumberAnimation {
                                        property: "opacity"
                                        from: 1
                                        to: 0
                                        duration: 100
                                        easing.type: Easing.InCubic
                                    }
                                    NumberAnimation {
                                        property: "scale"
                                        from: 1
                                        to: 0.25
                                        duration: 130
                                        easing.type: Easing.InCubic
                                    }
                                }
                            }
                        }

                        Connections {
                            target: greeterRoot
                            function onPasswordTextChanged() { passwordDotsArea.syncDots() }
                        }

                        Component.onCompleted: syncDots()
                    }

                    Rectangle {
                        id: loginButton
                        anchors {
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                            rightMargin: 5
                        }
                        width: 46
                        height: 46
                        radius: 23
                        color: loginMouse.containsMouse ? "#393939" : "#2b2b2b"

                        Text {
                            anchors.centerIn: parent
                            text: "→"
                            color: greeterRoot.passwordText.length > 0 ? "#c5c5c5" : "#666666"
                            font.family: "SF Pro Rounded"
                            font.weight: Font.Bold
                            font.pixelSize: 23
                        }

                        MouseArea {
                            id: loginMouse
                            anchors.fill: parent
                            enabled: greeterRoot.passwordText.length > 0
                                && !greeterRoot.passwordSubmitting
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: greeterRoot.submit()
                        }
                    }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: parent.width
                    text: greeterRoot.statusText
                    color: greeterRoot.statusIsError ? "#ff6674" : "#777777"
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    font.family: "SF Pro Rounded"
                    font.pixelSize: 12
                    opacity: greeterRoot.statusIsError || greeterRoot.authenticating
                        || !Greetd.available ? 1 : 0

                    Behavior on opacity { NumberAnimation { duration: 160 } }
                }
            }

            Row {
                id: powerActions
                anchors {
                    horizontalCenter: parent.horizontalCenter
                    bottom: parent.bottom
                    bottomMargin: Math.max(28, parent.height * 0.045)
                }
                spacing: 28
                opacity: 0

                SequentialAnimation {
                    running: true
                    PauseAnimation { duration: 350 }
                    NumberAnimation {
                        target: powerActions
                        property: "opacity"
                        from: 0
                        to: Greetd.available ? 1 : 0.55
                        duration: 260
                        easing.type: Easing.OutCubic
                    }
                }

                Repeater {
                    model: [
                        { label: "Restart", action: "reboot" },
                        { label: "Power off", action: "poweroff" }
                    ]

                    Rectangle {
                        required property var modelData
                        width: 138
                        height: 48
                        radius: 24
                        color: powerMouse.containsMouse ? "#242424" : "#171717"

                        Behavior on color { ColorAnimation { duration: 130 } }

                        Text {
                            anchors.centerIn: parent
                            text: parent.modelData.label
                            color: "#9a9a9a"
                            font.family: "SF Pro Rounded"
                            font.weight: Font.Bold
                            font.pixelSize: 15
                        }

                        MouseArea {
                            id: powerMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: Greetd.available && !powerCommand.running
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                powerCommand.command = ["systemctl", parent.modelData.action]
                                powerCommand.running = true
                            }
                        }
                    }
                }
            }

            Connections {
                target: greeterRoot
                function onResetGenerationChanged() {
                    passwordInput.forceActiveFocus(Qt.OtherFocusReason)
                }
                function onExitAnimationGenerationChanged() {
                    greeterExitAnimation.restart()
                }
                function onRestoreAnimationGenerationChanged() {
                    greeterRestoreAnimation.restart()
                }
            }

            ParallelAnimation {
                id: greeterExitAnimation

                ParallelAnimation {
                    NumberAnimation {
                        target: clockBlock
                        property: "opacity"
                        to: 0
                        duration: 190
                        easing.type: Easing.InCubic
                    }
                    NumberAnimation {
                        target: clockEnterOffset
                        property: "y"
                        to: -14
                        duration: 260
                        easing.type: Easing.InCubic
                    }
                    NumberAnimation {
                        target: loginCard
                        property: "opacity"
                        to: 0
                        duration: 210
                        easing.type: Easing.InCubic
                    }
                    NumberAnimation {
                        target: loginCard
                        property: "scale"
                        to: 0.94
                        duration: 280
                        easing.type: Easing.InCubic
                    }
                    NumberAnimation {
                        target: powerActions
                        property: "opacity"
                        to: 0
                        duration: 150
                    }
                }

                SequentialAnimation {
                    PauseAnimation { duration: 110 }
                    NumberAnimation {
                        target: backgroundCanvas
                        property: "opacity"
                        to: 0
                        duration: 330
                        easing.type: Easing.InOutCubic
                    }
                }
            }

            ParallelAnimation {
                id: greeterRestoreAnimation

                NumberAnimation {
                    target: backgroundCanvas
                    property: "opacity"
                    to: 1
                    duration: 360
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: clockBlock
                    property: "opacity"
                    to: 1
                    duration: 260
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: clockEnterOffset
                    property: "y"
                    to: 0
                    duration: 340
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: loginCard
                    property: "opacity"
                    to: 1
                    duration: 280
                    easing.type: Easing.OutCubic
                }
                NumberAnimation {
                    target: loginCard
                    property: "scale"
                    to: 1
                    duration: 400
                    easing.type: Easing.OutBack
                }
                NumberAnimation {
                    target: powerActions
                    property: "opacity"
                    to: Greetd.available ? 1 : 0.55
                    duration: 260
                    easing.type: Easing.OutCubic
                }
            }

            Component.onCompleted: passwordInput.forceActiveFocus(Qt.OtherFocusReason)
        }
    }
}
