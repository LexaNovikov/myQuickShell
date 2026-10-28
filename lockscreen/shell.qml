//@ pragma ShellId quickshell-lockscreen

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland

ShellRoot {
    id: lockRoot

    property string userName: ""
    property string passwordText: ""
    property string pendingPassword: ""
    property string statusText: "Touch the fingerprint sensor or enter your password"
    property bool statusIsError: false
    property bool passwordBusy: false
    property bool fingerprintUsable: true
    property bool suspendRequested: false
    property bool unlocking: false
    property int authenticationGeneration: 0
    property int exitAnimationGeneration: 0

    function handleRequest(contents) {
        let lines = (contents || "").trim().split("\n")
        let action = lines.length > 0 ? lines[0].trim() : ""
        let requestedUser = lines.length > 1 ? lines[1].trim() : ""

        if (requestedUser !== "" && !passwordPam.active && !fingerprintPam.active)
            userName = requestedUser

        if (action === "lock-and-suspend")
            suspendRequested = true

        if (sessionLock.secure && (action === "lock" || action === "lock-and-suspend"))
            finishLockRequest()
    }

    function finishLockRequest() {
        lockRequestFile.setText("")
        if (suspendRequested && !suspendProcess.running) {
            suspendRequested = false
            suspendProcess.running = true
        }
    }

    function startFingerprintAuthentication() {
        if (unlocking || fingerprintPam.active || !fingerprintUsable) return
        statusIsError = false
        statusText = "Touch the fingerprint sensor or enter your password"
        if (!fingerprintPam.start()) {
            fingerprintUsable = false
            statusText = "Fingerprint is unavailable — enter your password"
        }
    }

    function probeFingerprintAuthentication() {
        if (unlocking || fingerprintProbe.running || !fingerprintUsable) return
        fingerprintProbe.command = ["fprintd-list", userName]
        fingerprintProbe.running = true
    }

    function submitPassword() {
        if (unlocking || passwordBusy || passwordText.length === 0) return
        pendingPassword = passwordText
        passwordBusy = true
        statusIsError = false
        statusText = "Checking password…"
        if (!passwordPam.start()) {
            pendingPassword = ""
            passwordText = ""
            passwordBusy = false
            statusIsError = true
            statusText = "Could not start password authentication"
            authenticationGeneration++
        }
    }

    function authenticationSucceeded() {
        if (unlocking) return
        unlocking = true
        statusIsError = false
        statusText = "Unlocked"
        pendingPassword = ""
        passwordText = ""
        if (passwordPam.active) passwordPam.abort()
        if (fingerprintPam.active) fingerprintPam.abort()
        exitAnimationGeneration++
        unlockAfterAnimation.restart()
    }

    SystemClock {
        id: clock
        precision: SystemClock.Seconds
    }

    FileView {
        id: lockRequestFile
        path: Quickshell.shellPath(".request")
        blockLoading: true
        atomicWrites: true
        watchChanges: true
        printErrors: false
        onLoaded: lockRoot.handleRequest(text)
        onTextChanged: lockRoot.handleRequest(text)
    }

    PamContext {
        id: passwordPam
        configDirectory: "/etc/pam.d"
        config: "system-auth"
        user: lockRoot.userName

        onResponseRequiredChanged: {
            if (!responseRequired) return
            respond(lockRoot.pendingPassword)
            lockRoot.pendingPassword = ""
            lockRoot.passwordText = ""
        }

        onCompleted: result => {
            lockRoot.passwordBusy = false
            lockRoot.pendingPassword = ""
            lockRoot.passwordText = ""
            if (result === PamResult.Success) {
                lockRoot.authenticationSucceeded()
            } else if (!lockRoot.unlocking) {
                lockRoot.statusIsError = true
                lockRoot.statusText = result === PamResult.MaxTries
                    ? "Too many attempts — try again in a moment"
                    : "Incorrect password"
                lockRoot.authenticationGeneration++
            }
        }

        onError: {
            lockRoot.passwordBusy = false
            lockRoot.pendingPassword = ""
            lockRoot.passwordText = ""
            if (!lockRoot.unlocking) {
                lockRoot.statusIsError = true
                lockRoot.statusText = "Password authentication is unavailable"
                lockRoot.authenticationGeneration++
            }
        }
    }

    PamContext {
        id: fingerprintPam
        configDirectory: Quickshell.shellPath("pam.d")
        config: "fingerprint"
        user: lockRoot.userName

        onPamMessage: {
            if (!messageIsError && message !== "") {
                lockRoot.statusIsError = false
                lockRoot.statusText = message
            }
        }

        onCompleted: result => {
            if (result === PamResult.Success) {
                lockRoot.authenticationSucceeded()
            } else if (result === PamResult.Failed && !lockRoot.unlocking) {
                lockRoot.statusIsError = true
                lockRoot.statusText = "Fingerprint not recognized — try again"
                lockRoot.authenticationGeneration++
                fingerprintRetry.restart()
            } else if (!lockRoot.unlocking) {
                lockRoot.fingerprintUsable = false
                lockRoot.statusIsError = false
                lockRoot.statusText = "Fingerprint is unavailable — enter your password"
            }
        }

        onError: {
            if (!lockRoot.unlocking) {
                lockRoot.fingerprintUsable = false
                lockRoot.statusIsError = false
                lockRoot.statusText = "Fingerprint is unavailable — enter your password"
            }
        }
    }

    Timer {
        id: fingerprintStart
        interval: 350
        onTriggered: lockRoot.probeFingerprintAuthentication()
    }

    Timer {
        id: fingerprintRetry
        interval: 900
        onTriggered: lockRoot.startFingerprintAuthentication()
    }

    Process {
        id: fingerprintProbe
        onExited: (exitCode, exitStatus) => {
            if (exitCode === 0) {
                lockRoot.startFingerprintAuthentication()
            } else if (!lockRoot.unlocking) {
                lockRoot.fingerprintUsable = false
                lockRoot.statusIsError = false
                lockRoot.statusText = "Fingerprint is unavailable — enter your password"
            }
        }
    }

    Process {
        id: suspendProcess
        command: ["systemctl", "suspend"]
    }

    Timer {
        id: unlockAfterAnimation
        interval: 480
        onTriggered: sessionLock.locked = false
    }

    Timer {
        id: quitDelay
        interval: 80
        onTriggered: Qt.quit()
    }

    WlSessionLock {
        id: sessionLock
        locked: true

        onSecureChanged: {
            if (secure) {
                lockRoot.finishLockRequest()
                fingerprintStart.restart()
            } else if (lockRoot.unlocking) {
                quitDelay.restart()
            }
        }

        WlSessionLockSurface {
            id: lockSurface
            color: "#030504"

            Rectangle {
                anchors.fill: parent
                color: "#030504"

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
                    anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: parent.height * 0.155 }
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
                        font.pixelSize: Math.min(112, Math.max(74, lockSurface.height * 0.104))
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDate(clock.date, "dddd, d MMMM")
                        color: "#8d8d8d"
                        font.family: "SF Pro Rounded"
                        font.pixelSize: Math.min(20, Math.max(15, lockSurface.height * 0.018))
                    }
                }

                Column {
                    id: authenticationCard
                    anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: parent.height * 0.405 }
                    width: Math.min(380, parent.width - 48)
                    spacing: 10
                    opacity: 0
                    scale: 0.94

                    SequentialAnimation {
                        running: true
                        PauseAnimation { duration: 190 }
                        ParallelAnimation {
                            NumberAnimation {
                                target: authenticationCard
                                property: "opacity"
                                from: 0
                                to: 1
                                duration: 300
                                easing.type: Easing.OutCubic
                            }
                            NumberAnimation {
                                target: authenticationCard
                                property: "scale"
                                from: 0.94
                                to: 1
                                duration: 480
                                easing.type: Easing.OutBack
                            }
                        }
                    }

                    Item {
                        id: avatar
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(116, lockSurface.height * 0.108)
                        height: width

                        Canvas {
                            id: avatarCanvas
                            anchors.fill: parent
                            property url imageSource: Quickshell.shellPath("assets/avatar.jpg")

                            onImageLoaded: requestPaint()
                            onWidthChanged: requestPaint()
                            onHeightChanged: requestPaint()
                            Component.onCompleted: loadImage(imageSource)

                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                if (!isImageLoaded(imageSource)) return
                                ctx.save()
                                ctx.beginPath()
                                ctx.arc(width / 2, height / 2, Math.min(width, height) / 2, 0, Math.PI * 2)
                                ctx.clip()
                                ctx.drawImage(imageSource, 0, 0, width, height)
                                ctx.restore()
                            }
                        }

                        Rectangle {
                            anchors.fill: parent
                            radius: width / 2
                            color: "transparent"
                            border.width: 2
                            border.color: "#28a98a"
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: lockRoot.userName === "lexa" ? "Lexa" : (lockRoot.userName !== "" ? lockRoot.userName : "Lexa")
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"
                        font.weight: Font.Bold
                        font.pixelSize: 24
                    }

                    Item { width: 1; height: 2 }

                    Rectangle {
                        id: passwordBox
                        width: parent.width
                        height: 56
                        radius: 28
                        color: "#161616"
                        border.width: 2
                        border.color: lockRoot.statusIsError ? "#ff4d5e" : "#00d6a4"

                        Behavior on border.color { ColorAnimation { duration: 160 } }

                        TextInput {
                            id: passwordInput
                            anchors { left: parent.left; right: unlockButton.left; top: parent.top; bottom: parent.bottom; leftMargin: 22; rightMargin: 12 }
                            text: lockRoot.passwordText
                            onTextEdited: lockRoot.passwordText = text
                            color: "transparent"
                            selectionColor: "transparent"
                            selectedTextColor: "transparent"
                            font.family: "SF Pro Rounded"
                            font.pixelSize: 15
                            echoMode: TextInput.Password
                            passwordCharacter: "•"
                            verticalAlignment: TextInput.AlignVCenter
                            enabled: !lockRoot.passwordBusy && !lockRoot.unlocking
                            focus: lockSurface.visible
                            cursorDelegate: Item { width: 0; height: 0 }
                            Keys.onPressed: event => {
                                if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                                    lockRoot.submitPassword()
                                    event.accepted = true
                                }
                            }

                            onActiveFocusChanged: {
                                if (activeFocus && text !== lockRoot.passwordText)
                                    text = lockRoot.passwordText
                            }

                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                text: lockRoot.passwordBusy ? "Checking…" : "Password"
                                color: "#666666"
                                font: passwordInput.font
                                visible: passwordInput.text.length === 0
                            }
                        }

                        Item {
                            id: passwordDotsArea
                            anchors {
                                left: parent.left
                                right: unlockButton.left
                                top: parent.top
                                bottom: parent.bottom
                                leftMargin: 22
                                rightMargin: 12
                            }
                            clip: true

                            function syncDots() {
                                const wantedCount = lockRoot.passwordText.length
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
                                target: lockRoot
                                function onPasswordTextChanged() { passwordDotsArea.syncDots() }
                            }

                            Component.onCompleted: syncDots()
                        }

                        Rectangle {
                            id: unlockButton
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 5 }
                            width: 46; height: 46; radius: 23
                            color: unlockMouse.containsMouse ? "#393939" : "#2b2b2b"

                            Behavior on color { ColorAnimation { duration: 140 } }

                            Canvas {
                                anchors.centerIn: parent
                                width: 18; height: 18
                                property bool ready: lockRoot.passwordText.length > 0 && !lockRoot.passwordBusy
                                onReadyChanged: requestPaint()
                                onPaint: {
                                    let ctx = getContext("2d")
                                    ctx.reset()
                                    ctx.strokeStyle = ready ? "#c5c5c5" : "#666666"
                                    ctx.lineWidth = 2
                                    ctx.lineCap = "round"
                                    ctx.lineJoin = "round"
                                    ctx.beginPath()
                                    ctx.moveTo(3, 9)
                                    ctx.lineTo(15, 9)
                                    ctx.moveTo(10, 4)
                                    ctx.lineTo(15, 9)
                                    ctx.lineTo(10, 14)
                                    ctx.stroke()
                                }
                            }

                            MouseArea {
                                id: unlockMouse
                                anchors.fill: parent
                                enabled: lockRoot.passwordText.length > 0 && !lockRoot.passwordBusy
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: lockRoot.submitPassword()
                            }
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: parent.width
                        text: lockRoot.statusText
                        color: lockRoot.statusIsError ? "#ff6674" : "#777777"
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        font.family: "SF Pro Rounded"
                        font.pixelSize: 12
                    }
                }

                Text {
                    id: lockedFooter
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
                    text: "Session locked"
                    color: "#4f4f4f"
                    font.family: "SF Pro Rounded"
                    font.pixelSize: 12
                    opacity: 0

                    SequentialAnimation {
                        running: true
                        PauseAnimation { duration: 350 }
                        NumberAnimation {
                            target: lockedFooter
                            property: "opacity"
                            from: 0
                            to: 1
                            duration: 260
                            easing.type: Easing.OutCubic
                        }
                    }
                }

                Connections {
                    target: lockRoot
                    function onAuthenticationGenerationChanged() {
                        passwordInput.forceActiveFocus(Qt.OtherFocusReason)
                    }
                    function onExitAnimationGenerationChanged() {
                        lockExitAnimation.restart()
                    }
                }

                ParallelAnimation {
                    id: lockExitAnimation

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
                            target: authenticationCard
                            property: "opacity"
                            to: 0
                            duration: 210
                            easing.type: Easing.InCubic
                        }
                        NumberAnimation {
                            target: authenticationCard
                            property: "scale"
                            to: 0.94
                            duration: 280
                            easing.type: Easing.InCubic
                        }
                        NumberAnimation {
                            target: lockedFooter
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

                Component.onCompleted: passwordInput.forceActiveFocus(Qt.OtherFocusReason)
            }
        }
    }
}
