import Foundation

/// A tool's SF Symbol and display name, the same on every screen.
enum ToolIcon {
    static func symbol(_ name: String) -> String {
        switch name {
        case "Bash", "!": "terminal"
        case "Read": "doc.text"
        case "Write": "doc.badge.plus"
        case "Edit": "pencil.line"
        case "Glob": "folder.badge.questionmark"
        case "Grep": "text.magnifyingglass"
        case "TodoWrite": "checklist"
        case "Image": "photo"
        case "Screenshot": "camera.viewfinder"
        case "Compare": "square.split.2x1"
        case "Diagram": "point.3.connected.trianglepath.dotted"
        case "Visualize": "chart.xyaxis.line"
        case "VisualGuide": "book.pages"
        case "Present": "tablecells"
        case "Ask": "questionmark.bubble"
        case "CodeMap": "map"
        case "WebFetch": "globe"
        case "WebSearch": "magnifyingglass.circle"
        case "Docs": "book"
        case "Models": "cpu"
        case "Task": "person.2"
        case "Skill": "sparkles.rectangle.stack"
        case "Recall": "clock.arrow.circlepath"
        case "UseFolder": "folder"
        case "McpTools": "puzzlepiece.extension"
        case let n where n.hasPrefix("mcp__desktop__"): "macwindow.and.cursorarrow"
        case let n where n.hasPrefix("mcp__"): "puzzlepiece.extension"
        default: "wrench.and.screwdriver"
        }
    }

    /// `mcp__github__list_issues` reads as `github › list_issues`.
    static func title(_ name: String) -> String {
        if name == "!" { return "Shell" }
        if name == "Task" { return "Subagent" }
        guard name.hasPrefix("mcp__") else { return name }
        let parts = name.dropFirst(5).components(separatedBy: "__")
        return parts.count >= 2 ? "\(parts[0]) › \(parts.dropFirst().joined(separator: "__"))" : String(name.dropFirst(5))
    }
}
