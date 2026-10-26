import SwiftUI

/// The conversation as a line, top to bottom: a dot where each chapter starts (solid for your
/// prompts, hollow for an autonomous run, a gap where it was summarized), a soft thumb over the
/// turns on screen, and color only on a turn that needs you (failed, stopped, running). Hover to see a turn's
/// prompt, click or drag to scrub the transcript to it, right-click to fork or rewind there.
struct TimelineRail: View {
    let conversation: Conversation
    let visible: Set<TurnState.ID>
    /// Turns to call out (find matches): drawn with a marker beside the tick.
    var marked: Set<TurnState.ID> = []
    /// Turns with a preview screenshot: badged with a camera, and comparable in the preview.
    var checkpoints: Set<UInt64> = []
    /// Free width beside the rail (between the transcript's column and it): chapter names
    /// show there when there's enough of it.
    var labelRoom: CGFloat = 0
    let actions: TurnActions
    let jump: (TurnState.ID) -> Void

    static let width: CGFloat = 28

    @State private var hovered: Int?
    @State private var scrubbed: Int?
    @State private var confirmRewind: UInt64?

    private var turns: [TurnState] { conversation.turns }

    /// Where the chapters start (see `Chapter`), as turn indices, and the one on screen.
    private var chapters: [Chapter] { Chapter.cached(turns).chapters }
    private var chapterStarts: [Int] { Chapter.cached(turns).starts }
    private var chapterTitles: [String] { Chapter.cached(turns).titles }

    /// The chapter dots drawn, as (chapter, y): each clear of the last by `gap`, and the
    /// current chapter always.
    private func landmarks(in h: CGFloat, gap: CGFloat, current: Int?) -> [(chapter: Int, y: CGFloat)] {
        var out: [(chapter: Int, y: CGFloat)] = []
        var last = -CGFloat.infinity
        for (c, start) in chapterStarts.enumerated() {
            let y = y(of: start, in: h)
            guard c == current || y - last >= gap else { continue }
            if c == current, let prev = out.last, y - prev.y < gap, prev.chapter != current { out.removeLast() }
            last = y
            out.append((c, y))
        }
        return out
    }

    /// The rail's height for a conversation: by its chapters, not its turns, so a long session
    /// is a short list of topics rather than a wall of ticks.
    @MainActor static func height(for turns: [TurnState], room: CGFloat) -> CGFloat {
        let n = CGFloat(max(1, Chapter.cached(turns).chapters.count))
        return min(room, 360, n * 18 + 28)
    }

    private func currentChapter(_ starts: [Int]) -> Int? {
        guard let lo = turns.firstIndex(where: { visible.contains($0.id) }) else { return nil }
        return Chapter.index(of: lo, in: starts)
    }

    private var accessibility: String {
        var label = "Timeline, \(turns.count) turns"
        if let c = turns.firstIndex(where: { visible.contains($0.id) }),
           let ch = Chapter.index(of: c, in: chapterStarts) {
            label += ", in chapter \(ch + 1) of \(chapters.count)"
        }
        return label
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in draw(ctx, size) }
                if labelRoom >= 90 {
                    labels(in: h)
                }
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
        .accessibilityLabel(accessibility)
    }

    // MARK: Geometry

    private let pad: CGFloat = 12

    /// Where turn `i` sits: each chapter gets an equal share of the rail and its turns share
    /// that, so an autonomous stretch of 200 turns is as tall as a one-turn question.
    private func y(of i: Int, in h: CGFloat) -> CGFloat {
        guard turns.count > 1 else { return h / 2 }
        let starts = chapterStarts
        guard !starts.isEmpty, let c = Chapter.index(of: i, in: starts) else {
            return pad + (h - 2 * pad) * CGFloat(i) / CGFloat(turns.count - 1)
        }
        let end = c + 1 < starts.count ? starts[c + 1] : turns.count
        let within = CGFloat(i - starts[c]) / CGFloat(max(1, end - starts[c]))
        let t = (CGFloat(c) + within) / CGFloat(starts.count)
        return pad + (h - 2 * pad) * t
    }

    private func index(at y: CGFloat, in h: CGFloat) -> Int? {
        guard !turns.isEmpty else { return nil }
        guard turns.count > 1 else { return 0 }
        let starts = chapterStarts
        let t = min(1, max(0, (y - pad) / max(1, h - 2 * pad)))
        guard !starts.isEmpty else { return min(turns.count - 1, Int((t * CGFloat(turns.count - 1)).rounded())) }
        let slot = t * CGFloat(starts.count)
        let c = min(starts.count - 1, Int(slot))
        let end = c + 1 < starts.count ? starts[c + 1] : turns.count
        let i = starts[c] + Int((slot - CGFloat(c)) * CGFloat(end - starts[c]))
        return min(turns.count - 1, max(0, i))
    }

    // MARK: Drawing

    /// A turn's mark when it needs one: how it went wrong, or that it's running. Everything
    /// else is quiet; the chapters carry the shape of the conversation.
    private func signal(_ t: TurnState) -> Color? {
        switch t.end {
        case nil: conversation.busy ? .accentColor : nil
        case .error: .red
        case .looping, .stepLimit, .maxTokens: .orange
        default: nil
        }
    }

    /// One vocabulary, dots on a line: a hairline for the conversation, a soft thumb over the
    /// turns on screen, a dot per chapter, and color only where a turn needs you.
    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        guard !turns.isEmpty else { return }
        let h = size.height
        let mid = size.width / 2

        ctx.fill(Path(CGRect(x: mid - 0.5, y: pad, width: 1, height: max(0, h - 2 * pad))),
                 with: .color(.primary.opacity(0.14)))

        // The window of turns on screen.
        if let lo = turns.firstIndex(where: { visible.contains($0.id) }),
           let hi = turns.lastIndex(where: { visible.contains($0.id) }) {
            let top = y(of: lo, in: h) - 7, bottom = y(of: hi, in: h) + 7
            ctx.fill(Path(roundedRect: CGRect(x: mid - 6, y: top, width: 12, height: bottom - top), cornerRadius: 6),
                     with: .color(.primary.opacity(0.09)))
        }

        let chapters = self.chapters
        let current = currentChapter(chapterStarts)
        // A long session has more chapters than the rail has room for: a dot only where it
        // stands clear of the last one drawn (the one you're in always shows), so the line
        // reads as a few landmarks rather than a solid bar.
        for (c, y) in landmarks(in: h, gap: 7, current: current) {
            let here = c == current
            switch chapters[c].kind {
            case .compacted:
                // The summarized break: the line steps out for a moment.
                ctx.fill(Path(CGRect(x: mid - 1, y: y - 3, width: 2, height: 6)),
                         with: .color(Color(nsColor: .windowBackgroundColor)))
                ctx.fill(Path(CGRect(x: mid - 4, y: y - 3.5, width: 8, height: 1)), with: .color(.secondary.opacity(0.5)))
                ctx.fill(Path(CGRect(x: mid - 4, y: y + 2.5, width: 8, height: 1)), with: .color(.secondary.opacity(0.5)))
            case .run:
                let r: CGFloat = here ? 3 : 2.25
                ctx.stroke(Path(ellipseIn: CGRect(x: mid - r, y: y - r, width: 2 * r, height: 2 * r)),
                           with: .color(.primary.opacity(here ? 0.7 : 0.35)), lineWidth: 1)
            case .prompt:
                let r: CGFloat = here ? 3.5 : 2.5
                ctx.fill(Path(ellipseIn: CGRect(x: mid - r, y: y - r, width: 2 * r, height: 2 * r)),
                         with: .color(.primary.opacity(here ? 0.85 : 0.4)))
            }
        }

        for (i, t) in turns.enumerated() {
            let y = y(of: i, in: h)
            if let color = signal(t) {
                ctx.fill(Path(ellipseIn: CGRect(x: mid - 2, y: y - 2, width: 4, height: 4)), with: .color(color))
            }
            if hovered == i {
                ctx.stroke(Path(ellipseIn: CGRect(x: mid - 5, y: y - 5, width: 10, height: 10)),
                           with: .color(.primary.opacity(0.6)), lineWidth: 1)
            }
            if marked.contains(t.id) {
                ctx.fill(Path(ellipseIn: CGRect(x: 3, y: y - 2.5, width: 5, height: 5)), with: .color(.yellow))
            }
            if let n = t.number, checkpoints.contains(n) {
                var image = ctx.resolve(Image(systemName: "camera.fill"))
                image.shading = .color(.secondary)
                ctx.draw(image, in: CGRect(x: size.width - 10, y: y - 4, width: 8, height: 8))
            }
        }
    }

    // MARK: Hover label and menu

    /// Chapter names beside their dots, where there's height between them for a line.
    private func labels(in h: CGFloat) -> some View {
        let current = currentChapter(chapterStarts)
        let titles = chapterTitles
        return ForEach(landmarks(in: h, gap: 18, current: current), id: \.chapter) { mark in
            Text(titles[mark.chapter])
                .font(.caption)
                .foregroundStyle(mark.chapter == current ? .primary : .tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: min(labelRoom, 180) - 8, alignment: .trailing)
                .frame(width: 0, alignment: .trailing)
                .offset(x: -6, y: mark.y - 8)
                .allowsHitTesting(false)
                .opacity(hovered == nil ? 1 : 0.35)
        }
    }

    private func label(_ t: TurnState) -> some View {
        HStack(spacing: 6) {
            if let i = turns.firstIndex(where: { $0.id == t.id }),
               let c = Chapter.index(of: i, in: chapterStarts), chapters[c].turn == t.id {
                Text(chapterTitles[c])
                    .foregroundStyle(.secondary)
            }
            if let n = t.number { Text("\(n)").foregroundStyle(.secondary).monospacedDigit() }
            Text(t.input.isEmpty ? "(no prompt)" : t.request)
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
