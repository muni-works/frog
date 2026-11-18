#if DEBUG
import Foundation

/// PROBE only: a fixed ring of numbers from the lazy transcript, formatted only when dumped.
enum DiagLog {
    nonisolated(unsafe) static var declined = 0
    nonisolated(unsafe) static var parks = 0
    struct Entry { var t: Double = 0; var kind: Int = 0; var tag: Int = 0; var v: (Double, Double, Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0, 0, 0) }
    // kind: 1 geo(h, top, visH, below, fol, ansMin, ansMax, parked) 2 park(target-is-first, top) 3 follow-scroll 4 lastTurn-scroll 5 pastEnd
    nonisolated(unsafe) private static var ring = [Entry](repeating: Entry(), count: 2048)
    nonisolated(unsafe) private static var n = 0
    private static let lock = NSLock()
    nonisolated static func note(_ kind: Int, _ tag: AnyObject, _ v: (Double, Double, Double, Double, Double, Double, Double, Double) = (0, 0, 0, 0, 0, 0, 0, 0)) {
        let e = Entry(t: ProcessInfo.processInfo.systemUptime, kind: kind, tag: Int(UInt(bitPattern: ObjectIdentifier(tag).hashValue) % 10000), v: v)
        lock.lock(); ring[n % ring.count] = e; n += 1; lock.unlock()
    }
    nonisolated static func dump(last: Int = 400) -> String {
        lock.lock(); let copy = ring, count = n; lock.unlock()
        let from = max(0, count - min(last, copy.count))
        let names = [1: "geo", 2: "park", 3: "follow", 4: "newturn", 5: "pastEnd"]
        return (from..<count).map { i in
            let e = copy[i % copy.count]
            let v = e.v
            return String(format: "%.4f %@ #%d %.1f %.1f %.1f %.1f %.0f %.1f %.1f %.0f", e.t, names[e.kind] ?? "?", e.tag, v.0, v.1, v.2, v.3, v.4, v.5, v.6, v.7)
        }.joined(separator: "\n")
    }
}
#endif
