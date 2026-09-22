import SwiftUI

/// A small regex-based syntax highlighter for code blocks and diffs. Line-oriented (each line is
/// highlighted on its own), which is what diffs need and good enough for answers. Results are
/// cached, since the same lines re-render constantly while text streams.
enum Highlight {
    enum Lang: String {
        case swift, rust, python, js, go, c, shell, json, toml, plain
    }

    static func lang(fence: String) -> Lang {
        switch fence.lowercased() {
        case "swift": .swift
        case "rust", "rs": .rust
        case "python", "py": .python
        case "js", "javascript", "ts", "typescript", "tsx", "jsx": .js
        case "go", "golang": .go
        case "c", "cpp", "c++", "h", "hpp", "objc", "java", "kotlin": .c
        case "sh", "bash", "zsh", "shell", "console": .shell
        case "json": .json
        case "toml", "yaml", "yml", "ini": .toml
        default: .plain
        }
    }

    static func lang(path: String) -> Lang {
        lang(fence: (path as NSString).pathExtension)
    }

    private static let keywords: [Lang: Set<String>] = [
        .swift: ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum", "case", "switch",
                 "for", "in", "while", "import", "private", "public", "static", "self", "Self", "init", "throws",
                 "try", "await", "async", "extension", "protocol", "some", "any", "nil", "true", "false", "where",
                 "@MainActor", "final", "override", "mutating", "inout", "defer", "do", "catch", "break", "continue"],
        .rust: ["fn", "let", "mut", "if", "else", "match", "return", "struct", "enum", "impl", "trait", "for", "in",
                "while", "loop", "use", "mod", "pub", "crate", "self", "Self", "super", "async", "await", "move",
                "where", "const", "static", "type", "as", "ref", "dyn", "true", "false", "Some", "None", "Ok", "Err",
                "break", "continue", "unsafe"],
        .python: ["def", "class", "return", "if", "elif", "else", "for", "in", "while", "import", "from", "as",
                  "with", "try", "except", "finally", "raise", "lambda", "yield", "pass", "break", "continue", "and",
                  "or", "not", "is", "None", "True", "False", "self", "async", "await", "assert", "global"],
        .js: ["function", "const", "let", "var", "if", "else", "return", "class", "extends", "new", "for", "of", "in",
              "while", "import", "export", "from", "default", "async", "await", "try", "catch", "finally", "throw",
              "typeof", "instanceof", "this", "null", "undefined", "true", "false", "interface", "type", "enum",
              "switch", "case", "break", "continue"],
        .go: ["func", "var", "const", "if", "else", "return", "struct", "interface", "type", "for", "range", "go",
              "defer", "package", "import", "map", "chan", "select", "switch", "case", "nil", "true", "false"],
        .c: ["int", "char", "void", "if", "else", "return", "struct", "for", "while", "include", "define", "static",
             "const", "unsigned", "class", "public", "private", "new", "delete", "namespace", "template", "auto",
             "true", "false", "null", "nullptr"],
        .shell: ["if", "then", "else", "fi", "for", "do", "done", "while", "case", "esac", "function", "export",
                 "local", "return", "echo", "cd", "in"],
    ]

    private static let comment: [Lang: String] = [
        .python: "#", .shell: "#", .toml: "#",
    ]

    // Strings, numbers, identifiers, and comments in one pass.
    private static let token = try! NSRegularExpression(
        pattern: #"("(?:[^"\\]|\\.)*"?|'(?:[^'\\]|\\.)*'?|`[^`]*`?)|(\b\d[\d_.xXa-fA-F]*\b)|(@?[A-Za-z_][A-Za-z0-9_]*)|(//.*|#.*|--.*)"#
    )

    struct Palette {
        static let keyword = Color(red: 0.99, green: 0.47, blue: 0.62)
        static let string = Color(red: 0.99, green: 0.75, blue: 0.45)
        static let number = Color(red: 0.72, green: 0.65, blue: 1.0)
        static let type = Color(red: 0.45, green: 0.83, blue: 0.93)
        static let comment = Color(white: 0.5)
        static let call = Color(red: 0.55, green: 0.85, blue: 0.62)
    }

    // NSCache is thread-safe.
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSAttributedString>()

    static func line(_ text: String, _ lang: Lang) -> AttributedString {
        guard lang != .plain, !text.isEmpty else { return AttributedString(text) }
        let key = "\(lang.rawValue)\u{0}\(text)" as NSString
        if let hit = cache.object(forKey: key) {
            return AttributedString(hit)
        }
        var out = AttributedString(text)
        let ns = text as NSString
        let words = keywords[lang] ?? []
        let lineComment = comment[lang] ?? "//"
        for m in token.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: text), let ar = Range(r, in: out) else { continue }
            let s = String(text[r])
            var color: Color?
            if m.range(at: 1).location != NSNotFound {
                color = Palette.string
            } else if m.range(at: 2).location != NSNotFound {
                color = Palette.number
            } else if m.range(at: 4).location != NSNotFound {
                if s.hasPrefix(lineComment) || (lineComment == "//" && s.hasPrefix("//")) {
                    color = Palette.comment
                }
            } else if words.contains(s) {
                color = Palette.keyword
            } else if s.first?.isUppercase == true {
                color = Palette.type
            } else if r.upperBound < text.endIndex, text[r.upperBound] == "(" {
                color = Palette.call
            }
            if let color { out[ar].foregroundColor = color }
            // A comment runs to the end of the line.
            if color == Palette.comment {
                out[ar.lowerBound...].foregroundColor = Palette.comment
                break
            }
        }
        cache.setObject(NSAttributedString(out), forKey: key)
        return out
    }

    static func block(_ text: String, _ lang: Lang) -> AttributedString {
        guard lang != .plain else { return AttributedString(text) }
        var out = AttributedString()
        for (i, l) in text.components(separatedBy: "\n").enumerated() {
            if i > 0 { out += AttributedString("\n") }
            out += line(l, lang)
        }
        return out
    }
}
