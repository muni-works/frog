import Foundation

extension PermissionRequest {
    /// What frog is asking, in one line: the permission card's title, and what the lock screen,
    /// the island, the list, the watch and notifications say.
    var question: String {
        Self.question(name: name, arg: arg, outsideSandbox: reason != nil, creating: preview?.created == true)
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
