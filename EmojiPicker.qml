import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

PanelWindow {
    id: picker
    property color accentColor: "#25d8a3"
    property bool shown: false
    property bool displaying: false
    property bool hadFocus: false
    property string category: "recent"
    property string pendingEmoji: ""
    property var emojis: []
    property var filtered: []
    property var recent: []
    readonly property string emojiFontFamily: fluentFont.status === FontLoader.Ready
        ? fluentFont.name : "Noto Color Emoji"
    readonly property var categories: [
        { id: "all", icon: "◈", title: "Все" },
        { id: "recent", icon: "◷", title: "Недавние" },
        { id: "people", icon: "☺", title: "Люди" },
        { id: "animals", icon: "🐻", title: "Животные" },
        { id: "nature", icon: "🌿", title: "Природа" },
        { id: "food", icon: "🍕", title: "Еда" },
        { id: "activity", icon: "⚽", title: "Занятия" },
        { id: "travel", icon: "🚗", title: "Путешествия" },
        { id: "objects", icon: "💡", title: "Предметы" },
        { id: "symbols", icon: "♥", title: "Символы" },
        { id: "flags", icon: "⚑", title: "Флаги" }
    ]
    readonly property var usableScreen: findUsableScreen()

    function findUsableScreen() {
        for (const screen of Quickshell.screens) {
            if (screen.name && screen.width > 0 && screen.height > 0)
                return screen
        }
        return null
    }

    screen: usableScreen
    implicitWidth: 390
    implicitHeight: 420
    anchors { right: true; bottom: true }
    margins { right: 24; bottom: 28 }
    color: "transparent"
    visible: usableScreen !== null
    exclusiveZone: 0
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "quickshell-emoji-picker"
    WlrLayershell.keyboardFocus: shown ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
    mask: Region {
        x: 0; y: 0
        width: picker.displaying ? picker.width : 0
        height: picker.displaying ? picker.height : 0
        radius: panel.radius
    }

    function loadEmojis() {
        try {
            const russian = JSON.parse(russianTags.text() || "{}")
            const ruByEmoji = ({})
            for (const key in russian) {
                const item = russian[key]
                if (item.emoji) ruByEmoji[item.emoji] = item.tags || []
            }
            const parsed = JSON.parse(emojiData.text())
            emojis = parsed.map(item => ({
                emoji: item.emoji,
                name: item.name,
                category: item.category,
                search: (item.name + " " + (item.keywords || []).join(" ")
                    + " " + (ruByEmoji[item.emoji] || []).join(" ")).toLowerCase()
            }))
            refresh()
        } catch (error) {
            // Russian tags are optional; the bundled emoji list is sufficient.
            try {
                emojis = JSON.parse(emojiData.text()).map(item => ({
                    emoji: item.emoji,
                    name: item.name,
                    category: item.category,
                    search: (item.name + " " + (item.keywords || []).join(" ")).toLowerCase()
                }))
                refresh()
            } catch (dataError) {
                console.warn("Emoji picker: could not load emoji data:", dataError)
            }
        }
    }

    function refresh() {
        const query = searchInput.text.trim().toLowerCase()
        const source = query ? emojis : category === "recent"
            ? recent.map(symbol => emojis.find(item => item.emoji === symbol)).filter(Boolean)
            : emojis
        filtered = source.filter(item =>
            (query || category === "all" || category === "recent" || item.category === category)
                && (!query || item.search.includes(query)))
        emojiGrid.currentIndex = filtered.length > 0 ? 0 : -1
        emojiGrid.positionViewAtBeginning()
    }

    function open() {
        if (shown) {
            close()
            return
        }
        hideDelay.stop()
        category = "recent"
        searchInput.text = ""
        refresh()
        hadFocus = false
        displaying = true
        shown = true
        focusDelay.restart()
    }

    function close() {
        if (!shown) return
        shown = false
        focusDelay.stop()
        hideDelay.restart()
    }

    function choose(symbol) {
        if (!symbol) return
        recent = [symbol].concat(recent.filter(value => value !== symbol)).slice(0, 35)
        recentFile.setText(JSON.stringify(recent))
        pendingEmoji = symbol
        close()
        typeDelay.restart()
    }

    function moveSelection(offset) {
        if (filtered.length === 0) return
        emojiGrid.currentIndex = Math.max(0, Math.min(filtered.length - 1,
                                                       emojiGrid.currentIndex + offset))
        emojiGrid.positionViewAtIndex(emojiGrid.currentIndex, GridView.Contain)
    }

    IpcHandler {
        target: "emoji"
        function toggle(): bool { picker.open(); return true }
        function show(): bool { if (!picker.shown) picker.open(); return true }
        function hide(): bool { picker.close(); return true }
    }

    FontLoader {
        id: fluentFont
        source: "file://" + Quickshell.env("HOME")
            + "/.local/share/fonts/FluentEmoji3D/FluentEmoji3D.ttf"
    }

    FileView {
        id: emojiData
        path: Quickshell.shellPath("assets/emoji.json")
        blockLoading: true
        printErrors: true
    }

    FileView {
        id: russianTags
        path: "/usr/share/smile/assets/emoji_locales/ru.json"
        blockLoading: true
        printErrors: false
    }

    FileView {
        id: recentFile
        path: Quickshell.shellPath("emoji-recent.json")
        blockLoading: true
        atomicWrites: true
        printErrors: false
    }

    Component.onCompleted: {
        try {
            const saved = JSON.parse(recentFile.text() || "[]")
            if (Array.isArray(saved)) recent = saved.filter(value => typeof value === "string").slice(0, 35)
        } catch (error) {
            console.warn("Emoji picker: could not read recent emojis:", error)
        }
        loadEmojis()
    }

    Process { id: typeEmoji }

    Timer {
        id: focusDelay
        interval: 15
        onTriggered: searchInput.forceActiveFocus()
    }

    Timer {
        id: hideDelay
        interval: 140
        onTriggered: picker.displaying = false
    }

    Timer {
        id: typeDelay
        interval: 90
        onTriggered: {
            typeEmoji.command = ["wtype", picker.pendingEmoji]
            typeEmoji.running = true
        }
    }

    FocusScope {
        anchors.fill: parent
        focus: picker.shown
        onActiveFocusChanged: {
            if (activeFocus) picker.hadFocus = true
            else if (picker.shown && picker.hadFocus) picker.close()
        }

        Rectangle {
            id: panel
            anchors.fill: parent
            radius: 24
            color: "#090909"
            border.width: 1
            border.color: "#343434"
            opacity: picker.shown ? 1 : 0
            scale: picker.shown ? 1 : 0.97
            Behavior on opacity { NumberAnimation { duration: 125; easing.type: Easing.OutCubic } }
            Behavior on scale { NumberAnimation { duration: 125; easing.type: Easing.OutCubic } }

            Text {
                anchors { left: parent.left; top: parent.top; leftMargin: 19; topMargin: 15 }
                text: "Эмодзи"
                color: "#ffffff"
                font.family: "SF Pro Rounded"
                font.pixelSize: 18
                font.bold: true
            }

            Text {
                anchors { right: parent.right; top: parent.top; rightMargin: 19; topMargin: 18 }
                text: "Esc — закрыть"
                color: "#777777"
                font.family: "SF Pro Rounded"
                font.pixelSize: 11
            }

            Rectangle {
                id: searchBox
                anchors { top: parent.top; left: parent.left; right: parent.right
                          topMargin: 50; leftMargin: 14; rightMargin: 14 }
                height: 38
                radius: 13
                color: "#1a1a1a"
                border.width: searchInput.activeFocus ? 1 : 0
                border.color: picker.accentColor

                Text {
                    anchors { left: parent.left; verticalCenter: parent.verticalCenter; leftMargin: 12 }
                    text: "⌕"
                    color: picker.accentColor
                    font.pixelSize: 22
                }

                TextInput {
                    id: searchInput
                    anchors { left: parent.left; right: parent.right; verticalCenter: parent.verticalCenter
                              leftMargin: 39; rightMargin: 11 }
                    color: "#ffffff"
                    font.family: "SF Pro Rounded"
                    font.pixelSize: 14
                    selectByMouse: true
                    clip: true
                    onTextChanged: picker.refresh()

                    Text {
                        anchors.fill: parent
                        text: "Поиск на русском или английском"
                        color: "#777777"
                        font: searchInput.font
                        visible: searchInput.text === ""
                    }

                    Keys.onPressed: event => {
                        if (event.key === Qt.Key_Escape) picker.close()
                        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)
                            picker.choose(picker.filtered[emojiGrid.currentIndex]?.emoji)
                        else if (event.key === Qt.Key_Down) picker.moveSelection(7)
                        else if (event.key === Qt.Key_Up) picker.moveSelection(-7)
                        else if (event.key === Qt.Key_Right && searchInput.text === "") picker.moveSelection(1)
                        else if (event.key === Qt.Key_Left && searchInput.text === "") picker.moveSelection(-1)
                        else return
                        event.accepted = true
                    }
                }
            }

            Row {
                id: categoryRow
                anchors { top: searchBox.bottom; topMargin: 8; horizontalCenter: parent.horizontalCenter }
                spacing: 2

                Repeater {
                    model: picker.categories
                    delegate: Rectangle {
                        required property var modelData
                        width: 30; height: 32; radius: 9
                        color: picker.category === modelData.id ? "#252525" : "transparent"

                        Text {
                            anchors.centerIn: parent
                            anchors.horizontalCenterOffset: fluentFont.status === FontLoader.Ready
                                && parent.modelData.id !== "all" && parent.modelData.id !== "recent"
                                && parent.modelData.id !== "flags" ? 1 : 0
                            anchors.verticalCenterOffset: fluentFont.status === FontLoader.Ready
                                && parent.modelData.id !== "all" && parent.modelData.id !== "recent"
                                && parent.modelData.id !== "flags" ? -4 : 0
                            text: parent.modelData.icon
                            color: picker.category === parent.modelData.id ? picker.accentColor : "#aaaaaa"
                            font.family: parent.modelData.id === "flags"
                                ? "Noto Color Emoji" : picker.emojiFontFamily
                            font.pixelSize: 17
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                picker.category = parent.modelData.id
                                picker.refresh()
                                searchInput.forceActiveFocus()
                            }
                        }
                    }
                }
            }

            Rectangle {
                anchors { top: categoryRow.bottom; topMargin: 8; left: parent.left; right: parent.right
                          leftMargin: 14; rightMargin: 14 }
                height: 1
                color: "#292929"
            }

            GridView {
                id: emojiGrid
                anchors { top: categoryRow.bottom; bottom: footer.top; left: parent.left; right: parent.right
                          topMargin: 14; bottomMargin: 6; leftMargin: 14; rightMargin: 14 }
                model: picker.filtered
                cellWidth: 50
                cellHeight: 48
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                cacheBuffer: 96

                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: 46; height: 45; radius: 10
                    color: emojiGrid.currentIndex === index || emojiMouse.containsMouse
                        ? "#292929" : "transparent"

                    Text {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: parent.modelData.category === "flags"
                            || fluentFont.status !== FontLoader.Ready ? 0 : 2
                        anchors.verticalCenterOffset: parent.modelData.category === "flags"
                            || fluentFont.status !== FontLoader.Ready ? 0 : -19
                        text: parent.modelData.emoji
                        font.family: parent.modelData.category === "flags"
                            ? "Noto Color Emoji" : picker.emojiFontFamily
                        font.pixelSize: 27
                        renderType: Text.QtRendering
                    }

                    MouseArea {
                        id: emojiMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: picker.choose(parent.modelData.emoji)
                        onEntered: emojiGrid.currentIndex = parent.index
                    }
                }
            }

            Text {
                anchors.centerIn: emojiGrid
                visible: picker.filtered.length === 0
                text: picker.category === "recent" && searchInput.text === ""
                    ? "Пока нет недавних эмодзи" : "Ничего не найдено"
                color: "#888888"
                font.family: "SF Pro Rounded"
                font.pixelSize: 14
            }

            Text {
                id: footer
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom
                          leftMargin: 18; rightMargin: 18; bottomMargin: 13 }
                text: {
                    const index = Math.min(picker.filtered.length - 1, Math.max(0, emojiGrid.currentIndex))
                    const selected = picker.filtered[index]
                    return selected ? selected.name + "  ·  Enter — вставить"
                                    : "↑↓ — выбор  ·  Esc — закрыть"
                }
                color: "#777777"
                elide: Text.ElideRight
                font.family: "SF Pro Rounded"
                font.pixelSize: 11
            }
        }
    }
}
