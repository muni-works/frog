pragma Singleton
import Quickshell
import Quickshell.Io
import QtQuick

// Pilot Light (muon docs/design.md; branding/theme/palette.toml), the same
// roles narc's prompt uses, plus one colour of frog's own: mint, the
// agent's voice. Orange only on the focus path: the selected row or button
// and the caret. Square corners, hairlines, no ellipses (text clips).
Singleton {
    id: root
    readonly property color bg: "#0b0907"
    readonly property color surface: "#15110d"
    readonly property color raised: "#1e1813"
    readonly property color line: "#2a2119"
    readonly property color lineHi: "#4a3a2a"
    readonly property color text: "#e8e1d2"
    readonly property color label: "#a08d70"
    readonly property color faint: "#6b5a44"
    readonly property color sel: "#ff6a00"
    readonly property color selInk: "#000000"
    readonly property color caret: "#ff8a1f"
    readonly property color ok: "#4fd88a"
    readonly property color warn: "#e9c84a"
    readonly property color fault: "#ff5a4a"
    readonly property color info: "#4cc8e0"
    readonly property color kw: "#b08ad8"
    readonly property color scrim: "#b30b0907"
    // frog's voice: what the agent says, and its mark
    readonly property color mint: "#7ce6a6"
    readonly property color addBg: "#14271b"
    readonly property color delBg: "#2c1512"

    property string mono: "Berkeley Mono"   // fontconfig answers IBM Plex Mono without it
    property string sans: "IBM Plex Sans"
    readonly property int small: 12
    readonly property int body: 14
    readonly property int value: 13
    readonly property real track: 1.4        // tracked caps, structure only
    readonly property int fadeMs: 80

    FileView {
        path: "/etc/muon/fonts.env"
        onLoaded: {
            for (const line of text().split("\n")) {
                const m = /^\s*(MUON_FONT_MONO|MUON_FONT_SANS)\s*=\s*"?([^"#]*?)"?\s*$/.exec(line);
                if (!m || !m[2]) continue;
                if (m[1] === "MUON_FONT_MONO") root.mono = m[2]; else root.sans = m[2];
            }
        }
    }

    // 3s, 4m, 2h, 5d
    function ago(ms) {
        const s = Math.max(0, Math.round((Date.now() - ms) / 1000));
        return s < 60 ? s + "s" : s < 3600 ? Math.floor(s / 60) + "m"
             : s < 86400 ? Math.floor(s / 3600) + "h" : Math.floor(s / 86400) + "d";
    }
    function base(p) { return (p || "").replace(/\/+$/, "").replace(/^.*\//, "") || "/"; }
    function home(p) {
        const h = Quickshell.env("HOME") || "";
        return h && (p || "").indexOf(h) === 0 ? "~" + p.slice(h.length) : (p || "");
    }
    // tool output may carry ANSI colour
    function plain(s) { return (s || "").replace(/\x1b\[[0-9;?]*[ -\/]*[@-~]/g, "").replace(/\x1b\][^\x07]*\x07/g, ""); }
    function firstLine(s) { const t = (s || "").trim(); const i = t.indexOf("\n"); return i < 0 ? t : t.slice(0, i); }
}
