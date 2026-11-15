import Foundation

/// "2m" — the age of a row's last activity. Kept tiny: it sits beside the state glyph.
enum SessionAgeShort {
    static func age(_ date: Date, now: Date = Date()) -> String {
        let s = Int(now.timeIntervalSince(date))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        case ..<(86400 * 7): return "\(s / 86400)d"
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }
}
