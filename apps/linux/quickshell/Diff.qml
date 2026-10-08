import QtQuick

// A FileDiff (frog_engine::protocol): path, then hunks of numbered lines.
// Added lines on a dark green ground, removed on dark red; numbers faint.
Column {
    id: d
    property string json: ""
    property int limit: 400
    readonly property var fd: { try { return JSON.parse(json); } catch (e) { return null; } }
    readonly property var lines: {
        if (!fd) return [];
        const out = [];
        for (let h = 0; h < fd.hunks.length; h++) {
            if (h > 0) out.push({kind: "gap", text: "", n: ""});
            for (const l of fd.hunks[h].lines)
                out.push({kind: l.kind, text: l.text, n: String(l.kind === "remove" ? l.old : (l.new || l.old || ""))});
        }
        return out.slice(0, limit);
    }
    readonly property int hidden: {
        if (!fd) return 0;
        let n = 0;
        for (const h of fd.hunks) n += h.lines.length;
        return Math.max(0, n - lines.length);
    }
    spacing: 0
    Rectangle {
        width: d.width; height: 24
        color: Style.surface
        border.width: 1; border.color: Style.line
        Text {
            x: 10; anchors.verticalCenter: parent.verticalCenter
            width: parent.width - 20; clip: true
            text: d.fd ? Style.home(d.fd.path) + (d.fd.created ? "   new file" : "") : ""
            color: Style.text; font.family: Style.mono; font.pixelSize: Style.small
        }
    }
    Repeater {
        model: d.lines
        delegate: Rectangle {
            required property var modelData
            width: d.width; height: 18
            color: modelData.kind === "add" ? Style.addBg : modelData.kind === "remove" ? Style.delBg : "transparent"
            Text {
                x: 6; width: 40; horizontalAlignment: Text.AlignRight
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.kind === "gap" ? "·" : modelData.n
                color: Style.faint; font.family: Style.mono; font.pixelSize: Style.small
            }
            Text {
                x: 54; anchors.verticalCenter: parent.verticalCenter
                text: modelData.kind === "add" ? "+" : modelData.kind === "remove" ? "−" : " "
                color: modelData.kind === "add" ? Style.ok : Style.fault
                font.family: Style.mono; font.pixelSize: Style.small
            }
            Text {
                x: 68; width: parent.width - 74; clip: true
                anchors.verticalCenter: parent.verticalCenter
                text: modelData.text.replace(/\t/g, "    ")
                color: modelData.kind === "context" ? Style.label : Style.text
                font.family: Style.mono; font.pixelSize: Style.small
            }
        }
    }
    Text {
        visible: d.hidden > 0
        x: 68; topPadding: 4
        text: d.hidden + " more lines"
        color: Style.label; font.family: Style.sans; font.pixelSize: Style.small
    }
    Rectangle { width: d.width; height: 1; color: Style.line }
}
