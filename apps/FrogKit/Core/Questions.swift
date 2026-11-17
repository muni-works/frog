import Foundation

extension PermissionRequest {
    /// What frog is asking, in one line: the permission card's title, and what the lock screen,
    /// the island, the list, the watch and notifications say.
    var question: String {
        Self.question(name: name, arg: arg, outsideSandbox: reason != nil, creating: preview?.created == true)
    }

    /// Where the step runs, under the card's answers: a Frog Cloud session's sandbox, or this
    /// Mac, and whether the sandbox holds it (a request with a reason is to leave it).
    static func runsWhere(inCloud cloud: Bool, outsideSandbox: Bool) -> String {
        if cloud { return "Runs in your Frog Cloud sandbox" }
        return outsideSandbox ? "Runs on this Mac · outside the sandbox" : "Runs on this Mac · sandboxed"
    }

    static func question(name: String, arg: String, outsideSandbox: Bool = false, creating: Bool = false) -> String {
        let file = (arg as NSString).lastPathComponent
        switch name {
        case "Edit": return "Allow this edit to \(file)?"
        case "Write": return creating ? "Allow creating \(file)?" : "Allow rewriting \(file)?"
        case "Bash": return outsideSandbox ? "Allow this command outside the sandbox?" : "Allow this command?"
        case let n where n.hasPrefix("mcp__"): return "Allow \(ToolIcon.title(n))?"
        case "UseFolder": return "Move this conversation to \(file)?"
        default: return "Allow \(name)?"
        }
    }
}
