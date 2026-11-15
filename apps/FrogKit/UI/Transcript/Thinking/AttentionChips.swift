import SwiftUI

/// Small monospace chips for the files and pages a turn read — `TurnView.swift`, `example.com`
/// — shown in an expanded thinking trace. The one being read now is highlighted green with a
/// thin progress bar while its step runs. A file read twice is one chip; a long list wraps.
struct AttentionChips: View {
    let chips: [ThinkingStep.Attention]
    /// The chip to highlight: what the live step is reading now.
    var active: ThinkingStep.Attention?
    /// The live step's progress, 0…1, for the highlighted chip's bar.
    var progress: Double?

    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(chips, id: \.detail) { chip in
                AttentionChip(chip: chip, active: chip == active, progress: progress)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Read " + chips.map(\.label).joined(separator: ", "))
    }
}

/// Wraps its children onto as many lines as needed, left-aligned — a chip cloud.
struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x - spacing : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// One chip: a small monospace capsule, green with a thin progress bar when it's the one being
/// read now.
struct AttentionChip: View {
    let chip: ThinkingStep.Attention
    var active: Bool
    var progress: Double?

    var body: some View {
        Text(chip.label)
            .font(.frog(size: 10.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(active ? Color.frog.opacity(0.16) : Color.secondary.opacity(0.12), in: .capsule)
            .overlay(alignment: .bottom) {
                if active {
                    GeometryReader { geo in
                        Capsule()
                            .fill(Color.frog.opacity(0.6))
                            .frame(width: geo.size.width * fraction)
                            .offset(y: 0)
                    }
                    .frame(height: 2)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if active {
                    Capsule().strokeBorder(Color.frog.opacity(0.5), lineWidth: 0.5)
                }
            }
            .foregroundStyle(active ? Color.frog : Color.secondary)
            .help(chip.detail)
    }

    private var fraction: CGFloat {
        guard let progress else { return 1 }
        return CGFloat(min(max(progress, 0), 1))
    }
}
