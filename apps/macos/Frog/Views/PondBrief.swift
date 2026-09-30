import SwiftUI

/// What frog noticed while you were away, under the frog on its lily pad: one line on what to
/// do first, what's next on your calendar, the few things worth your time, and beneath the
/// card a receipt for how the brief was made. Click a row to talk it through with frog (in your
/// clone of its repo when you have one); hover for ↗ to open it on GitHub, ✕ when it isn't
/// worth your time.
struct PondBrief: View {
    @State private var pond = Pond.shared

    var body: some View {
        // Always something on screen, so the task runs before there's a brief to show.
        VStack(spacing: 0) {
            if let brief = pond.brief {
                content(brief)
                    .transition(.opacity.combined(with: .offset(y: 6)))
            }
        }
        .animation(.snappy(duration: 0.35), value: pond.brief?.at)
        .animation(.snappy(duration: 0.25), value: pond.brief?.items)
        .task {
            await pond.show()
            // You've seen it: next time, only what's come in since is new.
            if NSApp.isActive, pond.brief?.items.contains(where: \.new) == true {
                try? await Task.sleep(for: .seconds(2))
                if !Task.isCancelled { pond.markSeen() }
            }
        }
    }

    private func content(_ brief: Brief) -> some View {
        VStack(spacing: 10) {
            card(brief)
            ReceiptLine(brief: brief, refreshing: pond.refreshing) {
                Task { await pond.refresh() }
            }
        }
        .frame(maxWidth: 440)
    }

    private func card(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(brief.headline)
                .font(.body.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, brief.items.isEmpty && (brief.today ?? []).isEmpty ? 14 : 8)
            if let today = brief.today, let line = NextUp(events: today) {
                line
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
            }
            if !brief.items.isEmpty {
                Divider().padding(.horizontal, 16)
                VStack(spacing: 0) {
                    ForEach(brief.items) { PondRow(line: $0) }
                }
                .padding(6)
            }
            if !brief.also.isEmpty {
                Text(brief.also.count == 1 ? "1 quieter thing can wait" : "\(brief.also.count) quieter things can wait")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

/// "Standup in 40 min · then Design review 1:24 PM".
private struct NextUp: View {
    let first: Brief.Event
    let rest: [Brief.Event]

    init?(events: [Brief.Event]) {
        let timed = events.filter { $0.allDay != true && ($0.date ?? .distantPast) > .now }
        guard let first = timed.first else { return nil }
        self.first = first
        rest = Array(timed.dropFirst().prefix(1))
    }

    private var when: String {
        guard let d = first.date else { return "" }
        let minutes = Int(d.timeIntervalSinceNow / 60)
        if minutes < 1 { return "now" }
        if minutes < 90 { return "in \(minutes) min" }
        return "at \(first.clock ?? "")"
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.tint)
            (Text(first.title).foregroundStyle(.primary) + Text(" \(when)").foregroundStyle(.secondary))
                .lineLimit(1)
            if !rest.isEmpty {
                Text("· then " + rest.map { "\($0.title) \($0.clock ?? "")" }.joined(separator: ", "))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .font(.callout)
    }
}

private struct PondRow: View {
    let line: Brief.Line
    @State private var hovering = false
    @State private var starting = false
    @Environment(\.startConversation) private var startConversation

    /// Click: a conversation about it, in your clone of its repo when you have one.
    private func open() {
        guard !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            guard let c = await Pond.shared.conversation(about: line) else {
                // Couldn't make the prompt (gh, or the pond moved on): the page is still there.
                if let url = line.link { NSWorkspace.shared.open(url) }
                return
            }
            startConversation?(c.folder, c.prompt)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.symbol(line.kind))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Self.tint(line.kind))
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(line.title)
                    .font(.callout)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ZStack(alignment: .trailing) {
                HStack(spacing: 5) {
                    // New since the last brief.
                    if line.new {
                        Circle().fill(.tint).frame(width: 5, height: 5)
                    }
                    Text(age)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                .opacity(hovering || starting ? 0 : 1)
                if starting {
                    ProgressView().controlSize(.mini)
                } else {
                    HStack(spacing: 2) {
                        RowButton(symbol: "arrow.up.right", help: "Open on GitHub") {
                            if let url = line.link { NSWorkspace.shared.open(url) }
                        }
                        RowButton(symbol: "xmark", help: "Not worth my time") {
                            Pond.shared.dismiss(line)
                        }
                    }
                    .opacity(hovering ? 1 : 0)
                }
            }
            .frame(minWidth: 24, alignment: .trailing)
            .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.primary.opacity(hovering ? 0.05 : 0), in: .rect(cornerRadius: 12))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture(perform: open)
        .help("Talk it through with frog")
    }

    /// "ecto/frog · alex asked for a review".
    private var detail: String {
        let what: String = switch line.kind {
        case "review": line.who.map { "\($0) asked for a review" } ?? "review requested"
        case "failing": "checks failing"
        case "changes_requested": "changes requested"
        case "mention": "mentioned you"
        case "assigned": "assigned to you"
        case "ready": "approved, ready to merge"
        default: line.note
        }
        return "\(line.place) · \(what)"
    }

    /// "now", "40m", "14h", "3d".
    private var age: String {
        guard let d = line.date else { return "" }
        let s = Int(Date.now.timeIntervalSince(d))
        switch s {
        case ..<60: return "now"
        case ..<3600: return "\(s / 60)m"
        case ..<86400: return "\(s / 3600)h"
        default: return "\(s / 86400)d"
        }
    }

    static func symbol(_ kind: String) -> String {
        switch kind {
        case "review": "eye"
        case "failing": "xmark.circle"
        case "changes_requested": "arrow.uturn.backward.circle"
        case "mention": "at"
        case "assigned": "person.crop.circle"
        case "ready": "checkmark.circle"
        default: "circle"
        }
    }

    static func tint(_ kind: String) -> Color {
        switch kind {
        case "failing": .red
        case "changes_requested": .orange
        case "ready": .green
        case "mention": .purple
        default: .accentColor
        }
    }
}

/// A small icon button that shows on a row's hover.
private struct RowButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(hovering ? .primary : .secondary)
                .frame(width: 22, height: 22)
                .background(.primary.opacity(hovering ? 0.08 : 0), in: .circle)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// Under the card, like a footnote: what was read, what wrote it, what left this Mac.
private struct ReceiptLine: View {
    let brief: Brief
    let refreshing: Bool
    let refresh: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: brief.receipt.privateBytes == 0 ? "lock.fill" : "arrow.up.forward")
                .font(.system(size: 9))
            Text(brief.receipt.summary)
                .lineLimit(1)
            Group {
                if refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .help("Look again")
                }
            }
            .opacity(hovering || refreshing ? 1 : 0)
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(when + brief.receipt.detail + (brief.trouble ?? []).map { "\n\($0)" }.joined())
    }

    private var when: String {
        brief.date.map { "Written \($0.formatted(.relative(presentation: .named)))\n" } ?? ""
    }
}
