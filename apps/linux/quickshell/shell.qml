// frog for Linux: a native window that speaks `frog --serve`, like the Mac
// app, in muon's Pilot Light. A Quickshell config of its own:
//   qs -p /usr/share/frog/quickshell          (frog-app does this)
//   qs -p /usr/share/frog/quickshell ipc call frog ask "fix the build"
// Env: FROG_BIN (default frog on PATH), FROG_APP_CWD (default ~),
// FROG_APP_RESUME (a session id), FROG_APP_REPLAY (play a recorded session
// instead of a model: preview mode, for screenshots and design work).
import Quickshell
import Quickshell.Io
import QtQuick

ShellRoot {
    FrogWindow {
        id: win
        visible: true
        onVisibleChanged: if (!visible) Qt.quit()
    }
    IpcHandler {
        target: "frog"
        function raise(): void { win.visible = true; }
        function allow(): void { win.engine.allow(false); }
        function deny(): void { win.engine.deny(); }
        function newChat(): void { win.newChat(); }
        function models(): void { win.pickModel(); }
        function ask(text: string): void { win.ask(text); }
        function resume(id: string): void { win.openSession({id: id}); }
        function shot(path: string): void { win.shot(path); }
        function quit(): void { win.engine.stop(); Qt.quit(); }
    }
}
