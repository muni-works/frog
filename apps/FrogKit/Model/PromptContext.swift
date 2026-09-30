import Foundation

/// Context sent along with a message but not written by you: a block like
/// `<context source="github" label="ecto/ipse#458">…</context>` after the request (the brief
/// writes these, see crates/frog-engine/src/pond/ask.rs). The model reads it all; the
/// transcript shows your request, with each block folded away under it.
struct PromptContext: Identifiable, Equatable {
    let id: Int
    let source: String
    let label: String
    let body: String

    /// "GitHub · ecto/ipse#458".
    var title: String {
        let name = source == "github" ? "GitHub" : source.capitalized
        return label.isEmpty ? name : "\(name) · \(label)"
    }

    /// Your request, and the context blocks after it.
    static func split(_ text: String) -> (message: String, contexts: [PromptContext]) {
        let block = /<context([^>]*)>\n?([\s\S]*?)\n?<\/context>/
        var contexts: [PromptContext] = []
        for (i, m) in text.matches(of: block).enumerated() {
            let attrs = String(m.output.1)
            contexts.append(PromptContext(
                id: i,
                source: attribute("source", in: attrs) ?? "context",
                label: attribute("label", in: attrs) ?? "",
                body: String(m.output.2).replacingOccurrences(of: "&lt;/context", with: "</context")
            ))
        }
        guard !contexts.isEmpty else { return (text, []) }
        let message = text.replacing(block, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (message, contexts)
    }

    private static func attribute(_ name: String, in attrs: String) -> String? {
        guard let m = attrs.firstMatch(of: try! Regex<(Substring, Substring)>("\(name)=\"([^\"]*)\"")) else { return nil }
        return String(m.output.1)
    }
}

extension TurnState {
    /// What you asked, without the context sent along with it.
    var request: String { PromptContext.split(input).message }
}
