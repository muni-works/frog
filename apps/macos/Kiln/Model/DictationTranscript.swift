import Foundation

/// What's been said so far: text the recognizer has settled on, and a guess at the latest words
/// that it may still revise. Pure, so the composer's handling of dictation is testable without a
/// microphone.
struct DictationTranscript: Equatable {
    /// Settled text, in order.
    private(set) var finalized = ""
    /// The latest guess; replaced by each new result until one comes back final.
    private(set) var volatile = ""

    /// Take one recognizer result. A final one settles its words and clears the guess.
    mutating func apply(_ text: String, isFinal: Bool) {
        if isFinal {
            finalized = Self.join(finalized, text)
            volatile = ""
        } else {
            volatile = text
        }
    }

    /// The settled part and the guess as they read in the field: one space between words, no
    /// stray spaces at the ends.
    var parts: (final: String, volatile: String) {
        let final = Self.join("", finalized)
        let joined = Self.join(final, volatile)
        return (final, String(joined.dropFirst(final.count)))
    }

    /// Two runs of text with exactly one space between them (none if either is empty).
    static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    /// Spaces to put around dictated text so it doesn't run into what's on either side of it.
    static func padding(before: unichar?, after: unichar?, empty: Bool) -> (lead: String, trail: String) {
        guard !empty else { return ("", "") }
        func isSpace(_ c: unichar?) -> Bool {
            guard let c, let scalar = Unicode.Scalar(c) else { return true }
            return CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        return (isSpace(before) ? "" : " ", isSpace(after) ? "" : " ")
    }

    /// Where dictated text sits after someone edits the field: shifted when the edit is wholly
    /// before or after it, nil when the edit touches it (the person has taken over).
    static func shift(_ range: NSRange, byEdit edit: NSRange, replacement: Int) -> NSRange? {
        if edit.location + edit.length <= range.location {
            return NSRange(location: range.location + replacement - edit.length, length: range.length)
        }
        if edit.location >= range.location + range.length {
            return range
        }
        return nil
    }
}
