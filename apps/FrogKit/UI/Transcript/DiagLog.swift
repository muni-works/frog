#if DEBUG
import Foundation

/// DIAG (probe only, not for main): a ring buffer of the lazy transcript's follow decisions,
/// readable from a watchdog thread while the main thread is stuck.
enum DiagLog {
    nonisolated(unsafe) private static var ring: [String] = []
    nonisolated(unsafe) private static var seq = 0
    private static let lock = NSLock()
    nonisolated static func note(_ s: @autoclosure () -> String) {
        let line = s()
        lock.lock(); defer { lock.unlock() }
        seq += 1
        ring.append("\(seq) \(String(format: "%.4f", ProcessInfo.processInfo.systemUptime)) \(line)")
        if ring.count > 600 { ring.removeFirst(ring.count - 600) }
    }
    nonisolated static func dump() -> String {
        lock.lock(); defer { lock.unlock() }
        return ring.joined(separator: "\n")
    }
    nonisolated static func reset() { lock.lock(); ring = []; lock.unlock() }
}
#endif
