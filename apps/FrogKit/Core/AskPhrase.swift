import Foundation

/// A permission request as one short question a person reads at a glance — the row's second
/// line under the "needs you" dot: "Run cargo test?", "Edit fetch.ts?", never "Can I bash…".
/// The web's twin is `askLine` in apps/web/src/ui/ask.ts.
enum AskPhrase {
    static func line(name: String, arg: String) -> String {
        let first = arg.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let file = (first as NSString).lastPathComponent
        switch name {
        case "Bash", "Shell": return first.isEmpty ? "Run a command?" : "Run \(first)?"
        case "Edit", "MultiEdit": return first.isEmpty ? "Edit a file?" : "Edit \(file)?"
        case "Write": return first.isEmpty ? "Write a file?" : "Write \(file)?"
        case "Read": return first.isEmpty ? "Read a file?" : "Read \(file)?"
        case "WebFetch":
            let host = URL(string: first)?.host ?? first
            return host.isEmpty ? "Open a web page?" : "Open \(host)?"
        default: return first.isEmpty ? "Allow \(name)?" : "Allow \(name) \(first)?"
        }
    }
}
