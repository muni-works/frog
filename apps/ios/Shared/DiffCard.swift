import SwiftUI

extension FileDiff: Identifiable {
    public var id: String { path }
}

/// A file's change: its name and counts, then the lines with a gutter of line numbers.
struct DiffCard: View {
    let diff: FileDiff
    let limit: Int
    var framed = true

    var body: some View {
        let lines = diff.hunks.flatMap(\.lines)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: diff.created ? "doc.badge.plus" : "doc.text")
                    .foregroundStyle(diff.created ? .green : .secondary)
                Text((diff.path as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                Spacer(minLength: 4)
                Text("+\(diff.added)").foregroundStyle(.green)
                Text("−\(diff.removed)").foregroundStyle(.red)
            }
            .font(.caption.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, l in
                HStack(spacing: 0) {
                    Text(l.new.map(String.init) ?? l.old.map(String.init) ?? "")
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, alignment: .trailing)
                        .padding(.trailing, 6)
                    Text(Self.mark(l)).foregroundStyle(Self.markColor(l)).frame(width: 12)
                    Text(l.text).lineLimit(framed ? 1 : nil).fixedSize(horizontal: !framed, vertical: false)
                    Spacer(minLength: 0)
                }
                .font(.caption2.monospaced())
                .padding(.vertical, 1)
                .background(Self.tint(l))
            }
            if lines.count > limit {
                Text("\(lines.count - limit) more lines")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                Spacer().frame(height: 6)
            }
        }
        .background(framed ? Color(.secondarySystemBackground) : .clear, in: .rect(cornerRadius: 14))
        .overlay {
            if framed { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 0.5) }
        }
    }

    private static func mark(_ l: DiffLine) -> String {
        switch l.kind {
        case .add: "+"
        case .remove: "−"
        default: " "
        }
    }

    private static func markColor(_ l: DiffLine) -> Color {
        switch l.kind {
        case .add: .green
        case .remove: .red
        default: .clear
        }
    }

    private static func tint(_ l: DiffLine) -> Color {
        switch l.kind {
        case .add: .green.opacity(0.13)
        case .remove: .red.opacity(0.13)
        default: .clear
        }
    }
}
