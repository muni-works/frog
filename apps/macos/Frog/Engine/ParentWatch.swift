import Foundation

/// Ends a helper process when the app does — including a crash or SIGKILL, where no Swift code
/// runs to stop it. A tiny `/bin/sh` loop outlives the app (it's reparented to launchd), sees
/// the app's pid go, and terminates the helper; it ends on its own when the helper exits first.
/// Used for sidecars that otherwise keep serving, ppid 1, after the app is gone (`tang-llm`
/// for lending). The engine needs none: it exits on stdin EOF. `frog-apple` watches
/// `FROG_APP_PID` itself, and engine-started `tang-llm` gets the same loop from the engine.
enum ParentWatch {
    /// `$1` the parent, `$2` the helper. Polls once a second: kqueue would need a process of
    /// our own, and a second of lag doesn't matter for a sidecar.
    static let script = """
    p=$1 c=$2
    while kill -0 "$c" 2>/dev/null; do
      if ! kill -0 "$p" 2>/dev/null; then
        kill -TERM "$c" 2>/dev/null; sleep 3; kill -KILL "$c" 2>/dev/null; exit 0
      fi
      sleep 1
    done
    """

    /// Watch `child`; it's terminated once `parent` (this app, by default) is gone.
    @discardableResult
    static func watch(child: pid_t, parent: pid_t = getpid()) -> Process? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "frog-parent-watch", String(parent), String(child)]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        return p
    }
}
