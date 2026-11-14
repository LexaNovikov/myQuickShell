import QtQuick
import Quickshell
import Quickshell.Widgets

PopupWindow {
    id: trayMenu

    property color accentColor: "#25d8a3"
    property var menuHandles: []
    property var menuTitles: []
    readonly property int menuDepth: menuHandles.length - 1
    readonly property string menuTitle: menuDepth >= 0 ? menuTitles[menuDepth] : ""
    readonly property var menuEntries: menuDepth === 0 ? rootOpener.children
        : (menuDepth === 1 ? submenuOpener1.children
        : (menuDepth === 2 ? submenuOpener2.children
        : (menuDepth === 3 ? submenuOpener3.children : submenuOpener4.children)))

    function openFor(item, icon, window) {
        if (!item || !item.hasMenu || !item.menu) return
        let point = window.itemPosition(icon)
        let menuWidth = implicitWidth
        anchor.window = window
        anchor.rect.x = Math.max(8, Math.min(window.width - menuWidth - 8, point.x - 16))
        anchor.rect.y = point.y + icon.height + 7
        menuTitles = [item.title || item.tooltipTitle || ""]
        menuHandles = [item.menu]
        visible = true
    }

    function openSubmenu(entry) {
        if (menuHandles.length >= 5) return
        menuTitles = menuTitles.concat([entry.text])
        menuHandles = menuHandles.concat([entry])
    }

    function goBack() {
        if (menuDepth <= 0) return
        menuHandles = menuHandles.slice(0, -1)
        menuTitles = menuTitles.slice(0, -1)
    }

    onVisibleChanged: {
        if (!visible) {
            menuHandles = []
            menuTitles = []
        }
    }

    visible: false
    grabFocus: true
    color: "transparent"
    implicitWidth: 224
    implicitHeight: Math.min(380, menuColumn.implicitHeight + 12)

    QsMenuOpener {
        id: rootOpener
        menu: trayMenu.menuHandles.length > 0 ? trayMenu.menuHandles[0] : null
    }
    QsMenuOpener {
        id: submenuOpener1
        menu: trayMenu.menuHandles.length > 1 ? trayMenu.menuHandles[1] : null
    }
    QsMenuOpener {
        id: submenuOpener2
        menu: trayMenu.menuHandles.length > 2 ? trayMenu.menuHandles[2] : null
    }
    QsMenuOpener {
        id: submenuOpener3
        menu: trayMenu.menuHandles.length > 3 ? trayMenu.menuHandles[3] : null
    }
    QsMenuOpener {
        id: submenuOpener4
        menu: trayMenu.menuHandles.length > 4 ? trayMenu.menuHandles[4] : null
    }

    ClippingRectangle {
        anchors.fill: parent
        radius: 18
        color: "#090909"
        border.width: 1
        border.color: "#292929"

        Flickable {
            anchors.fill: parent
            anchors.margins: 6
            contentHeight: menuColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
                id: menuColumn
                width: parent.width
                spacing: 0

                Item {
                    width: parent.width
                    height: 24

                    Text {
                        anchors { left: parent.left; leftMargin: 10; right: parent.right; rightMargin: 10; verticalCenter: parent.verticalCenter }
                        text: trayMenu.menuDepth > 0 ? "‹  " + trayMenu.menuTitle : trayMenu.menuTitle
                        color: "#777777"
                        font.family: "SF Pro Rounded"
                        font.bold: true
                        font.pixelSize: 12
                        elide: Text.ElideRight
                    }

                    MouseArea {
                        anchors.fill: parent
                        enabled: trayMenu.menuDepth > 0
                        cursorShape: Qt.PointingHandCursor
                        onClicked: trayMenu.goBack()
                    }
                }

                Rectangle {
                    width: parent.width - 16
                    height: 1
                    x: 8
                    color: "#242424"
                }

                Repeater {
                    model: trayMenu.menuEntries

                    delegate: Item {
                        id: menuEntry
                        required property var modelData
                        width: menuColumn.width
                        height: modelData.isSeparator ? 4 : 28

                        Rectangle {
                            visible: menuEntry.modelData.isSeparator
                            anchors.centerIn: parent
                            width: parent.width - 16
                            height: 1
                            color: "#242424"
                        }

                        Rectangle {
                            anchors.fill: parent
                            visible: !menuEntry.modelData.isSeparator
                            radius: 11
                            color: entryMouse.containsMouse && menuEntry.modelData.enabled ? "#202020" : "transparent"
                            Behavior on color { ColorAnimation { duration: 120 } }

                            Image {
                                anchors { left: parent.left; leftMargin: 10; verticalCenter: parent.verticalCenter }
                                width: 16
                                height: 16
                                visible: menuEntry.modelData.icon !== ""
                                source: menuEntry.modelData.icon
                                sourceSize.width: 16
                                sourceSize.height: 16
                                fillMode: Image.PreserveAspectFit
                            }

                            Text {
                                anchors { left: parent.left; leftMargin: menuEntry.modelData.icon !== "" ? 34 : 12; right: entryMark.left; rightMargin: 7; verticalCenter: parent.verticalCenter }
                                text: menuEntry.modelData.text
                                color: menuEntry.modelData.enabled ? "#eeeeee" : "#666666"
                                font.family: "SF Pro Rounded"
                                font.pixelSize: 15
                                elide: Text.ElideRight
                            }

                            Text {
                                id: entryMark
                                anchors { right: parent.right; rightMargin: 11; verticalCenter: parent.verticalCenter }
                                text: menuEntry.modelData.hasChildren ? "›"
                                    : (menuEntry.modelData.buttonType !== QsMenuButtonType.None
                                        && menuEntry.modelData.checkState === Qt.Checked ? "✓" : "")
                                color: trayMenu.accentColor
                                font.family: "SF Pro Rounded"
                                font.bold: true
                                font.pixelSize: 16
                            }

                            MouseArea {
                                id: entryMouse
                                anchors.fill: parent
                                enabled: menuEntry.modelData.enabled
                                hoverEnabled: true
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                                onClicked: {
                                    if (menuEntry.modelData.hasChildren) {
                                        trayMenu.openSubmenu(menuEntry.modelData)
                                    } else {
                                        menuEntry.modelData.triggered()
                                        trayMenu.visible = false
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
