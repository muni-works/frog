import Foundation

/// One claim a worker made in its final message (the review-ux convention): a sentence about
/// the world, the command that checks it, and — read-only — the state the card shows. Read-only
/// means frog does not run the check yet (that's step 4): every parsed claim is `pending`, the
/// worker's say-so, with the command it named shown beside it.
struct Claim: Identifiable, Equatable {
    enum State: Equatable {
        /// Claimed, not checked: the signal color's quiet dot.
        case pending
        /// Machine-verified (step 4 and later; never parsed).
        case passed
        /// A check that ran and failed (step 4 and later; never parsed).
        case failed
    }

    /// The sentence about the world: "tests pass", "the app opens without a card".
    var text: String
    /// The command the worker said checks it, when it named one.
    var check: String?
    /// The worker's evidence when it offered some (a test name, a count) — shown under the text.
    var evidence: String?
    var state: State

    var id: String { text + "#" + (check ?? "") }

    init(text: String, check: String? = nil, evidence: String? = nil, state: State = .pending) {
        self.text = text
        self.check = check
        self.evidence = evidence
        self.state = state
    }
}

enum Claims {
    /// The claims a message ends with, or nil when it makes none. Tolerant on purpose: a
    /// worker's final message is prose first, so the block can open with `claims:`, `claims`,
    /// `Claims:`, `**claims**` and continue as a markdown list; the check is named after a `—`
    /// dash, `verify:` / `check:` / `checked by:`, or a `command:` line; anything that doesn't
    /// fit one of those shapes is still a claim (with no check) rather than dropped. `nil` (not
    /// `[]`) when there's no block at all, so a caller can tell "no claims" from "claims, all
    /// dropped" — and never mistake a `claims:` inside a fenced code block for the convention.
    static func parse(_ message: String) -> [Claim]? {
        // Line by line, ignoring fenced code (a claim block inside an example is not one).
        var inFence = false
        var fenceMark = ""
        var lines: [(raw: String, fence: Bool)] = []
        for line in message.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let mark = fenceMarker(trimmed) {
                if !inFence { inFence = true; fenceMark = mark } else if mark == fenceMark { inFence = false }
                lines.append((line, true))
            } else {
                lines.append((line, inFence))
            }
        }

        // The block: the last line that opens a claims list (a later mention in prose stays prose).
        guard let open = lines.lastIndex(where: { opensClaims($0.raw) && !$0.fence }) else { return nil }

        var claims: [Claim] = []
        for (raw, fence) in lines[(open + 1)...] where !fence {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // End the block at prose again: an empty line keeps it open only when claims follow.
            guard isClaimLine(line) else { break }
            guard let (text, check, evidence) = readClaim(line) else { continue }
            if text.isEmpty {
                // A field line ("verify: …") attaches to the claim above it.
                if let last = claims.indices.last {
                    if let check { claims[last].check = claims[last].check ?? check }
                    if let evidence { claims[last].evidence = claims[last].evidence ?? evidence }
                }
            } else {
                claims.append(Claim(text: text, check: check, evidence: evidence))
            }
        }
        // Nothing readable in the block isn't a card.
        return claims.isEmpty ? nil : claims
    }

    /// The claims of a turn's final answer, or nil: the last finished message that parses.
    static func fromTurn(_ turn: TurnState) -> [Claim]? {
        for item in turn.items.reversed() {
            guard item.kind == .message, item.done else { continue }
            if let claims = parse(item.text) { return claims }
        }
        return nil
    }

    // MARK: shapes

    /// A line that opens the block: "claims:", "claims", "**claims:**", "### Claims",
    /// optionally trailing a colon, alone on its line.
    private static func opensClaims(_ line: String) -> Bool {
        var s = line.trimmingCharacters(in: .whitespaces)
        s = s.hasSuffix(":") ? String(s.dropLast()) : s
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "*#` \t"))
        return s.lowercased() == "claims"
    }

    /// A fenced code block's fence, with its mark ("```", "~~~", and an indented ```). A
    /// closer must match its opener, so ` `` ` inside a ``` block stays fenced.
    private static func fenceMarker(_ line: String) -> String? {
        for mark in ["```", "~~~"] where line.hasPrefix(mark) {
            // A fence may name a language (```swift); the mark is its first run.
            return mark
        }
        return nil
    }

    /// `- text`, `* text`, `1. text` — or a field line (`verify:`, `evidence:`, …), which
    /// attaches to the claim above it.
    private static func isClaimLine(_ line: String) -> Bool {
        line.isEmpty || marker(after: line) != nil || isFieldLine(line)
    }

    /// "verify: cargo test", "evidence: 12 passed" — a field of the claim above it, or the
    /// shape "claims:\n- the app opens\n  verify: open -a Frog" with its field indented under.
    private static func isFieldLine(_ line: String) -> Bool {
        for name in ["checked by:", "verified by:", "verify:", "check:", "command:", "evidence:", "note:"] {
            if line.lowercased().hasPrefix(name) { return true }
        }
        return false
    }

    /// The claim text past the list marker, when there is one.
    private static func marker(after line: String) -> Substring? {
        if line.hasPrefix("-") || line.hasPrefix("*") { return line.dropFirst() }
        // "1." or "1)" numbered lists.
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count <= 2,
           let next = line.dropFirst(digits.count).first, next == "." || next == ")" {
            return line.dropFirst(digits.count + 1)
        }
        return nil
    }

    /// One claim line's pieces: the sentence, and its check in whatever shape it came.
    /// Known shapes — "text — verify: cmd", "text (verify: cmd)", "text :: cmd", "text — cmd",
    /// "text", and a whole-line field ("verify: …", "evidence: …") that attaches to the claim
    /// above it. Anything unparseable is dropped (an empty text); a prose dash stays prose.
    private static func readClaim(_ line: String) -> (text: String, check: String?, evidence: String?)? {
        var rest = line
        if let after = marker(after: rest) { rest = after.trimmingCharacters(in: .whitespaces) }
        guard !rest.isEmpty else { return nil }

        // A "field:" lead names what follows ("verified by:", "check:", "evidence:", "note:").
        func field(_ names: [String]) -> (name: String, value: String)? {
            for name in names {
                let lower = rest.lowercased()
                if lower.hasPrefix("\(name):") {
                    return (name, String(rest.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces))
                }
            }
            return nil
        }

        // A whole-line field names what follows; its text may have come from the line before
        // (the fields attach the other way — "text:" then "verify: …"), so an empty text here
        // means "this line is a field of the claim above" and parse() folds it in.
        if let f = field(["checked by", "verified by", "verify", "check", "command"]) {
            return ("", f.value, nil)
        } else if let f = field(["evidence"]) {
            return ("", nil, f.value)
        } else if let f = field(["note"]) {
            return (f.value, nil, nil)
        }

        // "text — verify: cmd" / "text (verify: cmd)" / "text :: cmd".
        for (lead, tag) in [("—", "verify"), ("(", "verify"), ("::", nil)] {
            guard let range = rest.range(of: lead) else { continue }
            let head = rest[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = rest[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if head.isEmpty { continue }
            if let tag {
                // The tag must lead the tail ("— verify: x", "(verify: x)"); else it's just prose.
                let lower = tail.lowercased()
                for f in ["verify:", "check:", "checked by:", "verified by:"] where lower.hasPrefix(f) {
                    var cmd = String(tail.dropFirst(f.count)).trimmingCharacters(in: .whitespaces)
                    // "(verify: x)" closes with its paren.
                    if lead == "(", cmd.hasSuffix(")") { cmd = String(cmd.dropLast()) }
                    return (head, cmd.isEmpty ? nil : cmd, nil)
                }
                if tag == "verify", lower.hasPrefix("command:") {
                    let cmd = String(tail.dropFirst("command:".count)).trimmingCharacters(in: .whitespaces)
                    return (head, cmd.isEmpty ? nil : cmd, nil)
                }
                continue
            }
            // A bare "::": whatever follows is the check.
            return (head, tail.isEmpty ? nil : tail, nil)
        }
        // A bare dash ("text — cmd"): the tail is the check only when it looks like a command
        // (starts with a known runner); otherwise the dash is prose, part of the sentence.
        if let range = rest.range(of: "—") {
            let head = rest[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            let tail = rest[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty {
                let lower = tail.lowercased()
                let looksLikeCommand = ["cargo", "xcodebuild", "swift", "swiftc", "npm", "pytest", "python",
                                        "go", "make", "bazel", "just", "grep", "git", "ls", "curl", "bash", "sh",
                                        "./", "/usr", "/bin", "toys.", "frog"].contains { lower.hasPrefix($0) }
                if looksLikeCommand, !tail.isEmpty {
                    return (head, tail, nil)
                }
                // Prose dash ("— and it costs nothing"): the sentence keeps its dash and tail.
                return (rest, nil, nil)
            }
        }
        return (rest, nil, nil)
    }
}
