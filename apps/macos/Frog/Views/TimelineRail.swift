import SwiftUI

/// The conversation as a strip: one tick per turn, top to bottom, as long as the turn did work
/// and colored by how it ended. The turns on screen sit in a lit window. Hover to see a turn's
/// prompt, click or drag to scrub the transcript to it, right-click to fork or rewind there.
struct TimelineRail: View {
    let conversation: Conversation
    let visible: Set<TurnState.ID>
    /// Turns to call out (find matches): drawn with a marker beside the tick.
    var marked: Set<TurnState.ID> = []
    let actions: TurnActions
    let jump: (TurnState.ID) -> Void

    static let width: CGFloat = 28

    @State private var hovered: Int?
    @State private var scrubbed: Int?
    @State private var confirmRewind: UInt64?

    private var turns: [TurnState] { conversation.turns }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                if let i = hovered, turns.indices.contains(i) {
                    // Hangs off the rail's leading edge, over the transcript.
                    label(turns[i])
                        .fixedSize()
                        .frame(width: 0, alignment: .trailing)
                        .offset(x: -8, y: y(of: i, in: h) - 13)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hovered = index(at: p.y, in: h)
                case .ended: hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    guard let i = index(at: g.location.y, in: h) else { return }
                    // A detent under the finger for each turn crossed while scrubbing.
                    if i != scrubbed { Haptics.tick() }
                    scrubbed = i
                    hovered = i
                    jump(turns[i].id)
                }
                .onEnded { _ in scrubbed = nil }
            )
            .contextMenu { menu }
        }
        .frame(width: Self.width)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .confirmationDialog(
            "Rewind to before this turn?",
            isPresented: Binding(get: { confirmRewind != nil }, set: { if !$0 { confirmRewind = nil } })
        ) {
            Button("Rewind", role: .destructive) {
                if let n = confirmRewind { actions.rewind?(n) }
            }
        } message: {
            Text("Files frog edited in this turn and later go back to how they were, and the conversation continues on a new branch from here. The current session is kept.")
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline, \(turns.count) turns")
    }

    // MARK: Geometry

    private let pad: CGFloat = 12

    private func y(of i: Int, in h: CGFloat) -> CGFloat {
        guard turns.count > 1 else { return h / 2 }
        return pad + (h - 2 * pad) * CGFloat(i) / CGFloat(turns.count - 1)
    }

    private func index(at y: CGFloat, in h: CGFloat) -> Int? {
        guard !turns.isEmpty else { return nil }
        guard turns.count > 1 else { return 0 }
        let t = (y - pad) / max(1, h - 2 * pad)
        return min(turns.count - 1, max(0, Int((t * CGFloat(turns.count - 1)).rounded())))
    }

    // MARK: Drawing

    /// How much a turn did: steps, plus changed files counting double.
    private func weight(_ t: TurnState) -> Double {
        Double(t.items.count) + 2 * Double(TurnParts(t).changes.count)
    }

    private func color(_ t: TurnState) -> Color {
        switch t.end {
        case nil: .accentColor
        case .error: .red
        case .looping, .stepLimit, .maxTokens: .orange
        case .cancelled: .secondary
        default: TurnParts(t).changes.isEmpty ? .primary : .green
        }
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard !turns.isEmpty else { return }
        let h = size.height
        let maxW = max(1, turns.map(weight).max() ?? 1)

        // The window of turns on screen.
        let shown = turns.indices.filter { visible.contains(turns[$0].id) }
        if let lo = shown.min(), let hi = shown.max() {
            let top = y(of: lo, in: h) - 6, bottom = y(of: hi, in: h) + 6
            ctx.fill(
                Path(roundedRect: CGRect(x: 4, y: top, width: size.width - 8, height: bottom - top), cornerRadius: 6),
                with: .color(.primary.opacity(0.10))
            )
        }
        for (i, t) in turns.enumerated() {
            let len = 5 + (size.width - 14) * CGFloat(weight(t) / maxW)
            let rect = CGRect(x: (size.width - len) / 2, y: y(of: i, in: h) - 1.25, width: len, height: 2.5)
            let lit = visible.contains(t.id) || hovered == i
            ctx.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(color(t).opacity(lit ? 0.95 : 0.45)))
            if marked.contains(t.id) {
                let dot = CGRect(x: 3, y: y(of: i, in: h) - 2.5, width: 5, height: 5)
                ctx.fill(Path(ellipseIn: dot), with: .color(.yellow))
            }
        }
    }

    // MARK: Hover label and menu

    private func label(_ t: TurnState) -> some View {
        HStack(spacing: 6) {
            if let n = t.number { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
            Text(t.input.isEmpty ? "(no prompt)" : t.input)
                .lineLimit(1)
                .frame(maxWidth: 260, alignment: .leading)
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .glassEffect(.regular, in: .capsule)
    }

    @ViewBuilder
    private var menu: some View {
        if let i = hovered, turns.indices.contains(i) {
            let t = turns[i]
            Button("Show Turn") { jump(t.id) }
            if let n = t.number, t.finished, !conversation.busy {
                Divider()
                Button("Fork After This Turn", systemImage: "arrow.triangle.branch") { actions.fork?(n) }
                Button("Rewind to Before This Turn…", systemImage: "arrow.uturn.backward") { confirmRewind = n }
            }
        }
    }
}
