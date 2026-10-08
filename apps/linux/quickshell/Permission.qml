import QtQuick

// frog asks before it acts: drawn like narc's prompt (narc
// firewall/quickshell/Prompt.qml), because agent requests are moving to
// narc. A plain sentence first, facts below, how long, then Deny | Allow
// with the flame on what ↵ does. A yellow edge when it needs a look.
//   ↵ allow · esc deny · ←/→ once or always
Rectangle {
    id: card
    required property var engine
    readonly property var p: engine.permission
    readonly property bool caution: !!(p && p.reason)
    property bool always: false
    onPChanged: { always = false; if (p) keys.forceActiveFocus(); }
    visible: p !== null
    implicitHeight: col.implicitHeight + 2
    color: Style.surface
    border.width: 1
    border.color: caution ? Style.warn : Style.lineHi

    readonly property var verbs: ({Bash: "run a command", Edit: "edit a file", Write: "write a file",
        WebFetch: "fetch a page", WebSearch: "search the web", Image: "generate an image",
        Screenshot: "take a screenshot", Task: "start a subagent"})
    readonly property string headline: {
        if (!p) return "";
        const v = verbs[p.name] || (p.name.indexOf("mcp__") === 0 ? "call " + p.name.split("__").slice(1).join(" · ") : "use " + p.name);
        return "frog wants to " + v + ".";
    }
    readonly property var rows: {
        if (!p) return [];
        const r = [["tool", p.name, "mono"], ["exactly", p.arg, "mono"]];
        if (p.preview) r.push(["changes", Style.home(p.preview.path) + "   +" + p.preview.added + " −" + p.preview.removed, "mono"]);
        if (p.reason) r.push(["because", p.reason, "warn"]);
        return r;
    }

    Item {
        id: keys
        focus: card.visible
        Keys.onPressed: e => {
            if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) card.engine.allow(card.always);
            else if (e.key === Qt.Key_Escape) card.engine.deny();
            else if (e.key === Qt.Key_Left || e.key === Qt.Key_Right || e.key === Qt.Key_Tab) card.always = !card.always;
            else return;
            e.accepted = true;
        }
    }

    Column {
        id: col
        x: 1; y: 1
        width: parent.width - 2

        Item {
            width: parent.width; height: 30
            Text {
                x: 18; anchors.verticalCenter: parent.verticalCenter
                text: "FROG · " + (card.p ? card.p.name.toUpperCase() : "") + " · REQUEST"
                color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
                font.weight: Font.DemiBold; font.letterSpacing: Style.track
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 18; anchors.verticalCenter: parent.verticalCenter
                text: Style.base(card.engine.cwd)
                color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Style.line }
        }

        Text {
            x: 18; width: parent.width - 36
            topPadding: 18; bottomPadding: 12
            text: card.headline
            wrapMode: Text.Wrap
            color: Style.text; font.family: Style.sans; font.pixelSize: 20; font.weight: Font.Medium
        }

        Column {
            x: 18; width: parent.width - 36
            spacing: 6
            Repeater {
                model: card.rows
                delegate: Row {
                    required property var modelData
                    width: parent.width
                    Text {
                        width: 130
                        text: modelData[0]
                        color: Style.label; font.family: Style.sans; font.pixelSize: Style.body
                    }
                    Text {
                        width: parent.width - 130
                        text: modelData[1]
                        wrapMode: modelData[2] === "warn" ? Text.Wrap : Text.WrapAnywhere
                        maximumLineCount: 8
                        color: modelData[2] === "warn" ? Style.warn : Style.text
                        font.family: modelData[2] === "warn" ? Style.sans : Style.mono
                        font.pixelSize: Style.body
                    }
                }
            }
        }

        Item { width: 1; height: 12 }
        Diff {
            visible: !!(card.p && card.p.preview)
            x: 18; width: parent.width - 36
            json: card.p && card.p.preview ? JSON.stringify(card.p.preview) : ""
            limit: 12
        }
        Item { width: 1; height: 12 }

        // how long; on-state is inverted text, never orange
        Row {
            x: 18; height: 30; spacing: 6
            Text {
                width: 124; anchors.verticalCenter: parent.verticalCenter
                text: "for"
                color: Style.label; font.family: Style.sans; font.pixelSize: Style.body
            }
            Repeater {
                model: ["once", "always"]
                delegate: Rectangle {
                    required property string modelData
                    required property int index
                    readonly property bool on: (index === 1) === card.always
                    anchors.verticalCenter: parent.verticalCenter
                    width: chip.implicitWidth + 18; height: 24
                    color: on ? Style.text : "transparent"
                    border.width: 1; border.color: on ? Style.text : Style.lineHi
                    Text {
                        id: chip
                        anchors.centerIn: parent
                        text: modelData
                        color: parent.on ? Style.bg : Style.text
                        font.family: Style.sans; font.pixelSize: 13
                    }
                    TapHandler { onTapped: card.always = index === 1 }
                }
            }
        }
        Text {
            visible: card.always && !!(card.p && card.p.always)
            x: 148; width: parent.width - 166
            text: card.p ? card.p.always : ""
            clip: true
            color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
        }

        Item { width: 1; height: 16 }
        Rectangle { width: parent.width; height: 1; color: Style.line }
        Row {
            width: parent.width; height: 44
            Repeater {
                model: [["Deny", "esc", false], [card.always ? "Allow always" : "Allow", "↵", true]]
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: parent.width / 2; height: 44
                    color: modelData[2] ? Style.sel : "transparent"
                    Text {
                        anchors.centerIn: parent
                        text: modelData[0] + "   " + modelData[1]
                        color: modelData[2] ? Style.selInk : Style.text
                        font.family: Style.sans; font.pixelSize: 15; font.weight: Font.Medium
                    }
                    TapHandler { onTapped: index === 1 ? card.engine.allow(card.always) : card.engine.deny() }
                }
            }
        }
        Rectangle { width: parent.width; height: 1; color: Style.line }
        Text {
            x: 18; topPadding: 8; bottomPadding: 8
            text: "↵ allow   esc deny   ←/→ once or always"
            color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
        }
    }
    Rectangle {
        visible: card.caution
        x: 0; y: 0; width: 4; height: parent.height
        color: Style.warn
    }
}
