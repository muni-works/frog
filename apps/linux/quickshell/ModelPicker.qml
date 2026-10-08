import QtQuick

// ┌─ MODEL ─┐ over a scrim: type to filter, ↑↓ moves the flame, ↵ switches
// this conversation's model (Op::SetModel). From `frog --models --json`.
Rectangle {
    id: pick
    required property var engine
    required property var library
    property bool open: false
    property int sel: 0
    visible: open
    color: Style.scrim
    function show() { library.loadModels(); filter.text = ""; sel = 0; open = true; filter.forceActiveFocus(); }
    function hide() { open = false; closed(); }
    signal closed()
    readonly property var shown: {
        const q = filter.text.toLowerCase();
        return library.models.filter(m => !q || m.spec.toLowerCase().indexOf(q) >= 0
                                     || (m.info && m.info.name && m.info.name.toLowerCase().indexOf(q) >= 0));
    }
    function choose() {
        if (!shown.length) return;
        engine.setModel(shown[Math.min(sel, shown.length - 1)].spec);
        hide();
    }
    TapHandler { onTapped: pick.hide() }

    Rectangle {
        id: box
        width: Math.min(640, parent.width - 80)
        height: Math.min(parent.height - 120, 64 + list.contentHeight + 40)
        anchors.horizontalCenter: parent.horizontalCenter
        y: 70
        color: Style.surface
        border.width: 1; border.color: Style.lineHi
        TapHandler {}
        // the title set into the top border
        Rectangle {
            x: 14; y: -9; width: ttl.implicitWidth + 12; height: 18; color: Style.surface
            Text {
                id: ttl; anchors.centerIn: parent
                text: "MODEL"
                color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
                font.weight: Font.DemiBold; font.letterSpacing: Style.track
            }
        }
        Text {
            x: 18; y: 20
            text: "›"
            color: Style.caret; font.family: Style.mono; font.pixelSize: Style.body + 2
        }
        TextInput {
            id: filter
            x: 38; y: 20; width: parent.width - 56
            color: Style.text; font.family: Style.mono; font.pixelSize: Style.body
            cursorDelegate: Rectangle { width: 2; color: Style.caret; visible: filter.activeFocus }
            onTextChanged: pick.sel = 0
            Keys.onPressed: e => {
                const n = pick.shown.length;
                if (e.key === Qt.Key_Down && n) pick.sel = (pick.sel + 1) % n;
                else if (e.key === Qt.Key_Up && n) pick.sel = (pick.sel + n - 1) % n;
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) pick.choose();
                else if (e.key === Qt.Key_Escape) pick.hide();
                else return;
                e.accepted = true;
                list.positionViewAtIndex(pick.sel, ListView.Contain);
            }
        }
        ListView {
            id: list
            x: 1; y: 52; width: parent.width - 2
            height: parent.height - 52 - 34
            clip: true
            model: pick.shown
            boundsBehavior: Flickable.StopAtBounds
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool on: index === pick.sel
                readonly property bool current: modelData.spec === pick.engine.model
                width: list.width; height: 30
                color: on ? Style.sel : "transparent"
                HoverHandler { onHoveredChanged: if (hovered) pick.sel = index }
                TapHandler { onTapped: { pick.sel = index; pick.choose(); } }
                Text {
                    x: 18; anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 150; clip: true
                    text: (current ? "■ " : "  ") + modelData.spec
                    color: on ? Style.selInk : Style.text
                    font.family: Style.mono; font.pixelSize: Style.value
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: 18
                    anchors.verticalCenter: parent.verticalCenter
                    text: [modelData.source, modelData.tier].filter(x => x).join(" · ")
                    color: on ? Style.selInk : Style.label
                    font.family: Style.sans; font.pixelSize: Style.small
                }
            }
            Text {
                visible: list.count === 0
                x: 18; y: 6
                text: pick.library.modelsLoading ? "asking frog for models" : "no models match"
                color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
            }
        }
        Rectangle { y: parent.height - 33; width: parent.width; height: 1; color: Style.line }
        Text {
            x: 18; y: parent.height - 25
            text: "↑↓ move   ↵ switch   esc close"
            color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
        }
    }
}
