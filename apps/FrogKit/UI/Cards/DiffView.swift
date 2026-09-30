import SwiftUI

/// A file's change, highlighted, with old and new line numbers: the same in a turn, a question,
/// and a notification.
struct DiffView: View {
    let diff: FileDiff
    var maxLines: Int = .max

    private var lines: [(hunk: Int, line: DiffLine)] {
        diff.hunks.enumerated().flatMap { h, hunk in hunk.lines.map { (h, $0) } }
    }

    var body: some View {
        let all = lines
        let shown = all.prefix(maxLines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: diff.created ? "doc.badge.plus" : "doc")
                Text(diff.path).font(.caption.weight(.medium))
                Spacer()
                Text("+\(diff.added)").foregroundStyle(.green)
                Text("−\(diff.removed)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider().opacity(0.5)
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, entry in
                        if i > 0, shown[shown.startIndex + i - 1].hunk != entry.hunk {
                            Text("⋯").font(.caption).foregroundStyle(.tertiary).padding(.leading, 60).padding(.vertical, 2)
                        }
                        DiffLineView(line: entry.line, lang: Highlight.lang(path: diff.path))
                    }
                    if all.count > shown.count {
                        Text("\(all.count - shown.count) more lines")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    }
                }
            }
        }
        .background(.background.opacity(0.6))
        .clipShape(.rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

struct DiffLineView: View {
    let line: DiffLine
    var lang: Highlight.Lang = .plain

    var body: some View {
        HStack(spacing: 0) {
            Text(line.old.map(String.init) ?? "")
                .frame(width: 32, alignment: .trailing)
            Text(line.new.map(String.init) ?? "")
                .frame(width: 32, alignment: .trailing)
            Text(sign)
                .frame(width: 20)
                .foregroundStyle(tint)
            Text(Highlight.line(line.text, lang))
                .foregroundStyle(.primary)
                .fixedSize()
                .padding(.trailing, 12)
        }
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(line.kind == .context ? 0 : 0.12))
    }

    private var sign: String {
        switch line.kind {
        case .add: "+"
        case .remove: "−"
        case .context: ""
        }
    }

    private var tint: Color {
        switch line.kind {
        case .add: .green
        case .remove: .red
        case .context: .clear
        }
    }
}
