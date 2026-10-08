import QtQuick

// Sessions, newest first: every folder's (`frog --sessions --all`). Click
// one to continue it; ■ marks the open one. Hover is the flame.
Rectangle {
    id: side
    required property var engine
    required property var library
    signal open(var s)
    signal newChat()
    color: Style.bg
    Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: Style.line }

    Text {
        x: 18; y: 14
        text: "SESSIONS"
        color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
        font.weight: Font.DemiBold; font.letterSpacing: Style.track
    }
    Rectangle {
        id: fresh
        y: 40; width: parent.width - 1; height: 30
        color: nh.hovered ? Style.sel : "transparent"
        HoverHandler { id: nh; cursorShape: Qt.PointingHandCursor }
        TapHandler { onTapped: side.newChat() }
        Text {
            x: 18; anchors.verticalCenter: parent.verticalCenter
            text: "New conversation"
            color: nh.hovered ? Style.selInk : Style.text
            font.family: Style.sans; font.pixelSize: Style.body
        }
        Text {
            anchors.right: parent.right; anchors.rightMargin: 14; anchors.verticalCenter: parent.verticalCenter
            text: "ctrl n"
            color: nh.hovered ? Style.selInk : Style.label
            font.family: Style.mono; font.pixelSize: Style.small
        }
    }
    Rectangle { y: 76; x: 18; width: parent.width - 37; height: 1; color: Style.line }
    ListView {
        id: list
        y: 82; width: parent.width - 1; height: parent.height - 82
        clip: true
        model: side.library.sessions
        boundsBehavior: Flickable.StopAtBounds
        delegate: Rectangle {
            required property var modelData
            readonly property bool current: modelData.id === side.engine.session
            readonly property bool on: h.hovered
            width: list.width; height: 48
            color: on ? Style.sel : "transparent"
            HoverHandler { id: h; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: side.open(modelData) }
            Text {
                x: 18; y: 7; width: parent.width - 30; clip: true
                text: (current ? "■ " : "") + (modelData.title || (modelData.first_input || "untitled").replace(/\s+/g, " "))
                color: on ? Style.selInk : Style.text
                font.family: Style.sans; font.pixelSize: Style.body
            }
            Text {
                x: 18; y: 27; width: parent.width - 30; clip: true
                text: Style.base(modelData.cwd) + "  ·  " + Style.ago(modelData.modified)
                color: on ? Style.selInk : Style.label
                font.family: Style.mono; font.pixelSize: Style.small
            }
        }
    }
}
