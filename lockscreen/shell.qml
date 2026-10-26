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
        sessionLock.locked = false
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
            color: "#050505"

            Rectangle {
                anchors.fill: parent
                color: "#050505"

                Rectangle {
                    width: Math.max(parent.width, parent.height) * 0.72
                    height: width
                    radius: width / 2
                    x: -width * 0.42
                    y: -height * 0.52
                    color: "#0b2b25"
                    opacity: 0.62
                }

                Rectangle {
                    width: Math.max(parent.width, parent.height) * 0.58
                    height: width
                    radius: width / 2
                    anchors { right: parent.right; bottom: parent.bottom; rightMargin: -width * 0.34; bottomMargin: -height * 0.43 }
                    color: "#101010"
                    opacity: 0.85
                }

                Column {
                    anchors { horizontalCenter: parent.horizontalCenter; top: parent.top; topMargin: Math.max(48, parent.height * 0.10) }
                    spacing: 0

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatTime(clock.date, "HH:mm")
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"
                        font.bold: true
                        font.pixelSize: Math.min(104, Math.max(72, lockSurface.height * 0.11))
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: Qt.formatDate(clock.date, "dddd, d MMMM")
                        color: "#8d8d8d"
                        font.family: "SF Pro Rounded"
                        font.pixelSize: 18
                    }
                }

                Column {
                    id: authenticationCard
                    anchors { horizontalCenter: parent.horizontalCenter; verticalCenter: parent.verticalCenter; verticalCenterOffset: 82 }
                    width: Math.min(380, parent.width - 48)
                    spacing: 14

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 76; height: 76; radius: 38
                        color: "#25d8a3"

                        Text {
                            anchors.centerIn: parent
                            text: lockRoot.userName !== "" ? lockRoot.userName.charAt(0).toUpperCase() : "•"
                            color: "#07120f"
                            font.family: "SF Pro Rounded"
                            font.bold: true
                            font.pixelSize: 34
                        }
                    }

                    Text {
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: lockRoot.userName !== "" ? lockRoot.userName : "User"
                        color: "#ffffff"
                        font.family: "SF Pro Rounded"
                        font.bold: true
                        font.pixelSize: 22
                    }

                    Item { width: 1; height: 4 }

                    Rectangle {
                        id: passwordBox
                        width: parent.width
                        height: 56
                        radius: 28
                        color: "#161616"
                        border.width: passwordInput.activeFocus ? 2 : 1
                        border.color: lockRoot.statusIsError ? "#ff4d5e"
                            : (passwordInput.activeFocus ? "#25d8a3" : "#252525")

                        Behavior on border.color { ColorAnimation { duration: 160 } }

                        TextInput {
                            id: passwordInput
                            anchors { left: parent.left; right: unlockButton.left; top: parent.top; bottom: parent.bottom; leftMargin: 22; rightMargin: 12 }
                            text: lockRoot.passwordText
                            onTextEdited: lockRoot.passwordText = text
                            color: "#ffffff"
                            selectionColor: "#25d8a3"
                            selectedTextColor: "#07120f"
                            font.family: "SF Pro Rounded"
                            font.pixelSize: 17
                            echoMode: TextInput.Password
                            passwordCharacter: "•"
                            verticalAlignment: TextInput.AlignVCenter
                            enabled: !lockRoot.passwordBusy && !lockRoot.unlocking
                            focus: lockSurface.visible
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

                        Rectangle {
                            id: unlockButton
                            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: 5 }
                            width: 46; height: 46; radius: 23
                            color: lockRoot.passwordText.length > 0 && !lockRoot.passwordBusy ? "#25d8a3" : "#242424"

                            Behavior on color { ColorAnimation { duration: 140 } }

                            Canvas {
                                anchors.centerIn: parent
                                width: 18; height: 18
                                property bool ready: lockRoot.passwordText.length > 0 && !lockRoot.passwordBusy
                                onReadyChanged: requestPaint()
                                onPaint: {
                                    let ctx = getContext("2d")
                                    ctx.reset()
                                    ctx.strokeStyle = ready ? "#07120f" : "#666666"
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
                                anchors.fill: parent
                                enabled: lockRoot.passwordText.length > 0 && !lockRoot.passwordBusy
                                cursorShape: Qt.PointingHandCursor
                                onClicked: lockRoot.submitPassword()
                            }
                        }
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 10

                        Canvas {
                            width: 24; height: 24
                            opacity: lockRoot.fingerprintUsable ? 1 : 0.45
                            property bool errorState: lockRoot.statusIsError
                            onErrorStateChanged: requestPaint()
                            onPaint: {
                                let ctx = getContext("2d")
                                ctx.reset()
                                ctx.strokeStyle = errorState ? "#ff4d5e" : "#25d8a3"
                                ctx.lineWidth = 1.7
                                ctx.lineCap = "round"
                                ctx.beginPath()
                                ctx.arc(12, 12, 8, Math.PI * 1.08, Math.PI * 1.92)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.arc(12, 12, 5, Math.PI * 0.95, Math.PI * 2.05)
                                ctx.stroke()
                                ctx.beginPath()
                                ctx.moveTo(12, 10)
                                ctx.quadraticCurveTo(15, 13, 12, 19)
                                ctx.stroke()
                            }
                        }

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.min(330, implicitWidth)
                            text: lockRoot.statusText
                            color: lockRoot.statusIsError ? "#ff6674" : "#8d8d8d"
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.WordWrap
                            font.family: "SF Pro Rounded"
                            font.pixelSize: 14
                        }
                    }
                }

                Text {
                    anchors { horizontalCenter: parent.horizontalCenter; bottom: parent.bottom; bottomMargin: 28 }
                    text: "Quickshell  •  secure session"
                    color: "#4f4f4f"
                    font.family: "SF Pro Rounded"
                    font.pixelSize: 12
                }

                Connections {
                    target: lockRoot
                    function onAuthenticationGenerationChanged() {
                        passwordInput.forceActiveFocus(Qt.OtherFocusReason)
                    }
                }

                Component.onCompleted: passwordInput.forceActiveFocus(Qt.OtherFocusReason)
            }
        }
    }
}
