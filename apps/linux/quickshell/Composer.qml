import QtQuick

// Where you type. The › and the cursor are the only orange text (caret).
//   ↵ send · shift ↵ newline · esc interrupt · !cmd runs a shell command
Rectangle {
    id: c
    required property var engine
    signal pickModel()
    signal newChat()
    property alias input: edit
    color: Style.bg
    implicitHeight: Math.min(200, Math.max(26, edit.contentHeight)) + 30

    Rectangle { width: parent.width; height: 1; color: Style.line }
    Text {
        x: 28; y: 15
        text: "›"
        color: edit.activeFocus ? Style.caret : Style.label
        font.family: Style.mono; font.pixelSize: Style.body + 2
    }
    Flickable {
        id: fl
        x: 48; y: 15
        width: parent.width - 76; height: parent.height - 30
        contentHeight: edit.contentHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        TextEdit {
            id: edit
            width: fl.width
            wrapMode: TextEdit.Wrap
            focus: true
            color: Style.text; font.family: Style.sans; font.pixelSize: Style.body
            selectionColor: Style.sel; selectedTextColor: Style.selInk
            cursorDelegate: Rectangle {
                width: 2; color: Style.caret
                visible: edit.activeFocus
            }
            onCursorRectangleChanged: {
                if (cursorRectangle.y < fl.contentY) fl.contentY = cursorRectangle.y;
                else if (cursorRectangle.y + cursorRectangle.height > fl.contentY + fl.height)
                    fl.contentY = cursorRectangle.y + cursorRectangle.height - fl.height;
            }
            Keys.onPressed: e => {
                const ctrl = e.modifiers & Qt.ControlModifier;
                if ((e.key === Qt.Key_Return || e.key === Qt.Key_Enter) && !(e.modifiers & Qt.ShiftModifier)) {
                    if (c.engine.busy) return e.accepted = true;
                    c.engine.submit(edit.text);
                    edit.text = "";
                    e.accepted = true;
                } else if (e.key === Qt.Key_Escape && c.engine.busy) {
                    c.engine.interrupt(); e.accepted = true;
                } else if (ctrl && e.key === Qt.Key_K) {
                    c.pickModel(); e.accepted = true;
                } else if (ctrl && e.key === Qt.Key_N) {
                    c.newChat(); e.accepted = true;
                }
            }
            Text {
                visible: edit.text === ""
                text: c.engine.busy ? "frog is working. esc interrupts" : "Ask frog to do something"
                color: Style.faint; font: edit.font
            }
        }
    }
}
