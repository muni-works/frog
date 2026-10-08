import Quickshell
import QtQuick

// The frog window: sessions on the left, the conversation, the composer,
// and a status line. Permission prompts and questions sit over the
// composer; the model picker over everything.
FloatingWindow {
    id: win
    title: "frog" + (engine.title ? " · " + engine.title : "")
    implicitWidth: 1180
    implicitHeight: 780
    minimumSize: Qt.size(640, 420)
    color: Style.bg

    property alias engine: engine
    Engine { id: engine }
    Library { id: library }

    function newChat(cwd) {
        picker.open = false;
        engine.start({cwd: cwd || engine.cwd});
        composer.input.forceActiveFocus();
    }
    function openSession(s) {
        picker.open = false;
        engine.start({resume: s.id, cwd: s.cwd});
        composer.input.forceActiveFocus();
    }
    function pickModel() { picker.show(); }
    function ask(text) {
        if (engine.busy || engine.items.count > 0) newChat();
        Qt.callLater(() => engine.submit(text));
    }
    Connections {
        target: engine
        function onBusyChanged() { if (!engine.busy) library.refresh(); }
        function onPermissionChanged() { if (!engine.permission) composer.input.forceActiveFocus(); }
        function onQuestionChanged() { if (!engine.question) composer.input.forceActiveFocus(); }
    }
    Component.onCompleted: {
        const r = Quickshell.env("FROG_APP_RESUME");
        engine.start(r ? {resume: r} : {});
    }

    Item {
        id: root
        anchors.fill: parent
        Rectangle { anchors.fill: parent; color: Style.bg }

        // the strip: what this is, where it works
        Rectangle {
            id: strip
            width: parent.width; height: 34
            color: Style.surface
            Row {
                x: 18; anchors.verticalCenter: parent.verticalCenter
                spacing: 12
                Image {
                    source: Qt.resolvedUrl("frog.svg")
                    sourceSize: Qt.size(16, 16)
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: ("frog" + (engine.title ? " · " + engine.title : "")).toUpperCase()
                    color: Style.text; font.family: Style.mono; font.pixelSize: Style.small
                    font.weight: Font.DemiBold; font.letterSpacing: Style.track
                }
            }
            Text {
                anchors.right: parent.right; anchors.rightMargin: 18; anchors.verticalCenter: parent.verticalCenter
                text: Style.home(engine.cwd)
                color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
            }
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Style.line }
        }

        Sidebar {
            id: sidebar
            y: strip.height; width: 280; height: parent.height - strip.height
            engine: engine; library: library
            onOpen: s => win.openSession(s)
            onNewChat: win.newChat()
        }

        Item {
            id: main
            x: sidebar.width; y: strip.height
            width: parent.width - sidebar.width; height: parent.height - strip.height

            Transcript {
                id: transcript
                width: parent.width
                height: parent.height - composer.height - statusLine.height - cards.height
                engine: engine
            }
            Text {
                visible: engine.items.count === 0
                anchors.centerIn: transcript
                horizontalAlignment: Text.AlignHCenter
                text: engine.resume ? "loading" : "frog · " + (engine.model || "starting") + "\n" + Style.home(engine.cwd)
                color: Style.label; font.family: Style.mono; font.pixelSize: Style.value
                lineHeight: 1.4
            }
            Column {
                id: cards
                y: transcript.height
                x: 28; width: parent.width - 56
                Permission { width: parent.width; engine: engine }
                Question { width: parent.width; engine: engine }
                Item { width: 1; height: (engine.permission || engine.question) ? 14 : 0 }
            }
            Composer {
                id: composer
                y: cards.y + cards.height
                width: parent.width
                engine: engine
                onPickModel: picker.show()
                onNewChat: win.newChat()
            }
            // model · mode · context · speed, plain text; a missing value is hidden
            Rectangle {
                id: statusLine
                y: composer.y + composer.height
                width: parent.width; height: 28
                color: Style.bg
                Rectangle { width: parent.width; height: 1; color: Style.line }
                Row {
                    x: 28; anchors.verticalCenter: parent.verticalCenter
                    spacing: 18
                    Text {
                        text: engine.model || "no model"
                        color: mh.hovered ? Style.selInk : Style.text
                        font.family: Style.mono; font.pixelSize: Style.small
                        Rectangle { z: -1; anchors.fill: parent; anchors.margins: -3; color: mh.hovered ? Style.sel : "transparent" }
                        HoverHandler { id: mh; cursorShape: Qt.PointingHandCursor }
                        TapHandler { onTapped: picker.show() }
                    }
                    Text {
                        text: engine.mode.replace("_", " ")
                        color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
                    }
                    Text {
                        readonly property var s: engine.status
                        visible: !!(s && s.context_tokens && s.context_window)
                        text: visible ? Math.round(100 * s.context_tokens / s.context_window) + "% context" : ""
                        color: visible && s.context_tokens / s.context_window > 0.85 ? Style.warn : Style.label
                        font.family: Style.mono; font.pixelSize: Style.small
                    }
                    Text {
                        visible: !!(engine.status && engine.status.tokens_per_sec)
                        text: visible ? Math.round(engine.status.tokens_per_sec) + " tok/s" : ""
                        color: Style.label; font.family: Style.mono; font.pixelSize: Style.small
                    }
                }
                Text {
                    anchors.right: parent.right; anchors.rightMargin: 18; anchors.verticalCenter: parent.verticalCenter
                    text: "ctrl k model   ctrl n new   esc interrupt"
                    color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
                }
            }
        }

        ModelPicker {
            id: picker
            anchors.fill: parent
            engine: engine; library: library
            onClosed: composer.input.forceActiveFocus()
        }
    }

    // the window's content as a PNG (docs, tests): `frog-app --shot PATH`
    function shot(path) {
        root.grabToImage(r => { r.saveToFile(path); console.log("frog: saved " + path); });
    }
}
