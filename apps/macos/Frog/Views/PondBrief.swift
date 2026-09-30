import SwiftUI

/// What frog noticed while you were away, under the frog on its lily pad: a headline, the few
/// things worth your time, and a receipt for how the brief was made. Click a line to open it;
/// hover for ✕ when it isn't worth your time.
struct PondBrief: View {
    @State private var pond = Pond.shared

    var body: some View {
        // Always something on screen, so the task runs before there's a brief to show.
        VStack(spacing: 0) {
            if let brief = pond.brief {
                card(brief)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.snappy(duration: 0.3), value: pond.brief?.at)
        .animation(.snappy(duration: 0.25), value: pond.brief?.items)
        .task { await pond.show() }
    }

    private func card(_ brief: Brief) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(brief.headline)
                .font(.callout.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            if let today = brief.today, !today.isEmpty {
                todayRow(today)
            }
            if !brief.items.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(brief.items) { PondRow(line: $0) }
                }
            }
            if !brief.also.isEmpty {
                Text(brief.also.count == 1 ? "and 1 quieter thing" : "and \(brief.also.count) quieter things")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            receipt(brief)
        }
        .multilineTextAlignment(.leading)
        .padding(14)
        .frame(maxWidth: 460, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    /// What's left of today, as a quiet row: "10:30 Standup · 1:00 PM Design review".
    private func todayRow(_ events: [Brief.Event]) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .foregroundStyle(.tertiary)
            ForEach(Array(events.prefix(4).enumerated()), id: \.offset) { _, e in
                HStack(spacing: 4) {
                    if let clock = e.clock {
                        Text(clock).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Text(e.title).lineLimit(1)
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(.quaternary.opacity(0.5), in: .capsule)
            }
        }
        .font(.caption)
    }

    private func receipt(_ brief: Brief) -> some View {
        HStack(spacing: 5) {
            Image(systemName: brief.receipt.privateBytes == 0 ? "lock" : "arrow.up.forward")
            Text(brief.receipt.summary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if pond.refreshing {
                ProgressView().controlSize(.mini)
            } else {
                Button { Task { await pond.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help("Look again")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .help(when(brief) + brief.receipt.detail + (brief.trouble ?? []).map { "\n\($0)" }.joined())
    }

    private func when(_ brief: Brief) -> String {
        brief.date.map { "Written \($0.formatted(.relative(presentation: .named)))\n" } ?? ""
    }
}

private struct PondRow: View {
    let line: Brief.Line
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // New since the last brief: filled.
            Circle()
                .fill(line.new ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
                .frame(width: 6, height: 6)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(line.title)
                    .lineLimit(1)
                Text("\(line.place) · \(line.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button { Pond.shared.dismiss(line) } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Not worth my time")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .background(.quaternary.opacity(hovering ? 0.5 : 0), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .onTapGesture { if let url = line.link { NSWorkspace.shared.open(url) } }
        .help(line.url)
    }
}
