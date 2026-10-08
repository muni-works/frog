import Quickshell
import Quickshell.Io
import QtQuick

// What the sidebar and the model picker list: `frog --sessions --all --json`
// and `frog --models --json`, read on demand.
Item {
    id: lib
    readonly property string bin: Quickshell.env("FROG_BIN") || "frog"
    property var sessions: []
    property var models: []
    property bool modelsLoading: false

    function refresh() { sess.running = false; sess.running = true; }
    function loadModels() { modelsLoading = true; mods.running = false; mods.running = true; }

    Process {
        id: sess
        command: [lib.bin, "--sessions", "--all", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const all = JSON.parse(text);
                    all.sort((a, b) => b.modified - a.modified);
                    lib.sessions = all.slice(0, 200);
                } catch (e) { lib.sessions = []; }
            }
        }
    }
    Process {
        id: mods
        command: [lib.bin, "--models", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                lib.modelsLoading = false;
                try { lib.models = JSON.parse(text); } catch (e) { lib.models = []; }
            }
        }
    }
    Component.onCompleted: refresh()
}
