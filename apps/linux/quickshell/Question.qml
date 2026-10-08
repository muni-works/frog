import QtQuick

// The model asks you to choose (frog's Ask tool). ↑↓ moves the flame, ↵
// picks, esc skips. Same card as a permission prompt.
Rectangle {
    id: card
    required property var engine
    readonly property var q: engine.question
    property int sel: 0
    property var picked: ({})
    onQChanged: { sel = 0; picked = {}; if (q) keys.forceActiveFocus(); }
    visible: q !== null
    implicitHeight: col.implicitHeight + 2
    color: Style.surface
    border.width: 1; border.color: Style.lineHi

    function choose() {
        if (!q) return;
        if (q.multi) {
            const c = Object.keys(picked).filter(k => picked[k]);
            engine.answer(c.length ? c : [q.options[sel].label]);
        } else engine.answer([q.options[sel].label]);
    }
    Item {
        id: keys
        focus: card.visible
        Keys.onPressed: e => {
            const n = card.q ? card.q.options.length : 0;
            if (e.key === Qt.Key_Down) card.sel = (card.sel + 1) % n;
            else if (e.key === Qt.Key_Up) card.sel = (card.sel + n - 1) % n;
            else if (e.key === Qt.Key_Space && card.q.multi) {
                const p = Object.assign({}, card.picked); const l = card.q.options[card.sel].label;
                p[l] = !p[l]; card.picked = p;
            }
            else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) card.choose();
            else if (e.key === Qt.Key_Escape) card.engine.answer([]);
            else return;
            e.accepted = true;
        }
    }
    Column {
        id: col
        x: 1; y: 1; width: parent.width - 2
        Item {
            width: parent.width; height: 30
            Text {
                x: 18; anchors.verticalCenter: parent.verticalCenter
                text: "FROG · QUESTION"
                color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
                font.weight: Font.DemiBold; font.letterSpacing: Style.track
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Style.line }
        }
        Text {
            x: 18; width: parent.width - 36
            topPadding: 18; bottomPadding: 12
            text: card.q ? card.q.question : ""
            wrapMode: Text.Wrap
            color: Style.mint; font.family: Style.sans; font.pixelSize: 18; font.weight: Font.Medium
        }
        Repeater {
            model: card.q ? card.q.options : []
            delegate: Rectangle {
                required property var modelData
                required property int index
                readonly property bool on: index === card.sel
                x: 1; width: col.width - 2; height: opt.implicitHeight + 14
                color: on ? Style.sel : "transparent"
                HoverHandler { onHoveredChanged: if (hovered) card.sel = index }
                TapHandler { onTapped: { card.sel = index; card.choose(); } }
                Column {
                    id: opt
                    x: 18; y: 7; width: parent.width - 36
                    Text {
                        text: (card.q.multi ? (card.picked[modelData.label] ? "■ " : "□ ") : "") + modelData.label
                        color: parent.parent.on ? Style.selInk : Style.text
                        font.family: Style.sans; font.pixelSize: Style.body; font.weight: Font.Medium
                    }
                    Text {
                        visible: !!modelData.detail
                        width: parent.width; wrapMode: Text.Wrap
                        text: modelData.detail || ""
                        color: parent.parent.on ? Style.selInk : Style.label
                        font.family: Style.sans; font.pixelSize: Style.small
                    }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Style.line }
        Text {
            x: 18; topPadding: 8; bottomPadding: 8
            text: "↑↓ move   ↵ choose" + (card.q && card.q.multi ? "   space pick" : "") + "   esc skip"
            color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
        }
    }
}
