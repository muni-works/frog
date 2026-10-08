import QtQuick

// The conversation: your messages, frog's (in mint), its thinking (folded),
// and tool calls with their output and diffs. Follows the bottom while a
// turn streams unless you scroll up.
ListView {
    id: view
    required property var engine
    model: engine.items
    clip: true
    spacing: 14
    boundsBehavior: Flickable.StopAtBounds
    property bool follow: true
    onMovementEnded: follow = atYEnd
    onCountChanged: if (follow) Qt.callLater(positionViewAtEnd)
    Connections {
        target: view.engine
        function onChanged() { if (view.follow) Qt.callLater(view.positionViewAtEnd); }
    }
    header: Item { width: 1; height: 18 }
    footer: Item {
        width: view.width; height: 40
        Text {
            x: 28; y: 6
            visible: view.engine.busy
            text: view.engine.progress || "working"
            color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
        }
    }

    delegate: Column {
        id: row
        required property int index
        required property string kind
        required property string text
        required property string name
        required property string arg
        required property string outcome
        required property string output
        required property string diff
        required property string level
        property bool open: false
        width: view.width
        readonly property int pad: 28
        readonly property int w: width - pad * 2

        // you
        Row {
            visible: row.kind === "user"
            x: row.pad; width: row.w
            spacing: 10
            Text { text: "›"; color: Style.label; font.family: Style.mono; font.pixelSize: Style.body }
            Text {
                width: parent.width - 20
                text: row.text
                wrapMode: Text.Wrap
                color: Style.text; font.family: Style.sans; font.pixelSize: Style.body
                font.weight: Font.Medium
            }
        }

        // frog's voice
        TextEdit {
            visible: row.kind === "message"
            x: row.pad + 20; width: row.w - 20
            readOnly: true; selectByMouse: true
            selectionColor: Style.sel; selectedTextColor: Style.selInk
            text: row.text
            textFormat: TextEdit.MarkdownText
            wrapMode: TextEdit.Wrap
            color: Style.mint; font.family: Style.sans; font.pixelSize: Style.body
        }

        // thinking: one line, the rest on click
        Text {
            visible: row.kind === "reasoning" && row.text.trim().length > 0
            x: row.pad + 20; width: row.w - 20
            text: row.open ? "thought   " + row.text.trim() : "thought   " + Style.firstLine(row.text)
            wrapMode: row.open ? Text.Wrap : Text.NoWrap
            clip: true
            color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: row.open = !row.open }
        }

        // a tool call
        Column {
            visible: row.kind === "tool"
            x: row.pad + 20; width: row.w - 20
            spacing: 6
            Rectangle {
                id: head
                width: parent.width; height: 26
                color: hover.hovered ? Style.sel : "transparent"
                HoverHandler { id: hover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: row.open = !row.open }
                readonly property color ink: hover.hovered ? Style.selInk : Style.text
                Row {
                    x: 6; anchors.verticalCenter: parent.verticalCenter
                    width: parent.width - 12
                    spacing: 10
                    Text {
                        text: row.outcome === "running" ? "□" : "■"
                        color: hover.hovered ? Style.selInk : Style.label
                        font.family: Style.mono; font.pixelSize: Style.value
                    }
                    Text {
                        id: tname
                        text: row.name
                        color: head.ink; font.family: Style.mono; font.pixelSize: Style.value; font.weight: Font.DemiBold
                    }
                    Text {
                        width: parent.width - tname.width - state.width - 60
                        text: row.arg.replace(/\s+/g, " ")
                        clip: true
                        color: hover.hovered ? Style.selInk : Style.label
                        font.family: Style.mono; font.pixelSize: Style.value
                    }
                    Text {
                        id: state
                        readonly property var words: ({running: "running", error: "failed", denied: "denied", skipped: "skipped"})
                        text: words[row.outcome] || (row.diff ? diffStat() : "")
                        function diffStat() {
                            try { const d = JSON.parse(row.diff); return "+" + d.added + " −" + d.removed; } catch (e) { return ""; }
                        }
                        color: hover.hovered ? Style.selInk
                             : row.outcome === "error" ? Style.fault
                             : row.outcome === "denied" ? Style.warn : Style.label
                        font.family: Style.mono; font.pixelSize: Style.value
                    }
                }
            }
            Diff {
                visible: row.diff !== "" && (row.open || row.outcome !== "denied")
                width: parent.width
                json: row.diff
                limit: row.open ? 400 : 14
            }
            Rectangle {
                visible: row.open && row.diff === "" && row.output.trim() !== ""
                width: parent.width
                height: out.implicitHeight + 16
                color: Style.surface
                border.width: 1; border.color: Style.line
                Text {
                    id: out
                    x: 10; y: 8; width: parent.width - 20
                    text: row.output.trim()
                    wrapMode: Text.WrapAnywhere
                    maximumLineCount: 40
                    color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
                }
            }
        }

        // a note: interrupted, an error, compaction
        Text {
            visible: row.kind === "note"
            x: row.pad + 20; width: row.w - 20
            text: row.text
            wrapMode: Text.Wrap
            color: row.level === "fault" ? Style.fault : row.level === "warn" ? Style.warn : Style.label
            font.family: Style.sans; font.pixelSize: Style.small
        }
    }
}
