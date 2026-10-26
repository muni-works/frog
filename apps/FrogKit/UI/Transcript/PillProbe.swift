#if DEBUG
import Foundation

/// The A/B knobs for the activity pill's churn benchmark: DEBUG builds only, never shipped
/// behavior. They reuse the states the views already have for Reduce Motion — `noFrog` holds
/// the frog's pose (`animating: false`), `noSweep` pauses the working line's 60/s timeline.
@MainActor
enum PillChurn {
    static var noFrog: Bool { UserDefaults.standard.bool(forKey: "pillChurn.noFrog") }
    static var noSweep: Bool { UserDefaults.standard.bool(forKey: "pillChurn.noSweep") }
}

/// Counters for the activity pill's churn benchmark (`PillChurnBenchmarkTests`): how often the
/// glass capsule's pieces re-evaluate while a turn runs — the playful frog at 30 a second, the
/// working line's sweep at 60, the elapsed clock at 1. A body that runs once per distinctive
/// state is idle; one that runs every frame is churn. Counted in the code (`#98`'s
/// `TranscriptProbe` pattern), not by grepping a render export: strings dedupe by ref there,
/// so a grep undercounts. Debug builds only.
@MainActor
enum PillProbe {
    /// `ActivityViewer` bodies built (the glass capsule's layout).
    static var viewerBodies = 0
    /// `FrogFace` bodies built in the pill (one per pose; 30 a second while it animates).
    static var frogBodies = 0
    /// `WorkingLine` bodies built (the sweep; 60 a second while it animates).
    static var lineBodies = 0
    /// `ActivityLabel` bodies built (the pill's words and icon layout).
    static var labelBodies = 0
    /// `ActivityLabel`'s periodic clock ticks (the honest 1 Hz elapsed timer).
    static var clockTicks = 0

    static func reset() {
        viewerBodies = 0
        frogBodies = 0
        lineBodies = 0
        labelBodies = 0
        clockTicks = 0
    }

    /// Inside a view builder: `let _ = PillProbe.viewer()`.
    @discardableResult static func viewer() -> Int { viewerBodies += 1; return viewerBodies }
    @discardableResult static func frog() -> Int { frogBodies += 1; return frogBodies }
    @discardableResult static func line() -> Int { lineBodies += 1; return lineBodies }
    @discardableResult static func label() -> Int { labelBodies += 1; return labelBodies }
    @discardableResult static func tick() -> Int { clockTicks += 1; return clockTicks }
}
#endif
